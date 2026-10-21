// Android credential scenario on the Pixel: a key saved through the settings
// store lands in Android Keystore-backed storage, never as plaintext on disk,
// and a fresh store reads it back. Run with `scripts/android-check`.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:koe/ai/engine_config.dart';
import 'package:koe/ai/speech_provider.dart';
import 'package:koe/platform/credential_store.dart';
import 'package:koe/state/app_settings_store.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('saved key is encrypted at rest and read back', (tester) async {
    expect(await CredentialStore().isIsolated, isFalse);
    final settings = await AppSettingsStore.load();
    expect(settings.storageError, isNull);
    // Put back whatever the device already holds.
    addTearDown(() => AppSettingsStore.save(settings, strict: true));

    final marker = 'koe-device-check-${DateTime.now().microsecondsSinceEpoch}';
    await AppSettingsStore.save(
      settings.copyWith(
        engines: {
          ...settings.engines,
          'qwen': EngineConfig(
            apiKey: marker,
            baseUrl: settings.engineConfig(SttProvider.qwen).baseUrl,
            model: settings.engineConfig(SttProvider.qwen).model,
          ),
        },
      ),
      strict: true,
    );

    // Neither preferences nor the settings folder hold the key in the clear.
    final data = (await getApplicationSupportDirectory()).parent;
    final documents = await getApplicationDocumentsDirectory();
    for (final entity in [
      ...Directory('${data.path}/shared_prefs').listSync(),
      ...Directory('${documents.path}/AnkerRecorder').listSync(),
    ]) {
      if (entity is! File) continue;
      final bytes = await entity.readAsBytes();
      expect(
        String.fromCharCodes(bytes).contains(marker),
        isFalse,
        reason: entity.path,
      );
    }

    AppSettingsStore.resetForTesting(); // As after an app restart.
    final reopened = await AppSettingsStore.load();
    expect(reopened.storageError, isNull);
    expect(reopened.engineConfig(SttProvider.qwen).apiKey, marker);
    expect((await CredentialStore().read())['qwen'], marker);
  });
}
