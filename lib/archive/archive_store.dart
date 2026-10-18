import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../platform/credential_store.dart';
import 'archive_pairing.dart';
import 'archive_wire.dart';

/// Per-original archive state on the phone. This is deliberately separate from
/// [RecordingAsset.archived], which is the existing 30-day trash marker.
enum MacArchivePhase { pending, uploading, verifying, verified, failed }

class ArchiveDeskReceipt {
  const ArchiveDeskReceipt({
    required this.contentHash,
    required this.length,
    required this.extension,
    required this.verifiedAt,
    required this.sourceLength,
    required this.sourceModifiedMs,
  });

  final String contentHash;
  final int length;
  final String extension;
  final DateTime verifiedAt;
  final int sourceLength;
  final int sourceModifiedMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'hash': contentHash,
    'length': length,
    'ext': extension,
    'verifiedAt': verifiedAt.toIso8601String(),
    'sourceLength': sourceLength,
    'sourceModifiedMs': sourceModifiedMs,
  };

  static ArchiveDeskReceipt? decode(Object? value) {
    if (value is! Map) return null;
    final hash = value['hash'];
    final length = value['length'];
    final extension = value['ext'];
    final verifiedAt = DateTime.tryParse('${value['verifiedAt']}');
    final sourceLength = value['sourceLength'];
    final sourceModifiedMs = value['sourceModifiedMs'];
    if (!archiveIsValidContentHash(hash) ||
        length is! int ||
        length <= 0 ||
        extension is! String ||
        !archiveAllowedStoredExtensions.contains(extension) ||
        verifiedAt == null ||
        sourceLength is! int ||
        sourceModifiedMs is! int) {
      return null;
    }
    return ArchiveDeskReceipt(
      contentHash: hash as String,
      length: length,
      extension: extension,
      verifiedAt: verifiedAt,
      sourceLength: sourceLength,
      sourceModifiedMs: sourceModifiedMs,
    );
  }
}

class ArchivePhoneRecord {
  const ArchivePhoneRecord({
    required this.localPath,
    required this.displayName,
    required this.originalExtension,
    required this.updatedAt,
    this.deskId,
    this.contentHash,
    this.length = 0,
    this.sourceModifiedMs = 0,
    this.recordedAt,
    this.phase = MacArchivePhase.pending,
    this.verifiedAt,
    this.verifiedLength,
    this.error,
    this.attempts = 0,
    this.manual = false,
    this.receipts = const <String, ArchiveDeskReceipt>{},
  });

  final String localPath;
  final String displayName;
  final String originalExtension;

  /// The Mac desk identity this record was paired with. A verified record is
  /// only meaningful for that desk; changing targets invalidates it.
  final String? deskId;

  /// SHA-256 of the exact original version queued for upload.
  final String? contentHash;
  final int length;
  final int sourceModifiedMs;
  final DateTime? recordedAt;
  final MacArchivePhase phase;
  final DateTime? verifiedAt;
  final int? verifiedLength;
  final String? error;
  final int attempts;

  /// Queued by an explicit user action; survives restarts even when automatic
  /// archiving is off.
  final bool manual;

  /// Verified copies on other Mac desks. Switching targets keeps these so a
  /// later pairing back can restore the old bytes.
  final Map<String, ArchiveDeskReceipt> receipts;
  final DateTime updatedAt;

  bool get verified => phase == MacArchivePhase.verified;
  bool get hasVersion => archiveIsValidContentHash(contentHash);

