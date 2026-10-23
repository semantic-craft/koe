import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ble/ble_service.dart';

/// The recorder's classic address, carried in its advertisement's
/// manufacturer data: the company id holds the first two bytes.
const _mac = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x01];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    const permissions = MethodChannel(
      'flutter.baseflow.com/permissions/methods',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(permissions, (call) async {
      if (call.method == 'checkPermissionStatus') return 1; // granted
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(permissions, null));
  });

  // #436: the recorder advertises from a new Bluetooth address after a
  // Wi‑Fi export. A scan that still reported the address the last scan saw
  // had Koe connect there first, and wait 100 seconds for nothing.
  test('a new scan finds the recorder where it advertises now, '
      'not where the last scan saw it', () async {
    final radio = _FakeRadio();
    FlutterBluePlusPlatform.instance = radio;
    final ble = BleService();
    addTearDown(ble.dispose);
    final found = <String>[];
    ble.scanResults.listen(
      (devices) => found.addAll(devices.map((device) => device.id)),
    );

    await ble.startScan();
    radio.advertise('7A:00:00:00:00:01');
    await _until(() => found.contains('7A:00:00:00:00:01'));
    await ble.stopScan();
    found.clear();

    await ble.startScan();
    radio.advertise('7A:00:00:00:00:02');
    await _until(() => found.contains('7A:00:00:00:00:02'));

    expect(found, isNot(contains('7A:00:00:00:00:01')));
  });
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Android's Bluetooth with the adapter on, reporting what [advertise]
/// sends while a scan runs.
final class _FakeRadio extends FlutterBluePlusPlatform {
  final _scans = StreamController<BmScanResponse>.broadcast();

  @override
  Stream<BmScanResponse> get onScanResponse => _scans.stream;

  @override
  Future<bool> isSupported(BmIsSupportedRequest request) async => true;

  @override
  Future<BmBluetoothAdapterState> getAdapterState(
    BmBluetoothAdapterStateRequest request,
  ) async => BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.on);

  @override
  Future<bool> startScan(BmScanSettings request) async => true;

  @override
  Future<bool> stopScan(BmStopScanRequest request) async => true;

  /// The recorder advertises from [address].
  void advertise(String address) {
    _scans.add(
      BmScanResponse(
        advertisements: [
          BmScanAdvertisement(
            remoteId: DeviceIdentifier(address),
            platformName: null,
            advName: 'soundcore Work',
            connectable: true,
            txPowerLevel: null,
            appearance: null,
            manufacturerData: {
              _mac[0] | (_mac[1] << 8): [..._mac.sublist(2), 0x80],
            },
            serviceData: const {},
            serviceUuids: const [],
            rssi: -50,
          ),
        ],
        success: true,
        errorCode: 0,
        errorString: '',
      ),
    );
  }
}
