import 'stt_types.dart';

enum SttProvider {
  apple('Apple 设备端'),
  soniox('Soniox'),
  moss('MOSS Pro'),
  qwen('通义 Qwen'),
  doubao('豆包');

  const SttProvider(this.label);
  final String label;

  /// Retained only to read historical transcript provenance and task journals.
  bool get retired => this == soniox || this == moss;
  static const available = [apple, qwen, doubao];
  bool get defersTranscription => this != apple;

  // Capabilities: callers ask what an engine can do, not which engine it is.

  /// Runs in Apple's on-device recognizer: no credentials, one recognizer
  /// shared by file work and live capture (capture pre-empts file work),
  /// and failures arrive as platform error codes.
  bool get onDevice => this == apple;

  /// Needs an API key before it can be selected or run.
  bool get needsCredentials => !onDevice;

  /// Cannot auto-detect the spoken language: a source language is chosen
  /// before transcribing, per recording, and kept as the transcript's
  /// language instead of whatever the engine reports.
  bool get requiresSourceLanguage => onDevice;

  /// Live display modes this engine offers while recording. Deferred engines
  /// only transcribe; Apple also translates, and no engine offers
  /// conversation today.
  bool supportsMode(SttDisplayMode mode) =>
      mode == SttDisplayMode.transcription ||
      mode == SttDisplayMode.translation && onDevice;

  /// Cloud engines whose credentials are the grouped (API key, base URL,
  /// model) trio saved through [EngineConfig]; key-only engines are not.
  bool get usesEngineTrio =>
      this == SttProvider.qwen || this == SttProvider.doubao;

  static SttProvider? parse(Object? value) {
    for (final provider in values) {
      if (provider.name == value) return provider;
    }
    return null;
  }
}

SttProvider initialSpeechProvider({
  required SttProvider? saved,
  required bool appleSupported,
  bool qwenConfigured = false,
}) {
  if (saved != null && !saved.retired) return saved;
  if (qwenConfigured) return SttProvider.qwen;
  return appleSupported ? SttProvider.apple : SttProvider.qwen;
}
