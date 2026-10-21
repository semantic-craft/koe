import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ble/ble_service.dart';

// permission_handler's wire values.
const _bluetoothScan = 28;
const _bluetoothConnect = 30;
const _granted = 1;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android asks only for Bluetooth scan and connect, not location', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
    final requested = <int>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(permissions, (call) async {
      if (call.method != 'requestPermissions') return null;
      final asked = (call.arguments as List).cast<int>();
      requested.addAll(asked);
      return {for (final permission in asked) permission: _granted};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(permissions, null));

    final granted = await BleService().ensurePermissions();

    expect(granted, isTrue);
    expect(requested, unorderedEquals([_bluetoothScan, _bluetoothConnect]));
  });
}
