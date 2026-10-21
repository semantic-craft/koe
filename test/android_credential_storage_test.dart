import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/engine_config.dart';
import 'package:koe/ai/speech_provider.dart';
import 'package:koe/platform/credential_store.dart';
import 'package:koe/state/app_settings_store.dart';
import 'package:path_provider/path_provider.dart';

/// Android has no Keychain channel: credentials live in flutter_secure_storage
/// (Android Keystore) as the same single JSON item.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Map<String, String> secure;
  late List<String> writes;
  Object? readFailure;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    secure = {};
    writes = [];
    readFailure = null;
    // As on a real Pixel: nothing answers the Apple Keychain channel.
    messenger.setMockMethodCallHandler(CredentialStore.channel, null);
    messenger.setMockMethodCallHandler(secureChannel, (call) async {
      final args = (call.arguments as Map).cast<String, Object?>();
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          if (readFailure != null) throw readFailure!;
          return secure[key];
        case 'write':
          writes.add(key!);
          secure[key] = args['value'] as String;
          return null;
      }
      throw MissingPluginException();
    });
    AppSettingsStore.resetForTesting();
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Future<File> settingsFile() async {
    final base = await getApplicationDocumentsDirectory();
    return File('${base.path}/AnkerRecorder/app_settings.json');
  }

  Future<void> writeLegacy(String key) async {
    final file = await settingsFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'qwenApiKey': key}));
  }

  test('saved key is read back after restart from one secure item', () async {
    final initial = await AppSettingsStore.load();
    expect(initial.storageError, isNull);
    expect(await CredentialStore().isIsolated, isFalse);
    await AppSettingsStore.save(
      const AppSettings(
        engines: {
          'qwen': EngineConfig(apiKey: 'fake-android-qwen'),
          'doubao': EngineConfig(apiKey: 'fake-android-doubao'),
        },
      ),
      strict: true,
    );
    expect(secure.keys, ['engines-v1']);
    expect(
      await (await settingsFile()).readAsString(),
      isNot(contains('fake-android')),
    );

    AppSettingsStore.resetForTesting(); // New process, same device storage.
    final reopened = await AppSettingsStore.load();
    expect(reopened.storageError, isNull);
    expect(reopened.engineConfig(SttProvider.qwen).apiKey, 'fake-android-qwen');
    expect(
      reopened.engineConfig(SttProvider.doubao).apiKey,
      'fake-android-doubao',
    );
  });

  test(
    'a cleared key stays cleared when a stale legacy file returns',
    () async {
      await AppSettingsStore.save(
        const AppSettings(
          engines: {'qwen': EngineConfig(apiKey: 'fake-first')},
        ),
        strict: true,
      );
      await AppSettingsStore.save(const AppSettings(), strict: true);
      await writeLegacy('fake-stale');
      AppSettingsStore.resetForTesting();
      final loaded = await AppSettingsStore.load();
      expect(loaded.storageError, isNull);
      expect(loaded.engineConfig(SttProvider.qwen).apiKey, isNull);
      expect(jsonDecode(secure['engines-v1']!), containsPair('qwen', null));
    },
  );

  test('unreadable secure item is an error, never a missing key', () async {
    await writeLegacy('fake-legacy');
    final before = await (await settingsFile()).readAsString();
    readFailure = PlatformException(
      code: 'Exception encountered',
      message: 'Failed to unwrap key',
    );
    final loaded = await AppSettingsStore.load();
    expect(loaded.storageError, const CredentialStorageException().message);
    expect(writes, isEmpty);
    expect(await (await settingsFile()).readAsString(), before);
    await expectLater(
      CredentialStore().authorize(),
      throwsA(isA<CredentialStorageException>()),
    );

    readFailure = null; // "重试读取安全配置" once the item is readable again.
    await CredentialStore().authorize();
    final retried = await AppSettingsStore.load();
    expect(retried.storageError, isNull);
    expect(retried.engineConfig(SttProvider.qwen).apiKey, 'fake-legacy');
  });
}
