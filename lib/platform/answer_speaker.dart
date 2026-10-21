import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'tts_answer_speaker.dart';

/// Reads Ask Koe answers aloud with the system's synthetic voice. It never
/// plays recorded audio, so the UI can label it plainly as synthetic.
abstract class AnswerSpeaker {
  /// Whether this device can read answers aloud at all.
  bool get available;

  /// Completes when the text has been read or [stop] cut it off.
  Future<void> speak(String text);

  Future<void> stop();
}

/// The phone's own synthetic voice: AVSpeechSynthesizer through
/// `koe/answer_speech` (ios/Runner) on iPhone, [TtsAnswerSpeaker] on Android.
/// The Mac app does not register the channel and reads nothing.
class SystemAnswerSpeaker implements AnswerSpeaker {
  SystemAnswerSpeaker({MethodChannel? channel, AnswerSpeaker? android})
    : _channel = channel ?? const MethodChannel('koe/answer_speech'),
      _android = android ?? TtsAnswerSpeaker();

  final MethodChannel _channel;
  final AnswerSpeaker _android;

  bool get _onIPhone => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  bool get available => _onIPhone || _android.available;

  @override
  Future<void> speak(String text) async {
    if (!_onIPhone) return _android.speak(text);
    try {
      await _channel.invokeMethod<void>('speak', {
        'text': text,
        'language': 'zh-CN',
      });
    } on MissingPluginException {
      // An older native build without the channel reads nothing.
    }
  }

  @override
  Future<void> stop() async {
    if (!_onIPhone) return _android.stop();
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Nothing is being read.
    }
  }
}

/// Answer text as it should sound: citation labels such as [S3] are for the
/// eye and are dropped.
String speakableAnswer(String text) => text
    .replaceAll(RegExp(r'\s*\[S\d+\]'), '')
    .replaceAll(RegExp(r'\n{2,}'), '\n')
    .trim();
