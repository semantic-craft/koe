import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/apple_speech.dart';
import 'package:koe/ai/doubao_stt.dart';
import 'package:koe/ai/engine_config.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/state/file_job_journal.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:path_provider/path_provider.dart';

import 'support/wav_fixture.dart';
import 'support/temp_dir.dart';

/// #10: every file-job stage (queued / upload / submit / poll / save) must
/// fail visibly, keep the recording, and recover after a controller restart
/// without automatically resubmitting a request whose outcome is unknown.
///
/// Each test drives the real controller and a real on-disk journal; only the
/// cloud service is faked so no paid API is called.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late File journalFile;
  late File audio;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('stage-recovery-');
    journalFile = File('${dir.path}/file_jobs.json');
    audio = File('${dir.path}/551100.wav');
    // A finished WAV: retrieved audio must pass the #13 completeness check.
    await audio.writeAsBytes(wavBytes([1, 2, 3, 4]));
  });
  tearDown(() => deleteTemporaryDirectory(dir));

  /// Opens a controller over [journal] the way a relaunch would: the journal
  /// is read from disk and recoverable jobs are resumed automatically.
  Future<RecorderController> open(
    FileJobJournal journal, {
    QwenSttService? qwen,
    DoubaoSttService? doubao,
    AppleSpeechService? apple,
    SttProvider provider = SttProvider.qwen,
    bool disposeOnTearDown = true,
  }) async {
    qwen?.apiKeyOverride = 'key';
    doubao?.apiKeyOverride = 'key';
    final c = RecorderController(
      loadPersistedState: false,
      meetingLocalOnly: false,
      qwenSpeech: qwen,
      doubaoSpeech: doubao,
      appleSpeech: apple,
      fileJobJournal: journal,
      // Stage recovery is not about the #13 completeness window.
      retrievedAudioSettleTime: Duration.zero,
    );
    if (disposeOnTearDown) addTearDown(c.dispose);
    if (qwen != null) await c.setQwenConfig(const EngineConfig(apiKey: 'key'));
    if (doubao != null) {
      await c.setDoubaoConfig(const EngineConfig(apiKey: 'key'));
    }
    if (apple != null) await c.refreshAppleCapabilities();
    c.setSpeechProvider(provider);
    c.setAutoTranscribe(true);
    return c;
  }

  Future<FileJob> reread() async {
    final journal = FileJobJournal(file: journalFile);
    await journal.load();
    return journal.jobs.values.single;
  }

  /// Reads the journal back from disk once the asynchronous write landed.
  Future<FileJob> onDisk(String stage) async {
    for (var i = 0; i < 200; i++) {
      final job = await reread();
      if (job.stage == stage) return job;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final job = await reread();
    expect(job.stage, stage, reason: 'journal on disk');
    return job;
  }

  /// The single job's stage, or null while a reopened journal is still being
  /// read from disk: `open` returns before the controller finishes loading it.
  String? stageOf(FileJobJournal journal) =>
      journal.jobs.values.singleOrNull?.stage;

  RecordingViewData view(RecorderController c) =>
      c.recordingView(RecordingReference(path: audio.path));

  /// Waits until the failed first run has fully ended. Its error is set before
  /// its last journal write, and the busy flag clears only after that write.
  /// A restart opens a second journal on the same file, so reopening earlier
  /// lets the two writers race on `file_jobs.json.tmp` (#64).
  Future<void> failedRunEnded(RecorderController c) =>
      settleUntil(() => view(c).error != null && !c.fileProcessingBusy);

  /// Lets the restored queue run; it must not make any call by itself.
  Future<void> idle() => Future<void>.delayed(const Duration(milliseconds: 60));

  group('queued', () {
    test(
      'missing audio at restart fails readably and is never auto-retried',
      () async {
        final first = FileJobJournal(file: journalFile);
        final c = await open(
          first,
          qwen: _StagedQwen()..gate = Completer(),
          disposeOnTearDown: false,
        );
        await c.processRetrievedRecording(audio.path);
        await settleUntil(() => stageOf(first) == 'running');
        c.dispose();
        // Rewind the on-disk record to "queued" as if the app died before the
        // pump started, then remove the audio before relaunch.
        final saved = FileJobJournal(file: journalFile);
        await saved.load();
        saved.jobs.values.single
          ..stage = 'queued'
          ..error = null;
        await saved.save();
        await audio.delete();

        final qwen = _StagedQwen();
        final restarted = FileJobJournal(file: journalFile);
        final r = await open(restarted, qwen: qwen);
        await settleUntil(() => stageOf(restarted) == 'failed');
        expect(qwen.calls, 0, reason: 'no request for a missing recording');
        expect(view(r).error, isNotNull);
        await onDisk('failed');

        final again = FileJobJournal(file: journalFile);
        await open(again, qwen: qwen);
        await idle();
        expect(qwen.calls, 0, reason: 'a failed queued job is not replayed');
      },
    );
  });

  group('upload / submit', () {
    for (final stage in [_Fail.upload, _Fail.submit]) {
      test('${stage.name} failure keeps the recording, persists a readable '
          'error and is not resubmitted on restart', () async {
        final qwen = _StagedQwen()..failAt = stage;
        final journal = FileJobJournal(file: journalFile);
        final c = await open(journal, qwen: qwen);
        await c.processRetrievedRecording(audio.path);
        await settleUntil(() => stageOf(journal) == 'failed');
        expect(qwen.calls, 1);
        expect(view(c).error, isNotNull);
        expect(view(c).text, isEmpty);
        expect(c.statusMessage, isNot('转写已保存'));
        final saved = await onDisk('failed');
        expect(saved.taskId, isNull);
        expect(saved.error, isNotNull);
        expect(await audio.exists(), isTrue);

        // Relaunch: the unknown/failed paid request must not be replayed.
        final retry = _StagedQwen();
        final reopened = FileJobJournal(file: journalFile);
        final r = await open(reopened, qwen: retry);
        await idle();
        expect(retry.calls, 0);
        expect(view(r).error, isNotNull);

        // An explicit retry is the only way to pay again.
        await r.transcribeLocalFile(audio.path);
        expect(retry.calls, 1);
        expect(retry.uploads, 1);
        await onDisk('complete');
        expect(r.transcriptForPath(audio.path), '通义文本 task-1');
      });
    }

    test(
      'task ID checkpoint write failure never resubmits the paid task',
      () async {
        final qwen = _StagedQwen();
        final journal = _FailingJournal(
          journalFile,
          when: (jobs) => jobs.any((j) => j.taskId != null),
        );
        final c = await open(journal, qwen: qwen);
        await c.processRetrievedRecording(audio.path);
        await settleUntil(() => view(c).error != null);
        expect(qwen.uploads, 1);
        expect(view(c).error, contains('存储空间'));
        expect(view(c).text, isEmpty);
        expect(c.statusMessage, isNot('转写已保存'));
        // Disk holds "running" without an ID: outcome unknown.
        final saved = await onDisk('running');
        expect(saved.taskId, isNull);

        final retry = _StagedQwen();
        final reopened = FileJobJournal(file: journalFile);
        final r = await open(reopened, qwen: retry);
        await idle();
        expect(retry.calls, 0, reason: 'unknown submission is not replayed');
        expect(view(r).error, contains('重复计费'));
      },
    );
  });

  group('poll', () {
    test('network failure while polling keeps the task ID; restart queries the '
        'same task without uploading again', () async {
      final qwen = _StagedQwen()..failAt = _Fail.poll;
      final journal = FileJobJournal(file: journalFile);
      final c = await open(journal, qwen: qwen);
      await c.processRetrievedRecording(audio.path);
      await failedRunEnded(c);
      expect(qwen.uploads, 1);
      final saved = await onDisk('running');
      expect(saved.taskId, 'task-1');
      expect(view(c).text, isEmpty);

      final resumed = _StagedQwen();
      final reopened = FileJobJournal(file: journalFile);
      final r = await open(reopened, qwen: resumed);
      // The complete stage is published before its final disk write ends.
      // Do not dispose or remove the journal directory while it is still busy.
      await settleUntil(
        () => stageOf(reopened) == 'complete' && !r.fileProcessingBusy,
      );
      expect(resumed.calls, 1);
      expect(resumed.uploads, 0, reason: 'only GET on the saved task');
      expect(resumed.seenTaskIds, ['task-1']);
      expect(r.transcriptForPath(audio.path), '通义文本 task-1');
    });

    test(
      'remote task failure clears the task and waits for an explicit retry',
      () async {
        final qwen = _StagedQwen()..failAt = _Fail.remote;
        final journal = FileJobJournal(file: journalFile);
        final c = await open(journal, qwen: qwen);
        await c.processRetrievedRecording(audio.path);
        await settleUntil(() => stageOf(journal) == 'failed');
        expect(view(c).error, contains('通义转写失败'));
        expect((await onDisk('failed')).taskId, isNull);

        final retry = _StagedQwen();
        await open(FileJobJournal(file: journalFile), qwen: retry);
        await idle();
        expect(retry.calls, 0);
      },
    );
  });

  group('save', () {
    test('transcript store failure does not report success; restart saves the '
        'returned text without a second request', () async {
      final docs = await getApplicationDocumentsDirectory();
      // A directory where the transcript file must go makes the write fail.
      final blocker = Directory('${docs.path}/AnkerRecorder/transcripts.json');
      await blocker.create(recursive: true);
      addTearDown(() async {
        if (await blocker.exists()) await blocker.delete(recursive: true);
      });

      final qwen = _StagedQwen();
      final journal = FileJobJournal(file: journalFile);
      final c = await open(journal, qwen: qwen);
      await c.processRetrievedRecording(audio.path);
      await failedRunEnded(c);
      expect(qwen.calls, 1);
      expect(c.statusMessage, isNot('转写已保存'));
      expect(view(c).error, contains('未能保存'));
      final saved = await onDisk('result');
      expect(saved.text, '通义文本 task-1');

      await blocker.delete(recursive: true);
      final resumed = _StagedQwen();
      final reopened = FileJobJournal(file: journalFile);
      final r = await open(reopened, qwen: resumed);
      await settleUntil(() => stageOf(reopened) == 'complete');
      expect(resumed.calls, 0, reason: 'saved result is reused');
      expect(r.transcriptForPath(audio.path), '通义文本 task-1');
      await settleUntil(() => r.statusMessage == '转写已保存');
      expect(r.statusMessage, '转写已保存');
    });

    test('journal failure when recording the result does not show the text as '
        'saved; restart re-queries the known task without uploading', () async {
      final qwen = _StagedQwen();
      final journal = _FailingJournal(
        journalFile,
        when: (jobs) => jobs.any((j) => j.stage == 'result'),
      );
      final c = await open(journal, qwen: qwen);
      await c.processRetrievedRecording(audio.path);
      await settleUntil(() => view(c).error != null);
      expect(view(c).error, contains('存储空间'));
      expect(view(c).text, isEmpty);
      expect(c.statusMessage, isNot('转写已保存'));
      final saved = await onDisk('running');
      expect(saved.taskId, 'task-1');

      final resumed = _StagedQwen();
      final reopened = FileJobJournal(file: journalFile);
      final r = await open(reopened, qwen: resumed);
      // As in the poll test: wait for the final disk write, not just the stage.
      await settleUntil(
        () => stageOf(reopened) == 'complete' && !r.fileProcessingBusy,
      );
      expect(resumed.uploads, 0);
      expect(resumed.seenTaskIds, ['task-1']);
    });
  });

  group('synchronous service (Doubao)', () {
    test('process exit while the answer is outstanding keeps a readable retry '
        'entry and never auto-resubmits', () async {
      final hanging = _HangingDoubao();
      final journal = FileJobJournal(file: journalFile);
      final c = await open(
        journal,
        doubao: hanging,
        provider: SttProvider.doubao,
        disposeOnTearDown: false,
      );
      await c.processRetrievedRecording(audio.path);
      await settleUntil(() => hanging.calls == 1);
      await onDisk('running');
      c.dispose(); // the process "dies" while the response is outstanding

      await onDisk('running');
      final retry = _HangingDoubao()..complete = true;
      final reopened = FileJobJournal(file: journalFile);
      final r = await open(
        reopened,
        doubao: retry,
        provider: SttProvider.doubao,
      );
      await idle();
      expect(retry.calls, 0);
      expect(view(r).error, contains('重复计费'));
      expect(await audio.exists(), isTrue);

      await r.transcribeLocalFile(audio.path);
      expect(retry.calls, 1);
      expect(r.transcriptForPath(audio.path), '豆包文本');
      await onDisk('complete');
    });
  });

  // #426: Koe quits or crashes in the middle of a job that nothing has been
  // charged for yet; the next launch puts it back in the queue and runs it.
  group('cut off before anything was charged', () {
    test('an upload under way runs again on the next launch', () async {
      final uploading = _StagedQwen()..gate = Completer();
      final first = FileJobJournal(file: journalFile);
      final c = await open(first, qwen: uploading, disposeOnTearDown: false);
      await c.processRetrievedRecording(audio.path);
      await settleUntil(() => uploading.calls == 1);
      await onDisk('running');
      c.dispose();

      final qwen = _StagedQwen();
      final reopened = FileJobJournal(file: journalFile);
      final r = await open(reopened, qwen: qwen);
      await settleUntil(
        () => stageOf(reopened) == 'complete' && !r.fileProcessingBusy,
      );
      expect(qwen.uploads, 1);
      expect(r.transcriptForPath(audio.path), '通义文本 task-1');
    });

    test('a Doubao upload under way runs again on the next launch', () async {
      final uploading = _HangingDoubao()..midUpload = true;
      final first = FileJobJournal(file: journalFile);
      final c = await open(
        first,
        doubao: uploading,
        provider: SttProvider.doubao,
        disposeOnTearDown: false,
      );
      await c.processRetrievedRecording(audio.path);
      await settleUntil(() => uploading.calls == 1);
      await onDisk('running');
      c.dispose();

      final doubao = _HangingDoubao()..complete = true;
      final reopened = FileJobJournal(file: journalFile);
      final r = await open(
        reopened,
        doubao: doubao,
        provider: SttProvider.doubao,
      );
      await settleUntil(
        () => stageOf(reopened) == 'complete' && !r.fileProcessingBusy,
      );
      expect(doubao.calls, 1);
      expect(r.transcriptForPath(audio.path), '豆包文本');
    });

    test('on-device transcription runs again on the next launch', () async {
      final busy = _HangingApple();
      final first = FileJobJournal(file: journalFile);
      final c = await open(
        first,
        apple: busy,
        provider: SttProvider.apple,
        disposeOnTearDown: false,
      );
      unawaited(c.transcribeLocalFile(audio.path));
      await settleUntil(() => busy.calls == 1);
      await onDisk('running');
      c.dispose();

      final apple = _HangingApple()..complete = true;
      final reopened = FileJobJournal(file: journalFile);
      final r = await open(reopened, apple: apple, provider: SttProvider.apple);
      await settleUntil(
        () => stageOf(reopened) == 'complete' && !r.fileProcessingBusy,
      );
      expect(apple.calls, 1);
      expect(r.transcriptForPath(audio.path), '本机文本');
    });
  });
}

