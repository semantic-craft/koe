import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/engine_config.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/ble/ble_service.dart';
import 'package:koe/protocol/frame.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/state/file_job_journal.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/wifi/wifi_export_service.dart';

// #13: BLE automatic, BLE manual and Wi-Fi export completions all reach the
// same automatic-transcription entry with audio-version deduplication, and
// audio that the transfer did not finish, that is not a complete WAV or that
// is still growing is kept but never submitted (and never marks an existing
// result as changed).

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _Ble ble;
  late _Wifi wifi;
  late _Qwen qwen;
  late FileJobJournal journal;
  late RecorderController controller;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('retrieval-entry-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    ble = _Ble();
    wifi = _Wifi(ble.packets, directory);
    qwen = _Qwen();
    journal = FileJobJournal(inMemory: true);
    controller =
        RecorderController(
            loadPersistedState: false,
            ble: ble,
            qwenSpeech: qwen,
            fileJobJournal: journal,
            wifiExport: wifi,
            wavConverter: _fakeWav,
          )
          ..connected = true
          ..encryptReady = true
          ..phase = AppPhase.ready;
    await controller.setQwenConfig(const EngineConfig(apiKey: 'key'));
    controller
      ..setSpeechProvider(SttProvider.qwen)
      ..setAutoTranscribe(true);
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

  bool jobsComplete(int count) =>
      journal.jobs.values.where((job) => job.stage == 'complete').length ==
      count;

  String? errorFor(String path) =>
      controller.recordingView(RecordingReference(path: path)).error;

  Future<void> listDeviceFiles(List<int> ids) async {
    await controller.listFiles();
    ble.filePage(ids);
    await _until(() => controller.files.length == ids.length);
  }

  group('BLE and Wi-Fi completions share one entry', () {
    test('BLE manual download is submitted once; repeats deduplicate',
        () async {
      controller.autoRealtime = false;
      await listDeviceFiles([201]);
      final work = controller.downloadFileOverBle(controller.files.single);
      await _until(() => ble.downloads.contains(201));
      ble.finish();
      await work;
      final path = controller.localPathFor(201)!;
      expect(path, endsWith('201.wav'));
      await _until(() => qwen.calls == 1 && jobsComplete(1));
      expect(qwen.paths, [path]);
      expect(controller.transcriptForPath(path), '通义文本');

      // A repeated completion event for the same audio submits nothing.
      await controller.processRetrievedRecording(path);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(qwen.calls, 1);
      expect(journal.jobs, hasLength(1));
    });

    test('BLE automatic transfer is submitted through the same entry',
        () async {
      await listDeviceFiles([301]);
      await _until(() => ble.downloads.contains(301));
      ble.finish();
      await _until(() => qwen.calls == 1 && jobsComplete(1));
      final path = controller.localPathFor(301)!;
      expect(qwen.paths, [path]);

      await controller.processRetrievedRecording(path);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(qwen.calls, 1);
    });

    test('Wi-Fi export submits finished files and keeps partial ones',
        () async {
      controller.autoRealtime = false;
      wifi.incompleteIds.add(402);
      await listDeviceFiles([402, 401]);
      final endpoint = await controller.beginWifiExport();
      expect(endpoint, isNotNull, reason: controller.errorMessage);
      controller.exportProgress = ExportProgress(
        phase: ExportPhase.awaitJoin,
        endpoint: endpoint,
      );
      final paths = await controller.continueWifiExport();
      expect(paths, hasLength(2));

      await _until(() => qwen.calls == 1 && jobsComplete(1));
      final finished = controller.localPathFor(401)!;
      final partial = controller.localPathFor(402)!;
      expect(qwen.paths, [finished]);
      expect(File(partial).existsSync(), isTrue, reason: 'partial kept');
      expect(errorFor(partial), contains('未完整取回'));
      expect(journal.jobs, hasLength(1));

      // Re-delivering the finished file through the entry deduplicates.
      await controller.processRetrievedRecording(finished);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(qwen.calls, 1);
    });
  });

  group('incomplete or growing audio is not submitted', () {
    late String path;
    setUp(() => path = '${directory.path}/501.wav');

    test('a WAV still being written is kept, then submitted once finished',
        () async {
      // Header patched for 320 bytes, only 160 written so far.
      await File(path).writeAsBytes(
        _wav(List.filled(160, 1), dataSize: 320, riffSize: 36 + 320),
      );
      await controller.processRetrievedRecording(path);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(qwen.calls, 0);
      expect(journal.jobs, isEmpty);
      expect(errorFor(path), contains('尚未完整写入'));
      expect(File(path).existsSync(), isTrue);

      await File(path).writeAsBytes(_wav(List.filled(320, 1)));
      await controller.processRetrievedRecording(path);
      await _until(() => qwen.calls == 1 && jobsComplete(1));
      expect(errorFor(path), isNull);
    });

    test('an unfinished transfer is not submitted', () async {
      await File(path).writeAsBytes(_wav(List.filled(320, 1)));
      await controller.processRetrievedRecording(
        path,
        transferComplete: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(qwen.calls, 0);
      expect(journal.jobs, isEmpty);
      expect(errorFor(path), contains('未完整取回'));
    });

    test('incomplete re-delivery never marks an existing result as changed',
        () async {
      await File(path).writeAsBytes(_wav(List.filled(320, 1)));
      await controller.processRetrievedRecording(path);
      await _until(() => qwen.calls == 1 && jobsComplete(1));
      final job = journal.jobs.values.single;

      // Same file number, different audio, but truncated mid-write.
      await File(path).writeAsBytes(
        _wav(List.filled(160, 9), dataSize: 320, riffSize: 36 + 320),
      );
      await controller.processRetrievedRecording(path);
      expect(job.audioChanged, isFalse);
      expect(errorFor(path), contains('尚未完整写入'));

      // Different, well-formed audio from a transfer that did not finish.
      await File(path).writeAsBytes(_wav(List.filled(320, 9)));
      await controller.processRetrievedRecording(
        path,
        transferComplete: false,
      );
      expect(job.audioChanged, isFalse);
      expect(errorFor(path), contains('未完整取回'));
      expect(controller.transcriptForPath(path), '通义文本');
      expect(qwen.calls, 1);
    });
  });
}

/// Stand-in for the Opus decoder (native in the app): wraps the raw bytes in
/// a complete WAV next to the raw file, like the real converter's output.
Future<String> _fakeWav(String rawPath) async {
  final wavPath = rawPath.replaceFirst(RegExp(r'\.opus$'), '.wav');
  await File(wavPath).writeAsBytes(_wav(await File(rawPath).readAsBytes()));
  return wavPath;
}

Uint8List _wav(List<int> pcm, {int? dataSize, int? riffSize}) {
  final header = ByteData(44);
  void ascii(int offset, String value) {
    for (var i = 0; i < 4; i++) {
      header.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, riffSize ?? 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, 16000, Endian.little);
  header.setUint32(28, 32000, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, dataSize ?? pcm.length, Endian.little);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...pcm]);
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue, reason: 'did not reach the expected state');
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
    return SttResult(
      text: '通义文本',
      sourcePath: path,
      language: language ?? 'auto',
    );
  }
}

