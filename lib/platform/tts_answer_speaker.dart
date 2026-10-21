import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'answer_speaker.dart';

/// Android's system TextToSpeech through flutter_tts (#342). Like the
/// iPhone's AVSpeechSynthesizer it is a synthetic voice, never recorded
/// audio.
class TtsAnswerSpeaker implements AnswerSpeaker {
  TtsAnswerSpeaker({FlutterTts Function()? engine})
    : _engine = engine ?? FlutterTts.new;

  /// Android refuses longer utterances outright
  /// (`TextToSpeech.getMaxSpeechInputLength()` is 4000), and flutter_tts
  /// 4.2.5 then waits forever instead of failing, so long answers go in parts.
  static const maxUtterance = 3900;

  final FlutterTts Function() _engine;
  Future<FlutterTts>? _tts;

  /// Bumped by every [speak] and [stop]; a part read for an older call is
  /// the last one it reads.
  int _generation = 0;
  bool _speaking = false;

  @override
  bool get available =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<FlutterTts> _setUp() async {
    final tts = _engine();
    // speak() then completes when the utterance ends, or when stop() cuts
    // it off, which is what AnswerSpeaker promises.
    await tts.awaitSpeakCompletion(true);
    // Answers are Chinese; without a Chinese voice the engine keeps its
    // default one rather than reading nothing.
    await tts.setLanguage('zh-CN');
    return tts;
  }

  @override
  Future<void> speak(String text) async {
    if (!available) return;
    final tts = await (_tts ??= _setUp());
    final generation = ++_generation;
    // flutter_tts drops a new utterance while one is still being read.
    if (_speaking) await tts.stop();
    _speaking = true;
    try {
      for (final part in utteranceParts(text)) {
        if (generation != _generation) return;
        await tts.speak(part);
      }
    } finally {
      if (generation == _generation) _speaking = false;
    }
  }

  @override
  Future<void> stop() async {
    if (!available) return;
    _generation++;
    _speaking = false;
    final tts = _tts;
    if (tts != null) await (await tts).stop();
  }
}

/// [text] cut into parts Android will read, at line or sentence ends where
/// it can.
@visibleForTesting
List<String> utteranceParts(
  String text, {
  int max = TtsAnswerSpeaker.maxUtterance,
}) {
  final parts = <String>[];
  var rest = text.trim();
  while (rest.length > max) {
    var cut = rest.lastIndexOf('\n', max);
    if (cut <= 0) cut = rest.lastIndexOf(RegExp(r'[。！？；.!?;]'), max - 1) + 1;
    if (cut <= 0) cut = max;
    parts.add(rest.substring(0, cut).trim());
    rest = rest.substring(cut).trim();
  }
  if (rest.isNotEmpty) parts.add(rest);
  return parts;
}