  ArchivePhoneRecord copyWith({
    String? localPath,
    String? displayName,
    String? originalExtension,
    String? deskId,
    bool clearDeskId = false,
    String? contentHash,
    int? length,
    int? sourceModifiedMs,
    DateTime? recordedAt,
    MacArchivePhase? phase,
    DateTime? verifiedAt,
    int? verifiedLength,
    String? error,
    bool clearError = false,
    bool clearContentHash = false,
    bool clearVerified = false,
    int? attempts,
    bool? manual,
    Map<String, ArchiveDeskReceipt>? receipts,
    DateTime? updatedAt,
  }) => ArchivePhoneRecord(
    localPath: localPath ?? this.localPath,
    displayName: displayName ?? this.displayName,
    originalExtension: originalExtension ?? this.originalExtension,
    deskId: clearDeskId ? null : (deskId ?? this.deskId),
    contentHash: clearContentHash ? null : (contentHash ?? this.contentHash),
    length: length ?? this.length,
    sourceModifiedMs: sourceModifiedMs ?? this.sourceModifiedMs,
    recordedAt: recordedAt ?? this.recordedAt,
    phase: phase ?? this.phase,
    verifiedAt: clearVerified ? null : (verifiedAt ?? this.verifiedAt),
    verifiedLength: clearVerified
        ? null
        : (verifiedLength ?? this.verifiedLength),
    error: clearError ? null : (error ?? this.error),
    attempts: attempts ?? this.attempts,
    manual: manual ?? this.manual,
    receipts: receipts ?? this.receipts,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'path': localPath,
    'name': displayName,
    'ext': originalExtension,
    if (deskId != null) 'desk': deskId,
    if (contentHash != null) 'hash': contentHash,
    'length': length,
    'modifiedMs': sourceModifiedMs,
    if (recordedAt != null) 'recordedAt': recordedAt!.toIso8601String(),
    'phase': phase.name,
    if (verifiedAt != null) 'verifiedAt': verifiedAt!.toIso8601String(),
    if (verifiedLength != null) 'verifiedLength': verifiedLength,
    if (error != null) 'error': error,
    'attempts': attempts,
    if (manual) 'manual': true,
    if (receipts.isNotEmpty)
      'receipts': <String, Object?>{
        for (final entry in receipts.entries) entry.key: entry.value.toJson(),
      },
    'updatedAt': updatedAt.toIso8601String(),
  };

  static ArchivePhoneRecord? decode(Object? value) {
    if (value is! Map) return null;
    final path = value['path'];
    final name = value['name'];
    final extension = value['ext'];
    final updatedAt = DateTime.tryParse('${value['updatedAt']}');
    final phase = MacArchivePhase.values
        .where((item) => item.name == value['phase'])
        .firstOrNull;
    if (path is! String ||
        path.isEmpty ||
        name is! String ||
        extension is! String ||
        extension.isEmpty ||
        updatedAt == null ||
        phase == null) {
      return null;
    }
    final hash = value['hash'];
    final deskId = value['desk'];
    final receipts = <String, ArchiveDeskReceipt>{};
    final rawReceipts = value['receipts'];
    if (rawReceipts is Map) {
      for (final entry in rawReceipts.entries) {
        final receipt = ArchiveDeskReceipt.decode(entry.value);
        if (receipt != null && entry.key is String) {
          receipts[entry.key as String] = receipt;
        }
      }
    }
    return ArchivePhoneRecord(
      localPath: path,
      displayName: archiveSanitizeDisplayName(name),
      originalExtension: extension,
      deskId: deskId is String && RegExp(r'^[a-f0-9]{16,64}$').hasMatch(deskId)
          ? deskId
          : null,
      contentHash: archiveIsValidContentHash(hash) ? hash as String : null,
      length: value['length'] is int ? value['length'] as int : 0,
      sourceModifiedMs: value['modifiedMs'] is int
          ? value['modifiedMs'] as int
          : 0,
      recordedAt: value['recordedAt'] is String
          ? DateTime.tryParse(value['recordedAt'] as String)
          : null,
      phase: phase,
      verifiedAt: value['verifiedAt'] is String
          ? DateTime.tryParse(value['verifiedAt'] as String)
          : null,
      verifiedLength: value['verifiedLength'] is int
          ? value['verifiedLength'] as int
          : null,
      error: value['error'] is String ? value['error'] as String : null,
      attempts: value['attempts'] is int ? value['attempts'] as int : 0,
      manual: value['manual'] == true,
      receipts: Map.unmodifiable(receipts),
      updatedAt: updatedAt,
    );
  }
}

class ArchivePhoneStore {
  ArchivePhoneStore({
    Directory? directory,
    bool inMemory = false,
    Future<Directory> Function()? supportDirectory,
    bool? developmentProfile,
    Future<bool> Function()? isolationProvider,
    Future<void> Function()? writeInterceptor,
  }) : _directoryOverride = directory,
       // ignore: prefer_initializing_formals
       _inMemory = inMemory,
       // ignore: prefer_initializing_formals
       _supportDirectory = supportDirectory,
       // ignore: prefer_initializing_formals
       _developmentProfile = developmentProfile,
       // ignore: prefer_initializing_formals
       _isolationProvider = isolationProvider,
       // ignore: prefer_initializing_formals
       _writeInterceptor = writeInterceptor;

  static const fileName = 'phone_archive.json';

  final Directory? _directoryOverride;
  final bool _inMemory;
  final Future<Directory> Function()? _supportDirectory;
  final bool? _developmentProfile;
  final Future<bool> Function()? _isolationProvider;
  final Future<void> Function()? _writeInterceptor;
  final Map<String, ArchivePhoneRecord> _records = {};