/// Wi-Fi export without a socket: writes one raw file per requested
/// recording and reports [incompleteIds] as partial receives.
class _Wifi extends WifiExportService {
  _Wifi(Stream<DecodedPacket> packets, this.root)
    : super(blePackets: packets, bleWrite: (_) async {});

  final Directory root;
  final incompleteIds = <int>{};
  final _incomplete = <String>{};

  @override
  Future<WifiEndpoint> openSoftAp({
    String? ssid,
    String? password,
    Duration timeout = const Duration(seconds: 45),
    Duration startupDelay = Duration.zero,
    Future<void> Function()? onConfigured,
  }) async => WifiEndpoint(
    ssid: 'soundcore-test',
    password: 'password',
    ip: '192.168.4.1',
    port: 8080,
  );

  @override
  Future<List<String>> transferFiles({
    required WifiEndpoint endpoint,
    required List<OfflineFileEntry> files,
    bool useSsl = true,
  }) async {
    final exports = await Directory(
      '${root.path}/AnkerRecorder/exports',
    ).create(recursive: true);
    final paths = <String>[];
    for (final file in files) {
      final path = '${exports.path}/${file.fileId}.opus';
      await File(path).writeAsBytes(List.filled(160, file.fileId % 251));
      if (incompleteIds.contains(file.fileId)) {
        _incomplete.add(path);
      } else {
        _incomplete.remove(path);
      }
      paths.add(path);
    }
    return paths;
  }

  @override
  bool isIncomplete(String path) => _incomplete.contains(path);
}

class _Ble extends BleService {
  final _packets = StreamController<DecodedPacket>.broadcast();
  final downloads = <int>[];

  void filePage(List<int> ids) {
    final data = ByteData(2 + ids.length * 12)
      ..setUint16(0, ids.length, Endian.little);
    for (var i = 0; i < ids.length; i++) {
      data.setUint32(2 + i * 12, ids[i], Endian.little);
      data.setUint32(6 + i * 12, ids[i] + 1, Endian.little);
      data.setUint32(10 + i * 12, 160, Endian.little);
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
    final raw = Uint8List(175)..fillRange(14, 174, 1);
    _emit(0x08, raw);
    _emit(0x0A, Uint8List(10));
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
  Stream<bool> get connectionState => const Stream.empty();
  @override
  Stream<String> get logs => const Stream.empty();
  @override
  bool get isConnected => true;
  @override
  Future<void> writeCommand(List<int> frame) async {
    if (frame[5] == 0x1A && frame[6] == 0x07) {
      downloads.add(readU32Le(Uint8List.fromList(frame), 13));
      _emit(0x07, Uint8List(10));
    }
  }

  @override
  Future<void> dispose() => _packets.close();
}
