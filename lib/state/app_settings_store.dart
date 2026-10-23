import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ai/stt_types.dart';
import '../platform/credential_store.dart';
import '../ai/speech_provider.dart';
import '../ai/engine_config.dart';
import 'atomic_file.dart';

/// Settings metadata on disk; user credentials live only in system Keychain.
class AppSettingsStore {
  AppSettingsStore._();
  static const _fileName = 'app_settings.json';
  static Future<void> _pending = Future.value();
  static bool _loadFailed = false;
  static final _credentials = CredentialStore();
  static const _providers = ['qwen', 'doubao'];

  @visibleForTesting
  static void resetForTesting() {
    _pending = Future.value();
    _loadFailed = false;
  }

  static Future<T> _serial<T>(Future<T> Function() work) {
    final operation = _pending.then((_) => work());
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  static Future<File> _file() async {
    final base = await getApplicationDocumentsDirectory();
    final folder = await _credentials.isIsolated
        ? 'AnkerRecorderDevelopment'
        : 'AnkerRecorder';
    return File(p.join(base.path, folder, _fileName));
  }

  static Future<void> _write(File file, AppSettings settings) async {
    await file.parent.create(recursive: true);
    await writeFileAtomically(file, jsonEncode(settings.toJson()));
  }

  static Future<AppSettings> load() => _serial(() async {
    AppSettings settings = const AppSettings();
    try {
      final file = await _file();
      final raw = await file.exists() ? await file.readAsString() : '{}';
      final map = jsonDecode(raw) as Map<String, dynamic>;
      settings = AppSettings.fromJson(map);
      final stored = await _credentials.read();
      final migrated = Map<String, String?>.from(stored);
      for (final provider in _providers) {
        final legacy = settings.engines[provider]?.apiKey;
        if (!migrated.containsKey(provider) && legacy != null) {
          migrated[provider] = legacy;
        }
      }
      if (!mapEquals(stored, migrated)) await _credentials.write(migrated);
      settings = settings.copyWith(
        engines: {
          for (final provider in _providers)
            if (settings.engines.containsKey(provider) ||
                migrated[provider] != null)
              provider: EngineConfig(
                apiKey: migrated[provider],
                baseUrl: settings.engines[provider]?.baseUrl,
                model: settings.engines[provider]?.model,
              ),
        },
      );
      // Strip both nested and old flat keys only after successful Keychain
      // read/write verification. A failed migration leaves the original intact.
      if (raw.contains('apiKey') || map.keys.any((k) => k.endsWith('ApiKey'))) {
        await _write(file, settings);
      }
      final temporary = File('${file.path}.tmp');
      if (await file.exists() && await temporary.exists()) {
        await temporary.delete();
      }
      _loadFailed = false;
      return settings;
    } catch (_) {
      _loadFailed = true;
      return settings.copyWith(
        storageError: const CredentialStorageException().message,
      );
    }
  });

  static Future<void> save(AppSettings settings, {bool strict = false}) =>
      _serial(() async {
        try {
          if (_loadFailed) throw const CredentialStorageException();
          final previous = await _credentials.read();
          final desired = {
            for (final provider in _providers)
              provider: settings.engines[provider]?.apiKey,
          };
          final changed = !mapEquals(previous, desired);
          try {
            if (changed) await _credentials.write(desired);
            await _write(await _file(), settings);
          } catch (_) {
            if (changed) {
              try {
                await _credentials.write(previous);
              } catch (_) {
                _loadFailed = true;
              }
            }
            rethrow;
          }
        } catch (_) {
          if (strict) throw const CredentialStorageException();
        }
      });
}

class AppSettings {
  const AppSettings({
    this.storageError,
    this.speechProvider,
    this.appleSourceLanguage = '',
    this.engines = const {},
    this.autoTranscribe = true,
    this.autoRealtime = true,
    this.allDayListening = false,
    this.meetingLocalOnly = true,
    this.recordHotKey = true,
    this.highlightHotKey = true,
    this.meetingAppPrompts = true,
    this.meetingAppPromptsMuted = const [],
    this.meetingFromCalendar = true,
    this.transcriptLanguage = 'auto',
    this.sttMode = SttDisplayMode.transcription,
    this.translationTargetLanguage = 'zh',
    this.ownerLanguage = 'zh',
    this.guestLanguage = 'en',
  });

  final String? storageError;

  /// Grouped cloud-engine credentials keyed by [SttProvider.name].
  final Map<String, EngineConfig> engines;

  /// Null means an existing install has not selected a provider yet.
  final SttProvider? speechProvider;
  final String appleSourceLanguage;
  final bool autoTranscribe;
  final bool autoRealtime;