  ArchivePairing? pairing;
  bool autoArchive = false;
  bool manualPaused = false;
  DateTime? autoArchiveFrom;
  String clientId = '';
  String? loadError;
  String? saveError;
  bool storageUnavailable = false;
  Future<void> _mutation = Future<void>.value();
  bool _loaded = false;

  bool get loaded => _loaded;
  List<ArchivePhoneRecord> get records => List.unmodifiable(_records.values);
  ArchivePhoneRecord? recordForPath(String path) => _records[path];

  Future<Directory> _directory() async {
    if (_directoryOverride != null) return _directoryOverride;
    Directory base;
    try {
      base = _supportDirectory == null
          ? await getApplicationSupportDirectory()
          : await _supportDirectory();
    } catch (_) {
      throw const ArchiveException('无法访问应用私有归档目录，已停止读写配对信息');
    }
    final development = await _resolveArchiveDevelopmentProfile(
      _developmentProfile,
      _isolationProvider,
    );
    return Directory(
      p.join(
        base.path,
        development ? 'KoeArchiveDevelopment' : 'KoeArchive',
        'phone',
      ),
    );
  }

  /// Test seam for the private Application Support boundary.
  Future<Directory> storageDirectory() => _directory();

  Future<File> _file() async =>
      File(p.join((await _directory()).path, fileName));

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    clientId = archiveRandomHex(16);
    if (_inMemory) return;
    try {
      final target = await _file();
      if (!await target.exists()) return;
      final raw = jsonDecode(await target.readAsString());
      if (raw is! Map) throw const FormatException('not an object');
      final config = raw['config'];
      if (config is Map) {
        final encoded = config['pairing'];
        if (encoded is String && encoded.isNotEmpty) {
          pairing = ArchivePairing.tryParse(encoded);
        }
        autoArchive = config['autoArchive'] == true;
        manualPaused = config['manualPaused'] == true;
        autoArchiveFrom = config['autoArchiveFrom'] is String
            ? DateTime.tryParse(config['autoArchiveFrom'] as String)
            : null;
        final id = config['clientId'];
        if (id is String && RegExp(r'^[a-f0-9]{16,64}$').hasMatch(id)) {
          clientId = id;
        }
      }
      final entries = raw['records'];
      if (entries is List) {
        for (final value in entries) {
          final record = ArchivePhoneRecord.decode(value);
          if (record != null) _records[record.localPath] = record;
        }
      }
      // Transient work never survives as "done"; it becomes retryable.
      var recovered = false;
      for (final entry in _records.entries.toList()) {
        final record = entry.value;
        if (record.phase == MacArchivePhase.uploading ||
            record.phase == MacArchivePhase.verifying) {
          _records[entry.key] = record.copyWith(
            phase: MacArchivePhase.pending,
            error: '上次归档未完成，等待重试',
            updatedAt: DateTime.now(),
          );
          recovered = true;
        }
      }
      if (recovered) await save();
    } on ArchiveException catch (error) {
      storageUnavailable = true;
      loadError = error.message;
    } catch (_) {
      loadError = 'Mac 归档记录无法读取，请重新配对或检查存储空间';
      // Keep the unreadable file in place; a later successful save replaces
      // only the metadata, never the original audio.
    }
  }

  Map<String, Object?> _encode({
    required Map<String, ArchivePhoneRecord> records,
    required ArchivePairing? pairing,
    required bool autoArchive,
    required bool manualPaused,
    required DateTime? autoArchiveFrom,
  }) => <String, Object?>{
    'version': 1,
    'config': <String, Object?>{
      if (pairing != null) 'pairing': pairing.encode(),
      'autoArchive': autoArchive,
      'manualPaused': manualPaused,
      if (autoArchiveFrom != null)
        'autoArchiveFrom': autoArchiveFrom.toIso8601String(),
      'clientId': clientId,
    },
    'records': records.values.map((record) => record.toJson()).toList(),
  };

  Future<void> _writeSnapshot({
    required Map<String, ArchivePhoneRecord> records,
    required ArchivePairing? pairing,
    required bool autoArchive,
    required bool manualPaused,
    required DateTime? autoArchiveFrom,
  }) async {
    if (_inMemory) return;
    await _writeInterceptor?.call();
    try {
      final target = await _file();
      await target.parent.create(recursive: true);
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsString(
        jsonEncode(
          _encode(
            records: records,
            pairing: pairing,
            autoArchive: autoArchive,
            manualPaused: manualPaused,
            autoArchiveFrom: autoArchiveFrom,
          ),
        ),
        flush: true,
      );
      await temporary.rename(target.path);
      saveError = null;
    } catch (_) {
      saveError = 'Mac 归档记录保存失败，请检查存储空间';
      rethrow;
    }
  }

  Future<T> _serializedMutation<T>(Future<T> Function() work) {
    final operation = _mutation.then((_) => work());
    _mutation = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  /// Persist the currently published state (used after load recovery).
  Future<void> save() => _serializedMutation(
    () => _writeSnapshot(
      records: Map<String, ArchivePhoneRecord>.of(_records),
      pairing: pairing,
      autoArchive: autoArchive,
      manualPaused: manualPaused,
      autoArchiveFrom: autoArchiveFrom,
    ),
  );

  Future<void> setConfiguration({
    required ArchivePairing? pairing,
    required bool autoArchive,
    bool manualPaused = false,
    DateTime? autoArchiveFrom,
  }) => _serializedMutation(() async {
    await _writeSnapshot(
      records: Map<String, ArchivePhoneRecord>.of(_records),
      pairing: pairing,
      autoArchive: autoArchive,
      manualPaused: manualPaused,
      autoArchiveFrom: autoArchiveFrom,
    );
    this.pairing = pairing;
    this.autoArchive = autoArchive;
    this.manualPaused = manualPaused;
    this.autoArchiveFrom = autoArchiveFrom;
  });

  Future<void> setAutoArchive(
    bool value, {
    DateTime? autoArchiveFrom,
    bool clearManualPause = false,
  }) => _serializedMutation(() async {
    final nextFrom = autoArchiveFrom ?? this.autoArchiveFrom;
    final nextPaused = clearManualPause ? false : manualPaused;
    await _writeSnapshot(
      records: Map<String, ArchivePhoneRecord>.of(_records),
      pairing: pairing,
      autoArchive: value,
      manualPaused: nextPaused,
      autoArchiveFrom: nextFrom,
    );
    autoArchive = value;
    manualPaused = nextPaused;
    this.autoArchiveFrom = nextFrom;
  });

  Future<void> setManualPaused(bool value) => _serializedMutation(() async {
    await _writeSnapshot(
      records: Map<String, ArchivePhoneRecord>.of(_records),
      pairing: pairing,
      autoArchive: autoArchive,
      manualPaused: value,
      autoArchiveFrom: autoArchiveFrom,
    );
    manualPaused = value;
  });

  Future<void> upsert(ArchivePhoneRecord record) =>
      _serializedMutation(() async {
        final next = Map<String, ArchivePhoneRecord>.of(_records)
          ..[record.localPath] = record;
        await _writeSnapshot(
          records: next,
          pairing: pairing,
          autoArchive: autoArchive,
          manualPaused: manualPaused,
          autoArchiveFrom: autoArchiveFrom,
        );
        _records[record.localPath] = record;
      });

  Future<void> upsertAll(Iterable<ArchivePhoneRecord> records) =>
      _serializedMutation(() async {
        final incoming = records.toList();
        final next = Map<String, ArchivePhoneRecord>.of(_records);
        for (final record in incoming) {
          next[record.localPath] = record;
        }
        await _writeSnapshot(
          records: next,
          pairing: pairing,
          autoArchive: autoArchive,
          manualPaused: manualPaused,
          autoArchiveFrom: autoArchiveFrom,
        );
        for (final record in incoming) {
          _records[record.localPath] = record;
        }
      });

  /// Conditional restore commit. The test and update run inside the same
  /// serialized mutation, against the latest published record, so a delete or
  /// rename that happened while the file was being fetched cannot be undone by
  /// an older snapshot.
  Future<bool> completeRestore({
    required String fromPath,
    required String targetPath,
    required bool Function(ArchivePhoneRecord current) test,
    required ArchivePhoneRecord Function(ArchivePhoneRecord current) update,
  }) => _serializedMutation(() async {
    final current = _records[fromPath];
    if (current == null || !test(current)) return false;
    final updated = update(current);
    final next = Map<String, ArchivePhoneRecord>.of(_records)
      ..remove(fromPath)
      ..[targetPath] = updated;
    await _writeSnapshot(
      records: next,
      pairing: pairing,
      autoArchive: autoArchive,
      manualPaused: manualPaused,
      autoArchiveFrom: autoArchiveFrom,
    );
    _records
      ..remove(fromPath)
      ..[targetPath] = updated;
    return true;
  });

  /// Roll back only the record written by this rename, inside the mutation
  /// queue. A later mutation must never be overwritten by an older rollback.
  Future<bool> rollbackRename({
    required String from,
    required String to,
    required ArchivePhoneRecord expected,
  }) => _serializedMutation(() async {
    if (!identical(_records[from], expected) || _records.containsKey(to)) {
      return false;
    }
    final next = Map<String, ArchivePhoneRecord>.of(_records)
      ..remove(from)
      ..[to] = expected.copyWith(localPath: to);
    await _commitRecords(next);
    return true;
  });

  Future<bool> restoreIfAbsent(
    ArchivePhoneRecord record, {
    required bool Function() isCurrent,
  }) => _serializedMutation(() async {
    if (!isCurrent() || _records.containsKey(record.localPath)) return false;
    await _commitRecords(
      Map<String, ArchivePhoneRecord>.of(_records)..[record.localPath] = record,
    );
    return true;
  });

  Future<void> _commitRecords(Map<String, ArchivePhoneRecord> next) async {
    await _writeSnapshot(
      records: next,
      pairing: pairing,
      autoArchive: autoArchive,
      manualPaused: manualPaused,
      autoArchiveFrom: autoArchiveFrom,
    );
    _records
      ..clear()
      ..addAll(next);
  }

  Future<void> remove(String path) => _serializedMutation(() async {
    if (!_records.containsKey(path)) return;
    final next = Map<String, ArchivePhoneRecord>.of(_records)..remove(path);
    await _writeSnapshot(
      records: next,
      pairing: pairing,
      autoArchive: autoArchive,
      manualPaused: manualPaused,
      autoArchiveFrom: autoArchiveFrom,
    );
    _records.remove(path);
  });

  Future<void> rename(String from, String to) => _serializedMutation(() async {
    final previous = _records[from];
    if (previous == null) return;
    final next = Map<String, ArchivePhoneRecord>.of(_records)..remove(from);
    next[to] = previous.copyWith(localPath: to, updatedAt: DateTime.now());
    await _writeSnapshot(
      records: next,
      pairing: pairing,
      autoArchive: autoArchive,
      manualPaused: manualPaused,
      autoArchiveFrom: autoArchiveFrom,
    );
    _records
      ..remove(from)
      ..[to] = next[to]!;
  });
}

