import 'package:anker_recorder/ai/stt_types.dart';
import 'package:anker_recorder/state/recorder_controller.dart';
import 'package:anker_recorder/ui/screens/device_screen.dart';
import 'package:anker_recorder/ui/screens/home_screen.dart';
import 'package:anker_recorder/ui/screens/communication_screen.dart';
import 'package:anker_recorder/ui/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('disconnected recorder cannot leave the live page active', () {
    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);

    controller
      ..connected = true
      ..recording = true;
    expect(controller.isLiveSession, isTrue);

    controller
      ..recording = false
      ..streamingSttActive = true;
    expect(controller.isLiveSession, isTrue);

    controller
      ..connected = false
      ..recording = true;
    expect(controller.isLiveSession, isFalse);
  });

  testWidgets('Home displays recording history tabs while idle', (
    tester,
  ) async {
    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    expect(find.byKey(const ValueKey('live-transcript-scroll')), findsNothing);
    expect(
      find.byKey(const ValueKey('live-transcript-placeholder')),
      findsNothing,
    );
    expect(find.text('本地'), findsOneWidget);
    expect(find.text('设备端'), findsOneWidget);
  });

  test('cloud ASR does not offer unsupported translation or conversation', () {
    final c = RecorderController(loadPersistedState: false);
    addTearDown(c.dispose);
    for (final provider in [SttProvider.qwen, SttProvider.doubao]) {
      c.setSpeechProvider(provider);
      c.setSttMode(SttDisplayMode.translation);
      expect(c.sttMode, SttDisplayMode.transcription);
      c.setSttMode(SttDisplayMode.conversation);
      expect(c.communicationModeActive, isFalse);
    }
  });

  testWidgets('connected Device uses flat management sections', (tester) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = RecorderController(loadPersistedState: false)
      ..connected = true;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: DeviceScreen()),
      ),
    );

    for (final key in [
      'device-battery-section',
      'device-recording-section',
      'device-pairing-section',
      'device-info-section',
      'device-danger-section',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }
    expect(find.text('绑定后播报（实验）'), findsNothing);
    expect(find.byType(SurfaceCard), findsNothing);
  });

  testWidgets('communication detail keeps equal rotated panels after pause', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = RecorderController(loadPersistedState: false)
      ..connected = true
      ..recording = true
      ..autoTranscribe = true
      ..sttMode = SttDisplayMode.conversation
      ..ownerLanguage = 'zh'
      ..guestLanguage = 'en'
      ..ownerTranslationTurns = const [
        SttTranslationTurn(
          targetLanguage: 'zh',
          sourceLanguage: 'en',
          text: '第一句',
          isFinal: true,
        ),
        SttTranslationTurn(
          targetLanguage: 'zh',
          sourceLanguage: 'en',
          text: '第二句',
          isFinal: true,
        ),
        SttTranslationTurn(
          targetLanguage: 'zh',
          sourceLanguage: 'en',
          text: '最新一句',
          isFinal: false,
        ),
      ]
      ..guestTranslationTurns = const [
        SttTranslationTurn(
          targetLanguage: 'en',
          sourceLanguage: 'zh',
          text: 'Latest translation',
          isFinal: true,
        ),
      ];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: CommunicationScreen()),
      ),
    );

    expect(find.text('首页'), findsNothing);
    expect(find.byKey(const ValueKey('communication-owner-panel')), findsOne);
    expect(find.byKey(const ValueKey('communication-guest-panel')), findsOne);
    expect(find.text('第一句'), findsOne);
    expect(find.text('第二句'), findsOne);
    expect(find.text('最新一句'), findsOne);
    expect(find.text('Latest translation'), findsOne);

    final ownerSize = tester.getSize(
      find.byKey(const ValueKey('communication-owner-panel')),
    );
    final guestSize = tester.getSize(
      find.byKey(const ValueKey('communication-guest-panel')),
    );
    expect(ownerSize.height, moreOrLessEquals(guestSize.height));

    final rotation = tester.widget<RotatedBox>(
      find.byKey(const ValueKey('communication-guest-rotation')),
    );
    expect(rotation.quarterTurns, 2);

    controller
      ..transcriptError = '交流模式错误：test'
      ..notifyListeners();
    await tester.pump();
    expect(find.text('交流模式错误：test'), findsOneWidget);

    controller
      ..transcriptError = null
      ..ownerTranslationTurns = const []
      ..guestTranslationTurns = const []
      ..notifyListeners();
    await tester.pump();
    expect(find.text('…'), findsNWidgets(2));

    controller
      ..recording = false
      ..streamingSttActive = false
      ..notifyListeners();
    await tester.pump();
    expect(find.text('双向交流'), findsOneWidget);
    expect(find.byKey(const ValueKey('communication-pause')), findsOneWidget);
  });
}