enum _Fail { none, upload, submit, poll, remote }

/// Mirrors QwenSttService's stage order: upload → onSending checkpoint →
/// submit → onSubmitted checkpoint → poll → fetch. A saved task ID skips
/// upload and submit.
class _StagedQwen extends QwenSttService {
  _Fail failAt = _Fail.none;
  Completer<void>? gate;
  int calls = 0;
  int uploads = 0;
  final seenTaskIds = <String?>[];

  @override
  Future<SttResult> transcribePath(
    String path, {
    String? apiKey,
    String? baseUrl,
    String? model,
    String? language,
    int? expectedSpeakers,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  }) async {
    calls++;
    final checkpoint = recovery;
    seenTaskIds.add(checkpoint?.taskId);
    if (gate != null) await gate!.future;
    var taskId = checkpoint?.taskId;
    if (taskId == null) {
      uploads++;
      if (failAt == _Fail.upload) {
        throw const SocketException('connection reset during upload');
      }
      await onSending?.call();
      if (failAt == _Fail.submit) {
        throw TimeoutException('submit response lost');
      }
      taskId = 'task-$uploads';
      await checkpoint?.onSubmitted(taskId);
    }
    if (failAt == _Fail.poll) throw const SocketException('offline');
    if (failAt == _Fail.remote) {
      throw const QwenTaskFailedException('通义转写失败：FAILED');
    }
    return SttResult(text: '通义文本 $taskId', sourcePath: path, language: 'zh');
  }
}