  /// The record buttons start all-day, text-only listening instead of a
  /// recording.
  final bool allDayListening;

  /// Meeting / formal recordings stay on the device (#376): live and
  /// post-recording transcription only use [SttProvider.onDevice] engines,
  /// while everyday voice input continues to use [speechProvider].
  final bool meetingLocalOnly;

  /// On the Mac, ⌃⌥⌘R starts or stops a take from any app (#405).
  final bool recordHotKey;

  /// On the Mac, ⌃⌥⌘B marks a highlight from any app while a take or text
  /// capture runs (#405).
  final bool highlightHotKey;

  /// On the Mac, asks to record when a meeting app takes the microphone,
  /// and to stop when the meeting is over (#406).
  final bool meetingAppPrompts;

  /// The meeting apps, by bundle ID, the user chose 不再提醒 for.
  final List<String> meetingAppPromptsMuted;

  /// On the Mac, names a microphone take after the calendar meeting it was
  /// recorded in and gives its invitees to the minutes (#407).
  final bool meetingFromCalendar;
  final String transcriptLanguage;
  final SttDisplayMode sttMode;
  final String translationTargetLanguage;
  final String ownerLanguage;
  final String guestLanguage;

  /// The credential trio saved for [provider] (empty when never configured).
  EngineConfig engineConfig(SttProvider provider) =>
      engines[provider.name] ?? const EngineConfig();

  AppSettings copyWith({
    String? storageError,
    SttProvider? speechProvider,
    String? appleSourceLanguage,
    Map<String, EngineConfig>? engines,
    bool? autoTranscribe,
    bool? autoRealtime,
    bool? allDayListening,
    bool? meetingLocalOnly,
    bool? recordHotKey,
    bool? highlightHotKey,
    bool? meetingAppPrompts,
    List<String>? meetingAppPromptsMuted,
    bool? meetingFromCalendar,
    String? transcriptLanguage,
    SttDisplayMode? sttMode,
    String? translationTargetLanguage,
    String? ownerLanguage,
    String? guestLanguage,
  }) {
    return AppSettings(
      storageError: storageError ?? this.storageError,
      speechProvider: speechProvider ?? this.speechProvider,
      appleSourceLanguage: appleSourceLanguage ?? this.appleSourceLanguage,
      engines: engines ?? this.engines,
      autoTranscribe: autoTranscribe ?? this.autoTranscribe,
      autoRealtime: autoRealtime ?? this.autoRealtime,
      allDayListening: allDayListening ?? this.allDayListening,
      meetingLocalOnly: meetingLocalOnly ?? this.meetingLocalOnly,
      recordHotKey: recordHotKey ?? this.recordHotKey,
      highlightHotKey: highlightHotKey ?? this.highlightHotKey,
      meetingAppPrompts: meetingAppPrompts ?? this.meetingAppPrompts,
      meetingAppPromptsMuted:
          meetingAppPromptsMuted ?? this.meetingAppPromptsMuted,
      meetingFromCalendar: meetingFromCalendar ?? this.meetingFromCalendar,
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
    'allDayListening': allDayListening,
    'meetingLocalOnly': meetingLocalOnly,
    'recordHotKey': recordHotKey,
    'highlightHotKey': highlightHotKey,
    'meetingAppPrompts': meetingAppPrompts,
    'meetingAppPromptsMuted': meetingAppPromptsMuted,
    'meetingFromCalendar': meetingFromCalendar,
    'transcriptLanguage': transcriptLanguage,
    'sttMode': sttMode.name,
    'translationTargetLanguage': translationTargetLanguage,
    'ownerLanguage': ownerLanguage,
    'guestLanguage': guestLanguage,
  };

  Map<String, dynamic> get _engineJson => {
    for (final entry in engines.entries)
      if (!entry.value.isEmpty)
        entry.key: {
          ...entry.value.toJson(),
          if (entry.value.isConfigured) 'credentialRef': entry.key,
        },
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
      allDayListening: map['allDayListening'] == true,
      meetingLocalOnly: map['meetingLocalOnly'] != false,
      recordHotKey: map['recordHotKey'] != false,
      highlightHotKey: map['highlightHotKey'] != false,
      meetingAppPrompts: map['meetingAppPrompts'] != false,
      meetingAppPromptsMuted: [
        if (map['meetingAppPromptsMuted'] case final List<Object?> apps)
          for (final app in apps)
            if (app is String) app,
      ],
      meetingFromCalendar: map['meetingFromCalendar'] != false,
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
