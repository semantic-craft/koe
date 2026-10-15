import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:anker_recorder/platform/credential_store.dart';
import 'package:path_provider/path_provider.dart';

import 'package:anker_recorder/ai/engine_config.dart';
import 'package:anker_recorder/ai/speech_provider.dart';
import 'package:anker_recorder/state/app_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('settings serialization never includes in-memory credentials', () {
    const settings = AppSettings(
      engines: {
        'qwen': EngineConfig(
          apiKey: 'fake-private-qwen',
          baseUrl: 'https://example.test',
        ),
        'doubao': EngineConfig(apiKey: 'fake-private-doubao'),
      },
    );
    final encoded = jsonEncode(settings.toJson());
    expect(encoded, isNot(contains('fake-private')));
    expect(encoded, isNot(contains('apiKey')));
  });
  Future<File> legacy(Map<String, dynamic> data) async {
    final directory = await getApplicationDocumentsDirectory();
    final f = File('${directory.path}/AnkerRecorder/app_settings.json');
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(data));
    return f;
  }

  for (final flat in [false, true]) {
    test('legacy key migrates to verified Keychain, flat=$flat', () async {
      final file = await legacy(
        flat
            ? {'qwenApiKey': 'fake-old-key', 'transcriptLanguage': 'ja'}
            : {
                'engines': {
                  'qwen': {'apiKey': 'fake-old-key'},
                },
                'transcriptLanguage': 'ja',
              },
      );
      final loaded = await AppSettingsStore.load();
      expect(loaded.storageError, isNull);
      expect(loaded.engineConfig(SttProvider.qwen).apiKey, 'fake-old-key');
      expect((await CredentialStore().read())['qwen'], 'fake-old-key');
      expect(await file.readAsString(), isNot(contains('fake-old-key')));
      expect(await File('${file.path}.tmp').exists(), false);
      final reopened = await AppSettingsStore.load();
      expect(reopened.engineConfig(SttProvider.qwen).apiKey, 'fake-old-key');
      expect(reopened.transcriptLanguage, 'ja');
    });
  }

  test(
    'migration failure preserves exact original and blocks preference overwrite',
    () async {
      final file = await legacy({'qwenApiKey': 'fake-only-copy'});
      final original = await file.readAsString();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(CredentialStore.channel, (call) async {
            if (call.method == 'read') return null;
            throw PlatformException(code: 'locked');
          });
      final loaded = await AppSettingsStore.load();
      expect(loaded.storageError, isNotNull);
      expect(loaded.engineConfig(SttProvider.qwen).apiKey, 'fake-only-copy');
      expect(await file.readAsString(), original);
      await expectLater(
        AppSettingsStore.save(
          loaded.copyWith(transcriptLanguage: 'en'),
          strict: true,
        ),
        throwsA(isA<CredentialStorageException>()),
      );
      expect(await file.readAsString(), original);
    },
  );

  test('Keychain read failure is not treated as a missing key', () async {
    final file = await legacy({'qwenApiKey': 'fake-legacy'});
    final before = await file.readAsString();
    var writes = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CredentialStore.channel, (call) async {
          if (call.method == 'write') writes++;
          throw PlatformException(code: 'locked');
        });
    expect((await AppSettingsStore.load()).storageError, isNotNull);
    expect(writes, 0);
    expect(await file.readAsString(), before);
  });

  test(
    'verified replacement and clear survive restart without resurrecting legacy',
    () async {
      await AppSettingsStore.save(
        const AppSettings(
          engines: {'qwen': EngineConfig(apiKey: 'fake-first')},
        ),
        strict: true,
      );
      await AppSettingsStore.save(
        const AppSettings(
          engines: {'qwen': EngineConfig(apiKey: 'fake-second')},
        ),
        strict: true,
      );
      expect(
        (await AppSettingsStore.load()).engineConfig(SttProvider.qwen).apiKey,
        'fake-second',
      );
      await legacy({'qwenApiKey': 'fake-stale'});
      expect(
        (await AppSettingsStore.load()).engineConfig(SttProvider.qwen).apiKey,
        'fake-second',
      );
      await AppSettingsStore.save(const AppSettings(), strict: true);
      await legacy({'qwenApiKey': 'fake-stale'});
      final loaded = await AppSettingsStore.load();
      expect(loaded.engineConfig(SttProvider.qwen).apiKey, isNull);
      expect((await CredentialStore().read()).containsKey('qwen'), true);
      expect((await CredentialStore().read())['qwen'], isNull);
    },
  );

  test('metadata write failure rolls back user credential change', () async {
    await AppSettingsStore.save(
      const AppSettings(engines: {'qwen': EngineConfig(apiKey: 'fake-first')}),
      strict: true,
    );
    final directory = await getApplicationDocumentsDirectory();
    final temporary = Directory(
      '${directory.path}/AnkerRecorder/app_settings.json.tmp',
    );
    await temporary.create();
    await expectLater(
      AppSettingsStore.save(
        const AppSettings(
          engines: {'qwen': EngineConfig(apiKey: 'fake-second')},
        ),
        strict: true,
      ),
      throwsA(isA<CredentialStorageException>()),
    );
    expect((await CredentialStore().read())['qwen'], 'fake-first');
  });

  test(
    'environment resolved key is never part of saved credential overrides',
    () async {
      await AppSettingsStore.save(const AppSettings(), strict: true);
      expect(
        (await CredentialStore().read()).values.whereType<String>(),
        isEmpty,
      );
      final directory = await getApplicationDocumentsDirectory();
      expect(
        await File(
          '${directory.path}/AnkerRecorder/app_settings.json',
        ).readAsString(),
        isNot(contains('apiKey')),
      );
    },
  );
  test(
    'write succeeds but verification read fails: previous Keychain state is restored',
    () async {
      String? item = jsonEncode({'qwen': 'fake-old', 'doubao': null});
      var failNextRead = false;
      var firstWrite = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(CredentialStore.channel, (call) async {
            if (call.method == 'read') {
              if (failNextRead) {
                failNextRead = false;
                throw PlatformException(code: 'locked');
              }
              return item;
            }
            item = call.arguments as String;
            if (firstWrite) {
              firstWrite = false;
              failNextRead = true;
            }
            return null;
          });
      await expectLater(
        AppSettingsStore.save(
          const AppSettings(
            engines: {'qwen': EngineConfig(apiKey: 'fake-new')},
          ),
          strict: true,
        ),
        throwsA(isA<CredentialStorageException>()),
      );
      expect((await CredentialStore().read())['qwen'], 'fake-old');
    },
  );
}