/// Waits on Doubao forever unless [complete]: after the whole request went
/// out, or with [midUpload] while the audio is still going up.
class _HangingDoubao extends DoubaoSttService {
  bool complete = false;
  bool midUpload = false;
  int calls = 0;

  @override
  Future<SttResult> transcribePath(
    String path, {
    String? apiKey,
    String? baseUrl,
    String? model,
    String? language,
    int? expectedSpeakers,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  }) async {
    calls++;
    if (!midUpload) await onSending?.call();
    if (!complete) await Completer<void>().future;
    return SttResult(text: '豆包文本', sourcePath: path, language: 'zh');
  }
}

/// On-device recognition that never finishes unless [complete].
class _HangingApple extends AppleSpeechService {
  bool complete = false;
  int calls = 0;

  @override
  bool get offered => true;

  @override
  Future<AppleSpeechCapabilities> capabilities({
    String? sourceLanguage,
    String? targetLanguage,
  }) async => const AppleSpeechCapabilities(
    supported: true,
    speechStatus: SpeechResourceStatus.ready,
    translationStatus: SpeechResourceStatus.ready,
    suggestedSourceLanguage: 'zh-CN',
    speechLanguages: [SpeechLanguage(code: 'zh-CN', name: '简体中文')],
  );

  @override
  Future<SttResult> transcribePath(
    String path, {
    required String sourceLanguage,
    SttFileProgressCallback? onProgress,
  }) async {
    calls++;
    if (!complete) await Completer<void>().future;
    return SttResult(text: '本机文本', sourcePath: path, language: sourceLanguage);
  }
}

/// A real on-disk journal whose writes fail once [when] matches, emulating a
/// full disk at a specific stage.
class _FailingJournal extends FileJobJournal {
  _FailingJournal(File file, {required this.when}) : super(file: file);
  final bool Function(Iterable<FileJob>) when;
  @override
  Future<void> save() async {
    await load();
    if (when(jobs.values)) throw const FileSystemException('disk full');
    return super.save();
  }
}

Future<void> settleUntil(bool Function() predicate) async {
  for (var i = 0; i < 200; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(predicate(), isTrue, reason: 'condition did not settle');
}
