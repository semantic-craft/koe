import 'package:anker_recorder/ai/doubao_stt.dart';
import 'package:anker_recorder/ai/engine_config.dart';
import 'package:anker_recorder/ai/qwen_stt.dart';
import 'package:anker_recorder/state/recorder_controller.dart';
import 'package:anker_recorder/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(RecorderController controller) => ChangeNotifierProvider.value(
    value: controller,
    child: const MaterialApp(home: SettingsScreen()),
  );

  test('setQwenConfig saves the credential trio as one group', () {
    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);

    controller.setQwenConfig(
      const EngineConfig(
        apiKey: ' qwen-key ',
        baseUrl: 'dashscope-intl.aliyuncs.com/api/v1/',
        model: ' qwen-audio-3.1-asr-flash-filetrans ',
      ),
    );

    final config = controller.engineConfig(SttProvider.qwen);
    expect(config.apiKey, 'qwen-key');
    expect(config.baseUrl, 'https://dashscope-intl.aliyuncs.com');
    expect(config.model, 'qwen-audio-3.1-asr-flash-filetrans');
    expect(controller.engineConfigured(SttProvider.qwen), isTrue);

    // Saving a fresh object clears whatever it omits.
    controller.setQwenConfig(
      const EngineConfig(baseUrl: 'https://dashscope-intl.aliyuncs.com'),
    );
    final cleared = controller.engineConfig(SttProvider.qwen);
    expect(cleared.apiKey, isNull);
    expect(cleared.model, isNull);
    expect(cleared.baseUrl, 'https://dashscope-intl.aliyuncs.com');
    expect(controller.engineConfigured(SttProvider.qwen), isFalse);
  });

  test('setQwenConfig rejects an invalid base URL without saving', () {
    final controller = RecorderController(loadPersistedState: false)
      ..setQwenConfig(const EngineConfig(apiKey: 'qwen-key'));
    addTearDown(controller.dispose);

    expect(
      () => controller.setQwenConfig(
        const EngineConfig(apiKey: 'qwen-key', baseUrl: 'http://bad'),
      ),
      throwsA(isA<QwenSttException>()),
    );
    final config = controller.engineConfig(SttProvider.qwen);
    expect(config.apiKey, 'qwen-key');
    expect(config.baseUrl, isNull);
    expect(controller.engineConfigured(SttProvider.qwen), isTrue);
  });

  test('setDoubaoConfig saves the credential trio as one group', () {
    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);

    controller.setDoubaoConfig(
      const EngineConfig(
        apiKey: ' doubao-key ',
        baseUrl: 'openspeech.bytedance.com/api/v3/',
        model: ' volc.bigasr.auc_turbo ',
      ),
    );

    final config = controller.engineConfig(SttProvider.doubao);
    expect(config.apiKey, 'doubao-key');
    expect(config.baseUrl, 'https://openspeech.bytedance.com');
    expect(config.model, 'volc.bigasr.auc_turbo');
    expect(controller.engineConfigured(SttProvider.doubao), isTrue);

    // Saving a fresh object clears whatever it omits.
    controller.setDoubaoConfig(const EngineConfig(apiKey: 'doubao-key'));
    final cleared = controller.engineConfig(SttProvider.doubao);
    expect(cleared.baseUrl, isNull);
    expect(cleared.model, isNull);
    expect(cleared.apiKey, 'doubao-key');
  });

  test('setDoubaoConfig rejects an invalid base URL without saving', () {
    final controller = RecorderController(loadPersistedState: false)
      ..setDoubaoConfig(const EngineConfig(apiKey: 'doubao-key'));
    addTearDown(controller.dispose);

    expect(
      () => controller.setDoubaoConfig(
        const EngineConfig(apiKey: 'doubao-key', baseUrl: 'http://bad'),
      ),
      throwsA(isA<DoubaoSttException>()),
    );
    final config = controller.engineConfig(SttProvider.doubao);
    expect(config.apiKey, 'doubao-key');
    expect(config.baseUrl, isNull);
    expect(controller.engineConfigured(SttProvider.doubao), isTrue);
  });

  test('Doubao config is independent of the Qwen trio', () {
    final controller = RecorderController(loadPersistedState: false)
      ..setQwenConfig(const EngineConfig(apiKey: 'qwen-key'))
      ..setDoubaoConfig(const EngineConfig(apiKey: 'doubao-key'));
    addTearDown(controller.dispose);

    expect(controller.engineConfig(SttProvider.qwen).apiKey, 'qwen-key');
    expect(controller.engineConfig(SttProvider.doubao).apiKey, 'doubao-key');
    expect(controller.engineConfigured(SttProvider.doubao), isTrue);
    expect(controller.engineConfigured(SttProvider.qwen), isTrue);
  });

  test('engineConfig exposes the key-only engines', () {
    final controller = RecorderController(loadPersistedState: false)
      ..setSonioxApiKey('soniox-key');
    addTearDown(controller.dispose);

    expect(controller.engineConfig(SttProvider.soniox).apiKey, 'soniox-key');
    expect(controller.engineConfigured(SttProvider.soniox), isTrue);
    expect(controller.engineConfigured(SttProvider.moss), isFalse);
    expect(controller.engineConfig(SttProvider.qwen), const EngineConfig());
  });

  testWidgets('engine lineup renders every provider from data', (
    tester,
  ) async {
    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(controller));

    expect(find.text('共 ${SttProvider.values.length} 个引擎'), findsOneWidget);
    for (final provider in SttProvider.values) {
      expect(
        find.byKey(ValueKey('speech-provider-option-${provider.name}')),
        findsOneWidget,
      );
      expect(find.text(provider.label), findsWidgets);
    }
  });

  testWidgets('unconfigured cloud engine is visible but not selectable', (
    tester,
  ) async {
    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(controller));

    expect(controller.engineConfigured(SttProvider.qwen), isFalse);
    await tester.tap(
      find.byKey(const ValueKey('speech-provider-option-qwen')),
    );
    await tester.pump();

    expect(controller.speechProvider, SttProvider.soniox);
    expect(find.text('请先配置 通义 Qwen 的访问密钥'), findsOneWidget);
  });

  testWidgets('tapping a configured engine card selects it', (tester) async {
    final controller = RecorderController(loadPersistedState: false)
      ..setQwenConfig(const EngineConfig(apiKey: 'qwen-key'));
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(controller));

    await tester.tap(
      find.byKey(const ValueKey('speech-provider-option-qwen')),
    );
    await tester.pump();

    expect(controller.speechProvider, SttProvider.qwen);
    expect(find.text('使用中'), findsOneWidget);
  });

  testWidgets('Qwen trio saves as a group from the settings form', (
    tester,
  ) async {
    final controller = RecorderController(loadPersistedState: false)
      ..setSpeechProvider(SttProvider.qwen)
      ..setQwenConfig(const EngineConfig(apiKey: 'old-key'));
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(controller));

    await tester.enterText(
      find.byKey(const ValueKey('apikey-qwen')),
      'new-key',
    );
    await tester.enterText(
      find.byKey(const ValueKey('qwen-base-url')),
      'dashscope-intl.aliyuncs.com/api/v1/',
    );
    await tester.enterText(
      find.byKey(const ValueKey('qwen-model')),
      'qwen-audio-3.1-asr-flash-filetrans',
    );
    await tester.scrollUntilVisible(
      find.text('保存'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pump();

    final config = controller.engineConfig(SttProvider.qwen);
    expect(config.apiKey, 'new-key');
    expect(config.baseUrl, 'https://dashscope-intl.aliyuncs.com');
    expect(config.model, 'qwen-audio-3.1-asr-flash-filetrans');
  });

  testWidgets('invalid trio is rejected with a readable message', (
    tester,
  ) async {
    final controller = RecorderController(loadPersistedState: false)
      ..setSpeechProvider(SttProvider.qwen)
      ..setQwenConfig(const EngineConfig(apiKey: 'old-key'));
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(controller));

    await tester.enterText(
      find.byKey(const ValueKey('apikey-qwen')),
      'new-key',
    );
    await tester.enterText(
      find.byKey(const ValueKey('qwen-base-url')),
      'http://bad',
    );
    await tester.scrollUntilVisible(
      find.text('保存'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(find.text('通义服务地址需要 HTTPS'), findsOneWidget);
    expect(controller.engineConfig(SttProvider.qwen).apiKey, 'old-key');
  });

  testWidgets('unconfigured Doubao card is visible but not selectable', (
    tester,
  ) async {
    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(controller));

    expect(controller.engineConfigured(SttProvider.doubao), isFalse);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('speech-provider-option-doubao')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -80));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('speech-provider-option-doubao')),
    );
    await tester.pump();

    expect(controller.speechProvider, SttProvider.soniox);
    expect(find.text('请先配置 豆包 的访问密钥'), findsOneWidget);
  });

  testWidgets('a configured Doubao card selects it', (tester) async {
    final controller = RecorderController(loadPersistedState: false)
      ..setDoubaoConfig(const EngineConfig(apiKey: 'doubao-key'));
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(controller));

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('speech-provider-option-doubao')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -80));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('speech-provider-option-doubao')),
    );
    await tester.pump();

    expect(controller.speechProvider, SttProvider.doubao);
    expect(find.text('使用中'), findsOneWidget);
  });

  testWidgets('Doubao trio saves as a group from the settings form', (
    tester,
  ) async {
    final controller = RecorderController(loadPersistedState: false)
      ..setSpeechProvider(SttProvider.doubao)
      ..setDoubaoConfig(const EngineConfig(apiKey: 'old-key'));
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(controller));

    await tester.enterText(
      find.byKey(const ValueKey('apikey-doubao')),
      'new-key',
    );
    await tester.enterText(
      find.byKey(const ValueKey('doubao-base-url')),
      'openspeech.bytedance.com/api/v3/',
    );
    await tester.enterText(
      find.byKey(const ValueKey('doubao-model')),
      'volc.bigasr.auc_turbo',
    );
    await tester.scrollUntilVisible(
      find.text('保存'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pump();

    final config = controller.engineConfig(SttProvider.doubao);
    expect(config.apiKey, 'new-key');
    expect(config.baseUrl, 'https://openspeech.bytedance.com');
    expect(config.model, 'volc.bigasr.auc_turbo');
  });

  testWidgets('invalid Doubao trio is rejected with a readable message', (
    tester,
  ) async {
    final controller = RecorderController(loadPersistedState: false)
      ..setSpeechProvider(SttProvider.doubao)
      ..setDoubaoConfig(const EngineConfig(apiKey: 'old-key'));
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(controller));

    await tester.enterText(
      find.byKey(const ValueKey('doubao-base-url')),
      'http://bad',
    );
    await tester.scrollUntilVisible(
      find.text('保存'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(find.text('豆包服务地址需要 HTTPS'), findsOneWidget);
    expect(controller.engineConfig(SttProvider.doubao).apiKey, 'old-key');
  });
}
