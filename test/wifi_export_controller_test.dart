import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ble/ble_service.dart';
import 'package:koe/protocol/frame.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/wifi/softap_link.dart';
import 'package:koe/wifi/wifi_export_service.dart';

import 'support/fake_wifi_recorder.dart';

/// A Wi‑Fi export the recorder breaks off (#437), from the export sheet's
/// side: what the library keeps and what 「开始导出」 does next.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding answers every HttpClient request with 400; the export
  // needs a real WebSocket handshake with the fake recorder.
  HttpOverrides.global = null;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory documents;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('wifi-export-ui-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => documents.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await documents.delete(recursive: true);
  });

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue);
  }

  /// A controller connected to the recorder over Bluetooth, with
  /// [fileIds] on the recorder.
  (RecorderController, _Ble, FakeSoftApLink) connected(
    FakeWifiRecorder recorder,
    List<int> fileIds, {
    SoftApJoinException? joinError,
  }) {
    final ble = _Ble()..ready = true;
    final link = FakeSoftApLink(
      recorderPort: recorder.port,
      joinError: joinError,
    );
    final controller =
        RecorderController(
            ble: ble,
            loadPersistedState: false,
            phoneRecordingEnabled: false,
            topicsEnabled: false,
            rawExportConverter: (raw) async => raw,
            wifiExport: WifiExportService(
              blePackets: ble.packets,
              bleWrite: ble.writeCommand,
              link: link,
              startupDelay: Duration.zero,
              useSsl: false,
            ),
          )
          ..connected = true
          ..encryptReady = true
          ..phase = AppPhase.ready
          ..files = [
            for (final id in fileIds)
              OfflineFileEntry(fileId: id, durationMs: 21600),
          ];
    addTearDown(() async {
      await recorder.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
    });
    return (controller, ble, link);
  }

  test('recordings saved before a file fails are in the library', () async {
    final first = recorderAudio(1761100001, units: 2);
    final recorder = await FakeWifiRecorder.start((socket, fileId) async {
      // The recorder turns its hotspot off after the first file.
      socket.add([
        ...FakeWifiRecorder.head(fileId, units: 2),
        ...FakeWifiRecorder.slices(first),
        ...FakeWifiRecorder.done(),
      ]);
      await socket.close();
    });
    final (controller, _, _) = connected(recorder, [1761100001, 1761100002]);

    expect(await controller.beginWifiExport(), isNotNull);
    await controller.continueWifiExport().timeout(const Duration(seconds: 5));

    expect(controller.localPathFor(1761100001), isNotNull);
    expect(controller.errorMessage, startsWith('已保存 1 个，第 2 个失败：'));
  });

  test('after the hotspot is gone, 开始导出 opens a new one over Bluetooth and '
      'exports through it', () async {
    final audio = recorderAudio(1761100001, units: 2);
    final recorder = await FakeWifiRecorder.serving({1761100001: audio});
    final (controller, ble, link) = connected(
      recorder,
      [1761100001],
      // The user cancels the system's 「连接设备」 dialog.
      joinError: const SoftApJoinException('没有连上录音豆的 Wi‑Fi'),
    );

    expect(await controller.beginWifiExport(), isNotNull);
    expect(await controller.continueWifiExport(), isEmpty);
    // The recorder leaves Wi‑Fi mode and Bluetooth connects again.
    ble.linkUp();
    await until(() => controller.connected);

    final saved = await controller.continueWifiExport().timeout(
      const Duration(seconds: 5),
    );

    expect(saved, hasLength(1));
    expect(ble.hotspots, hasLength(2));
    expect(link.joins, ble.hotspots);
  });
}

/// Bluetooth to the recorder: answers a Wi‑Fi request (1A05) with the
/// hotspot's address, as the recorder does before turning it on.
class _Ble extends BleService {
  final _packets = StreamController<DecodedPacket>.broadcast();
  final _scanResults = StreamController<List<ScannedDevice>>.broadcast();
  final _connectionState = StreamController<bool>.broadcast();
  final _logs = StreamController<String>.broadcast();
  bool ready = false;

  /// SSIDs of the hotspots Koe asked for, in order.
  final hotspots = <String>[];

  void linkUp() {
    ready = true;
    _connectionState.add(true);
  }

  @override
  Stream<DecodedPacket> get packets => _packets.stream;

  @override
  Stream<List<ScannedDevice>> get scanResults => _scanResults.stream;

  @override
  Stream<bool> get connectionState => _connectionState.stream;

  @override
  Stream<String> get logs => _logs.stream;

  @override
  bool get isConnected => ready;

  @override
  bool get isConnecting => false;

  @override
  bool get canAwaitDevice => false;

  @override
  Future<bool> isD3200ConnectedToSystem(String remoteId) async => false;

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 30),
  }) async {}

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> writeCommand(List<int> frame) async {
    if (!ready) throw StateError('未连接');
    if (frame[5] == 0x2E) throw StateError('encryption unavailable in test');
    if (frame[5] == 0x1A && frame[6] == 0x05) {
      hotspots.add(String.fromCharCodes(frame.sublist(10, 10 + frame[9])));
      // 192.168.43.1:443, IP octets reversed and the port little-endian.
      final body = [
        0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x05, 0x10, 0x00, //
        0x01, 0x2B, 0xA8, 0xC0, 0xBB, 0x01,
      ];
      scheduleMicrotask(
        () => _packets.add(
          DecodedPacket.fromBytes([...body, ProtocolFrame.checksum(body)]),
        ),
      );
    }
  }

  @override
  Future<void> disconnect() async {
    ready = false;
    _connectionState.add(false);
  }

  @override
  Future<void> dispose() async {
    await _packets.close();
    await _scanResults.close();
    await _connectionState.close();
    await _logs.close();
  }
}
