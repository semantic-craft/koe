import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ai/stt_types.dart';
import '../ai/speech_provider.dart';
import '../ai/engine_config.dart';

/// Lightweight JSON settings for speech providers and recording preferences.
class AppSettingsStore {
  AppSettingsStore._();

  static const _fileName = 'app_settings.json';
  static Future<void> _pendingSave = Future.value();

  static Future<File> _file() async {
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    final dir = Directory(p.join(base.path, 'AnkerRecorder'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, _fileName));
  }

  static Future<AppSettings> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return const AppSettings();
      final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return AppSettings.fromJson(map);
    } catch (e) {
      debugPrint('[AppSettings] load failed: $e');
      return const AppSettings();
    }
  }

  static Future<void> save(AppSettings s, {bool strict = false}) {
    final encoded = const JsonEncoder.withIndent('  ').convert(s.toJson());
    final operation = _pendingSave.then((_) async {
      try {
        final file = await _file();
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(encoded, flush: true);
        await temporary.rename(file.path);
      } catch (error) {
        debugPrint('[AppSettings] save failed: $error');
        if (strict) rethrow;
      }
    });
    _pendingSave = operation.catchError((Object _) {});
    return operation;
  }
}

class AppSettings {
  const AppSettings({
    this.speechProvider,
    this.appleSourceLanguage = '',
    this.engines = const {},
    this.autoTranscribe = true,
    this.autoRealtime = true,
    this.transcriptLanguage = 'auto',
    this.sttMode = SttDisplayMode.transcription,
    this.translationTargetLanguage = 'zh',
    this.ownerLanguage = 'zh',
    this.guestLanguage = 'en',
  });

  /// Grouped cloud-engine credentials keyed by [SttProvider.name].
  final Map<String, EngineConfig> engines;

  /// Null means an existing install has not selected a provider yet.
  final SttProvider? speechProvider;
  final String appleSourceLanguage;
  final bool autoTranscribe;
  final bool autoRealtime;
  final String transcriptLanguage;
  final SttDisplayMode sttMode;
  final String translationTargetLanguage;
  final String ownerLanguage;
  final String guestLanguage;

  /// The credential trio saved for [provider] (empty when never configured).
  EngineConfig engineConfig(SttProvider provider) =>
      engines[provider.name] ?? const EngineConfig();

  AppSettings copyWith({
    SttProvider? speechProvider,
    String? appleSourceLanguage,
    Map<String, EngineConfig>? engines,
    bool? autoTranscribe,
    bool? autoRealtime,
    String? transcriptLanguage,
    SttDisplayMode? sttMode,
    String? translationTargetLanguage,
    String? ownerLanguage,
    String? guestLanguage,
  }) {
    return AppSettings(
      speechProvider: speechProvider ?? this.speechProvider,
      appleSourceLanguage: appleSourceLanguage ?? this.appleSourceLanguage,
      engines: engines ?? this.engines,
      autoTranscribe: autoTranscribe ?? this.autoTranscribe,
      autoRealtime: autoRealtime ?? this.autoRealtime,
      transcriptLanguage: transcriptLanguage ?? this.transcriptLanguage,
      sttMode: sttMode ?? this.sttMode,
      translationTargetLanguage:
          translationTargetLanguage ?? this.translationTargetLanguage,
      ownerLanguage: ownerLanguage ?? this.ownerLanguage,
      guestLanguage: guestLanguage ?? this.guestLanguage,
    );
  }

  Map<String, dynamic> toJson() => {
    if (speechProvider != null) 'speechProvider': speechProvider!.name,
    'appleSourceLanguage': appleSourceLanguage,
    if (_engineJson.isNotEmpty) 'engines': _engineJson,
    'autoTranscribe': autoTranscribe,
    'autoRealtime': autoRealtime,
    'transcriptLanguage': transcriptLanguage,
    'sttMode': sttMode.name,
    'translationTargetLanguage': translationTargetLanguage,
    'ownerLanguage': ownerLanguage,
    'guestLanguage': guestLanguage,
  };

  Map<String, dynamic> get _engineJson => {
    for (final entry in engines.entries)
      if (!entry.value.isEmpty) entry.key: entry.value.toJson(),
  };

  factory AppSettings.fromJson(Map<String, dynamic> map) {
    final modeName = _str(map['sttMode']);
    final sttMode = SttDisplayMode.values.firstWhere(
      (mode) => mode.name == modeName,
      orElse: () => map['communicationModeEnabled'] == true
          ? SttDisplayMode.conversation
          : SttDisplayMode.transcription,
    );
    var ownerLanguage = (_str(map['ownerLanguage']) ?? 'zh').toLowerCase();
    var guestLanguage = (_str(map['guestLanguage']) ?? 'en').toLowerCase();
    if (ownerLanguage == guestLanguage) {
      ownerLanguage = 'zh';
      guestLanguage = 'en';
    }
    final engines = _enginesFrom(map);
    return AppSettings(
      speechProvider: SttProvider.parse(map['speechProvider']),
      appleSourceLanguage: _str(map['appleSourceLanguage']) ?? '',
      engines: engines,
      autoTranscribe: map['autoTranscribe'] != false,
      autoRealtime: map['autoRealtime'] != false,
      transcriptLanguage: _str(map['transcriptLanguage']) ?? 'auto',
      sttMode: sttMode,
      translationTargetLanguage: _str(map['translationTargetLanguage']) ?? 'zh',
      ownerLanguage: ownerLanguage,
      guestLanguage: guestLanguage,
    );
  }

  /// Providers whose API key lives in a dedicated legacy field rather than
  /// the grouped trio map.
  static const _legacyKeyFields = {'soniox', 'moss'};

  /// Reads the grouped `engines` map, then migrates legacy flat
  /// `{name}ApiKey` / `{name}BaseUrl` / `{name}Model` keys for every trio
  /// engine. Nested entries win; legacy keys only fill engines not yet
  /// present.
  static Map<String, EngineConfig> _enginesFrom(Map<String, dynamic> map) {
    final engines = <String, EngineConfig>{};
    final nested = map['engines'];
    if (nested is Map) {
      for (final entry in nested.entries) {
        if (SttProvider.available.any((p) => p.name == entry.key) &&
            entry.value is Map) {
          engines['${entry.key}'] = EngineConfig.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
        }
      }
    }
    for (final provider in SttProvider.available) {
      if (_legacyKeyFields.contains(provider.name)) continue;
      final legacy = EngineConfig.fromJson({
        'apiKey': map['${provider.name}ApiKey'],
        'baseUrl': map['${provider.name}BaseUrl'],
        'model': map['${provider.name}Model'],
      });
      if (!legacy.isEmpty) {
        engines.putIfAbsent(provider.name, () => legacy);
      }
    }
    return engines;
  }

  static String? _str(dynamic v) {
    final s = '$v'.trim();
    if (s.isEmpty || s == 'null') return null;
    return s;
  }
}
