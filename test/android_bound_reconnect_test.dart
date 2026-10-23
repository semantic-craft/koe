import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ble/ble_service.dart';
import 'package:koe/platform/recorder_presence.dart';
import 'package:koe/protocol/frame.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/state/device_store.dart';
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

  RecorderController build(
    _FakeBleService ble, {
    PersistedDeviceLoader? loader,
  }) {
    final controller = RecorderController(
      ble: ble,
      loadPersistedState: false,
      persistedDeviceLoader: loader,
      phoneRecordingEnabled: false,
      topicsEnabled: false,
      rawExportConverter: (raw) async => raw,
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
    await until(() => service.text == 'Koe 已连接录音豆');
  });

  test('linked with nothing to move, the service keeps Koe running without '
      'keeping the phone awake; retrieving a recording keeps it awake until '
      'the recording is saved', () async {
    final service = FakeForegroundService();
    final ble = _FakeBleService();
    final controller = build(ble);
    await controller.connect(_device);
    await until(() => service.text == 'Koe 已连接录音豆');
    expect(service.wakeLock, isFalse);

    final download = controller.downloadFileOverBle(
      OfflineFileEntry(fileId: 1761100001, durationMs: 20),
    );
    await until(() => ble.pulls.contains(1761100001));
    await until(() => service.wakeLock);
    expect(service.text, 'Koe 正在同步录音');

    ble.finishPull();
    await download;
    expect(controller.localPathFor(1761100001), isNotNull);
    await until(() => !service.wakeLock);
    expect(service.running, isTrue);
    expect(service.text, 'Koe 已连接录音豆');
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

  group('全天常驻', () {
    test('nothing waits for the recorder while Android\'s scan does not see '
        'it; the scan seeing it brings it back', () async {
      final service = FakeForegroundService();
      final presence = _FakePresence(address: 'D3200-TEST', mac: _mac);
      final ble = _FakeBleService();
      final controller = build(ble, loader: _bound);
      await until(() => ble.scans > 0);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ble.waiting, isFalse);
      expect(service.running, isFalse);

      await presence.tell(near: true, at: 'D3200-test');
      await until(() => ble.waiting);
      expect(service.text, 'Koe 正在等录音豆回来');
      ble.deviceBack();
      await until(() => controller.connected);
      expect(presence.watching, _mac);

      // Linked, the recorder stops advertising and the scan loses it. Once
      // the link drops, Koe lets go of it until the scan sees it again.
      await presence.tell(near: false);
      expect(controller.connected, isTrue);
      ble.drop();
      await until(() => !service.running);
      expect(ble.waiting, isFalse);
      expect(controller.statusMessage, '录音豆不在身边，回来后会自动连上');
    });

    // #436: the recorder changes its Bluetooth address, at least with every
    // Wi‑Fi export. Koe took it for another recorder, dropped 全天常驻, and
    // went on waiting where it no longer was.
    test('a recorder back at another Bluetooth address is the same '
        'recorder: Koe connects it there and stays resident', () async {
      final service = FakeForegroundService();
      final presence = _FakePresence();
      final ble = _FakeBleService();
      final controller = build(ble, loader: _bound);
      await until(() => ble.waiting);
      ble.deviceBack();
      await until(() => controller.connected);
      expect(await controller.setResident(true), isTrue);

      ble.drop();
      await controller.reconnectBoundDevice();
      ble.found([_device.withId('D3200-moved')]);
      await until(() => ble.fileListRequests > 0);
      expect(ble.connects.last, 'D3200-moved');
      expect(controller.resident, isTrue);
      expect(presence.address, 'D3200-TEST');

      // Away from Koe it moves again; the scan Android runs sees it there.
      ble.drop();
      await until(() => !service.running);
      await presence.tell(near: true, at: 'D3200-moved-again');
      await until(() => ble.waiting);
      ble.deviceBack();
      await until(() => controller.connected);
      expect(ble.connects.last, 'D3200-moved-again');
      expect(controller.resident, isTrue);
    });

    test('switched on, Android associates the recorder; switched off, Koe '
        'waits for it itself again', () async {
      final service = FakeForegroundService();
      final presence = _FakePresence();
      final ble = _FakeBleService();
      final controller = build(ble, loader: _bound);
      await until(() => ble.waiting);
      ble.deviceBack();
      await until(() => controller.connected);

      expect(await controller.setResident(true), isTrue);
      expect(presence.address, 'D3200-TEST');
      expect(presence.watching, _mac);
      ble.drop();
      await until(() => !service.running);
      expect(ble.waiting, isFalse);

      expect(await controller.setResident(false), isFalse);
      expect(presence.address, isNull);
      await until(() => ble.waiting);
      expect(service.text, 'Koe 正在等录音豆回来');
    });

    test('is offered once, also after Koe restarts', () async {
      FakeForegroundService();
      _FakePresence();
      final controller = build(_FakeBleService(), loader: DeviceStore.load);
      await controller.connect(_device);
      expect(controller.offersResident, isTrue);

      controller.markResidentOffered();
      expect(controller.offersResident, isFalse);
      await DeviceStore.waitForWrites();
      final restarted = build(_FakeBleService(), loader: DeviceStore.load);
      await restarted.connect(_device);
      expect(restarted.offersResident, isFalse);
    });

    test('binding another recorder drops the old association and asks '
        'again', () async {
      FakeForegroundService();
      final presence = _FakePresence();
      final controller = build(_FakeBleService(), loader: DeviceStore.load);
      await controller.connect(_device);
      expect(await controller.setResident(true), isTrue);

      await controller.connect(_otherDevice);
      await until(() => presence.address == null);
      expect(controller.resident, isFalse);
      expect(controller.offersResident, isTrue);
    });
  });
}

