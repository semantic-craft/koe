import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ble/ble_service.dart';

// permission_handler's wire values.
const _bluetoothScan = 28;
const _bluetoothConnect = 30;
const _denied = 0;
const _granted = 1;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Answers permission_handler as Android would with [granted] already
  /// allowed, granting whatever is asked for; returns what was asked for.
  List<int> fakePermissions({Set<int> granted = const {}}) {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
    final requested = <int>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(permissions, (call) async {
      switch (call.method) {
        case 'checkPermissionStatus':
          return granted.contains(call.arguments) ? _granted : _denied;
        case 'requestPermissions':
          final asked = (call.arguments as List).cast<int>();
          requested.addAll(asked);
          return {for (final permission in asked) permission: _granted};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(permissions, null));
    return requested;
  }

  test('Android asks only for Bluetooth scan and connect, not location', () async {
    final requested = fakePermissions();

    final granted = await BleService().ensurePermissions();

    expect(granted, isTrue);
    expect(requested, unorderedEquals([_bluetoothScan, _bluetoothConnect]));
  });

  // Asking fails without Koe on screen, as when Android starts Koe because
  // the recorder came near (全天常驻).
  test('Android does not ask again for Bluetooth it already has', () async {
    final requested = fakePermissions(
      granted: {_bluetoothScan, _bluetoothConnect},
    );

    final granted = await BleService().ensurePermissions();

    expect(granted, isTrue);
    expect(requested, isEmpty);
  });
}
