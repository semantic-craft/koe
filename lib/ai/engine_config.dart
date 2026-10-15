/// Grouped credentials for one cloud transcription engine: API key, service
/// base URL, and model name.
///
/// Engines whose console only needs a key (or only a key plus model) leave the
/// other fields null. Saving is a whole-object replacement, so clearing a field
/// means saving a config that omits it — there are no per-field clear flags.
class EngineConfig {
  const EngineConfig({this.apiKey, this.baseUrl, this.model});

  final String? apiKey;
  final String? baseUrl;
  final String? model;

  /// True when the engine has an API key and can be selected / used.
  bool get isConfigured => (apiKey ?? '').trim().isNotEmpty;

  /// True when every field is blank; empty configs are omitted from JSON.
  bool get isEmpty =>
      (apiKey ?? '').trim().isEmpty &&
      (baseUrl ?? '').trim().isEmpty &&
      (model ?? '').trim().isEmpty;

  EngineConfig copyWith({String? apiKey, String? baseUrl, String? model}) {
    return EngineConfig(
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
    );
  }

  Map<String, dynamic> toJson() => {
    if ((apiKey ?? '').trim().isNotEmpty) 'apiKey': apiKey!.trim(),
    if ((baseUrl ?? '').trim().isNotEmpty) 'baseUrl': baseUrl!.trim(),
    if ((model ?? '').trim().isNotEmpty) 'model': model!.trim(),
  };

  factory EngineConfig.fromJson(Map<String, dynamic> map) => EngineConfig(
    apiKey: _clean(map['apiKey']),
    baseUrl: _clean(map['baseUrl']),
    model: _clean(map['model']),
  );

  static String? _clean(dynamic value) {
    final text = '$value'.trim();
    if (text.isEmpty || text == 'null') return null;
    return text;
  }

  @override
  bool operator ==(Object other) =>
      other is EngineConfig &&
      other.apiKey == apiKey &&
      other.baseUrl == baseUrl &&
      other.model == model;

  @override
  int get hashCode => Object.hash(apiKey, baseUrl, model);

  @override
  String toString() =>
      'EngineConfig(keyConfigured: $isConfigured, $baseUrl, $model)';
}
