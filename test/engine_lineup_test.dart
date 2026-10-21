import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:koe/platform/credential_store.dart';
import 'support/settings_completion.dart';
import 'package:koe/ai/doubao_stt.dart';
import 'package:koe/ai/engine_config.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(RecorderController controller) => ChangeNotifierProvider.value(
    value: controller,
    child: const MaterialApp(home: SettingsScreen()),
  );

  testWidgets('first setup only asks for key and save closes and selects', (
    tester,
  ) async {
    final c = RecorderController(loadPersistedState: false);
    addTearDown(c.dispose);
    await tester.pumpWidget(wrap(c));
    for (final name in ['qwen', 'doubao']) {
      final card = find.byKey(ValueKey('speech-provider-option-$name'));
      await tester.ensureVisible(card);
      await tester.tap(card);
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      expect(
        find.descendant(of: dialog, matching: find.byType(TextField)),
        findsNWidgets(name == 'qwen' ? 2 : 1),
      );
      expect(find.text('服务地址'), findsNothing);
      expect(find.text('模型'), findsNothing);
      await tester.enterText(
        find.descendant(
          of: dialog,
          matching: find.byKey(ValueKey('apikey-$name')),
        ),
        '$name-key',
      );
      await tester.tap(find.descendant(of: dialog, matching: find.text('保存')));
      await tester.pump();
      await waitForSettings(tester, c);
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(c.speechProvider.name, name);
      expect(c.engineConfig(c.speechProvider).apiKey, '$name-key');
    }
  });

  testWidgets('Qwen workspace derives endpoint without asking for a URL', (
    tester,
  ) async {
    final c = RecorderController(loadPersistedState: false);
    c.setQwenConfig(const EngineConfig(apiKey: 'test-key'));
    await waitForSettings(tester, c);
    addTearDown(c.dispose);
    await tester.pumpWidget(wrap(c));
    await tester.enterText(
      find.byKey(const ValueKey('qwen-workspace')),
      'llm-test',
    );
    await tester.scrollUntilVisible(
      find.text('保存'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pump();
    await waitForSettings(tester, c);
    await tester.pump();
    await tester.pump();
    expect(
      c.engineConfig(SttProvider.qwen).baseUrl,
      'https://llm-test.cn-beijing.maas.aliyuncs.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('qwen-workspace')),
      'https://wrong.example',
    );
    await tester.tap(find.text('保存'));
    await tester.pump();
    await waitForSettings(tester, c);
    await tester.pump();
    await tester.pump();
    expect(find.text('请填写 Workspace ID，不需要填写网址'), findsOneWidget);
    expect(
      c.engineConfig(SttProvider.qwen).baseUrl,
      'https://llm-test.cn-beijing.maas.aliyuncs.com',
    );
  });

  test('setQwenConfig saves the credential trio as one group', () async {
    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);

    await controller.setQwenConfig(
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
    await controller.setQwenConfig(
      const EngineConfig(baseUrl: 'https://dashscope-intl.aliyuncs.com'),
    );
    final cleared = controller.engineConfig(SttProvider.qwen);
    expect(cleared.apiKey, isNull);
    expect(cleared.model, isNull);
    expect(cleared.baseUrl, 'https://dashscope-intl.aliyuncs.com');
    expect(controller.engineConfigured(SttProvider.qwen), isFalse);
  });

  test('setQwenConfig rejects an invalid base URL without saving', () async {
    final controller = RecorderController(loadPersistedState: false);
    await controller.setQwenConfig(const EngineConfig(apiKey: 'qwen-key'));
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

  test('setDoubaoConfig saves the credential trio as one group', () async {
    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);

    await controller.setDoubaoConfig(
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
    await controller.setDoubaoConfig(const EngineConfig(apiKey: 'doubao-key'));
    final cleared = controller.engineConfig(SttProvider.doubao);
    expect(cleared.baseUrl, isNull);
    expect(cleared.model, isNull);
    expect(cleared.apiKey, 'doubao-key');
  });

  test('setDoubaoConfig rejects an invalid base URL without saving', () async {
    final controller = RecorderController(loadPersistedState: false);
    await controller.setDoubaoConfig(const EngineConfig(apiKey: 'doubao-key'));
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

  test('Doubao config is independent of the Qwen trio', () async {
    final controller = RecorderController(loadPersistedState: false);
    await controller.setQwenConfig(const EngineConfig(apiKey: 'qwen-key'));
    await controller.setDoubaoConfig(const EngineConfig(apiKey: 'doubao-key'));
    addTearDown(controller.dispose);

    expect(controller.engineConfig(SttProvider.qwen).apiKey, 'qwen-key');
    expect(controller.engineConfig(SttProvider.doubao).apiKey, 'doubao-key');
    expect(controller.engineConfigured(SttProvider.doubao), isTrue);
    expect(controller.engineConfigured(SttProvider.qwen), isTrue);
  });

  test('retired engines have no credentials and cannot be selected', () async {
    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);

    expect(controller.engineConfig(SttProvider.soniox).apiKey, isNull);
    expect(controller.engineConfigured(SttProvider.soniox), isFalse);
    expect(controller.engineConfigured(SttProvider.moss), isFalse);
    expect(controller.engineConfig(SttProvider.qwen), const EngineConfig());
  });

  testWidgets('engine lineup renders every provider from data', (tester) async {
    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(controller));

    expect(find.text('共 ${SttProvider.available.length} 个引擎'), findsOneWidget);
    for (final provider in SttProvider.available) {
      expect(
        find.byKey(ValueKey('speech-provider-option-${provider.name}')),
        findsOneWidget,
      );
      expect(find.text(provider.label), findsWidgets);
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'unconfigured Qwen opens configuration without changing active provider',
    (tester) async {
      final controller = RecorderController(loadPersistedState: false);
      addTearDown(controller.dispose);
      await tester.pumpWidget(wrap(controller));

      expect(controller.engineConfigured(SttProvider.qwen), isFalse);
      await tester.tap(
        find.byKey(const ValueKey('speech-provider-option-qwen')),
      );
      await tester.pump();

      expect(controller.speechProvider, SttProvider.qwen);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byKey(const ValueKey('apikey-qwen')),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('tapping a configured engine card selects it', (tester) async {
    final controller = RecorderController(loadPersistedState: false);
    controller.setQwenConfig(const EngineConfig(apiKey: 'qwen-key'));
    await waitForSettings(tester, controller);
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(controller));

    await tester.tap(find.byKey(const ValueKey('speech-provider-option-qwen')));
    await tester.pump();

    expect(controller.speechProvider, SttProvider.qwen);
    expect(find.text('使用中'), findsOneWidget);
  });

  testWidgets('Qwen settings only edit API key', (tester) async {
    final controller = RecorderController(loadPersistedState: false);
    controller.setQwenConfig(const EngineConfig(apiKey: 'old-key'));
    await waitForSettings(tester, controller);
    controller.setSpeechProvider(SttProvider.qwen);
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(controller));
    expect(find.text('服务地址'), findsNothing);
    expect(find.text('模型'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('apikey-qwen')),
      'new-key',
    );
    await tester.scrollUntilVisible(
      find.text('保存'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pump();
    await waitForSettings(tester, controller);
    await tester.pump();
    await tester.pump();
    expect(controller.engineConfig(SttProvider.qwen).apiKey, 'new-key');
    expect(find.text('已保存'), findsOneWidget);
  });

  testWidgets('Qwen empty key is rejected without losing saved key', (
    tester,
  ) async {
    final controller = RecorderController(loadPersistedState: false);
    controller.setQwenConfig(const EngineConfig(apiKey: 'old-key'));
    await waitForSettings(tester, controller);
    controller.setSpeechProvider(SttProvider.qwen);
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(controller));
    await tester.enterText(find.byKey(const ValueKey('apikey-qwen')), '');
    await tester.scrollUntilVisible(
      find.text('保存'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pump();
    await waitForSettings(tester, controller);
    await tester.pump();
    await tester.pump();
    expect(find.text('请输入 API Key'), findsOneWidget);
    expect(controller.engineConfig(SttProvider.qwen).apiKey, 'old-key');
  });

  testWidgets(
    'unconfigured Doubao opens configuration without changing active provider',
    (tester) async {
      final controller = RecorderController(loadPersistedState: false);
      addTearDown(controller.dispose);
      await tester.pumpWidget(wrap(controller));

      expect(controller.engineConfigured(SttProvider.doubao), isFalse);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('speech-provider-option-doubao')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('speech-provider-option-doubao')),
      );
      await tester.pump();

      expect(controller.speechProvider, SttProvider.qwen);
      expect(find.byKey(const ValueKey('apikey-doubao')), findsOneWidget);
    },
  );

  testWidgets('a configured Doubao card selects it', (tester) async {
    final controller = RecorderController(loadPersistedState: false);
    controller.setDoubaoConfig(const EngineConfig(apiKey: 'doubao-key'));
    await waitForSettings(tester, controller);
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(controller));

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('speech-provider-option-doubao')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('speech-provider-option-doubao')),
    );
    await tester.pump();

    expect(controller.speechProvider, SttProvider.doubao);
    expect(find.text('使用中'), findsOneWidget);
  });

  testWidgets('Doubao settings only edit API key', (tester) async {
    final controller = RecorderController(loadPersistedState: false);
    controller.setDoubaoConfig(const EngineConfig(apiKey: 'old-key'));
    await waitForSettings(tester, controller);
    controller.setSpeechProvider(SttProvider.doubao);
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(controller));
    expect(find.text('服务地址'), findsNothing);
    expect(find.text('模型'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('apikey-doubao')),
      'new-key',
    );
    await tester.scrollUntilVisible(
      find.text('保存'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pump();
    await waitForSettings(tester, controller);
    await tester.pump();
    await tester.pump();
    expect(controller.engineConfig(SttProvider.doubao).apiKey, 'new-key');
    expect(find.text('已保存'), findsOneWidget);
  });

  testWidgets('Doubao empty key is rejected without losing saved key', (
    tester,
  ) async {
    final controller = RecorderController(loadPersistedState: false);
    controller.setDoubaoConfig(const EngineConfig(apiKey: 'old-key'));
    await waitForSettings(tester, controller);
    controller.setSpeechProvider(SttProvider.doubao);
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(controller));
    await tester.enterText(find.byKey(const ValueKey('apikey-doubao')), '');
    await tester.scrollUntilVisible(
      find.text('保存'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pump();
    await waitForSettings(tester, controller);
    await tester.pump();
    await tester.pump();
    expect(find.text('请输入 API Key'), findsOneWidget);
    expect(controller.engineConfig(SttProvider.doubao).apiKey, 'old-key');
  });
  testWidgets(
    'failed secure save keeps old key and exposes error, clear is explicit',
    (tester) async {
      final c = RecorderController(loadPersistedState: false);
      addTearDown(c.dispose);
      c.setQwenConfig(const EngineConfig(apiKey: 'fake-old'));
      await waitForSettings(tester, c);
      c.setSpeechProvider(SttProvider.qwen);
      await waitForSettings(tester, c);
      await tester.pumpWidget(wrap(c));
      final stored = jsonEncode(await CredentialStore().read());
      var fail = true;
      String? item = stored;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(CredentialStore.channel, (call) async {
            if (call.method == 'mode') return 'system';
            if (call.method == 'authorize') return null;
            if (call.method == 'read') return item;
            if (fail) throw PlatformException(code: 'locked');
            item = call.arguments as String;
            return null;
          });
      await tester.enterText(
        find.byKey(const ValueKey('apikey-qwen')),
        'fake-new',
      );
      await tester.scrollUntilVisible(
        find.text('保存'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await waitForSettings(tester, c);
      expect(c.engineConfig(SttProvider.qwen).apiKey, 'fake-old');
      expect(find.text('已保存'), findsNothing);
      expect(find.textContaining('无法确认系统安全存储状态'), findsOneWidget);
      fail = false;
      // Rollback could not be confirmed while locked: UI offers an explicit reload.
      await tester.scrollUntilVisible(
        find.text('重试读取安全配置'),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('重试读取安全配置'));
      for (var i = 0; i < 50 && c.settingsStorageError != null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      expect(c.settingsStorageError, isNull);
      await tester.scrollUntilVisible(
        find.text('清除已保存的 API Key'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('清除已保存的 API Key'));
      await waitForSettings(tester, c);
      expect(c.engineConfig(SttProvider.qwen).apiKey, isNull);
      expect(
        (await tester.runAsync(() => CredentialStore().read()))!['qwen'],
        isNull,
      );
      expect(find.textContaining('已清除已保存的 API Key'), findsOneWidget);
    },
  );
}
