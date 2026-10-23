import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/state/device_store.dart';

/// Koe keeps the bound recorder and its last device info on disk. The
/// recorder answers the battery poll every 15 seconds, mostly with nothing
/// new, and each answer used to rewrite the file (#438).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory documents;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('device-store-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => documents.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await documents.delete(recursive: true);
  });

  test('saving what the file already holds leaves the file alone', () async {
    final device = ScannedDevice(
      id: 'D3200-test',
      name: 'soundcore Work',
      rssi: -40,
      productCode: 'D3200',
      isBoundAdvertised: true,
      isD3200: true,
    );
    final info = DeviceInfoModel(
      serialNumber: 'SN-TEST',
      firmwareVersion: '1.0.0',
      battery: 80,
      boxBattery: 60,
      boxMac: '',
    );
    await DeviceStore.save(bound: true, device: device, info: info);
    final file = File('${documents.path}/AnkerRecorder/bound_device.json');
    final written = await file.readAsString();

    await DeviceStore.save(bound: true, device: device, info: info);

    expect(await file.readAsString(), written);
  });
}
