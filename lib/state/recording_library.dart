import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum RecordingSource { device, localImport, phone }

/// One original audio asset in the local library.
///
/// The audio file is the source of truth. This record only remembers where it
/// came from, when it was recorded/imported, and whether the original copy is
/// still present. Derived files and transcripts never replace [path].
class RecordingAsset {
  const RecordingAsset({
    required this.path,
    required this.displayName,
    required this.source,
    required this.importedAt,
    this.recordedAt,
    this.originalPath,
    this.contentHash,
    this.originalComplete = true,
    this.archived = false,
    this.deletedAt,
    this.permanentlyDeleted = false,
  });

  final String path;
  final String displayName;
  final RecordingSource source;
  final DateTime? recordedAt;
  final DateTime importedAt;
  final String? originalPath;
  final String? contentHash;
  final bool originalComplete;
  final bool archived;

  /// When this asset was moved to the 30-day trash. Null means it is live.
  final DateTime? deletedAt;

  /// A hidden marker for a device recording the user permanently deleted.
  /// It prevents automatic transfer from recreating the same material.
  final bool permanentlyDeleted;

  bool get trashed => deletedAt != null || archived;

  RecordingAsset copyWith({
    String? path,
    String? displayName,
    RecordingSource? source,
    DateTime? recordedAt,
    DateTime? importedAt,
    String? originalPath,
    String? contentHash,
    bool? originalComplete,
    bool? archived,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    bool? permanentlyDeleted,
  }) => RecordingAsset(
    path: path ?? this.path,
    displayName: displayName ?? this.displayName,
    source: source ?? this.source,
    recordedAt: recordedAt ?? this.recordedAt,
    importedAt: importedAt ?? this.importedAt,
    originalPath: originalPath ?? this.originalPath,
    contentHash: contentHash ?? this.contentHash,
    originalComplete: originalComplete ?? this.originalComplete,
    archived: archived ?? this.archived,
    deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    permanentlyDeleted: permanentlyDeleted ?? this.permanentlyDeleted,
  );

  Map<String, Object?> toJson() => {
    'path': path,
    'displayName': displayName,
    'source': source.name,
    'recordedAt': recordedAt?.toIso8601String(),
    'importedAt': importedAt.toIso8601String(),
    if (originalPath != null) 'originalPath': originalPath,
    if (contentHash != null) 'contentHash': contentHash,
    'originalComplete': originalComplete,
    'archived': archived,
    if (deletedAt != null) 'deletedAt': deletedAt!.toIso8601String(),
    if (permanentlyDeleted) 'permanentlyDeleted': true,
  };

  static RecordingAsset? decode(Object? value) {
    if (value is! Map) return null;
    final path = value['path'];
    final displayName = value['displayName'];
    final importedAt = DateTime.tryParse('${value['importedAt']}');
    final source = RecordingSource.values
        .where((item) => item.name == value['source'])
        .firstOrNull;
    if (path is! String ||
        path.isEmpty ||
        displayName is! String ||
        displayName.trim().isEmpty ||
        importedAt == null ||
        source == null) {
      return null;
    }
    final recordedAt = value['recordedAt'] is String
        ? DateTime.tryParse(value['recordedAt'] as String)
        : null;
    final deletedAt = value['deletedAt'] is String
        ? DateTime.tryParse(value['deletedAt'] as String)
        : null;
    return RecordingAsset(
      path: path,
      displayName: displayName.trim(),
      source: source,
      recordedAt: recordedAt,
      importedAt: importedAt,
      originalPath: value['originalPath'] is String
          ? value['originalPath'] as String
          : null,
      contentHash: value['contentHash'] is String
          ? value['contentHash'] as String
          : null,
      originalComplete: value['originalComplete'] != false,
      archived: value['archived'] == true || deletedAt != null,
      deletedAt: deletedAt,
      permanentlyDeleted: value['permanentlyDeleted'] == true,
    );
  }
}

/// Persists original-audio provenance independently of transcript/analysis
/// state. A corrupt or missing record never causes an audio file to be deleted.
class RecordingLibraryStore {
  RecordingLibraryStore({this.file, this.inMemory = false});

  static const fileName = 'recording_library.json';

  final File? file;
  final bool inMemory;
  final Map<String, RecordingAsset> _assets = {};
  Future<void> _pendingSave = Future<void>.value();

