import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/protocol/frame.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/wifi/softap_link.dart';
import 'package:koe/wifi/wifi_export_service.dart';

import 'support/fake_wifi_recorder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding answers every HttpClient request with 400; the export
  // needs a real WebSocket handshake with the fake recorder.
  HttpOverrides.global = null;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory documents;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('android-wifi-export-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => documents.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await documents.delete(recursive: true);
  });

  // TEST-NET-1: nothing answers there, so on Android only the hotspot the
  // link joined reaches the recorder — the phone's default network does not.
  WifiEndpoint endpoint(int port) => WifiEndpoint(
    ssid: 'WiFi-1761100000000',
    password: '1761100000000',
    ip: '192.0.2.1',
    port: port,
  );

  test('Android export joins the hotspot and pulls the file through it', () async {
    final audio = List<int>.generate(160, (i) => i);
    final recorder = await FakeWifiRecorder.serving({1761100000: audio});
    final link = FakeSoftApLink(recorderPort: recorder.port);
    final service = WifiExportService(
      blePackets: const Stream<DecodedPacket>.empty(),
      bleWrite: (_) async {},
      link: link,
      useSsl: false,
    );

    final saved = await service
        .transferFiles(
          endpoint: endpoint(recorder.port),
          files: [OfflineFileEntry(fileId: 1761100000, sizeBytes: 160)],
        )
        .timeout(const Duration(seconds: 10));

    expect(saved, hasLength(1));
    expect(await File(saved.single).readAsBytes(), audio);
    expect(link.events, [
      'join WiFi-1761100000000 1761100000000',
      'dial 192.0.2.1:${recorder.port}',
      'keepalive 192.0.2.1',
      'release',
    ]);
    // The recorder still sees its own address, as with a direct connection.
    expect(recorder.host, '192.0.2.1:${recorder.port}');
    await recorder.close();
    await service.dispose();
  });

  test('a failed hotspot join ends the export with its reason', () async {
    const reason = '没有连上录音豆的 Wi‑Fi「WiFi-1761100000000」';
    final link = FakeSoftApLink(
      recorderPort: 9,
      joinError: const SoftApJoinException(reason),
    );
    final service = WifiExportService(
      blePackets: const Stream<DecodedPacket>.empty(),
      bleWrite: (_) async {},
      link: link,
      useSsl: false,
    );

    await expectLater(
      service.transferFiles(
        endpoint: endpoint(9),
        files: [OfflineFileEntry(fileId: 1761100000, sizeBytes: 160)],
      ),
      throwsA(isA<SoftApJoinException>()),
    );

    expect(service.current.phase, ExportPhase.error);
    expect(service.current.error, reason);
    // Withdraws the system's network request instead of leaving it pending.
    expect(link.events, ['join WiFi-1761100000000 1761100000000', 'release']);
    await service.dispose();
  });
}

