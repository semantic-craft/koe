import '../ai/engine_config.dart';
import '../ai/speech_provider.dart';
import '../ai/stt_types.dart';

/// Immutable snapshot of the speech settings a recording was captured
/// with. Deferred engines replay this snapshot when the take stops, so
/// later settings changes never rewrite a taken recording.
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
    this.engines = const {},
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

  /// Credentials resolved at capture time, keyed by engine: the settings
  /// or environment API key, a base URL already normalized to its default
  /// when unset, and a defaulted model. Key-only engines carry only the
  /// key; Apple is absent.
  final Map<SttProvider, EngineConfig> engines;

  /// The resolved credentials for [provider] (empty when never configured).
  EngineConfig engineConfig(SttProvider provider) =>
      engines[provider] ?? const EngineConfig();

  /// The resolved API key for [provider], or null.
  String? engineKey(SttProvider provider) => engineConfig(provider).apiKey;

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
    engines: engines,
  );
}
