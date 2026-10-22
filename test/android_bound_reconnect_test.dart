import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ble/ble_service.dart';
import 'package:koe/protocol/frame.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/state/recorder_controller.dart';

import 'support/fake_foreground_service.dart';

/// On Android the bound recorder comes back through a connection request
/// the system holds: Android pauses Koe's scans while the screen is off, and
/// the foreground service keeps Koe running to take the link.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory documents;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('android-reconnect-');
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

  RecorderController build(_FakeBleService ble) {
    final controller = RecorderController(
      ble: ble,
      loadPersistedState: false,
      phoneRecordingEnabled: false,
      topicsEnabled: false,
    );
    addTearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
    });
    return controller;
  }

  test('a recorder that drops out is awaited through the system, with the '
      'service kept, and set up again once it is back', () async {
    final service = FakeForegroundService();
    final ble = _FakeBleService();
    final controller = build(ble);
    await controller.connect(_device);
    expect(controller.connected, isTrue);

    ble.drop();
    await until(() => ble.waiting);
    expect(ble.waits, [_device.id]);
    expect(service.running, isTrue);
    expect(service.text, 'Koe 正在等录音豆回来');

    final listed = ble.fileListRequests;
    ble.deviceBack();
    await until(() => controller.connected);
    expect(ble.connectCalls, 2);
    await until(() => ble.fileListRequests > listed);
    expect(service.text, 'Koe 正在同步录音');
  });

  test('a set-up that fails keeps the service and asks the system again; an '
      'explicit disconnect ends both', () async {
    final service = FakeForegroundService();
    final ble = _FakeBleService();
    final controller = build(ble);
    await controller.connect(_device);
    ble.drop();
    await until(() => ble.waiting);

    ble.failConnect = true;
    ble.deviceBack();
    await until(() => ble.waits.length == 2);
    expect(controller.connected, isFalse);
    expect(service.running, isTrue);
    expect(service.text, 'Koe 正在等录音豆回来');

    await controller.disconnect();
    expect(ble.waiting, isFalse);
    expect(service.running, isFalse);
  });
}

final _device = ScannedDevice(
  id: 'D3200-test',
  name: 'soundcore Work',
  rssi: -40,
  productCode: 'D3200',
  isBoundAdvertised: true,
  isD3200: true,
);

/// Android's Bluetooth: [waitForDevice] stands for the system's connection
/// request, which [deviceBack] answers.
class _FakeBleService extends BleService {
  final _packets = StreamController<DecodedPacket>.broadcast();
  final _scanResults = StreamController<List<ScannedDevice>>.broadcast();
  final _connectionState = StreamController<bool>.broadcast();
  final _logs = StreamController<String>.broadcast();
  final _frames = <List<int>>[];

  /// Ids of the requests made, in order.
  final waits = <String>[];
  Completer<bool>? _wait;
  bool ready = false;
  bool failConnect = false;
  int connectCalls = 0;

  bool get waiting => _wait != null;

  int get fileListRequests =>
      _frames.where((frame) => frame[5] == 0x1B && frame[6] == 0x0E).length;

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
  bool get canAwaitDevice => true;

  @override
  Future<bool> isD3200ConnectedToSystem(String remoteId) async => false;

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 30),
  }) async {}

  @override
  Future<void> stopScan() async {}

  @override
  Future<bool> waitForDevice(String remoteId) {
    _withdraw();
    waits.add(remoteId);
    return (_wait = Completer<bool>()).future;
  }

  /// The recorder is back in range and the system has connected it.
  void deviceBack() {
    final wait = _wait;
    _wait = null;
    wait?.complete(true);
  }

  /// The recorder goes out of range.
  void drop() {
    ready = false;
    _connectionState.add(false);
  }

  void _withdraw() {
    final wait = _wait;
    _wait = null;
    wait?.complete(false);
  }

  @override
  Future<void> connect(String remoteId, {String? serviceUuidHint}) async {
    connectCalls++;
    _withdraw();
    if (failConnect) throw StateError('录音豆没有响应');
    ready = true;
    _connectionState.add(true);
  }

  @override
  Future<void> writeCommand(List<int> frame) async {
    _frames.add(List<int>.from(frame));
    // Skips the encryption handshake's wait; the controller goes on without.
    if (frame[5] == 0x2E) throw StateError('encryption unavailable in test');
  }

  @override
  Future<void> disconnect() async {
    _withdraw();
    ready = false;
    _connectionState.add(false);
  }

  @override
  Future<void> dispose() async {
    _withdraw();
    await _packets.close();
    await _scanResults.close();
    await _connectionState.close();
    await _logs.close();
  }
}
