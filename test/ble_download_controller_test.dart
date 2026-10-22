import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:koe/ai/engine_config.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/ble/ble_service.dart';
import 'package:koe/state/file_job_journal.dart';
import 'package:koe/protocol/frame.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/protocol/slice_marks.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/wav_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _Ble ble;
  late RecorderController controller;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ble-download-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    ble = _Ble();
    controller = RecorderController(loadPersistedState: false, ble: ble)
      ..connected = true
      ..encryptReady = true
      ..phase = AppPhase.ready;
  });

  tearDown(() async {
    controller.autoRealtime = false;
    ble.finish();
    await _until(
      () =>
          !controller.autoTransferActive &&
          controller.downloadingFileId == null,
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await directory.delete(recursive: true);
  });

  Future<void> startBacklog() async {
    final exports = await Directory(
      '${directory.path}/AnkerRecorder/exports',
    ).create(recursive: true);
    await File('${exports.path}/101.wav').writeAsBytes(List.filled(200, 0));
    await controller.listFiles();
    ble.filePage([103, 102, 101]);
    await _until(() => ble.downloads.isNotEmpty);
    expect(ble.downloads.first, 103);
  }

  test('a copy saved before retrieved sizes were recorded that holds less '
      'than the device lists is not shown as downloaded', () async {
    controller.autoRealtime = false;
    final exports = await Directory(
      '${directory.path}/AnkerRecorder/exports',
    ).create(recursive: true);
    await File('${exports.path}/101.wav').writeAsBytes(List.filled(100, 0));
    await controller.refreshLocalFiles();
    expect(controller.localPathFor(101), isNotNull);

    await controller.listFiles();
    ble.filePage([101], size: 400);
    await _until(() => controller.files.isNotEmpty);
    await _until(() => controller.unexportedFiles.isNotEmpty);
    expect(
      controller.copyStatusOf(controller.files.single),
      DeviceCopyStatus.partial,
    );
  });

  test('a take the recorder kept recording through a link drop is not shown '
      'as downloaded and is retrieved again in full (#231)', () async {
    controller.dispose();
    ble = _Ble();
    controller =
        RecorderController(
            loadPersistedState: false,
            ble: ble,
            blePullInactivityTimeout: const Duration(milliseconds: 200),
            // Like the real conversion, the WAV is far larger than the raw
            // Opus payload the device lists.
            rawExportConverter: (raw) async {
              final wav = '${raw.substring(0, raw.lastIndexOf('.'))}.wav';
              await File(wav).writeAsBytes(
                wavBytes([...await File(raw).readAsBytes(), 0, 0]),
              );
              return wav;
            },
          )
          ..connected = true
          ..encryptReady = true
          ..phase = AppPhase.ready;

    // Recording starts while connected; the live stream saves what it gets.
    ble.recordStatus(104);
    await _until(() => ble.downloads.contains(104));
    ble.slice();
    await _until(() => controller.realtimeState.bytesReceived == 160);

    // The link drops; the recorder keeps recording on its own, then stops.
    ble.link(false);
    await _until(() => !controller.connected);
    await _until(() => controller.localPathFor(104)?.endsWith('.wav') ?? false);

    // Reconnected: the device file now also holds the audio from the gap.
    ble.link(true);
    controller
      ..connected = true
      ..encryptReady = true
      ..phase = AppPhase.ready;
    await controller.listFiles();
    ble.filePage([104], size: 480);
    await _until(() => controller.files.isNotEmpty);
    expect(controller.unexportedFiles.map((f) => f.fileId), [
      104,
    ], reason: 'the copy with the gap must not count as downloaded');
    await _until(() => ble.downloads.where((id) => id == 104).length == 2);

    // The whole device file again, replacing the copy with the gap.
    ble.slice();
    ble.slice();
    ble.finish();
    await _until(() => !controller.autoTransferActive);
    expect(controller.unexportedFiles, isEmpty);
    expect(
      await File('${directory.path}/AnkerRecorder/exports/104.opus').length(),
      480,
    );
  });

  test('a file the recorder is still paused on is not pulled until it ends, '
      'and the user is told how to end it (#253)', () async {
    controller.autoRealtime = true;
    ble.unfinished.add(105);
    ble.deviceStatus(2);
    await _until(() => controller.info?.recordingStatus == 2);
    await controller.listFiles();
    ble.filePage([105, 104]);

    // The recorder answers 105 with an unknown size; the backlog moves on.
    await _until(() => ble.downloads.contains(104));
    expect(ble.downloads, [105, 104]);
    ble.finish();
    await _until(() => !controller.autoTransferActive);
    expect(
      controller.errorMessage ?? '',
      isNot(contains('自动传输失败')),
      reason: 'not a transfer failure',
    );

    // Tapping it again explains instead of waiting for a pull to time out.
    await controller.downloadFileOverBle(
      OfflineFileEntry(fileId: 105, sizeBytes: 160),
    );
    expect(ble.downloads.where((id) => id == 105), hasLength(1));
    expect(controller.errorMessage, contains('按一下录音豆按键结束录音'));
    expect(
      controller.copyStatusOf(OfflineFileEntry(fileId: 105, sizeBytes: 160)),
      DeviceCopyStatus.unfinished,
    );

    // Ended on the recorder: it is pulled automatically.
    ble.unfinished.remove(105);
    ble.deviceStatus(0);
    await _until(() => controller.info?.recordingStatus == 0);
    ble.filePage([105, 104]);
    await _until(() => ble.downloads.where((id) => id == 105).length == 2);
    ble.finish();
    await _until(() => !controller.autoTransferActive);
    expect(controller.unexportedFiles, isEmpty);
  });

  test(
    'a double tap on the recorder becomes a bookmark at its moment',
    () async {
      controller.dispose();
      ble = _Ble();
      controller =
          RecorderController(
              loadPersistedState: false,
              ble: ble,
              rawExportConverter: (raw) async {
                final wav = '${raw.substring(0, raw.lastIndexOf('.'))}.wav';
                await File(
                  wav,
                ).writeAsBytes(wavBytes([...await File(raw).readAsBytes()]));
                return wav;
              },
            )
            ..autoRealtime = false
            ..connected = true
            ..encryptReady = true
            ..phase = AppPhase.ready;

      final work = controller.downloadFileOverBle(
        OfflineFileEntry(fileId: 106, sizeBytes: 480),
      );
      await _until(() => ble.downloads.contains(106));
      ble.slice(sequence: 0);
      // Slice 50 starts one second in: 50 × 20 ms.
      ble.slice(sequence: 50, flags: 0x01);
      ble.slice(sequence: 51);
      ble.finish();
      await work;

      final path = controller.localPathFor(106)!;
      final marks = controller.bookmarksFor(
        RecordingReference(fileId: 106, path: path),
      );
      expect(marks.map((b) => b.position), [const Duration(seconds: 1)]);
      expect(marks.single.note, SliceMark.bookmarkNote);
    },
  );

  test(
    'failed automatic downloads do not increment the completed count',
    () async {
      ble.failDownloads.add(103);
      await startBacklog();
      await _until(() => ble.downloads.length == 2);
      expect(controller.statusMessage, startsWith('自动传输 1/3'));
      expect(controller.localPathFor(103), isNull);
    },
  );

  test(
    'manual request during backlog preparation reserves the BLE puller',
    () async {
      Future<void>? manual;
      void request() {
        if (!controller.autoTransferActive || manual != null) return;
        controller.removeListener(request);
        manual = controller.downloadFileOverBle(
          controller.files.singleWhere((file) => file.fileId == 102),
        );
      }

      controller.addListener(request);
      await controller.listFiles();
      ble.filePage([103, 102]);
      await _until(() => ble.downloads.isNotEmpty);
      expect(ble.downloads, [102]);
      expect(controller.downloadingFileId, 102);
      ble.finish();
      await manual;
      await _until(() => ble.downloads.length == 2);
      expect(ble.downloads, [102, 103]);
    },
  );

  group('shared retrieval entry (#13)', () {
    late _Qwen qwen;
    late FileJobJournal journal;

    setUp(() async {
      controller.dispose();
      ble = _Ble();
      qwen = _Qwen();
      journal = FileJobJournal(inMemory: true);
      controller =
          RecorderController(
              loadPersistedState: false,
              meetingLocalOnly: false,
              ble: ble,
              qwenSpeech: qwen,
              fileJobJournal: journal,
              retrievedAudioSettleTime: Duration.zero,
              blePullInactivityTimeout: const Duration(milliseconds: 200),
              rawExportConverter: (raw) async {
                final wav = '${raw.substring(0, raw.lastIndexOf('.'))}.wav';
                // Like the real conversion, the WAV is larger than the raw
                // Opus payload and has a finished header even when cut short.
                await File(wav).writeAsBytes(
                  wavBytes([...await File(raw).readAsBytes(), 0, 0]),
                );
                return wav;
              },
            )
            ..connected = true
            ..encryptReady = true
            ..phase = AppPhase.ready;
      await controller.setQwenConfig(const EngineConfig(apiKey: 'key'));
      controller.setSpeechProvider(SttProvider.qwen);
      controller.setAutoTranscribe(true);
    });

    Future<void> completedJobs(int count) => _until(
      () =>
          journal.jobs.values.where((j) => j.stage == 'complete').length ==
          count,
    );

    test('BLE manual download submits through the shared entry', () async {
      final work = controller.downloadFileOverBle(
        OfflineFileEntry(fileId: 102, sizeBytes: 160),
      );
      await _until(() => ble.downloads.contains(102));
      ble.finish();
      await work;
      await completedJobs(1);
      expect(qwen.paths.single, endsWith('/102.wav'));
      expect(controller.transcriptForPath(qwen.paths.single), '通义文本');
    });

    test('BLE pull cut off after >= 95% is kept, not transcribed, and a later '
        'complete pull transcribes it', () async {
      // An earlier, fully retrieved and transcribed recording.
      final earlier = controller.downloadFileOverBle(
        OfflineFileEntry(fileId: 101, sizeBytes: 160),
      );
      await _until(() => ble.downloads.contains(101));
      ble.finish();
      await earlier;
      await completedJobs(1);
      final earlierPath = qwen.paths.single;
      expect(qwen.calls, 1);

      // The link drops after 160 of 168 bytes (95.2%): no done signal.
      final cut = controller.downloadFileOverBle(
        OfflineFileEntry(fileId: 102, sizeBytes: 168),
      );
      await _until(() => ble.downloads.contains(102));
      ble.slice();
      await cut;
      final partialPath = controller.localPathFor(102);
      expect(partialPath, isNotNull, reason: 'kept for playback');
      expect(File(partialPath!).existsSync(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(qwen.calls, 1, reason: 'partial BLE pull must not transcribe');
      expect(journal.jobs.keys.where((k) => k.contains('102')), isEmpty);
      expect(
        controller.recordingView(RecordingReference(path: partialPath)).error,
        contains('未完整取回'),
      );
      expect(
        controller.recordingAudioChanged(RecordingReference(path: earlierPath)),
        isFalse,
      );
      expect(journal.jobs.values.where((j) => j.audioChanged), isEmpty);
      expect(controller.transcriptForPath(earlierPath), '通义文本');

      // Retrieving again pulls the file instead of reusing the partial one.
      final again = controller.downloadFileOverBle(
        OfflineFileEntry(fileId: 102, sizeBytes: 168),
      );
      await _until(() => ble.downloads.where((id) => id == 102).length == 2);
      ble.finish();
      await again;
      await completedJobs(2);
      expect(qwen.calls, 2);
      expect(qwen.paths.last, endsWith('/102.wav'));
      expect(controller.transcriptForPath(qwen.paths.last), '通义文本');
      expect(
        controller.recordingView(RecordingReference(path: partialPath)).error,
        isNull,
      );
      expect(journal.jobs.values.where((j) => j.audioChanged), isEmpty);
    });

    test('a partial pull stays unexported after a restart and is pulled '
        'again', () async {
      // Same storage directory for the journal and the exports across both
      // controller lifetimes.
      final journalFile = File(
        '${directory.path}/AnkerRecorder/file_jobs.json',
      );
      RecorderController open(_Ble link) =>
          RecorderController(
              loadPersistedState: false,
              meetingLocalOnly: false,
              ble: link,
              qwenSpeech: qwen,
              fileJobJournal: FileJobJournal(file: journalFile),
              deviceCopies: DeviceCopies(directory: journalFile.parent),
              retrievedAudioSettleTime: Duration.zero,
              blePullInactivityTimeout: const Duration(milliseconds: 200),
              rawExportConverter: (raw) async {
                final wav = '${raw.substring(0, raw.lastIndexOf('.'))}.wav';
                await File(wav).writeAsBytes(
                  wavBytes([...await File(raw).readAsBytes(), 0, 0]),
                );
                return wav;
              },
            )
            ..connected = true
            ..encryptReady = true
            ..phase = AppPhase.ready;

      controller.dispose();
      ble = _Ble();
      controller = open(ble);
      // 160 of 168 bytes (95.2%), no done signal.
      final cut = controller.downloadFileOverBle(
        OfflineFileEntry(fileId: 102, sizeBytes: 168),
      );
      await _until(() => ble.downloads.contains(102));
      ble.slice();
      await cut;
      expect(controller.localPathFor(102), isNotNull);
      controller.autoRealtime = false;
      controller.dispose();
      await Future<void>.delayed(Duration.zero);

      // Restart: the device lists 102 at a size the partial WAV exceeds 95%
      // of, so only the persisted incomplete mark makes it pull again.
      ble = _Ble();
      controller = open(ble);
      await controller.setQwenConfig(const EngineConfig(apiKey: 'key'));
      controller.setSpeechProvider(SttProvider.qwen);
      controller.setAutoTranscribe(true);
      await controller.listFiles();
      ble.filePage([102]);
      await _until(() => ble.downloads.contains(102));
      ble.finish();
      await _until(
        () =>
            controller.transcriptForPath(controller.localPathFor(102)!) ==
            '通义文本',
      );
      expect(qwen.calls, 1);
    });

    test('BLE automatic download submits through the shared entry', () async {
      await controller.listFiles();
      ble.filePage([103]);
      await _until(() => ble.downloads.contains(103));
      ble.finish();
      await completedJobs(1);
      expect(qwen.paths.single, endsWith('/103.wav'));
      expect(qwen.calls, 1);
    });
  });
}

class _Qwen extends QwenSttService {
  int calls = 0;
  final paths = <String>[];

  @override
  Future<SttResult> transcribePath(
    String path, {
    String? apiKey,
    String? baseUrl,
    String? model,
    String? language,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  }) async {
    calls++;
    paths.add(path);
    return SttResult(text: '通义文本', sourcePath: path);
  }
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(
    ready(),
    isTrue,
    reason: 'BLE operation did not reach the expected state',
  );
}

class _Ble extends BleService {
  final _packets = StreamController<DecodedPacket>.broadcast();
  final downloads = <int>[];
  final failDownloads = <int>{};

  /// Files the recorder has not finished: their head reports an unknown size.
  final unfinished = <int>{};

  /// Device info carrying recording status 0 stopped, 1 recording, 2 paused.
  void deviceStatus(int status) {
    final raw = Uint8List(75)..[59] = status;
    _packets.add(
      DecodedPacket(
        raw: raw,
        statusByte: 1,
        cmdType: 1,
        cmdId: 1,
        payload: Uint8List.sublistView(raw, 9, 74),
      ),
    );
  }

  final _connection = StreamController<bool>.broadcast();

  void link(bool up) => _connection.add(up);

  /// `1A06`: the recorder started writing device file [fileId].
  void recordStatus(int fileId) {
    final payload = Uint8List(4)
      ..buffer.asByteData().setUint32(0, fileId, Endian.little);
    _packets.add(
      DecodedPacket(
        raw: Uint8List(0),
        statusByte: 1,
        cmdType: 0x1A,
        cmdId: 0x06,
        payload: payload,
      ),
    );
  }

  void filePage(List<int> ids, {int size = 160}) {
    final data = ByteData(2 + ids.length * 12)
      ..setUint16(0, ids.length, Endian.little);
    for (var i = 0; i < ids.length; i++) {
      data.setUint32(2 + i * 12, ids[i], Endian.little);
      data.setUint32(6 + i * 12, ids[i] + 1, Endian.little);
      data.setUint32(10 + i * 12, size, Endian.little);
    }
    _packets.add(
      DecodedPacket(
        raw: Uint8List(0),
        statusByte: 1,
        cmdType: 0x1B,
        cmdId: 0x0E,
        payload: data.buffer.asUint8List(),
      ),
    );
  }

  void finish() {
    slice();
    _emit(0x0A, Uint8List(10));
  }

  /// One 160-byte file slice without the done signal (link dropped).
  /// [flags] 0x01 is the recorder's double-tap mark.
  void slice({int sequence = 0, int flags = 0}) {
    final raw = Uint8List(175)..fillRange(14, 174, 1);
    raw.buffer.asByteData().setUint32(9, sequence, Endian.little);
    raw[13] = flags;
    _emit(0x08, raw);
  }

  void _emit(int id, Uint8List raw) => _packets.add(
    DecodedPacket(
      raw: raw,
      statusByte: 1,
      cmdType: 0x1A,
      cmdId: id,
      payload: Uint8List(0),
    ),
  );

  @override
  Stream<DecodedPacket> get packets => _packets.stream;
  @override
  Stream<List<ScannedDevice>> get scanResults => const Stream.empty();
  @override
  Stream<bool> get connectionState => _connection.stream;
  @override
  Stream<String> get logs => const Stream.empty();
  @override
  bool get isConnected => true;
  @override
  Future<void> writeCommand(List<int> frame) async {
    if (frame[5] == 0x1A && frame[6] == 0x07) {
      final id = readU32Le(Uint8List.fromList(frame), 13);
      downloads.add(id);
      if (failDownloads.contains(id)) throw StateError('BLE request failed');
      if (unfinished.contains(id)) {
        final head = Uint8List(97)
          ..buffer.asByteData().setUint32(9, id, Endian.little);
        head.buffer.asByteData().setUint32(13, 0xFFFFFFFF, Endian.little);
        _emit(0x07, head);
        return;
      }
      _emit(0x07, Uint8List(10));
    }
  }

  @override
  Future<void> dispose() async {
    await _packets.close();
    await _connection.close();
  }
}