class ArchiveDeskConfig {
  const ArchiveDeskConfig({
    required this.deskId,
    required this.pairingKey,
    this.receivingEnabled = false,
    this.preferredPort = archiveDefaultPort,
  });

  final String deskId;
  final String pairingKey;
  final bool receivingEnabled;
  final int preferredPort;

  ArchiveDeskConfig copyWith({
    String? deskId,
    String? pairingKey,
    bool? receivingEnabled,
    int? preferredPort,
  }) => ArchiveDeskConfig(
    deskId: deskId ?? this.deskId,
    pairingKey: pairingKey ?? this.pairingKey,
    receivingEnabled: receivingEnabled ?? this.receivingEnabled,
    preferredPort: preferredPort ?? this.preferredPort,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'deskId': deskId,
    'pairingKey': pairingKey,
    'receivingEnabled': receivingEnabled,
    'preferredPort': preferredPort,
  };

  static ArchiveDeskConfig? decode(Object? value) {
    if (value is! Map) return null;
    final deskId = value['deskId'];
    final key = value['pairingKey'];
    if (deskId is! String ||
        !RegExp(r'^[a-f0-9]{16,64}$').hasMatch(deskId) ||
        key is! String) {
      return null;
    }
    try {
      ArchivePairing(
        deskId: deskId,
        key: key,
        hosts: const ['127.0.0.1'],
        port: 1,
      ).keyBytes;
    } catch (_) {
      return null;
    }
    final port = value['preferredPort'];
    return ArchiveDeskConfig(
      deskId: deskId,
      pairingKey: key,
      receivingEnabled: value['receivingEnabled'] == true,
      preferredPort: port is int && port >= 1 && port <= 65535
          ? port
          : archiveDefaultPort,
    );
  }
}

