import 'dart:async';
import 'dart:io';

import 'package:koe/platform/credential_store.dart';
import 'package:koe/state/app_settings_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/temp_dir.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final directories = <Directory>[];
  tearDownAll(() async {
    for (final directory in directories) {
      await deleteTemporaryDirectory(directory);
    }
  });
  setUp(() async {
    TestDefaultBinaryMessengerBinding binding;
    try {
      binding = TestDefaultBinaryMessengerBinding.instance;
    } catch (_) {
      return;
    }
    AppSettingsStore.resetForTesting();
    final directory = await Directory.systemTemp.createTemp(
      'koe-test-settings-',
    );
    String? credentialItem;
    final messenger = binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    messenger.setMockMethodCallHandler(CredentialStore.channel, (call) async {
      if (call.method == 'mode') return 'system';
      if (call.method == 'authorize') return null;
      if (call.method == 'read') return credentialItem;
      if (call.method == 'write') {
        credentialItem = call.arguments as String;
        return null;
      }
      throw MissingPluginException();
    });
    // Android keeps the same single item in flutter_secure_storage.
    final secure = <String, String>{};
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map).cast<String, Object?>();
        final key = args['key'] as String?;
        switch (call.method) {
          case 'read':
            return secure[key];
          case 'write':
            secure[key!] = args['value'] as String;
            return null;
          case 'delete':
            secure.remove(key);
            return null;
        }
        throw MissingPluginException();
      },
    );
    await AppSettingsStore.load();
    directories.add(directory);
  });
  await testMain();
}
