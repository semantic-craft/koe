// Android scenario: a phone take keeps recording behind the lock screen for
// two minutes as microphone work of Koe's foreground service, and 停止 on
// its notification saves an original whose audio is real sound, not the
// digital silence Android feeds a background app that lost the microphone.
// Run with `scripts/android-check`, which grants the microphone first and
// turns the screen off and on when asked.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:koe/state/recorder_controller.dart';

import 'background_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'phone recording keeps recording behind the lock screen and 停止 on its '
    'notification saves the original',
    timeout: const Timeout(Duration(minutes: 5)),
    (tester) async {
      final dir = await Directory.systemTemp.createTemp('koe-phone-bg-');
      final controller = RecorderController(
        loadPersistedState: false,
        libraryDirectory: Directory('${dir.path}/imports'),
        phoneRecordingEnabled: true,
        placeCapture: NoPlace(),
      );
      final tone = await Tone.play();
      addTearDown(() async {
        wakeScreen();
        await tone.stop();
        if (controller.phoneRecordingActive) {
          await controller.discardPhoneRecording();
        }
        controller.dispose();
        await dir.delete(recursive: true);
      });

      await controller.startPhoneRecording();
      expect(controller.phoneRecordingError, isNull);
      expect(controller.phoneRecordingActive, isTrue);
      final started = await serviceStatusWhen(
        (s) => s['running'] == true && s['notificationPosted'] == true,
      );
      expect(started['types'], ['microphone']);
      expect(started['text'], 'Koe 正在录音');
      expect(started['actions'], ['停止']);

      await leaveAndLockScreen();
      await Future<void>.delayed(const Duration(minutes: 2));

      final behind = await serviceStatus();
      expect(behind['running'], isTrue);
      expect(behind['screenInteractive'], isFalse);
      expect(behind['text'], 'Koe 正在录音');
      expect(controller.phoneRecordingPaused, isFalse);

      // Stop from the notification, as from the lock screen.
      expect(await native.invokeMethod<bool>('pressStop'), isTrue);
      await waitUntil(() => controller.library.assets.isNotEmpty);
      final stopped = await serviceStatusWhen(
        (s) => s['running'] == false && s['notificationPosted'] == false,
      );
      expect(stopped['running'], isFalse);
      expect(controller.phoneRecordingActive, isFalse);

      final asset = controller.library.assets.single;
      expect(asset.source, RecordingSource.phone);
      final wav = await File(asset.path).readAsBytes();
      final header = ByteData.sublistView(wav);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(header.getUint32(4, Endian.little), wav.length - 8);
      final seconds = (wav.length - 44) / 32000;
      expect(seconds, greaterThanOrEqualTo(118), reason: '$seconds s');
      // The last minute, all of it behind the lock screen, holds the tone.
      final (level, zeros) = pcmLevel(
        Uint8List.sublistView(wav, wav.length - 32000 * 60),
      );
      // ignore: avoid_print
      print(
        'phone take: ${seconds.toStringAsFixed(1)} s, last minute '
        'level ${level.toStringAsFixed(0)}, zeros '
        '${(zeros * 100).toStringAsFixed(1)}%',
      );
      expect(zeros, lessThan(0.2));
      expect(level, greaterThan(100));
    },
  );
}
