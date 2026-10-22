// Android scenario: long-pressing the Koe icon offers 开始录音, and choosing
// it while Koe is off screen, with all-day listening switched on, enters
// all-day listening as microphone work of Koe's foreground service; Android
// 14 allows that only because the shortcut brings Koe back on screen.
// `scripts/android-check` goes to the home screen, checks the shortcut is
// registered and fires it the way the launcher does. Recognition goes to a
// stand-in endpoint on the phone (background_support.dart), so no key is
// needed. A cold launch from the shortcut cannot run here: it would end this
// test's process. On a phone locked with a PIN the scenario is skipped, and
// `scripts/android-check` exits 77.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:koe/ai/cloud_stt_stream.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/platform/recording_shortcut_service.dart';
import 'package:koe/state/minutes_document.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';

import 'background_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    '开始录音 on the Koe icon brings Koe back and enters all-day listening',
    timeout: const Timeout(Duration(minutes: 2)),
    (tester) async {
      final dir = await Directory.systemTemp.createTemp('koe-shortcut-');
      final cloud = await StandInRecognizer.start();
      final controller = RecorderController(
        loadPersistedState: false,
        analysisController: RecordingAnalysis(inMemory: true),
        qwenSpeech: QwenSttService()..apiKeyOverride = 'stand-in',
        transcriptPersister: ({bool strict = false}) async {},
        libraryDirectory: Directory('${dir.path}/imports'),
        minutesStore: MinutesDocumentStore(
          file: File('${dir.path}/minutes.json'),
        ),
        placeCapture: NoPlace(),
        phoneRecordingEnabled: true,
        speechStream: (config) =>
            QwenSttStreamSession(apiKey: 'stand-in', endpoint: cloud.endpoint),
      )..allDayListening = true;
      addTearDown(() async {
        if (controller.textCaptureActive) {
          await controller.discardTextCapture();
        }
        controller.dispose();
        await cloud.close();
        await dir.delete(recursive: true);
      });

      await RecordingShortcutService().initialize(
        onStartRecording: controller.requestRecordingFromShortcut,
      );
      // To the home screen, where the Koe icon is. moveTaskToBack is not
      // enough: a charging Pixel shows its clock screen saver instead, and
      // Koe stays resumed behind it.
      // ignore: avoid_print
      print('KOE_ADB: home');
      await waitUntil(
        () => tester.binding.lifecycleState == AppLifecycleState.paused,
      );
      expect(
        tester.binding.lifecycleState,
        AppLifecycleState.paused,
        reason: 'scripts/android-check did not take Koe off screen',
      );
      // Behind a lock screen with a PIN the shortcut still reaches Koe, but
      // Koe stays behind the lock screen and Android refuses it microphone
      // work. Nobody fires the shortcut there: the icon is only on the home
      // screen, after unlocking.
      if ((await serviceStatus())['deviceLocked'] == true) {
        const reason = '手机锁着，有锁屏密码；解锁后再跑 recording_shortcut_test.dart';
        // ignore: avoid_print
        print('KOE_ADB: skip $reason');
        markTestSkipped(reason);
        return;
      }
      final tone = await Tone.play();
      addTearDown(tone.stop);
      expect(controller.textCaptureActive, isFalse);

      // ignore: avoid_print
      print(
        'KOE_ADB: launch-shortcut '
        '${RecordingShortcutService.startRecordingShortcut.type}',
      );
      await waitUntil(() => controller.textCaptureActive);
      expect(
        controller.textCaptureActive,
        isTrue,
        reason: 'the shortcut did not reach Koe; see the android-check line',
      );
      await waitUntil(
        () => tester.binding.lifecycleState == AppLifecycleState.resumed,
      );
      expect(tester.binding.lifecycleState, AppLifecycleState.resumed);
      expect(controller.textCaptureAllDay, isTrue);
      expect(controller.errorMessage, isNull);

      final started = await serviceStatusWhen(
        (s) => s['running'] == true && s['notificationPosted'] == true,
      );
      expect(
        started['running'],
        isTrue,
        reason: 'Android refused the microphone work: Koe was not brought back',
      );
      expect(started['types'], ['microphone']);
      expect(started['text'], 'Koe 正在全天监听（只留文字）');
      await waitUntil(() => controller.textCaptureText.isNotEmpty);
      expect(controller.textCaptureText, contains('亮屏'));
    },
  );
}
