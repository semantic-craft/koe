import 'dart:convert';
import 'dart:io';

import 'package:anker_recorder/ai/engine_config.dart';
import 'package:anker_recorder/ai/speech_provider.dart';
import 'package:anker_recorder/ai/stt_types.dart';
import 'package:anker_recorder/state/app_settings_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MOSS credentials round-trip independently of Soniox', () {
    final settings = AppSettings.fromJson({
      'speechProvider': 'moss',
      'mossApiKey': 'moss-key',
      'sonioxApiKey': 'soniox-key',
    });
    expect(settings.speechProvider?.name, 'moss');
    expect(settings.toJson()['mossApiKey'], 'moss-key');
    final cleared = settings.copyWith(clearMoss: true);
    expect(cleared.mossApiKey, isNull);
    expect(cleared.sonioxApiKey, 'soniox-key');
    expect(AppSettings.fromJson({}).mossApiKey, isNull);
  });

  test('translation settings use backward-compatible defaults', () {
    final settings = AppSettings.fromJson(const {});

    expect(settings.sttMode, SttDisplayMode.transcription);
    expect(settings.translationTargetLanguage, 'zh');
    expect(settings.ownerLanguage, 'zh');
    expect(settings.guestLanguage, 'en');
    expect(settings.transcriptLanguage, 'auto');
  });

  test('translation settings round-trip through JSON', () {
    const original = AppSettings(
      sttMode: SttDisplayMode.translation,
      translationTargetLanguage: 'ja',
      ownerLanguage: 'ja',
      guestLanguage: 'ko',
    );

    final restored = AppSettings.fromJson(original.toJson());

    expect(restored.sttMode, SttDisplayMode.translation);
    expect(restored.translationTargetLanguage, 'ja');
    expect(restored.ownerLanguage, 'ja');
    expect(restored.guestLanguage, 'ko');
  });

  test('legacy communication switch migrates to conversation mode', () {
    final settings = AppSettings.fromJson(const {
      'communicationModeEnabled': true,
    });

    expect(settings.sttMode, SttDisplayMode.conversation);
  });

  test('explicit display mode takes precedence over legacy switch', () {
    final settings = AppSettings.fromJson(const {
      'sttMode': 'translation',
      'communicationModeEnabled': true,
    });

    expect(settings.sttMode, SttDisplayMode.translation);
  });

  test('duplicate persisted languages fall back to a valid pair', () {
    final settings = AppSettings.fromJson(const {
      'sttMode': 'conversation',
      'ownerLanguage': 'en',
      'guestLanguage': 'en',
    });

    expect(settings.ownerLanguage, 'zh');
    expect(settings.guestLanguage, 'en');
  });

  test('legacy xAI settings are ignored when settings are rewritten', () {
    final settings = AppSettings.fromJson(const {
      'sttProvider': 'xai',
      'xaiApiKey': 'obsolete',
    });

    expect(settings.toJson(), isNot(contains('sttProvider')));
    expect(settings.toJson(), isNot(contains('xaiApiKey')));
  });

  test('Qwen key, base URL, and model round-trip independently', () {
    final settings = AppSettings.fromJson({
      'speechProvider': 'qwen',
      'qwenApiKey': 'qwen-key',
      'qwenBaseUrl': 'https://dashscope-intl.aliyuncs.com',
      'qwenModel': 'qwen-audio-3.1-asr-flash-filetrans',
      'sonioxApiKey': 'soniox-key',
    });

    expect(settings.speechProvider, SttProvider.qwen);
    final qwen = settings.engineConfig(SttProvider.qwen);
    expect(qwen.apiKey, 'qwen-key');
    expect(qwen.baseUrl, 'https://dashscope-intl.aliyuncs.com');
    expect(qwen.model, 'qwen-audio-3.1-asr-flash-filetrans');

    // Clearing is a grouped replacement with a fresh value object that omits
    // the fields; the remaining field survives the JSON round-trip.
    final clearedSettings = settings.copyWith(
      engines: {
        SttProvider.qwen.name: const EngineConfig(
          baseUrl: 'https://dashscope-intl.aliyuncs.com',
        ),
      },
    );
    final restored = AppSettings.fromJson(clearedSettings.toJson());
    expect(restored.engineConfig(SttProvider.qwen).apiKey, isNull);
    expect(restored.engineConfig(SttProvider.qwen).model, isNull);
    expect(
      restored.engineConfig(SttProvider.qwen).baseUrl,
      'https://dashscope-intl.aliyuncs.com',
    );
    expect(restored.sonioxApiKey, 'soniox-key');
  });

  test('legacy flat Qwen keys migrate into the grouped engines map', () {
    final settings = AppSettings.fromJson(const {
      'speechProvider': 'qwen',
      'qwenApiKey': 'qwen-key',
      'qwenBaseUrl': 'https://dashscope-intl.aliyuncs.com/api/v1/',
      'qwenModel': 'qwen-audio-3.1-asr-flash-filetrans',
      'sonioxApiKey': 'soniox-key',
      'mossApiKey': 'moss-key',
      'autoTranscribe': false,
      'transcriptLanguage': 'ja',
    });

    final qwen = settings.engineConfig(SttProvider.qwen);
    expect(qwen.apiKey, 'qwen-key');
    expect(qwen.baseUrl, 'https://dashscope-intl.aliyuncs.com/api/v1/');
    expect(qwen.model, 'qwen-audio-3.1-asr-flash-filetrans');
    expect(settings.speechProvider, SttProvider.qwen);
    // Neighbouring settings are untouched by the migration.
    expect(settings.sonioxApiKey, 'soniox-key');
    expect(settings.mossApiKey, 'moss-key');
    expect(settings.autoTranscribe, isFalse);
    expect(settings.transcriptLanguage, 'ja');
  });

  test('upgraded settings write the new grouped format only', () {
    final settings = AppSettings.fromJson(const {
      'speechProvider': 'qwen',
      'qwenApiKey': 'qwen-key',
      'qwenBaseUrl': 'https://dashscope-intl.aliyuncs.com',
      'qwenModel': 'qwen-audio-3.1-asr-flash-filetrans',
      'sonioxApiKey': 'soniox-key',
    });

    final json = settings.toJson();
    expect(json['engines'], {
      'qwen': {
        'apiKey': 'qwen-key',
        'baseUrl': 'https://dashscope-intl.aliyuncs.com',
        'model': 'qwen-audio-3.1-asr-flash-filetrans',
      },
    });
    expect(json, isNot(contains('qwenApiKey')));
    expect(json, isNot(contains('qwenBaseUrl')));
    expect(json, isNot(contains('qwenModel')));
    // Soniox / Moss keep their existing flat keys.
    expect(json['sonioxApiKey'], 'soniox-key');

    // Round-trip: new format reloads without losing fields.
    final restored = AppSettings.fromJson(json);
    final qwen = restored.engineConfig(SttProvider.qwen);
    expect(qwen.apiKey, 'qwen-key');
    expect(qwen.baseUrl, 'https://dashscope-intl.aliyuncs.com');
    expect(qwen.model, 'qwen-audio-3.1-asr-flash-filetrans');
  });

  test('empty engine config omits the engines key entirely', () {
    const settings = AppSettings();
    expect(settings.toJson(), isNot(contains('engines')));
    expect(AppSettings.fromJson(const {}).engineConfig(SttProvider.qwen),
        const EngineConfig());
  });

  test('nested engines map wins over legacy flat keys', () {
    final settings = AppSettings.fromJson({
      'engines': {
        'qwen': {'apiKey': 'nested-key'},
      },
      'qwenApiKey': 'flat-key',
    });

    expect(settings.engineConfig(SttProvider.qwen).apiKey, 'nested-key');
  });

  test('store upgrades a legacy settings file on disk losslessly', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final directory = await Directory.systemTemp.createTemp('engine-config-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      await directory.delete(recursive: true);
    });

    // A pre-upgrade settings file written by the old three-field format.
    final legacyFile = File(
      '${directory.path}/AnkerRecorder/app_settings.json',
    );
    await legacyFile.parent.create(recursive: true);
    await legacyFile.writeAsString(
      JsonEncoder.withIndent('  ').convert({
        'speechProvider': 'qwen',
        'qwenApiKey': 'qwen-key',
        'qwenBaseUrl': 'https://dashscope-intl.aliyuncs.com',
        'qwenModel': 'qwen-audio-3.1-asr-flash-filetrans',
        'sonioxApiKey': 'soniox-key',
        'mossApiKey': 'moss-key',
        'autoTranscribe': false,
        'transcriptLanguage': 'ja',
        'translationTargetLanguage': 'en',
      }),
    );

    // Upgrade: load and save back.
    final loaded = await AppSettingsStore.load();
    await AppSettingsStore.save(loaded);

    final upgraded =
        jsonDecode(await legacyFile.readAsString()) as Map<String, dynamic>;
    expect(upgraded['engines'], {
      'qwen': {
        'apiKey': 'qwen-key',
        'baseUrl': 'https://dashscope-intl.aliyuncs.com',
        'model': 'qwen-audio-3.1-asr-flash-filetrans',
      },
    });
    expect(upgraded, isNot(contains('qwenApiKey')));
    expect(upgraded['sonioxApiKey'], 'soniox-key');
    expect(upgraded['mossApiKey'], 'moss-key');
    expect(upgraded['speechProvider'], 'qwen');
    expect(upgraded['autoTranscribe'], false);
    expect(upgraded['transcriptLanguage'], 'ja');
    expect(upgraded['translationTargetLanguage'], 'en');
  });
}
