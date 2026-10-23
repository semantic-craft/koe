import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:koe/ble/ble_service.dart';
import 'package:koe/protocol/frame.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/state/device_store.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/wifi/wifi_export_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory deviceDirectory;
  setUp(() async {
    deviceDirectory = await Directory.systemTemp.createTemp('recorder-device-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => deviceDirectory.path,
        );
  });
  tearDown(() async {
    // A controller still saves the device record after a test's last step,
    // for example right after it reconnects. Without the folder or the mock
    // that save lands in the system temp folder, or the delete below fails.
    await DeviceStore.waitForWrites();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await deviceDirectory.delete(recursive: true);
  });

  test('legacy device records retain automatic connection', () async {
    await DeviceStore.save(bound: true, device: _device);
    final file = File(
      '${deviceDirectory.path}/AnkerRecorder/bound_device.json',
    );
    final legacy =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    legacy.remove('manuallyDisconnected');
    await file.writeAsString(jsonEncode(legacy));
    final restored = await DeviceStore.load();
    expect(restored.bound, isTrue);
    expect(restored.manuallyDisconnected, isFalse);
  });

  test('latest disconnect intent wins overlapping metadata saves', () async {
    final metadata = DeviceStore.save(bound: true, device: _device);
    final disconnect = DeviceStore.save(
      bound: true,
      device: _device,
      manuallyDisconnected: true,
    );
    await Future.wait([metadata, disconnect]);
    expect((await DeviceStore.load()).manuallyDisconnected, isTrue);
  });

  test(
    'manual disconnect survives restart until an explicit connection',
    () async {
      final first = _controller(_FakeBleService()..ready = true)
        ..bound = true
        ..lastKnownDevice = _device
        ..activeDevice = _device
        ..connected = true;
      await first.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      first.dispose();

      final ble = _FakeBleService();
      final restarted = RecorderController(
        ble: ble,
        loadPersistedState: false,
        phoneRecordingEnabled: false,
        topicsEnabled: false,
        persistedDeviceLoader: DeviceStore.load,
      );
      _disposeAfterSettling(restarted);
      await _until(restarted, () => restarted.bound);
      expect(restarted.bound, isTrue);
      expect(
        ble.startScanCalls,
        0,
        reason: 'restart must preserve manual disconnect',
      );
      await restarted.startScan();
      ble.emitScan([_device]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        ble.connectCalls,
        0,
        reason: 'scanning alone must not resume connection',
      );
      await restarted.requestRecordingFromShortcut();
      expect(ble.connectCalls, 0);
      expect(restarted.recordingShortcutPending, isFalse);
      await restarted.connect(_device);
      expect(ble.connectCalls, 1);
      final nextBle = _FakeBleService();
      final next = RecorderController(
        ble: nextBle,
        loadPersistedState: false,
        phoneRecordingEnabled: false,
        topicsEnabled: false,
        persistedDeviceLoader: DeviceStore.load,
      );
      _disposeAfterSettling(next);
      await nextBle.scanStarted.future.timeout(const Duration(seconds: 5));
      expect(
        nextBle.startScanCalls,
        1,
        reason: 'explicit connection restores automatic reconnection',
      );
      await next.stopScan();
    },
  );

  testWidgets('expired scan returns to idle so it can be retried', (
    tester,
  ) async {
    final ble = _FakeBleService();
    final controller = _controller(ble);
    _disposeAfterSettling(controller);

    await controller.startScan();
    expect(controller.phase, AppPhase.scanning);

    await tester.pump(const Duration(seconds: 31));

    expect(controller.phase, AppPhase.idle);
    expect(ble.stopScanCalls, 1);

    await controller.startScan();
    expect(ble.startScanCalls, 2);
    await controller.stopScan();
  });

  testWidgets('bound recorder keeps retrying after a scan timeout', (
    tester,
  ) async {
    final ble = _FakeBleService();
    final controller = _controller(ble)
      ..bound = true
      ..lastKnownDevice = _device
      ..activeDevice = _device;
    _disposeAfterSettling(controller);

    await controller.startScan();
    await tester.pump(const Duration(seconds: 31));
    expect(controller.phase, AppPhase.idle);

    await tester.pump(const Duration(seconds: 3));

    expect(controller.phase, AppPhase.scanning);
    expect(ble.startScanCalls, 2);
    await controller.stopScan();
  });

  test(
    'manual disconnect survives duplicate notifications and stale scans',
    () async {
      final ble = _FakeBleService()..ready = true;
      final controller = _controller(ble)
        ..bound = true
        ..lastKnownDevice = _device
        ..activeDevice = _device
        ..connected = true
        ..phase = AppPhase.ready;
      _disposeAfterSettling(controller);

      await controller.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        ble.startScanCalls,
        0,
        reason: 'explicit disconnect must not start reconnect',
      );
      ble.emitScan([_device]);
      ble.emitConnection(false);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(ble.connectCalls, 0);
      expect(ble.startScanCalls, 0);
      expect(controller.connected, isFalse);

      await controller.startScan();
      expect(ble.startScanCalls, 1, reason: 'user can explicitly reconnect');
      await controller.stopScan();
    },
  );

  test(
    'one tap brings the bound recorder back after a manual disconnect',
    () async {
      final ble = _FakeBleService()..ready = true;
      final controller = _controller(ble)
        ..bound = true
        ..lastKnownDevice = _device
        ..activeDevice = _device
        ..connected = true;
      await controller.disconnect();
      expect(controller.manuallyDisconnected, isTrue);
      expect(controller.canReconnectBoundDevice, isTrue);

      // Handed to the other device and back: no scan list to pick from.
      await controller.reconnectBoundDevice();
      expect(ble.startScanCalls, 1);
      ble.emitScan([_device]);
      // The connection starts once the device record is on disk, behind the
      // saves from disconnecting and reconnecting (#335).
      await _until(controller, () => controller.connected);
      expect(ble.connectCalls, 1);
      expect(controller.manuallyDisconnected, isFalse);
    },
  );

  test('unexpected disconnect still reconnects a bound recorder', () async {
    final ble = _FakeBleService()..ready = true;
    final controller = _controller(ble)
      ..bound = true
      ..lastKnownDevice = _device
      ..connected = true
      ..phase = AppPhase.ready;
    _disposeAfterSettling(controller);
    ble.emitConnection(false);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(ble.startScanCalls, 1);
    await controller.stopScan();
  });

  group('recording shortcut', () {
    test('connected recorder starts exactly once', () async {
      final ble = _FakeBleService()..ready = true;
      final controller = _controller(ble)
        ..connected = true
        ..phase = AppPhase.ready
        ..encryptReady = true;
      _disposeAfterSettling(controller);

      await controller.requestRecordingFromShortcut();

      expect(controller.recording, isTrue);
      expect(controller.recordingShortcutPending, isFalse);
      expect(ble.startRecordWrites, 1);
    });

    test(
      'duplicate requests coalesce while start write is in flight',
      () async {
        final ble = _FakeBleService()
          ..ready = true
          ..blockStartWrite = true;
        final controller = _controller(ble)
          ..connected = true
          ..phase = AppPhase.ready
          ..encryptReady = true;
        _disposeAfterSettling(controller);

        final first = controller.requestRecordingFromShortcut();
        await ble.startWriteEntered.future;
        await controller.requestRecordingFromShortcut();

        expect(ble.startRecordWrites, 1);
        ble.releaseStartWrite();
        await first;
        expect(controller.recording, isTrue);
      },
    );

    test('already-recording invocation sends no command', () async {
      final ble = _FakeBleService()..ready = true;
      final controller = _controller(ble)
        ..connected = true
        ..phase = AppPhase.ready
        ..recording = true;
      _disposeAfterSettling(controller);

      await controller.requestRecordingFromShortcut();

      expect(ble.startRecordWrites, 0);
      expect(controller.statusMessage, '录音中');
    });

    test('failed BLE write never sets optimistic recording state', () async {
      final ble = _FakeBleService()
        ..ready = true
        ..failStartWrite = true;
      final controller = _controller(ble)
        ..connected = true
        ..phase = AppPhase.ready;
      _disposeAfterSettling(controller);

      await controller.requestRecordingFromShortcut();

      expect(controller.recording, isFalse);
      expect(controller.recordingShortcutPending, isFalse);
      expect(controller.statusMessage, '快捷录音未开始');
      expect(controller.errorMessage, contains('start write failed'));
    });

    test('waits for persisted device state before reconnecting', () async {
      final ble = _FakeBleService();
      final loaded = Completer<PersistedDeviceState>();
      final controller = RecorderController(
        ble: ble,
        loadPersistedState: false,
        phoneRecordingEnabled: false,
        topicsEnabled: false,
        persistedDeviceLoader: () => loaded.future,
        recordingShortcutScanTimeout: const Duration(seconds: 1),
      );
      _disposeAfterSettling(controller);

      final request = controller.requestRecordingFromShortcut();
      await Future<void>.delayed(Duration.zero);
      expect(ble.startScanCalls, 0);

      loaded.complete((
        bound: true,
        manuallyDisconnected: false,
        residentOffered: false,
        device: _device,
        info: null,
      ));
      await request;
      await Future<void>.delayed(Duration.zero);

      expect(controller.recordingShortcutPending, isTrue);
      expect(ble.startScanCalls, 1);
    });

    test('offline paired recorder reconnects and starts', () async {
      final ble = _FakeBleService();
      final controller = _controller(ble)
        ..bound = true
        ..lastKnownDevice = _device
        ..activeDevice = _device;
      _disposeAfterSettling(controller);

      await controller.requestRecordingFromShortcut();
      expect(controller.recordingShortcutPending, isTrue);
      ble.emitScan([_device]);
      await _until(controller, () => controller.recording);

      expect(ble.connectCalls, 1);
      expect(ble.startRecordWrites, 1);
      expect(controller.recording, isTrue);
      expect(controller.recordingShortcutPending, isFalse);
    });

    test('unpaired, busy, and exporting states fail without writing', () async {
      final unpairedBle = _FakeBleService();
      final unpaired = _controller(unpairedBle);
      _disposeAfterSettling(unpaired);
      await unpaired.requestRecordingFromShortcut();
      expect(unpaired.errorMessage, contains('已绑定'));

      final busyBle = _FakeBleService()..ready = true;
      final busy = _controller(busyBle)
        ..connected = true
        ..phase = AppPhase.busy;
      _disposeAfterSettling(busy);
      await busy.requestRecordingFromShortcut();
      expect(busy.errorMessage, contains('设备正忙'));

      final exportingBle = _FakeBleService()..ready = true;
      final exporting = _controller(exportingBle)
        ..connected = true
        ..phase = AppPhase.ready
        ..exportProgress = ExportProgress(phase: ExportPhase.transferring);
      _disposeAfterSettling(exporting);
      await exporting.requestRecordingFromShortcut();
      expect(exporting.errorMessage, contains('正在导出'));

      expect(unpairedBle.startRecordWrites, 0);
      expect(busyBle.startRecordWrites, 0);
      expect(exportingBle.startRecordWrites, 0);
    });

    test(
      'scan timeout clears request so later reconnect cannot record',
      () async {
        final ble = _FakeBleService();
        final controller =
            RecorderController(
                ble: ble,
                loadPersistedState: false,
                phoneRecordingEnabled: false,
                topicsEnabled: false,
                recordingShortcutScanTimeout: const Duration(milliseconds: 20),
              )
              ..bound = true
              ..lastKnownDevice = _device;
        _disposeAfterSettling(controller);

        await controller.requestRecordingFromShortcut();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(controller.recordingShortcutPending, isFalse);
        expect(controller.errorMessage, contains('30 秒'));

        ble.ready = true;
        ble.emitConnection(true);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(ble.startRecordWrites, 0);
      },
    );
  });
}