  String? recoveryNotice;
  String? saveError;

  List<RecordingAsset> get assets => List.unmodifiable(_assets.values);

  RecordingAsset? assetForPath(String path) => _assets[path];

  RecordingAsset? assetForHash(String hash) {
    if (hash.isEmpty) return null;
    for (final asset in _assets.values) {
      if (asset.contentHash == hash && File(asset.path).existsSync()) {
        return asset;
      }
    }
    return null;
  }

  Future<File> _file() async {
    if (file != null) return file!;
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    final dir = Directory(p.join(base.path, 'AnkerRecorder'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, fileName));
  }

  Future<void> load() async {
    if (inMemory) return;
    try {
      final target = await _file();
      if (!await target.exists()) return;
      final decoded = decode(await target.readAsString());
      if (decoded == null) {
        recoveryNotice = '资料信息无法读取，原音频文件仍保留';
        return;
      }
      _assets.addAll(decoded);
    } catch (error) {
      recoveryNotice = '资料信息无法读取，原音频文件仍保留';
      debugPrint('[RecordingLibrary] load failed: $error');
    }
  }

  @visibleForTesting
  static Map<String, RecordingAsset>? decode(String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return null;
      final entries = value['assets'];
      if (entries is! List) return null;
      final assets = <String, RecordingAsset>{};
      for (final entry in entries) {
        final asset = RecordingAsset.decode(entry);
        if (asset != null) assets[asset.path] = asset;
      }
      return assets;
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static Map<String, Object?> encode(Iterable<RecordingAsset> assets) => {
    'version': 1,
    'assets': assets.map((asset) => asset.toJson()).toList(),
  };

  Future<void> upsert(RecordingAsset asset, {bool strict = true}) async {
    final previous = _assets[asset.path];
    _assets[asset.path] = asset;
    try {
      await save(strict: strict);
    } catch (_) {
      if (previous == null) {
        _assets.remove(asset.path);
      } else {
        _assets[asset.path] = previous;
      }
      rethrow;
    }
  }

  Future<void> upsertAll(
    Iterable<RecordingAsset> assets, {
    bool strict = true,
  }) async {
    final previous = <String, RecordingAsset?>{};
    try {
      for (final asset in assets) {
        previous.putIfAbsent(asset.path, () => _assets[asset.path]);
        _assets[asset.path] = asset;
      }
      await save(strict: strict);
    } catch (_) {
      for (final entry in previous.entries) {
        final before = entry.value;
        if (before == null) {
          _assets.remove(entry.key);
        } else {
          _assets[entry.key] = before;
        }
      }
      rethrow;
    }
  }

  Future<void> remove(String path, {bool strict = true}) async {
    final previous = _assets.remove(path);
    try {
      await save(strict: strict);
    } catch (_) {
      if (previous != null) _assets[path] = previous;
      rethrow;
    }
  }

  Future<void> rename(
    String from,
    RecordingAsset asset, {
    bool strict = true,
  }) async {
    final previousFrom = _assets[from];
    final previousTarget = _assets[asset.path];
    _assets.remove(from);
    _assets[asset.path] = asset;
    try {
      await save(strict: strict);
    } catch (_) {
      _assets.remove(asset.path);
      if (previousTarget != null) _assets[asset.path] = previousTarget;
      if (previousFrom != null) _assets[from] = previousFrom;
      rethrow;
    }
  }

  Future<void> save({bool strict = true}) {
    if (inMemory) return Future<void>.value();
    final snapshot = List<RecordingAsset>.of(_assets.values);
    final operation = _pendingSave.then((_) => _write(snapshot, strict));
    _pendingSave = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _write(List<RecordingAsset> snapshot, bool strict) async {
    try {
      final target = await _file();
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(encode(snapshot)),
        flush: true,
      );
      await temporary.rename(target.path);
      saveError = null;
    } catch (error) {
      saveError = '资料信息保存失败，请检查存储空间后重试';
      debugPrint('[RecordingLibrary] save failed: $error');
      if (strict) rethrow;
    }
  }
}

String recordingSourceLabel(RecordingSource source) => switch (source) {
  RecordingSource.device => '设备录音',
  RecordingSource.localImport => '本地导入',
  RecordingSource.phone => '手机录音',
};
