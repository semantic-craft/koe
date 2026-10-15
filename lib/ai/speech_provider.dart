enum SttProvider {
  apple('Apple 设备端'),
  soniox('Soniox'),
  moss('MOSS Pro'),
  qwen('通义 Qwen');

  const SttProvider(this.label);
  final String label;

  /// Transcription starts after the recording is saved. There is no live stream.
  bool get defersTranscription =>
      this == SttProvider.moss || this == SttProvider.qwen;

  static SttProvider? parse(Object? value) {
    for (final provider in values) {
      if (provider.name == value) return provider;
    }
    return null;
  }
}

/// A saved choice wins, including [SttProvider.qwen].
///
/// Otherwise Apple is used when it is supported and Soniox is not configured.
/// Qwen is the fallback only when Apple is unavailable and Soniox is not
/// configured either.
SttProvider initialSpeechProvider({
  required SttProvider? saved,
  required bool appleSupported,
  required bool sonioxConfigured,
  bool qwenConfigured = false,
}) {
  if (saved != null) return saved;
  if (appleSupported && !sonioxConfigured) return SttProvider.apple;
  if (sonioxConfigured || !qwenConfigured) return SttProvider.soniox;
  return SttProvider.qwen;
}
