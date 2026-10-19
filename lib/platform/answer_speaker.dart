import 'dart:io';

import 'package:flutter/services.dart';

/// Reads Ask Koe answers aloud with the system's synthetic voice. It never
/// plays recorded audio, so the UI can label it plainly as synthetic.
abstract class AnswerSpeaker {
  /// Whether this device can read answers aloud at all.
  bool get available;

  /// Completes when the text has been read or [stop] cut it off.
  Future<void> speak(String text);

  Future<void> stop();
}

/// AVSpeechSynthesizer through `koe/answer_speech` (ios/Runner). iPhone only:
/// the Mac app does not register the channel.
class SystemAnswerSpeaker implements AnswerSpeaker {
  SystemAnswerSpeaker({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('koe/answer_speech');

  final MethodChannel _channel;

  @override
  bool get available => Platform.isIOS;

  @override
  Future<void> speak(String text) async {
    if (!available) return;
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
    if (!available) return;
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
