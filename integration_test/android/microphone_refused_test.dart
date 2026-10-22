// Android scenario: microphone work begun while Koe is off screen. Android
// 14+ will not run Koe's foreground service as microphone then, so Koe stops
// that work and says why instead of showing it as running, and all-day
// listening starts again by itself once Koe is back on screen.
// `scripts/android-check` takes Koe to the home screen and later brings it
// back as its launcher icon does. Recognition goes to a stand-in endpoint on
// the phone (background_support.dart), so no key is needed. On a phone
// locked with a PIN the scenario is skipped: nothing could bring Koe back.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:koe/ai/cloud_stt_stream.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/state/minutes_document.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';

import 'background_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'all-day listening begun off screen stops, says why and listens again '
    'once Koe is back on screen',
    timeout: const Timeout(Duration(minutes: 2)),
    (tester) async {
      if (await skipIfLocked('microphone_refused_test.dart')) return;
      final dir = await Directory.systemTemp.createTemp('koe-mic-refused-');
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
      final tone = await Tone.play();
      addTearDown(() async {
        await tone.stop();
        if (controller.textCaptureActive) {
          await controller.discardTextCapture();
        }
        controller.dispose();
        await cloud.close();
        await dir.delete(recursive: true);
      });

      await leaveForHomeScreen(tester);
      expect(await controller.startTextCapture(allDay: true), isTrue);
      await waitUntil(() => !controller.textCaptureActive);
      final refused = await serviceStatusWhen(
        (s) => s['running'] == false && s['notificationPosted'] == false,
      );
      expect(
        controller.textCaptureActive,
        isFalse,
        reason: refused['running'] == true
            ? 'Android ran the service as ${refused['types']} off screen'
            : 'Koe kept listening after Android refused it the microphone',
      );
      expect(
        controller.textCaptureError,
        'Koe 不在屏幕上时 Android 不让它开始用麦克风，回到 Koe 后接着听',
      );
      expect(refused['running'], isFalse);
      expect(refused['notificationPosted'], isFalse);

      await openKoe(tester);
      await waitUntil(() => controller.textCaptureActive);
      expect(
        controller.textCaptureActive,
        isTrue,
        reason: 'all-day listening did not start again with Koe on screen',
      );
      expect(controller.textCaptureAllDay, isTrue);
      expect(controller.textCaptureError, isNull);
      final listening = await serviceStatusWhen(
        (s) => s['running'] == true && s['notificationPosted'] == true,
      );
      expect(listening['types'], ['microphone']);
      expect(listening['text'], 'Koe 正在全天监听（只留文字）');
      await waitUntil(() => controller.textCaptureText.isNotEmpty);
      expect(controller.textCaptureText, contains('亮屏'));
    },
  );

  testWidgets(
    '手机录音 begun off screen stops and says why',
    timeout: const Timeout(Duration(minutes: 2)),
    (tester) async {
      if (await skipIfLocked('microphone_refused_test.dart')) return;
      final dir = await Directory.systemTemp.createTemp('koe-mic-refused-');
      final controller = RecorderController(
        loadPersistedState: false,
        libraryDirectory: Directory('${dir.path}/imports'),
        phoneRecordingEnabled: true,
        placeCapture: NoPlace(),
      );
      addTearDown(() async {
        if (controller.phoneRecordingActive) {
          await controller.discardPhoneRecording();
        }
        controller.dispose();
        await dir.delete(recursive: true);
      });

      await leaveForHomeScreen(tester);
      await controller.startPhoneRecording();
      await waitUntil(() => !controller.phoneRecordingActive);
      final refused = await serviceStatusWhen(
        (s) => s['running'] == false && s['notificationPosted'] == false,
      );
      expect(
        controller.phoneRecordingActive,
        isFalse,
        reason: refused['running'] == true
            ? 'Android ran the service as ${refused['types']} off screen'
            : 'Koe kept recording after Android refused it the microphone',
      );
      // Koe says why only once it has dealt with the stopped take.
      await waitUntil(() => controller.phoneRecordingError != null);
      expect(
        controller.phoneRecordingError,
        'Koe 不在屏幕上时 Android 不让它开始用麦克风，录音已停下',
      );
      expect(refused['running'], isFalse);
      expect(refused['notificationPosted'], isFalse);
      await openKoe(tester);
    },
  );
}

/// Takes Koe to the home screen, then waits out the grace Android gives an
/// app that was just on screen, in which it may still start microphone work.
Future<void> leaveForHomeScreen(WidgetTester tester) async {
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
  await Future<void>.delayed(const Duration(seconds: 15));
}

/// Brings Koe back on screen as its launcher icon does.
Future<void> openKoe(WidgetTester tester) async {
  // ignore: avoid_print
  print('KOE_ADB: open-koe');
  await waitUntil(
    () => tester.binding.lifecycleState == AppLifecycleState.resumed,
  );
  expect(
    tester.binding.lifecycleState,
    AppLifecycleState.resumed,
    reason: 'scripts/android-check did not bring Koe back',
  );
}
