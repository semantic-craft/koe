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
    this.cloudUploadConfirmed = false,
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

  /// One-shot user confirmation allowing this file transcription to upload
  /// meeting audio to a cloud engine while `meetingLocalOnly` is on (#376).
  /// Never persisted to disk.
  final bool cloudUploadConfirmed;

  /// The resolved credentials for [provider] (empty when never configured).
  EngineConfig engineConfig(SttProvider provider) =>
      engines[provider] ?? const EngineConfig();

  /// The resolved API key for [provider], or null.
  String? engineKey(SttProvider provider) => engineConfig(provider).apiKey;

  /// The same settings with recording transcription turned off.
  SpeechConfiguration withoutTranscription() => SpeechConfiguration(
    provider: provider,
    sourceLanguage: sourceLanguage,
    targetLanguage: targetLanguage,
    ownerLanguage: ownerLanguage,
    guestLanguage: guestLanguage,
    mode: mode,
    enabled: false,
    appleReady: appleReady,
    appleTranslationReady: appleTranslationReady,
    engines: engines,
  );

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
    cloudUploadConfirmed: cloudUploadConfirmed,
  );
}