Future<PersistedDeviceState> _bound() async => (
  bound: true,
  manuallyDisconnected: false,
  residentOffered: false,
  device: _device,
  info: null,
);

/// The bound recorder's classic address, which stays when its Bluetooth
/// address changes.
const _mac = 'AA:BB:CC:DD:EE:01';

final _device = ScannedDevice(
  id: 'D3200-test',
  name: 'soundcore Work',
  rssi: -40,
  productCode: 'D3200',
  macAddress: _mac,
  isBoundAdvertised: true,
  isD3200: true,
);

final _otherDevice = ScannedDevice(
  id: 'D3200-other',
  name: 'soundcore Work',
  rssi: -40,
  productCode: 'D3200',
  macAddress: 'AA:BB:CC:DD:EE:02',
  isBoundAdvertised: true,
  isD3200: true,
);

/// Android's companion device manager and the scan it runs for Koe: Koe is
/// associated with the recorder at [address] (none when null) and watches
/// for the classic address [watching]; [tell] says the scan sees the
/// recorder, and at which Bluetooth address, or has lost it.
class _FakePresence {
  _FakePresence({this.address, String? mac}) : watching = mac {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, Object?>();
      switch (call.method) {
        case 'state':
          return {
            'supported': true,
            'associated': address != null,
            'mac': watching,
            'present': present,
            'address': seenAt,
          };
        case 'associate':
          address = (args!['address'] as String).toUpperCase();
          return true;
        case 'observe':
          watching = args!['on'] == true ? args['mac'] as String? : null;
          return null;
        case 'disassociate':
          address = null;
          watching = null;
          return null;
      }
      return null;
    });
    final previous = RecorderPresence.shared;
    RecorderPresence.shared = RecorderPresence(
      channel: _channel,
      enabled: true,
    );
    addTearDown(() {
      RecorderPresence.shared = previous;
      messenger.setMockMethodCallHandler(_channel, null);
    });
  }

  static const _channel = MethodChannel('test/recorder_presence');

  String? address;
  String? watching;
  bool present = false;
  String? seenAt;

  Future<void> tell({required bool near, String? at}) async {
    present = near;
    seenAt = at ?? seenAt;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _channel.name,
          _channel.codec.encodeMethodCall(
            MethodCall('presence', {'near': near, 'address': at}),
          ),
          (_) {},
        );
  }
}

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

  /// Ids Koe connected, in order.
  final connects = <String>[];
  Completer<bool>? _wait;
  bool ready = false;
  bool failConnect = false;
  int connectCalls = 0;
  int scans = 0;

  /// Device files Koe asked to retrieve, in order.
  final pulls = <int>[];

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
  }) async {
    scans++;
  }

  @override
  Future<void> stopScan() async {}

  @override
  Future<bool> waitForDevice(String remoteId) {
    _withdraw();
    waits.add(remoteId);
    return (_wait = Completer<bool>()).future;
  }

  @override
  Future<void> withdrawWait() async => _withdraw();

  /// The scan sees [devices].
  void found(List<ScannedDevice> devices) => _scanResults.add(devices);

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
    connects.add(remoteId);
    ready = true;
    _connectionState.add(true);
  }

  @override
  Future<void> writeCommand(List<int> frame) async {
    _frames.add(List<int>.from(frame));
    // Skips the encryption handshake's wait; the controller goes on without.
    if (frame[5] == 0x2E) throw StateError('encryption unavailable in test');
    if (frame[5] == 0x1A && frame[6] == 0x07) {
      pulls.add(readU32Le(frame, 13));
      _emit(0x07, Uint8List(10));
    }
  }

  /// Sends the file asked for last: one slice, then the done signal.
  void finishPull() {
    _emit(0x08, Uint8List(175)..fillRange(14, 174, 1));
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
