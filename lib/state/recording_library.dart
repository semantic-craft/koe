import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'context/context_file.dart';

enum RecordingSource { device, localImport, phone }

/// Where a recording's place label came from.
enum RecordingPlaceSource { automatic, manual }

/// A coarse place note attached to one recording.
///
/// Only a human-readable region label is stored. Coordinates are deliberately
/// not persisted: default queries and shares never carry precise location.
class RecordingPlace {
  const RecordingPlace({
    required this.label,
    required this.source,
    required this.capturedAt,
  });

  final String label;
  final RecordingPlaceSource source;
  final DateTime capturedAt;

  Map<String, Object?> toJson() => {
    'label': label,
    'source': source.name,
    'capturedAt': capturedAt.toIso8601String(),
  };

  static RecordingPlace? decode(Object? value) {
    if (value is! Map) return null;
    final label = value['label'];
    final capturedAt = DateTime.tryParse('${value['capturedAt']}');
    final source = RecordingPlaceSource.values
        .where((item) => item.name == value['source'])
        .firstOrNull;
    if (label is! String || label.trim().isEmpty || capturedAt == null) {
      return null;
    }
    return RecordingPlace(
      label: label.trim(),
      source: source ?? RecordingPlaceSource.manual,
      capturedAt: capturedAt,
    );
  }
}

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
    this.place,
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
  final RecordingPlace? place;

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
    RecordingPlace? place,
    bool clearPlace = false,
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
    place: clearPlace ? null : (place ?? this.place),
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
    if (place != null) 'place': place!.toJson(),
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
      place: RecordingPlace.decode(value['place']),
      deletedAt: deletedAt,
      permanentlyDeleted: value['permanentlyDeleted'] == true,
    );
  }
}

/// Persists original-audio provenance independently of transcript/analysis
/// state. A corrupt or missing record never causes an audio file to be deleted.
class RecordingLibraryStore {
  RecordingLibraryStore({this.file, this.inMemory = false})
    : _doc = ContextFile(fileName, file: file, inMemory: inMemory);

  static const fileName = 'recording_library.json';

  final File? file;
  final bool inMemory;
  final ContextFile _doc;
  final Map<String, RecordingAsset> _assets = {};
  final Map<String, RecordingAsset> _persisted = {};
  bool _writeBlocked = false;
  Future<void> _mutationQueue = Future<void>.value();

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

  Future<void> load() async {
    if (inMemory) return;
    try {
      final raw = await _doc.readText();
      if (raw == null) return;
      final decoded = decode(raw);
      if (decoded == null) throw const FormatException('recording library');
      _assets.addAll(decoded);
      _persisted
        ..clear()
        ..addAll(_assets);
    } catch (error) {
      debugPrint('[RecordingLibrary] load failed: $error');
      // Keep the unreadable file aside so the next save cannot erase the
      // titles and places it still holds.
      try {
        await _doc.setAside();
        recoveryNotice = '资料信息无法读取，已另存原文件；原音频文件仍保留';
      } catch (backupError) {
        debugPrint('[RecordingLibrary] backup failed: $backupError');
        _writeBlocked = true;
        recoveryNotice = '资料信息无法读取，也未能另存原文件；为避免覆盖，暂不保存资料信息修改。';
      }
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

  Future<void> upsert(RecordingAsset asset, {bool strict = true}) {
    return _enqueueMutation(() async {
      final committed = _persisted[asset.path];
      _assets[asset.path] = asset;
      try {
        await save(strict: strict);
      } catch (_) {
        if (identical(_assets[asset.path], asset)) {
          if (committed == null) {
            _assets.remove(asset.path);
          } else {
            _assets[asset.path] = committed;
          }
        }
        rethrow;
      }
    });
  }

  Future<void> upsertAll(
    Iterable<RecordingAsset> assets, {
    bool strict = true,
  }) {
    return _enqueueMutation(() async {
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
    });
  }

  Future<void> remove(String path, {bool strict = true}) {
    return _enqueueMutation(() async {
      final previous = _assets.remove(path);
      try {
        await save(strict: strict);
      } catch (_) {
        if (previous != null) _assets[path] = previous;
        rethrow;
      }
    });
  }

  Future<void> rename(String from, RecordingAsset asset, {bool strict = true}) {
    return _enqueueMutation(() async {
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
    });
  }

  /// Every mutation shares one queue so a later removal or rename can never
  /// be overtaken by a snapshot captured by an earlier, still-pending write.
  Future<void> _enqueueMutation(Future<void> Function() mutate) {
    final operation = _mutationQueue.then((_) => mutate());
    _mutationQueue = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> save({bool strict = true}) {
    if (inMemory) {
      _persisted
        ..clear()
        ..addAll(_assets);
      return Future<void>.value();
    }
    final snapshot = List<RecordingAsset>.of(_assets.values);
    return _doc.serialize(() => _write(snapshot, strict));
  }

  Future<void> _write(List<RecordingAsset> snapshot, bool strict) async {
    try {
      if (_writeBlocked) {
        throw StateError('recording library unreadable and not backed up');
      }
      await _doc.replace(
        const JsonEncoder.withIndent('  ').convert(encode(snapshot)),
      );
      _persisted
        ..clear()
        ..addAll({for (final asset in snapshot) asset.path: asset});
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