// Phone takes and topics stay off: their library I/O would still be writing
// into the mocked documents folder when tearDown deletes it.
RecorderController _controller(_FakeBleService ble) => RecorderController(
  ble: ble,
  loadPersistedState: false,
  phoneRecordingEnabled: false,
  topicsEnabled: false,
  recordingShortcutScanTimeout: const Duration(seconds: 1),
);

/// Waits until [condition] holds, checking again on every controller change.
Future<void> _until(
  RecorderController controller,
  bool Function() condition,
) async {
  final met = Completer<void>();
  void check() {
    if (condition() && !met.isCompleted) met.complete();
  }

  controller.addListener(check);
  check();
  try {
    await met.future.timeout(const Duration(seconds: 5));
  } finally {
    controller.removeListener(check);
  }
}

void _disposeAfterSettling(RecorderController controller) {
  addTearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
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

class _FakeBleService extends BleService {
  final _packets = StreamController<DecodedPacket>.broadcast();
  final _scanResults = StreamController<List<ScannedDevice>>.broadcast();
  final _connectionState = StreamController<bool>.broadcast();
  final _logs = StreamController<String>.broadcast();
  final writtenFrames = <List<int>>[];

  bool ready = false;
  bool failStartWrite = false;
  bool blockStartWrite = false;
  int startScanCalls = 0;
  final scanStarted = Completer<void>();
  int stopScanCalls = 0;
  int connectCalls = 0;
  Completer<void> startWriteEntered = Completer<void>();
  Completer<void>? _startWriteRelease;

  int get startRecordWrites => writtenFrames
      .where(
        (frame) =>
            frame.length > 9 &&
            frame[5] == 0x18 &&
            frame[6] == 0x82 &&
            frame[9] == 0x01,
      )
      .length;

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
  Future<bool> isD3200ConnectedToSystem(String remoteId) async => false;

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    startScanCalls++;
    if (!scanStarted.isCompleted) scanStarted.complete();
  }

  @override
  Future<void> stopScan() async {
    stopScanCalls++;
  }

  @override
  Future<void> connect(String remoteId, {String? serviceUuidHint}) async {
    connectCalls++;
    ready = true;
    _connectionState.add(true);
  }

  @override
  Future<void> writeCommand(List<int> frame) async {
    writtenFrames.add(List<int>.from(frame));
    final isStart =
        frame.length > 9 &&
        frame[5] == 0x18 &&
        frame[6] == 0x82 &&
        frame[9] == 0x01;
    if (isStart) {
      if (!startWriteEntered.isCompleted) startWriteEntered.complete();
      if (failStartWrite) throw StateError('start write failed');
      if (blockStartWrite) {
        _startWriteRelease ??= Completer<void>();
        await _startWriteRelease!.future;
      }
    }
    // Keep reconnect tests fast: the controller treats a failed optional ECDH
    // handshake as non-fatal and continues to the recording request.
    if (frame.length > 6 && frame[5] == 0x2E) {
      throw StateError('encryption unavailable in test');
    }
  }

  void releaseStartWrite() {
    if (!(_startWriteRelease?.isCompleted ?? true)) {
      _startWriteRelease!.complete();
    }
  }

  void emitScan(List<ScannedDevice> devices) => _scanResults.add(devices);

  void emitConnection(bool connected) => _connectionState.add(connected);

  @override
  Future<void> disconnect() async {
    ready = false;
    // Mirrors the two down notifications previously emitted by BleService.
    _connectionState.add(false);
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