class ArchiveDeskEntry {
  const ArchiveDeskEntry({
    required this.contentHash,
    required this.length,
    required this.extension,
    required this.displayName,
    required this.verifiedAt,
    this.sourceClientId = '',
  });

  final String contentHash;
  final int length;
  final String extension;
  final String displayName;
  final DateTime verifiedAt;
  final String sourceClientId;

  Map<String, Object?> toJson() => <String, Object?>{
    'hash': contentHash,
    'length': length,
    'ext': extension,
    'name': displayName,
    'verifiedAt': verifiedAt.toIso8601String(),
    'client': sourceClientId,
  };

  static ArchiveDeskEntry? decode(Object? value) {
    if (value is! Map) return null;
    final hash = value['hash'];
    final length = value['length'];
    final extension = value['ext'];
    final name = value['name'];
    final verifiedAt = DateTime.tryParse('${value['verifiedAt']}');
    if (!archiveIsValidContentHash(hash) ||
        length is! int ||
        length <= 0 ||
        extension is! String ||
        !archiveAllowedStoredExtensions.contains(extension) ||
        name is! String ||
        verifiedAt == null) {
      return null;
    }
    return ArchiveDeskEntry(
      contentHash: hash as String,
      length: length,
      extension: extension,
      displayName: archiveSanitizeDisplayName(name),
      verifiedAt: verifiedAt,
      sourceClientId: value['client'] is String
          ? value['client'] as String
          : '',
    );
  }
}

