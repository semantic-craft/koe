import '../ai/speech_provider.dart';
import '../ai/stt_types.dart';

/// Immutable snapshot of the speech settings one recording take was captured
/// with. Deferred engines replay this snapshot when the take stops, so later
/// setting changes never rewrite history.
class SpeechConfiguration {
  const SpeechConfiguration({
    required this.provider,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.ownerLanguage,
    required this.guestLanguage,
    required this.mode,
    required this.enabled,
    required this.appleReady,
    required this.appleTranslationReady,
    this.sonioxKey,
    this.mossKey,
    this.qwenKey,
    this.qwenBaseUrl,
    this.qwenModel,
    this.doubaoKey,
    this.doubaoBaseUrl,
    this.doubaoModel,
  });
  final SttProvider provider;
  final String sourceLanguage;
  final String targetLanguage;
  final String ownerLanguage;
  final String guestLanguage;
  final SttDisplayMode mode;
  final bool enabled;
  final bool appleReady;
  final bool appleTranslationReady;
  final String? sonioxKey;
  final String? mossKey;
  final String? qwenKey;
  final String? qwenBaseUrl;
  final String? qwenModel;
  final String? doubaoKey;
  final String? doubaoBaseUrl;
  final String? doubaoModel;

  SpeechConfiguration withSourceLanguage(String source) => SpeechConfiguration(
    provider: provider,
    sourceLanguage: source,
    targetLanguage: targetLanguage,
    ownerLanguage: ownerLanguage,
    guestLanguage: guestLanguage,
    mode: mode,
    enabled: enabled,
    appleReady: appleReady,
    appleTranslationReady: appleTranslationReady,
    sonioxKey: sonioxKey,
    mossKey: mossKey,
    qwenKey: qwenKey,
    qwenBaseUrl: qwenBaseUrl,
    qwenModel: qwenModel,
    doubaoKey: doubaoKey,
    doubaoBaseUrl: doubaoBaseUrl,
    doubaoModel: doubaoModel,
  );
}
