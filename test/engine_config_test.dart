import 'package:koe/ai/engine_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('constructs with the credential trio', () {
    const config = EngineConfig(
      apiKey: ' key ',
      baseUrl: 'https://dashscope.aliyuncs.com',
      model: 'qwen-audio-3.1-asr-flash-filetrans',
    );

    expect(config.apiKey, ' key ');
    expect(config.baseUrl, 'https://dashscope.aliyuncs.com');
    expect(config.model, 'qwen-audio-3.1-asr-flash-filetrans');
  });

  test('copyWith keeps unspecified fields and allows clearing', () {
    const config = EngineConfig(
      apiKey: 'key',
      baseUrl: 'https://dashscope.aliyuncs.com',
      model: 'model-a',
    );

    final updated = config.copyWith(model: 'model-b');
    expect(updated.apiKey, 'key');
    expect(updated.baseUrl, 'https://dashscope.aliyuncs.com');
    expect(updated.model, 'model-b');

    // copyWith(null) keeps the previous value; clearing a field is done by
    // saving a fresh EngineConfig that omits it (grouped replacement).
    final kept = config.copyWith(apiKey: null);
    expect(kept.apiKey, 'key');
    expect(kept.baseUrl, 'https://dashscope.aliyuncs.com');
  });

  test('serializes only filled fields and round-trips', () {
    const config = EngineConfig(apiKey: 'key', model: 'model-a');

    final json = config.toJson();
    expect(json, {'model': 'model-a'});

    final restored = EngineConfig.fromJson(json);
    expect(restored.apiKey, isNull);
    expect(restored.baseUrl, isNull);
    expect(restored.model, 'model-a');
  });

  test('fromJson trims values and treats blank or null as absent', () {
    final restored = EngineConfig.fromJson({
      'apiKey': '  ',
      'baseUrl': null,
      'model': ' model-a ',
    });

    expect(restored.apiKey, isNull);
    expect(restored.baseUrl, isNull);
    expect(restored.model, 'model-a');
    expect(const EngineConfig().toJson(), isEmpty);
  });

  test('isConfigured requires a non-blank API key', () {
    expect(const EngineConfig().isConfigured, isFalse);
    expect(const EngineConfig(apiKey: '   ').isConfigured, isFalse);
    expect(const EngineConfig(baseUrl: 'https://x').isConfigured, isFalse);
    expect(const EngineConfig(apiKey: 'key').isConfigured, isTrue);
  });
}
