// Android scenario: all-day listening keeps recognizing behind the lock
// screen as microphone work of Koe's foreground service, and 停止 on its
// notification saves the text and ends listening for good. Recognition goes
// through the real DashScope streaming client to a stand-in endpoint on the
// phone (background_support.dart), so no key is needed; the phone plays a
// tone into its own microphone as the speech. Run with
// `scripts/android-check`.
import 'dart:io';

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
    'all-day listening keeps recognizing behind the lock screen and 停止 on '
    'its notification saves the text',
    timeout: const Timeout(Duration(minutes: 4)),
    (tester) async {
      final dir = await Directory.systemTemp.createTemp('koe-all-day-bg-');
      final cloud = await StandInRecognizer.start();
      RecorderController build() => RecorderController(
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
      final controller = build();
      final tone = await Tone.play();
      addTearDown(() async {
        wakeScreen();
        await tone.stop();
        if (controller.textCaptureActive) {
          await controller.discardTextCapture();
        }
        controller.dispose();
        await cloud.close();
        await dir.delete(recursive: true);
      });

      expect(await controller.startTextCapture(allDay: true), isTrue);
      final started = await serviceStatusWhen(
        (s) => s['running'] == true && s['notificationPosted'] == true,
      );
      expect(started['types'], ['microphone']);
      expect(started['text'], 'Koe 正在全天监听（只留文字）');
      expect(started['actions'], ['停止']);
      await waitUntil(() => controller.textCaptureText.contains('亮屏'));
      expect(controller.textCaptureText, contains('亮屏'));

      cloud.phase = '锁屏';
      final sentAtLock = cloud.audioBytes;
      await leaveAndLockScreen();
      await Future<void>.delayed(const Duration(seconds: 60));

      final behind = await serviceStatus();
      expect(behind['running'], isTrue);
      expect(behind['screenInteractive'], isFalse);
      final sentBehind = (cloud.audioBytes - sentAtLock) / 32000;
      // ignore: avoid_print
      print(
        'all-day: ${sentBehind.toStringAsFixed(1)} s of audio sent and '
        '${cloud.sentences.where((s) => s.startsWith('锁屏')).length} '
        'sentences recognized behind the lock screen',
      );
      expect(sentBehind, greaterThan(50));
      expect(controller.textCaptureText, contains('锁屏'));

      expect(await native.invokeMethod<bool>('pressStop'), isTrue);
      await waitUntil(() => !controller.textCaptureActive);
      final stopped = await serviceStatusWhen(
        (s) => s['running'] == false && s['notificationPosted'] == false,
      );
      expect(stopped['running'], isFalse);
      expect(controller.textCaptureActive, isFalse);
      final saved = controller.minutesDocuments.map((d) => d.bodyText).join();
      expect(saved, contains('锁屏'));
      expect(controller.library.assets, isEmpty, reason: 'only text is kept');

      // Reopening Koe does not start listening again on its own.
      final reopened = build();
      addTearDown(reopened.dispose);
      await reopened.waitForMinutesDocuments();
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(reopened.textCaptureActive, isFalse);
      expect((await serviceStatus())['running'], isFalse);
    },
  );
}
