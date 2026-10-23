import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/platform/wifi_connectivity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.semanticcraft.koe/wifi_connectivity');
  for (final name in ['en0', 'eth0', 'ap0']) {
    test('$name alone is not proof of Wi-Fi transport', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => false);
      expect(
        await defaultIsWifiConnected(
          listInterfaces: () async => [_Interface(name)],
        ),
        isFalse,
      );
    });
  }
}

class _Interface implements NetworkInterface {
  _Interface(this.name);
  @override
  final String name;
  @override
  int get index => 1;
  @override
  List<InterfaceAddress> get addresses => [_Address()];
}

class _Address implements InterfaceAddress {
  @override
  bool get isLoopback => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
