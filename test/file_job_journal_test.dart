import 'dart:convert';
import 'dart:io';
import 'package:koe/ai/engine_config.dart';
import 'package:koe/ai/speech_provider.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/state/file_job_journal.dart';
import 'package:koe/state/speech_configuration.dart';
import 'package:flutter_test/flutter_test.dart';

SpeechConfiguration config({
  String key = 'secret-not-on-disk',
  String url = 'https://example.com',
  String model = 'saved-model',
}) => SpeechConfiguration(
  provider: SttProvider.qwen,
  sourceLanguage: 'zh',
  targetLanguage: 'en',
  ownerLanguage: 'zh',
  guestLanguage: 'en',
  mode: SttDisplayMode.transcription,
  enabled: true,
  appleReady: false,
  appleTranslationReady: false,
  engines: {
    SttProvider.qwen: EngineConfig(apiKey: key, baseUrl: url, model: model),
  },
);
void main() {
  test(
    'retired pending jobs never resume while saved results retain provenance',
    () {
      for (final provider in ['moss', 'soniox']) {
        final original = FileJob(
          key: 'k',
          path: '/recording.wav',
          config: {...FileJob.snapshot(config()), 'provider': provider},
        );
        original.stage = 'running';
        original.taskId = 'paid-remote-task';
        final stopped = FileJob.fromJson(original.toJson());
        expect(stopped.recoverable, isFalse);
        expect(stopped.taskId, 'paid-remote-task');
        expect(stopped.error, contains('已停用'));
        original.stage = 'result';
        original.text = 'Saved text';
        final saved = FileJob.fromJson(original.toJson());
        expect(saved.recoverable, isTrue);
        expect(saved.text, 'Saved text');
        expect(saved.config['provider'], provider);
      }
    },
  );

  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('file-journal-test-');
    file = File('${directory.path}/jobs.json');
  });
  tearDown(() => directory.delete(recursive: true));
  test('two writers saving the same journal at once both succeed', () async {
    // A relaunch can open a second journal on the same file while the first
    // still writes; a shared temporary name let one rename the other's file
    // away, so the slower save failed with "Cannot rename file".
    final first = FileJobJournal(file: file);
    final second = FileJobJournal(file: file);
    await first.enqueue('a', '/a.wav', config());
    await second.enqueue('b', '/b.wav', config());
    for (var round = 0; round < 20; round++) {
      await Future.wait([first.save(), second.save()]);
    }
    expect(jsonDecode(await file.readAsString()), isA<List<dynamic>>());
  });
  test(
    'queued task survives restart without credentials and pins model',
    () async {
      await FileJobJournal(
        file: file,
      ).enqueue('recording', '/audio.wav', config());
      expect(await file.readAsString(), isNot(contains('secret-not-on-disk')));
      final recovered = FileJobJournal(file: file);
      await recovered.load();
      final job = recovered.jobs['recording']!;
      expect(job.recoverable, isTrue);
      final resolved = job.resolve(
        config(key: 'rotated-key', model: 'new-model'),
      );
      expect(resolved.engineConfig(SttProvider.qwen).model, 'saved-model');
      expect(resolved.engineKey(SttProvider.qwen), 'rotated-key');
      expect(
        job
            .resolve(config(url: 'https://new.example'))
            .engineKey(SttProvider.qwen),
        isNull,
      );
    },
  );
  test(
    'uncertain request blocks automatic retry; known task resumes',
    () async {
      final journal = FileJobJournal(file: file);
      final job = await journal.enqueue('a', '/a.wav', config());
      job
        ..stage = 'running'
        ..sent = true;
      await journal.save();
      final unknown = FileJobJournal(file: file);
      await unknown.load();
      expect(unknown.jobs['a']!.recoverable, isFalse);
      expect(unknown.jobs['a']!.error, contains('重复计费'));
      job.taskId = 'remote-task';
      await journal.save();
      final known = FileJobJournal(file: file);
      await known.load();
      expect(known.jobs['a']!.recoverable, isTrue);
      final retry = await known.enqueue(
        'a',
        '/a.wav',
        config(model: 'different'),
        retry: true,
      );
      expect(retry.taskId, 'remote-task');
      expect(retry.config['model'], 'saved-model');
    },
  );
  test(
    'a journal from before #426 reruns cut-off on-device work, not cloud runs',
    () async {
      Map<String, dynamic> running(String key, String provider) {
        final job = FileJob(
          key: key,
          path: '/$key.wav',
          config: {...FileJob.snapshot(config()), 'provider': provider},
        )..stage = 'running';
        return job.toJson()..remove('sent');
      }

      await file.writeAsString(
        jsonEncode([running('cloud', 'qwen'), running('device', 'apple')]),
      );
      final journal = FileJobJournal(file: file);
      await journal.load();
      expect(journal.jobs['cloud']!.recoverable, isFalse);
      expect(journal.jobs['cloud']!.error, contains('重复计费'));
      expect(journal.jobs['device']!.recoverable, isTrue);
    },
  );
  test(
    'saved result survives; completed task deduplicates; rename and delete persist',
    () async {
      final journal = FileJobJournal(file: file);
      final job = await journal.enqueue('a', '/a.wav', config());
      job.stage = 'result';
      job.text = 'saved text';
      await journal.save();
      final recovered = FileJobJournal(file: file);
      await recovered.load();
      expect(recovered.jobs['a']!.text, 'saved text');
      expect(recovered.jobs['a']!.recoverable, isTrue);
      recovered.jobs['a']!.stage = 'complete';
      await recovered.save();
      expect(
        (await recovered.enqueue('a', '/a.wav', config())).recoverable,
        isFalse,
      );
      await recovered.rename('a', 'b', '/b.wav');
      final renamed = FileJobJournal(file: file);
      await renamed.load();
      expect(renamed.jobs['b']!.path, '/b.wav');
      await renamed.discard('b');
      final empty = FileJobJournal(file: file);
      await empty.load();
      expect(empty.jobs, isEmpty);
    },
  );
  test('corruption blocks both recovery and new requests', () async {
    await file.writeAsString('{broken');
    final journal = FileJobJournal(file: file);
    await expectLater(journal.load(), throwsFormatException);
    await expectLater(
      journal.enqueue('a', '/a.wav', config()),
      throwsFormatException,
    );
    expect(await file.readAsString(), '{broken');
  });
  test('completed result keeps provider times across restart', () async {
    final journal = FileJobJournal(file: file);
    final job = await journal.enqueue('timed', '/timed.wav', config());
    job.stage = 'result';
    job.text = '第一句第二句';
    job.segments = const [
      SttSegment(
        text: '第一句',
        startMs: 0,
        endMs: 4200,
        speaker: '1',
        speakerChanged: true,
      ),
      SttSegment(
        text: '第二句',
        startMs: 4200,
        endMs: 9000,
        speaker: '2',
        speakerChanged: true,
      ),
    ];
    await journal.save();

    final recovered = FileJobJournal(file: file);
    await recovered.load();
    final timed = recovered.jobs['timed']!;
    expect(timed.text, '第一句第二句');
    expect(timed.segments, hasLength(2));
    expect(timed.segments[1].text, '第二句');
    expect(timed.segments[1].startMs, 4200);
    expect(timed.segments[1].speaker, '2');
    expect(timed.segments[1].speakerChanged, isTrue);
  });
}
