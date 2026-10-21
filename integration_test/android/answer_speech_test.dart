// Android scenario (#342): the Pixel's system TextToSpeech reads an Ask Koe
// answer to the end, and stop cuts a long one off. Run with
// `scripts/android-check integration_test/android/answer_speech_test.dart`.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:koe/platform/answer_speaker.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the system voice reads an answer to the end and stops on '
      'request', (tester) async {
    final speaker = SystemAnswerSpeaker();
    expect(speaker.available, isTrue);

    final started = DateTime.now();
    await speaker
        .speak(speakableAnswer('师傅说下周一开工 [S1]。'))
        .timeout(const Duration(seconds: 30));
    // Completing at once would mean the engine dropped the text unread.
    expect(
      DateTime.now().difference(started),
      greaterThan(const Duration(milliseconds: 500)),
    );

    final long = speaker.speak('这是一段很长的回答。' * 40);
    await Future<void>.delayed(const Duration(seconds: 2));
    final stopping = DateTime.now();
    await speaker.stop();
    await long.timeout(const Duration(seconds: 5));
    expect(
      DateTime.now().difference(stopping),
      lessThan(const Duration(seconds: 5)),
    );
  });
}