class ArchiveDeskStore {
  ArchiveDeskStore({
    Directory? directory,
    bool inMemory = false,
    Future<Directory> Function()? supportDirectory,
    bool? developmentProfile,
    Future<bool> Function()? isolationProvider,
    Future<void> Function()? configWriteInterceptor,
  }) : _directoryOverride = directory,
       // ignore: prefer_initializing_formals
       _inMemory = inMemory,
       // ignore: prefer_initializing_formals
       _supportDirectory = supportDirectory,
       // ignore: prefer_initializing_formals
       _developmentProfile = developmentProfile,
       // ignore: prefer_initializing_formals
       _isolationProvider = isolationProvider,
       // ignore: prefer_initializing_formals
       _configWriteInterceptor = configWriteInterceptor,
       // ignore: prefer_initializing_formals
       config = ArchiveDeskConfig(
         deskId: ArchivePairing.generateDeskId(),
         pairingKey: ArchivePairing.generateKey(),
       );

  static const indexFileName = 'archive_index.json';
  static const configFileName = 'archive_config.json';

  final Directory? _directoryOverride;
  final bool _inMemory;
  final Future<Directory> Function()? _supportDirectory;
  final bool? _developmentProfile;
  final Future<bool> Function()? _isolationProvider;
  final Future<void> Function()? _configWriteInterceptor;
  final Map<String, ArchiveDeskEntry> _entries = {};
  ArchiveDeskConfig config;
  String? loadError;
  String? saveError;
  bool storageUnavailable = false;
  Future<void> _pendingWrite = Future<void>.value();
  Future<void> _configChain = Future<void>.value();
  Future<void> _commitChain = Future<void>.value();
  bool _loaded = false;

  bool get loaded => _loaded;
  List<ArchiveDeskEntry> get entries => List.unmodifiable(
    _entries.values.toList()
      ..sort((a, b) => b.verifiedAt.compareTo(a.verifiedAt)),
  );
  ArchiveDeskEntry? entryForHash(String hash) => _entries[hash];

  Future<Directory> _directory() async {
    if (_directoryOverride != null) return _directoryOverride;
    Directory base;
    try {
      base = _supportDirectory == null
          ? await getApplicationSupportDirectory()
          : await _supportDirectory();
    } catch (_) {
      throw const ArchiveException('无法访问 Mac 私有归档目录，已停止接收与读写配对信息');
    }
    final development = await _resolveArchiveDevelopmentProfile(
      _developmentProfile,
      _isolationProvider,
    );
    return Directory(
      p.join(
        base.path,
        development ? 'KoeArchiveDevelopment' : 'KoeArchive',
        'desk',
      ),
    );
  }

  /// Test seam for the private Application Support boundary.
  Future<Directory> storageDirectory() => _directory();

  Future<Directory> filesDirectory() async =>
      Directory(p.join((await _directory()).path, 'files'));

  Future<Directory> incomingDirectory() async =>
      Directory(p.join((await _directory()).path, 'incoming'));

  Future<File> fileForEntry(ArchiveDeskEntry entry) async => File(
    p.join(
      (await filesDirectory()).path,
      '${entry.contentHash}${entry.extension}',
    ),
  );

