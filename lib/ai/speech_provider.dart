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
