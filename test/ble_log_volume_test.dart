import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ble/ble_service.dart';
import 'package:koe/protocol/commands.dart';
import 'package:koe/protocol/frame.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/state/recorder_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documents;
  setUp(() async {
    documents = await Directory.systemTemp.createTemp('ble-log-volume-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => documents.path,
        );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await documents.delete(recursive: true);
  });

  test('audio slices reach listeners without one log line each', () async {
    final ble = BleService();
    final packets = <DecodedPacket>[];
    final logs = <String>[];
    final packetSub = ble.packets.listen(packets.add);
    final logSub = ble.logs.listen(logs.add);

    for (var sequence = 0; sequence < 1000; sequence++) {
      ble.handleNotification(_sliceFrame(sequence));
    }
    ble.handleNotification(_frame(RxCmd.fileDoneId, const []));
    await Future<void>.delayed(Duration.zero);

    expect(packets, hasLength(1001));
    expect(logs.length, lessThanOrEqualTo(3));
    expect(logs.last, contains('RX'));

    await packetSub.cancel();
    await logSub.cancel();
  });

  test('a slice flagged by the bean shows in the log once, with its '
      'sequence', () async {
    final ble = BleService();
    final logs = <String>[];
    final logSub = ble.logs.listen(logs.add);

    for (var sequence = 0; sequence < 100; sequence++) {
      ble.handleNotification(
        _sliceFrame(sequence, flags: sequence >= 40 && sequence < 43 ? 2 : 0),
      );
    }
    ble.handleNotification(_sliceFrame(100, cmdId: RxCmd.fileSliceMarkId));
    await Future<void>.delayed(Duration.zero);

    final marks = logs.where((line) => line.startsWith('标记线索')).toList();
    expect(marks, hasLength(3));
    expect(marks[0], contains('cmd=0x08 seq=40 flags=0x02'));
    expect(marks[1], contains('cmd=0x08 seq=43 flags=0x00'));
    expect(marks[2], contains('cmd=0x12 seq=100 flags=0x00'));
    await logSub.cancel();
  });

  test('BLE diagnostic lines do not rebuild controller listeners', () async {
    final ble = _LogOnlyBleService();
    final controller = RecorderController(
      ble: ble,
      loadPersistedState: false,
      persistedDeviceLoader: () async =>
          (bound: false, manuallyDisconnected: false, device: null, info: null),
    );
    addTearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    var notifications = 0;
    controller.addListener(() => notifications++);

    for (var i = 0; i < 200; i++) {
      ble.emitLog('line $i');
    }
    await Future<void>.delayed(Duration.zero);

    expect(notifications, 0);
    expect(controller.logs.first, 'line 199');
  });

  test('audio slices do not rebuild controller listeners', () async {
    final ble = _QuietBleService();
    final controller = RecorderController(
      ble: ble,
      loadPersistedState: false,
      persistedDeviceLoader: () async =>
          (bound: false, manuallyDisconnected: false, device: null, info: null),
    );
    addTearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    var notifications = 0;
    controller.addListener(() => notifications++);

    for (var sequence = 0; sequence < 500; sequence++) {
      ble.handleNotification(_sliceFrame(sequence));
    }
    await Future<void>.delayed(Duration.zero);
    expect(notifications, 0);

    // Other packets still update the controller.
    ble.handleNotification(
      _frame(RxCmd.batteryId, const [5, 7], type: RxCmd.deviceInfoType),
    );
    await Future<void>.delayed(Duration.zero);
    expect(notifications, 1);
    expect(controller.info?.battery, isNotNull);
  });
}

Uint8List _sliceFrame(
  int sequence, {
  int flags = 0,
  int cmdId = RxCmd.fileSliceId,
}) {
  final slice = Uint8List(166);
  ByteData.sublistView(slice).setUint32(0, sequence, Endian.little);
  slice[4] = flags;
  return _frame(cmdId, slice);
}

Uint8List _frame(
  int cmdId,
  List<int> payload, {
  int type = RxCmd.transportType,
}) {
  final length = 9 + payload.length + 1;
  final body = [
    0x09, 0xFF, 0x00, 0x00, 0x01, type, cmdId, //
    length & 0xFF, (length >> 8) & 0xFF,
    ...payload,
  ];
  return Uint8List.fromList([...body, ProtocolFrame.checksum(body)]);
}

class _LogOnlyBleService extends BleService {
  final _packets = StreamController<DecodedPacket>.broadcast();
  final _scanResults = StreamController<List<ScannedDevice>>.broadcast();
  final _connectionState = StreamController<bool>.broadcast();
  final _logs = StreamController<String>.broadcast(sync: true);

  void emitLog(String line) => _logs.add(line);

  @override
  Stream<DecodedPacket> get packets => _packets.stream;

  @override
  Stream<List<ScannedDevice>> get scanResults => _scanResults.stream;

  @override
  Stream<bool> get connectionState => _connectionState.stream;

  @override
  Stream<String> get logs => _logs.stream;

  @override
  bool get isConnected => false;

  @override
  bool get isConnecting => false;

  @override
  Future<bool> isD3200ConnectedToSystem(String remoteId) async => false;

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 30),
  }) async {}

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> dispose() async {
    await _packets.close();
    await _scanResults.close();
    await _connectionState.close();
    await _logs.close();
  }
}

/// Real packet decoding, but never scans or connects.
class _QuietBleService extends BleService {
  @override
  bool get isConnected => false;

  @override
  bool get isConnecting => false;

  @override
  Future<bool> isD3200ConnectedToSystem(String remoteId) async => false;

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 30),
  }) async {}

  @override
  Future<void> stopScan() async {}
}