  Future<File> fileFor(String hash, String extension) async =>
      File(p.join((await filesDirectory()).path, '$hash$extension'));

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    if (_inMemory) return;
    try {
      final directory = await _directory();
      final target = File(p.join(directory.path, configFileName));
      if (await target.exists()) {
        final decoded = ArchiveDeskConfig.decode(
          jsonDecode(await target.readAsString()),
        );
        if (decoded == null) {
          loadError = 'Mac 归档配置无法读取，已生成新的配对信息';
          await saveConfig();
        } else {
          config = decoded;
        }
      }
      final index = File(p.join(directory.path, indexFileName));
      if (await index.exists()) {
        try {
          final decoded = jsonDecode(await index.readAsString());
          if (decoded is Map && decoded['entries'] is List) {
            for (final value in decoded['entries'] as List) {
              final entry = ArchiveDeskEntry.decode(value);
              if (entry != null) _entries[entry.contentHash] = entry;
            }
          }
        } catch (_) {
          loadError = 'Mac 归档目录无法读取，将按磁盘文件核对后恢复';
        }
      }
      await _adoptFilesOnDisk();
    } on ArchiveException catch (error) {
      storageUnavailable = true;
      loadError = error.message;
    } catch (_) {
      loadError = 'Mac 归档目录无法读取，请检查存储空间';
    }
  }

  Future<void> _adoptFilesOnDisk() async {
    final files = await filesDirectory();
    if (!await files.exists()) return;
    var changed = false;
    final pattern = RegExp(r'^([a-f0-9]{64})(\.[a-z0-9.]+)$');
    await for (final entity in files.list(followLinks: false)) {
      if (entity is! File) continue;
      final match = pattern.firstMatch(p.basename(entity.path));
      if (match == null) continue;
      final hash = match.group(1)!;
      final extension = match.group(2)!;
      if (!archiveAllowedStoredExtensions.contains(extension)) continue;
      if (_entries.containsKey(hash)) continue;
      final stat = await entity.stat();
      if (stat.type != FileSystemEntityType.file || stat.size <= 0) continue;
      String? actual;
      try {
        actual = await archiveFileHash(entity.path);
      } on ArchiveException {
        continue;
      }
      if (actual != hash) {
        // Keep a misleadingly named/corrupt file on disk for diagnosis, but do
        // not expose it as a verified archive entry.
        continue;
      }
      _entries[hash] = ArchiveDeskEntry(
        contentHash: hash,
        length: stat.size,
        extension: extension,
        displayName: 'Koe 归档',
        verifiedAt: DateTime.now(),
      );
      changed = true;
    }
    if (changed) await saveIndex();
  }

  Future<void> _writeConfig(ArchiveDeskConfig value) async {
    if (_inMemory) return;
    await _configWriteInterceptor?.call();
    final target = File(p.join((await _directory()).path, configFileName));
    await _writeAtomic(target, jsonEncode(value.toJson()));
  }

  Future<T> _serializedConfig<T>(Future<T> Function() work) {
    final operation = _configChain.then((_) => work());
    _configChain = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> saveConfig() => _serializedConfig(() => _writeConfig(config));

  Future<void> saveIndex({Map<String, ArchiveDeskEntry>? entries}) {
    if (_inMemory) return Future<void>.value();
    final source = entries ?? _entries;
    final snapshot = jsonEncode(<String, Object?>{
      'version': 1,
      'entries': source.values.map((entry) => entry.toJson()).toList(),
    });
    return _serialized(() async {
      final target = File(p.join((await _directory()).path, indexFileName));
      await _writeAtomic(target, snapshot);
    });
  }

  Future<void> setReceiving({required bool enabled, int? preferredPort}) =>
      _serializedConfig(() async {
        final next = config.copyWith(
          receivingEnabled: enabled,
          preferredPort: preferredPort,
        );
        await _writeConfig(next);
        config = next;
      });

  Future<void> updatePreferredPort(int port) async {
    if (config.preferredPort == port) return;
    try {
      await _serializedConfig(() async {
        final next = config.copyWith(preferredPort: port);
        await _writeConfig(next);
        config = next;
      });
    } catch (_) {
      // Port persistence is best effort; a later start can reveal a fresh code.
    }
  }

  Future<void> forgetEntry(String hash) => _serializedCommit(() async {
    if (!_entries.containsKey(hash)) return;
    final next = Map<String, ArchiveDeskEntry>.of(_entries)..remove(hash);
    await saveIndex(entries: next);
    _entries.remove(hash);
  });

  Future<ArchiveDeskEntry> recordVerified(ArchiveDeskEntry entry) =>
      _serializedCommit(() async {
        final existing = _entries[entry.contentHash];
        if (existing != null) return existing;
        final next = Map<String, ArchiveDeskEntry>.of(_entries)
          ..[entry.contentHash] = entry;
        await saveIndex(entries: next);
        _entries[entry.contentHash] = entry;
        return entry;
      });

  Future<bool> verifyEntry(ArchiveDeskEntry entry) async {
    final file = await fileForEntry(entry);
    if (!await file.exists()) return false;
    String? actual;
    try {
      actual = await archiveFileHash(file.path);
    } on ArchiveException {
      return false;
    }
    if (actual != entry.contentHash) return false;
    return (await file.length()) == entry.length;
  }

  /// Moves a verified temporary file to its content-addressed final name.
  ///
  /// The caller has already hashed the bytes on disk. This method never
  /// overwrites a different payload: an existing final file is re-read and
  /// compared before it is accepted as a duplicate.
  Future<ArchiveDeskEntry> commitVerified({
    required String temporaryPath,
    required String contentHash,
    required int length,
    required String extension,
    required String displayName,
    required DateTime verifiedAt,
    required String sourceClientId,
  }) {
    return _serializedCommit(() async {
      if (!archiveIsValidContentHash(contentHash) ||
          length <= 0 ||
          length > archiveMaxAudioBytes) {
        throw const ArchiveProtocolException('归档内容参数不合法');
      }
      final storedExtension = archiveStoredExtension(extension);
      await (await filesDirectory()).create(recursive: true);
      final finalFile = await fileFor(contentHash, storedExtension);

      final next = Map<String, ArchiveDeskEntry>.of(_entries);
      final existing = next[contentHash];
      if (existing != null) {
        if (existing.length == length && await verifyEntry(existing)) {
          final temp = File(temporaryPath);
          if (await temp.exists()) {
            try {
              await temp.delete();
            } catch (_) {}
          }
          return existing;
        }
        // A stale/corrupt index entry is removed under the same commit lock;
        // the unreadable file is moved aside, never overwritten in place.
        if (await finalFile.exists()) {
          try {
            await finalFile.rename(
              '${finalFile.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}',
            );
          } catch (_) {
            throw const ArchiveRemoteException(
              'Mac 上的旧归档损坏且无法隔离，已拒绝覆盖',
              reason: 'remote_corrupt',
            );
          }
        }
        next.remove(contentHash);
      }

      var created = false;
      if (await finalFile.exists()) {
        final actual = await archiveFileHash(finalFile.path);
        if (actual != contentHash) {
          throw const ArchiveRemoteException(
            'Mac 上已有同 ID 但内容不同的文件，已拒绝覆盖',
            reason: 'conflict',
          );
        }
        if (await finalFile.length() != length) {
          throw const ArchiveRemoteException(
            'Mac 上已有同 ID 但长度不同的文件，已拒绝覆盖',
            reason: 'conflict',
          );
        }
      } else {
        try {
          await File(temporaryPath).rename(finalFile.path);
          created = true;
        } on FileSystemException {
          if (!await finalFile.exists()) rethrow;
          final actual = await archiveFileHash(finalFile.path);
          if (actual != contentHash) {
            throw const ArchiveRemoteException(
              'Mac 上已有同 ID 但内容不同的文件，已拒绝覆盖',
              reason: 'conflict',
            );
          }
        }
      }

      final entry = ArchiveDeskEntry(
        contentHash: contentHash,
        length: length,
        extension: storedExtension,
        displayName: archiveSanitizeDisplayName(displayName),
        verifiedAt: verifiedAt,
        sourceClientId: sourceClientId,
      );
      next[contentHash] = entry;
      try {
        await saveIndex(entries: next);
      } catch (_) {
        if (created) {
          try {
            await finalFile.delete();
          } catch (_) {}
        }
        rethrow;
      } finally {
        final temp = File(temporaryPath);
        if (await temp.exists()) {
          try {
            await temp.delete();
          } catch (_) {}
        }
      }
      _entries
        ..clear()
        ..addAll(next);
      return entry;
    });
  }

  Future<T> _serializedCommit<T>(Future<T> Function() work) {
    final operation = _commitChain.then((_) => work());
    _commitChain = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<T> _serialized<T>(Future<T> Function() work) {
    final operation = _pendingWrite.then((_) => work());
    _pendingWrite = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }
}

Future<void> _writeAtomic(File target, String contents) async {
  await target.parent.create(recursive: true);
  final temporary = File('${target.path}.tmp');
  await temporary.writeAsString(contents, flush: true);
  await temporary.rename(target.path);
}

Future<bool> _resolveArchiveDevelopmentProfile(
  bool? explicit,
  Future<bool> Function()? provider,
) async {
  if (explicit != null) return explicit;
  try {
    final Future<bool> pending = provider != null
        ? provider()
        : CredentialStore().isIsolated;
    return await pending;
  } catch (_) {
    // Fail closed: an unreadable build mode must never open production pairing.
    return true;
  }
}
