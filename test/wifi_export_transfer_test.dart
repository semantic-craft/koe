import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/protocol/frame.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/wifi/wifi_export_service.dart';
import 'package:path/path.dart' as p;

import 'support/fake_wifi_recorder.dart';

/// How a Wi‑Fi export ends on the recorder's real behavior (#437): file heads
/// count 166-byte units, done markers can come again after Koe moved on, and
/// the recorder turns its hotspot off on its own.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding answers every HttpClient request with 400; the export
  // needs a real WebSocket handshake with the fake recorder.
  HttpOverrides.global = null;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory documents;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('wifi-export-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => documents.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await documents.delete(recursive: true);
  });

  WifiExportService serviceFor(FakeWifiRecorder recorder) {
    final service = WifiExportService(
      blePackets: const Stream<DecodedPacket>.empty(),
      bleWrite: (_) async {},
      link: FakeSoftApLink(recorderPort: recorder.port),
      useSsl: false,
    );
    addTearDown(() async {
      await recorder.close();
      await service.dispose();
    });
    return service;
  }

  Future<List<String>> transfer(WifiExportService service, List<int> ids) =>
      service
          .transferFiles(
            endpoint: WifiEndpoint(
              ssid: 'WiFi-1761100000000',
              password: '1761100000000',
              ip: '192.0.2.1',
              port: 443,
            ),
            // The file list's size is not in the head's units.
            files: [
              for (final id in ids)
                OfflineFileEntry(fileId: id, sizeBytes: 21600),
            ],
          )
          .timeout(const Duration(seconds: 5));

  test('a file whose announced units have all arrived is saved complete at '
      '100 %, without waiting for the done marker', () async {
    final audio = recorderAudio(1761100001, units: 3);
    final recorder = await FakeWifiRecorder.start((socket, fileId) {
      socket.add([
        ...FakeWifiRecorder.head(fileId, units: 3),
        ...FakeWifiRecorder.slices(audio),
      ]);
    });
    final service = serviceFor(recorder);
    final seen = <ExportProgress>[];
    final sub = service.progress.listen(seen.add);
    addTearDown(sub.cancel);

    final saved = await transfer(service, [1761100001]);

    expect(await File(saved.single).readAsBytes(), audio);
    expect(service.incompletePaths, isEmpty);
    expect(
      seen.where((e) => e.currentFileIndex == 0).map((e) => e.fileFraction),
      contains(1.0),
    );
  });

  test('a done marker the recorder repeats for the previous file does not '
      'cut the next one short', () async {
    final first = recorderAudio(1761100001, units: 2);
    final second = recorderAudio(1761100002, units: 4);
    final recorder = await FakeWifiRecorder.start((socket, fileId) async {
      if (fileId == 1761100001) {
        socket.add([
          ...FakeWifiRecorder.head(fileId, units: 2),
          ...FakeWifiRecorder.slices(first),
          ...FakeWifiRecorder.done(),
        ]);
        return;
      }
      // The first file's done marker comes again while the second file is
      // still arriving, as it does a few seconds after the first one.
      socket.add([
        ...FakeWifiRecorder.head(fileId, units: 4),
        ...FakeWifiRecorder.slices(second.sublist(0, 320)),
        ...FakeWifiRecorder.done(),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      socket.add([
        ...FakeWifiRecorder.slices(second.sublist(320), sequence: 2),
        ...FakeWifiRecorder.done(),
      ]);
    });
    final service = serviceFor(recorder);

    final saved = await transfer(service, [1761100001, 1761100002]);

    expect(await File(saved[1]).readAsBytes(), second);
    expect(service.incompletePaths, isEmpty);
  });

  test('the recorder turning its hotspot off ends the export at once with '
      'what was saved, and leaves no empty file', () async {
    final first = recorderAudio(1761100001, units: 2);
    final recorder = await FakeWifiRecorder.start((socket, fileId) async {
      // The recorder sends the first file, then closes the connection while
      // Koe is still saving it.
      socket.add([
        ...FakeWifiRecorder.head(fileId, units: 2),
        ...FakeWifiRecorder.slices(first),
        ...FakeWifiRecorder.done(),
      ]);
      await socket.close();
    });
    final service = serviceFor(recorder);

    Object? error;
    try {
      await transfer(service, [1761100001, 1761100002, 1761100003]);
    } catch (e) {
      error = e;
    }

    expect(error, isA<WifiTransferException>());
    expect('$error', isNot(contains('Bad state')));
    expect(service.current.error, startsWith('已保存 1 个，第 2 个失败：'));
    expect(service.current.savedPaths, hasLength(1));
    final exports = Directory(
      p.join(documents.path, 'AnkerRecorder', 'exports'),
    );
    expect(
      [for (final f in exports.listSync()) p.basename(f.path)],
      [p.basename(service.current.savedPaths.single)],
    );
  });
}
