import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'archive_pairing.dart';
import 'archive_service.dart';
import 'archive_store.dart';
import 'archive_wire.dart';

class ArchiveCandidate {
  const ArchiveCandidate({
    required this.path,
    required this.displayName,
    required this.extension,
    required this.length,
    required this.modifiedMs,
    this.recordedAt,
  });

  final String path;
  final String displayName;
  final String extension;
  final int length;
  final int modifiedMs;
  final DateTime? recordedAt;
}

/// The small seam between the archive coordinator and the recording library.
/// The coordinator owns protocol, queue and verification; the library owns
/// where an original lives and how it is registered for playback.
abstract interface class ArchiveSource {
  Future<List<ArchiveCandidate>> archiveCandidates();
  Future<ArchiveCandidate?> archiveCandidate(String path);
  Future<String> archiveRestoreTarget(ArchivePhoneRecord record);
  Future<bool> archiveDidRestore(
    ArchivePhoneRecord record,
    String path, {
    required int length,
    required String contentHash,
    required bool Function() isCurrent,
  });
}

typedef ArchiveClientConnector =
    Future<ArchiveClient> Function(ArchivePairing pairing, String clientId);
typedef ArchiveDeskServerFactory =
    ArchiveDeskServer Function(ArchiveDeskStore store);

enum ArchiveLinkPhase {
  unpaired,
  disconnected,
  connecting,
  connected,
  waiting,
  failed,
}

class MacArchiveController extends ChangeNotifier {
  MacArchiveController({
    required this.source,
    required this.isDesk,
    ArchivePhoneStore? phoneStore,
    ArchiveDeskStore? deskStore,
    bool inMemory = false,
    ArchiveClientConnector? clientConnector,
    ArchiveDeskServerFactory? deskServerFactory,
    DateTime Function()? clock,
  }) : phoneStore = phoneStore ?? ArchivePhoneStore(inMemory: inMemory),
       deskStore = deskStore ?? ArchiveDeskStore(inMemory: inMemory),
       _clientConnector =
           clientConnector ??
           ((pairing, clientId) =>
               ArchiveClient.connect(pairing, clientId: clientId)),
       _deskServerFactory =
           deskServerFactory ?? ((store) => ArchiveDeskServer(store: store)),
       _clock = clock ?? DateTime.now {
    if (isDesk) {
      _server = _deskServerFactory(this.deskStore);
      _server!.onVerified = _onDeskVerified;
    }
  }

  final ArchiveSource source;
  final bool isDesk;
  final ArchivePhoneStore phoneStore;
  final ArchiveDeskStore deskStore;
  final ArchiveClientConnector _clientConnector;
  final ArchiveDeskServerFactory _deskServerFactory;
  final DateTime Function() _clock;

  ArchiveDeskServer? _server;
  ArchiveClient? _workerClient;
  ArchiveClient? _interactiveClient;
  int _connectionEpoch = 0;
  int _pairEpoch = 0;
  ArchiveLinkPhase _linkPhase = ArchiveLinkPhase.unpaired;
  String? _phoneError;
  String? _deskError;
  bool _manualPaused = false;
  bool _authFailed = false;
  bool _disposed = false;
  bool _initialized = false;
  Future<void>? _initialization;
  Future<void>? _worker;
  bool _kickRequested = false;
  String? _inFlightPath;
  Timer? _retryTimer;
  final Set<String> _explicitPaths = <String>{};
  final Map<String, DateTime> _nextAttempt = <String, DateTime>{};
  final Map<String, int> _recordGenerations = <String, int>{};
  final Set<String> _restoreInFlight = <String>{};
  final Map<String, String> _restoreErrors = <String, String>{};
  final Map<String, double> _transferProgress = <String, double>{};

  bool get initialized => _initialized;
  bool get deskReceivingEnabled => deskStore.config.receivingEnabled;
  bool get deskRunning => _server?.running ?? false;
  int? get deskPort => _server?.port;
  ArchiveDeskServer? get deskServer => _server;
  ArchivePairing? get deskPairing => _server?.pairing;
  List<String> get deskAddresses => _server?.addresses ?? const <String>[];
  int get receivedCount => deskStore.entries.length;
  DateTime? get lastReceivedAt =>
      deskStore.entries.isEmpty ? null : deskStore.entries.first.verifiedAt;
  String? get deskError =>
      _deskError ?? _server?.lastError ?? deskStore.loadError;

  ArchivePairing? get pairing => phoneStore.pairing;
  bool get autoArchive => phoneStore.autoArchive;
  bool get connected =>
      _interactiveClient?.connected == true || _workerClient?.connected == true;
  bool get manualPaused => _manualPaused;
  bool get authorizationFailed => _authFailed;
  ArchiveLinkPhase get linkPhase => _linkPhase;
  String? get phoneError => _phoneError;
  List<ArchivePhoneRecord> get records => List.unmodifiable(phoneStore.records);
  ArchivePhoneRecord? recordForPath(String path) =>
      phoneStore.recordForPath(path);
  String? restoreErrorForPath(String path) => _restoreErrors[path];
  double? transferProgressForPath(String path) => _transferProgress[path];

  String get linkLabel {
    if (pairing == null) return '未配对';
    if (_manualPaused) return '已断开';
    if (connected && _linkPhase != ArchiveLinkPhase.failed) return '已连接';
    return switch (_linkPhase) {
      ArchiveLinkPhase.unpaired => '未配对',
      ArchiveLinkPhase.disconnected => '已断开',
      ArchiveLinkPhase.connecting => '连接中',
      ArchiveLinkPhase.connected => '已连接',
      ArchiveLinkPhase.waiting => '等待 Mac',
      ArchiveLinkPhase.failed => '连接失败',
    };
  }

  String get linkDetail {
    final error = _phoneError;
    if (error != null && error.isNotEmpty) return error;
    if (pairing == null) return '还没有配对 Mac';
    if (_manualPaused) return '已手动断开；点“连接”后继续归档';
    if (connected) return '直连 ${pairing!.address} · 加密传输';
    return '将自动连接 ${pairing!.address}';
  }

  List<String> get archivedWithoutLocal => [
    for (final record in phoneStore.records)
      if (record.verified &&
          record.hasVersion &&
          (pairing == null ||
              record.deskId == null ||
              record.deskId == pairing!.deskId) &&
          !File(record.localPath).existsSync())
        record.localPath,
  ];

  ArchiveDeskReceipt? receiptForCurrentDesk(ArchivePhoneRecord record) {
    final desk = pairing?.deskId;
    if (desk == null) return null;
    return record.receipts[desk];
  }

  String? otherDeskWithReceipt(ArchivePhoneRecord record) {
    final current = pairing?.deskId;
    // A desk identity alone is not evidence of a verified copy: failed,
    // pending, cancelled or hash-less records must rely on receipts only.
    if (record.verified &&
        record.hasVersion &&
        record.deskId != null &&
        record.deskId != current) {
      return record.deskId;
    }
    for (final entry in record.receipts.entries) {
      if (entry.key != current) return entry.key;
    }
    return null;
  }

  bool hasAnyReceipt(ArchivePhoneRecord record) => record.receipts.isNotEmpty;

  bool hasArchiveForPath(String path) {
    final record = phoneStore.recordForPath(path);
    return record?.verified == true &&
        (pairing == null ||
            record?.deskId == null ||
            record?.deskId == pairing!.deskId);
  }

  String statusForPath(String path) {
    final record = phoneStore.recordForPath(path);
    if (record == null) {
      return pairing == null ? '未配对' : '未归档';
    }
    final localPresent = File(path).existsSync();
    final otherDesk = otherDeskWithReceipt(record);
    if (!record.verified && otherDesk != null) {
      return '原件在另一台 Mac';
    }
    if (record.verified &&
        record.deskId != null &&
        pairing != null &&
        record.deskId != pairing!.deskId) {
      return '需重新归档到当前 Mac';
    }
    return switch (record.phase) {
      MacArchivePhase.pending => connected ? '等待传输' : '等待连接',
      MacArchivePhase.uploading => '传输中',
      MacArchivePhase.verifying => '校验中',
      MacArchivePhase.verified => localPresent ? '已校验归档' : '已校验归档 · 原件不在本机',
      MacArchivePhase.failed => '失败可重试',
    };
  }

  String detailForPath(String path) {
    final record = phoneStore.recordForPath(path);
    if (record == null) {
      if (pairing == null) return '未配对 Mac；原件保留在手机';
      return '原件保留在手机，可手动归档到 Mac';
    }
    final otherDesk = otherDeskWithReceipt(record);
    if (!record.verified && otherDesk != null) {
      return '原件在另一台 Mac；请配回原 Mac 后恢复原字节';
    }
    if (record.verified &&
        record.deskId != null &&
        pairing != null &&
        record.deskId != pairing!.deskId) {
      return '这条归档属于另一台 Mac；原字节仍保留在旧 Mac';
    }
    final error = record.error;
    return switch (record.phase) {
      MacArchivePhase.pending =>
        error?.isNotEmpty == true ? error! : '等待 Mac 连接后继续',
      MacArchivePhase.uploading => _progressLabel(path) ?? '正在传输原件',
      MacArchivePhase.verifying => 'Mac 正在核对落盘内容',
      MacArchivePhase.verified =>
        '已核对内容哈希与长度${record.verifiedAt == null ? '' : ' · ${_formatDateTime(record.verifiedAt!)}'}',
      MacArchivePhase.failed => error?.isNotEmpty == true ? error! : '归档失败，可重试',
    };
  }

  String? _progressLabel(String path) {
    final value = _transferProgress[path];
    if (value == null) return null;
    return '正在传输 ${(value.clamp(0, 1) * 100).round()}%';
  }

  Future<void> initialize() {
    final existing = _initialization;
    if (existing != null) return existing;
    final task = _initialize();
    _initialization = task;
    return task;
  }

  Future<void> _initialize() async {
    await Future.wait(<Future<void>>[phoneStore.load(), deskStore.load()]);
    if (_disposed) return;
    _initialized = true;
    final legacyDesk = phoneStore.pairing?.deskId;
    if (legacyDesk != null) {
      final unbound = phoneStore.records
          .where((record) => record.deskId == null)
          .map(
            (record) =>
                record.copyWith(deskId: legacyDesk, updatedAt: _clock()),
          )
          .toList();
      if (unbound.isNotEmpty) await phoneStore.upsertAll(unbound);
    }
    if (phoneStore.loadError != null) _phoneError = phoneStore.loadError;
    if (deskStore.loadError != null) _deskError = deskStore.loadError;
    if (isDesk &&
        !deskStore.storageUnavailable &&
        deskStore.config.receivingEnabled) {
      try {
        await _server!.start();
      } on ArchiveException catch (error) {
        _deskError = error.message;
      } catch (_) {
        _deskError = 'Mac 接收服务启动失败';
      }
    }
    _linkPhase = pairing == null
        ? ArchiveLinkPhase.unpaired
        : _manualPaused
        ? ArchiveLinkPhase.disconnected
        : ArchiveLinkPhase.waiting;
    _ensureTimer();
    _notify();
    if (pairing != null && (phoneStore.autoArchive || _hasManualPending)) {
      unawaited(_kick());
    }
  }

  bool get _hasManualPending => phoneStore.records.any(
    (record) => record.manual && record.phase == MacArchivePhase.pending,
  );

  Future<void> pairWithCode(String raw) async {
    await initialize();
    _requireActive();
    _requirePhoneStorage();
    final next = ArchivePairing.parse(raw);
    final operation = ++_pairEpoch;
    final startEpoch = _connectionEpoch;
    ArchiveClient? probe;
    ArchiveException? offline;
    try {
      probe = await _clientConnector(next, phoneStore.clientId);
    } on ArchiveAuthException {
      rethrow;
    } on ArchiveException catch (error) {
      offline = error;
    }
    if (_disposed ||
        operation != _pairEpoch ||
        startEpoch != _connectionEpoch) {
      await probe?.close();
      throw const ArchiveException('配对已取消，请重试');
    }
    if (probe != null && probe.pairing.deskId != next.deskId) {
      await probe.close();
      throw const ArchiveAuthException();
    }
    final now = _clock();
    final previousDesk = phoneStore.pairing?.deskId;
    try {
      await phoneStore.setConfiguration(
        pairing: next,
        autoArchive: true,
        autoArchiveFrom: now,
      );
    } catch (_) {
      await probe?.close();
      throw const ArchiveException('保存配对信息失败，请检查存储空间');
    }
    if (previousDesk != null && previousDesk != next.deskId) {
      _connectionEpoch++;
      await _closeWorkerClient();
      await _closeInteractiveClient();
    }
    _connectionEpoch++;
    await _closeWorkerClient();
    await _closeInteractiveClient();
    _interactiveClient = probe;
    _manualPaused = false;
    _authFailed = false;
    _phoneError = probe == null ? offline?.message : null;
    _linkPhase = probe == null
        ? ArchiveLinkPhase.waiting
        : ArchiveLinkPhase.connected;
    await _rebindRecordsTo(next.deskId, now);
    _ensureTimer();
    _notify();
    unawaited(_kick());
  }

  Map<String, ArchiveDeskReceipt> _receiptsWith(ArchivePhoneRecord record) {
    final receipts = Map<String, ArchiveDeskReceipt>.of(record.receipts);
    final desk = record.deskId;
    if (desk != null && record.verified && record.hasVersion) {
      receipts[desk] = ArchiveDeskReceipt(
        contentHash: record.contentHash!,
        length: record.verifiedLength ?? record.length,
        extension: record.originalExtension,
        verifiedAt: record.verifiedAt ?? record.updatedAt,
        sourceLength: record.length,
        sourceModifiedMs: record.sourceModifiedMs,
      );
    }
    return receipts;
  }

  Future<void> _rebindRecordsTo(String deskId, DateTime now) async {
    final changes = <ArchivePhoneRecord>[];
    for (final record in phoneStore.records) {
      if (record.deskId == deskId) continue;
      final receipts = _receiptsWith(record);
      final target = receipts[deskId];
      final local = File(record.localPath);
      final localPresent = await local.exists();
      final stat = localPresent ? await local.stat() : null;
      invalidateRestore(record.localPath);
      if (target != null) {
        final matches =
            !localPresent ||
            (stat != null &&
                stat.size == target.sourceLength &&
                stat.modified.millisecondsSinceEpoch ==
                    target.sourceModifiedMs);
        changes.add(
          record.copyWith(
            deskId: deskId,
            receipts: receipts,
            phase: matches ? MacArchivePhase.verified : MacArchivePhase.pending,
            contentHash: matches ? target.contentHash : null,
            clearContentHash: !matches,
            clearVerified: !matches,
            length: localPresent ? stat!.size : target.sourceLength,
            sourceModifiedMs: localPresent
                ? stat!.modified.millisecondsSinceEpoch
                : target.sourceModifiedMs,
            verifiedAt: matches ? target.verifiedAt : null,
            verifiedLength: matches ? target.length : null,
            originalExtension: target.extension,
            manual: !matches && localPresent,
            error: !matches && !localPresent ? '原件不在本机，无法归档到新 Mac' : null,
            clearError: matches || localPresent,
            updatedAt: now,
          ),
        );
      } else {
        changes.add(
          record.copyWith(
            deskId: deskId,
            receipts: receipts,
            phase: localPresent
                ? MacArchivePhase.pending
                : MacArchivePhase.failed,
            clearContentHash: true,
            clearVerified: true,
            manual: localPresent,
            error: localPresent ? null : '原件不在本机，无法归档到新 Mac',
            clearError: localPresent,
            updatedAt: now,
          ),
        );
      }
    }
    if (changes.isEmpty) return;
    await phoneStore.upsertAll(changes);
  }

  Future<void> unpair() async {
    await initialize();
    _connectionEpoch++;
    await _closeWorkerClient();
    await _closeInteractiveClient();
    await phoneStore.setConfiguration(
      pairing: null,
      autoArchive: false,
      autoArchiveFrom: null,
    );
    _manualPaused = false;
    _authFailed = false;
    _phoneError = null;
    _linkPhase = ArchiveLinkPhase.unpaired;
    _retryTimer?.cancel();
    _retryTimer = null;
    _notify();
  }

  Future<void> setAutoArchive(bool value) async {
    await initialize();
    _requireActive();
    _requirePhoneStorage();
    if (value && pairing == null) {
      throw const ArchiveException('请先配对 Mac');
    }
    await phoneStore.setAutoArchive(
      value,
      autoArchiveFrom: value ? _clock() : null,
    );
    if (value) {
      _manualPaused = false;
      _ensureTimer();
      unawaited(_kick());
    }
    _notify();
  }

  Future<void> connectNow() async {
    await initialize();
    _requireActive();
    _requirePhoneStorage();
    if (pairing == null) throw const ArchiveException('请先配对 Mac');
    _manualPaused = false;
    _authFailed = false;
    _nextAttempt.clear();
    try {
      await _ensureInteractiveClient(expectedDeskId: pairing!.deskId);
      _ensureTimer();
      unawaited(_kick());
      _notify();
    } on ArchiveException catch (error) {
      _phoneError = error.message;
      _notify();
      rethrow;
    }
  }

  Future<void> disconnect() async {
    await initialize();
    _manualPaused = true;
    _connectionEpoch++;
    await _closeWorkerClient();
    await _closeInteractiveClient();
    _linkPhase = ArchiveLinkPhase.disconnected;
    _notify();
  }

  Future<void> archiveNow(String path) async {
    await initialize();
    _requireActive();
    _requirePhoneStorage();
    if (pairing == null) throw const ArchiveException('请先配对 Mac');
    final candidate = await source.archiveCandidate(path);
    if (candidate == null) {
      throw const ArchiveException('原件不在手机上，无法再次归档');
    }
    _manualPaused = false;
    final now = _clock();
    final existing = phoneStore.recordForPath(path);
    final record = (existing ?? _newRecord(candidate, now)).copyWith(
      phase: MacArchivePhase.pending,
      manual: true,
      displayName: candidate.displayName,
      originalExtension: candidate.extension,
      length: candidate.length,
      sourceModifiedMs: candidate.modifiedMs,
      recordedAt: candidate.recordedAt,
      error: null,
      clearError: true,
      updatedAt: now,
    );
    await phoneStore.upsert(record);
    _nextAttempt.remove(path);
    _explicitPaths.add(path);
    _ensureTimer();
    _notify();
    unawaited(_kick());
  }

  Future<void> retry(String path) => archiveNow(path);

  Future<int> queueAllExisting() async {
    await initialize();
    _requireActive();
    _requirePhoneStorage();
    if (pairing == null) throw const ArchiveException('请先配对 Mac');
    final candidates = await source.archiveCandidates();
    final now = _clock();
    final queued = <ArchivePhoneRecord>[];
    for (final candidate in candidates) {
      if (!archiveIsAllowedSourceExtension(candidate.path)) continue;
      final existing = phoneStore.recordForPath(candidate.path);
      if (existing?.verified == true &&
          existing!.contentHash != null &&
          existing.sourceModifiedMs == candidate.modifiedMs &&
          existing.length == candidate.length) {
        continue;
      }
      final record = (existing ?? _newRecord(candidate, now)).copyWith(
        phase: MacArchivePhase.pending,
        manual: true,
        displayName: candidate.displayName,
        originalExtension: candidate.extension,
        length: candidate.length,
        sourceModifiedMs: candidate.modifiedMs,
        recordedAt: candidate.recordedAt,
        error: null,
        clearError: true,
        updatedAt: now,
      );
      queued.add(record);
    }
    if (queued.isEmpty) return 0;
    await phoneStore.upsertAll(queued);
    _manualPaused = false;
    _nextAttempt.clear();
    _ensureTimer();
    _notify();
    unawaited(_kick());
    return queued.length;
  }

  Future<String> restoreFromArchive(String path) async {
    await initialize();
    _requireActive();
    _requirePhoneStorage();
    final record = phoneStore.recordForPath(path);
    if (record == null || !record.verified || !record.hasVersion) {
      throw const ArchiveException('这条资料没有已校验的 Mac 归档，无法恢复');
    }
    final targetDeskId = pairing?.deskId;
    if (targetDeskId == null) throw const ArchiveException('请先配对 Mac');
    if (record.deskId != null && record.deskId != targetDeskId) {
      throw const ArchiveException('这条归档属于另一台 Mac，请重新配对或归档');
    }
    if (!_restoreInFlight.add(path)) {
      throw const ArchiveException('这条资料正在恢复，请稍候');
    }
    final epoch = _connectionEpoch;
    final generation = _recordGeneration(path);
    _manualPaused = false;
    _restoreErrors.remove(path);
    _notify();
    try {
      final client = await _ensureInteractiveClient(
        expectedDeskId: targetDeskId,
      );
      if (!_targetStillCurrent(epoch, targetDeskId)) {
        throw const ArchiveException('连接目标已变更');
      }
      final remote = await client.verify(record.contentHash!);
      if (!_targetStillCurrent(epoch, targetDeskId)) {
        throw const ArchiveException('连接目标已变更');
      }
      if (!remote.verified ||
          remote.length == null ||
          remote.length != (record.verifiedLength ?? record.length)) {
        throw const ArchiveRemoteException('Mac 上的归档未通过校验，不能恢复');
      }
      final target = await source.archiveRestoreTarget(record);
      await client.fetchToFile(
        contentHash: record.contentHash!,
        expectedLength: remote.length!,
        targetPath: target,
        onProgress: (received, total) {
          if (total <= 0) return;
          _transferProgress[path] = received / total;
          _notify();
        },
      );
      if (!_restoreTokenCurrent(
        path,
        generation,
        epoch,
        targetDeskId,
        record.contentHash!,
      )) {
        // Never delete the downloaded final file here: the path may already
        // belong to a newer user action. fetchToFile only removes its own
        // temporary part on failure.
        throw const ArchiveException('资料已变更，已取消恢复');
      }
      final diskHash = await archiveFileHash(target);
      final diskLength = await File(target).length();
      if (diskHash != record.contentHash || diskLength != remote.length) {
        throw const ArchiveRemoteException('恢复的原件校验失败，未加入手机资料库');
      }
      // The source re-checks this token before and after its library write, so
      // a delete/rename during that window cannot leave a resurrected asset.
      final applied = await source.archiveDidRestore(
        record,
        target,
        length: diskLength,
        contentHash: diskHash!,
        isCurrent: () => _restoreTokenCurrent(
          path,
          generation,
          epoch,
          targetDeskId,
          record.contentHash!,
        ),
      );
      if (!applied ||
          !_restoreTokenCurrent(
            path,
            generation,
            epoch,
            targetDeskId,
            record.contentHash!,
          )) {
        throw const ArchiveException('资料已变更，已取消恢复');
      }
      final committed = await phoneStore.completeRestore(
        fromPath: record.localPath,
        targetPath: target,
        test: (current) =>
            current.contentHash == record.contentHash &&
            current.deskId == targetDeskId &&
            _restoreTokenCurrent(
              path,
              generation,
              epoch,
              targetDeskId,
              record.contentHash!,
            ),
        update: (current) {
          final receipts = _receiptsWith(current);
          receipts[targetDeskId] = ArchiveDeskReceipt(
            contentHash: record.contentHash!,
            length: diskLength,
            extension: record.originalExtension,
            verifiedAt: record.verifiedAt ?? _clock(),
            sourceLength: record.length,
            sourceModifiedMs: record.sourceModifiedMs,
          );
          return current.copyWith(
            localPath: target,
            deskId: targetDeskId,
            phase: MacArchivePhase.verified,
            verifiedLength: diskLength,
            receipts: receipts,
            error: null,
            clearError: true,
            updatedAt: _clock(),
          );
        },
      );
      if (!committed) {
        throw const ArchiveException('资料已变更，已取消恢复');
      }
      _restoreErrors.remove(path);
      _restoreErrors.remove(target);
      _transferProgress.remove(path);
      _notify();
      return target;
    } on ArchiveException catch (error) {
      _restoreErrors[path] = error.message;
      if (error is ArchiveAuthException) {
        _authFailed = true;
        _linkPhase = ArchiveLinkPhase.failed;
      } else if (error is ArchiveProtocolException ||
          error is ArchiveTimeoutException) {
        await _closeInteractiveClient();
        _linkPhase = ArchiveLinkPhase.waiting;
      }
      _phoneError = error.message;
      _notify();
      rethrow;
    } catch (error) {
      _restoreErrors[path] = '恢复失败，请重试';
      _phoneError = '恢复失败，请重试';
      _notify();
      throw const ArchiveException('恢复失败，请重试');
    } finally {
      _restoreInFlight.remove(path);
    }
  }

  /// Invalidates an in-flight restore without deleting the phone original or
  /// the Mac copy. Called when the local material is trashed, renamed or
  /// permanently removed.
  void invalidateRestore(String path) {
    _recordGenerations[path] = _recordGeneration(path) + 1;
  }

  int _recordGeneration(String path) => _recordGenerations[path] ?? 0;

  Future<void> forgetLocalPath(String path) async {
    invalidateRestore(path);
    await phoneStore.remove(path);
    _restoreErrors.remove(path);
    _nextAttempt.remove(path);
    _transferProgress.remove(path);
    _notify();
  }

  Future<void> renameLocalPath(String from, String to) async {
    invalidateRestore(from);
    invalidateRestore(to);
    await phoneStore.rename(from, to);
    _notify();
  }

  Future<void> onLocalLibraryChanged() async {
    if (pairing == null) return;
    _ensureTimer();
    unawaited(_kick());
  }

  Future<void> setDeskReceiving(bool enabled) async {
    await initialize();
    if (!isDesk) throw const ArchiveException('只有 Mac 可以接收原件');
    if (deskStore.storageUnavailable) {
      throw ArchiveException(deskStore.loadError ?? '无法访问 Mac 私有归档目录');
    }
    final server = _server!;
    if (enabled) {
      try {
        await server.start();
        await deskStore.setReceiving(enabled: true, preferredPort: server.port);
        _deskError = null;
      } on ArchiveException catch (error) {
        _deskError = error.message;
        await server.stop();
        _notify();
        rethrow;
      }
    } else {
      await server.stop();
      await deskStore.setReceiving(
        enabled: false,
        preferredPort: deskStore.config.preferredPort,
      );
      _deskError = null;
    }
    _notify();
  }

  Future<void> refreshDeskPairing() async {
    await initialize();
    if (!isDesk || !deskReceivingEnabled) return;
    final server = _server!;
    if (server.running) {
      await server.stop();
      await server.start();
      await deskStore.setReceiving(enabled: true, preferredPort: server.port);
      _notify();
    }
  }

  void _onDeskVerified() {
    _notify();
  }

  Future<ArchiveClient> _ensureWorkerClient({required String expectedDeskId}) =>
      _ensureClient(expectedDeskId: expectedDeskId, interactive: false);

  Future<ArchiveClient> _ensureInteractiveClient({
    required String expectedDeskId,
  }) => _ensureClient(expectedDeskId: expectedDeskId, interactive: true);

  Future<ArchiveClient> _ensureClient({
    required String expectedDeskId,
    required bool interactive,
  }) async {
    final epoch = _connectionEpoch;
    final existing = interactive ? _interactiveClient : _workerClient;
    if (existing != null &&
        existing.connected &&
        existing.pairing.deskId == expectedDeskId) {
      try {
        await existing.ping();
        if (!_targetStillCurrent(epoch, expectedDeskId)) {
          throw const ArchiveException('连接目标已变更');
        }
        _linkPhase = ArchiveLinkPhase.connected;
        return existing;
      } on ArchiveException {
        if (interactive) {
          await _closeInteractiveClient();
        } else {
          await _closeWorkerClient();
        }
      }
    }
    if (!_targetStillCurrent(epoch, expectedDeskId)) {
      throw const ArchiveException('连接目标已变更');
    }
    final current = pairing;
    if (current == null) throw const ArchiveException('请先配对 Mac');
    if (current.deskId != expectedDeskId) {
      throw const ArchiveException('Mac 配对目标已变更');
    }
    if (interactive) {
      await _closeInteractiveClient();
    } else {
      await _closeWorkerClient();
    }
    _linkPhase = ArchiveLinkPhase.connecting;
    _notify();
    try {
      final client = await _clientConnector(current, phoneStore.clientId);
      if (!_targetStillCurrent(epoch, expectedDeskId) ||
          client.pairing.deskId != expectedDeskId) {
        await client.close();
        throw const ArchiveException('连接目标已变更');
      }
      if (interactive) {
        _interactiveClient = client;
      } else {
        _workerClient = client;
      }
      _linkPhase = ArchiveLinkPhase.connected;
      _phoneError = null;
      _authFailed = false;
      _notify();
      return client;
    } on ArchiveAuthException catch (error) {
      _authFailed = true;
      _linkPhase = ArchiveLinkPhase.failed;
      _phoneError = error.message;
      _notify();
      rethrow;
    } on ArchiveException catch (error) {
      _linkPhase = ArchiveLinkPhase.waiting;
      _phoneError = error.message;
      _notify();
      rethrow;
    }
  }

  bool _targetStillCurrent(int epoch, String deskId) =>
      !_disposed &&
      epoch == _connectionEpoch &&
      phoneStore.pairing?.deskId == deskId;

  bool _restoreTokenCurrent(
    String path,
    int generation,
    int epoch,
    String deskId,
    String contentHash,
  ) {
    final latest = phoneStore.recordForPath(path);
    return !_disposed &&
        epoch == _connectionEpoch &&
        _recordGeneration(path) == generation &&
        phoneStore.pairing?.deskId == deskId &&
        latest != null &&
        latest.contentHash == contentHash &&
        latest.deskId == deskId;
  }

  Future<void> _closeWorkerClient() async {
    final client = _workerClient;
    _workerClient = null;
    if (client != null) {
      try {
        await client.close();
      } catch (_) {}
    }
  }

  Future<void> _closeInteractiveClient() async {
    final client = _interactiveClient;
    _interactiveClient = null;
    if (client != null) {
      try {
        await client.close();
      } catch (_) {}
    }
  }

  void _ensureTimer() {
    if (_disposed || _retryTimer != null || phoneStore.pairing == null) return;
    _retryTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_disposed || _worker != null || _manualPaused) return;
      if (phoneStore.autoArchive || _hasDueManual) {
        unawaited(_kick());
      }
    });
  }

  bool get _hasDueManual {
    final now = _clock();
    for (final record in phoneStore.records) {
      if (!record.manual || record.phase != MacArchivePhase.pending) continue;
      final due = _nextAttempt[record.localPath];
      if (due == null || !due.isAfter(now)) return true;
    }
    return false;
  }

  Future<void> _kick() {
    if (_disposed) return Future<void>.value();
    final running = _worker;
    if (running != null) {
      _kickRequested = true;
      return running;
    }
    final task = _runWorker();
    _worker = task;
    return task;
  }

  Future<void> _runWorker() async {
    try {
      do {
        _kickRequested = false;
        try {
          await _discover();
        } catch (error) {
          _phoneError = '无法读取手机原件列表';
          debugPrint('[MacArchive] discovery failed: $error');
        }
        while (!_disposed) {
          final record = _nextProcessable();
          if (record == null) break;
          await _process(record);
        }
      } while (_kickRequested && !_disposed);
    } finally {
      _worker = null;
    }
  }

  /// Resolves when the current scan/transfer attempt has finished. It never
  /// waits for an offline Mac: records stay visibly queued instead.
  Future<void> waitForWorker() async {
    while (true) {
      final running = _worker;
      if (running == null) return;
      await running;
      if (identical(_worker, running)) return;
    }
  }

  Future<void> _discover() async {
    final candidates = await source.archiveCandidates();
    final now = _clock();
    final changes = <ArchivePhoneRecord>[];
    final seen = <String>{};
    for (final candidate in candidates) {
      if (!archiveIsAllowedSourceExtension(candidate.path)) continue;
      seen.add(candidate.path);
      final existing = phoneStore.recordForPath(candidate.path);
      if (existing == null) {
        if (!_explicitPaths.contains(candidate.path) &&
            !_shouldAutoQueue(candidate)) {
          continue;
        }
        changes.add(
          _newRecord(
            candidate,
            now,
          ).copyWith(manual: _explicitPaths.contains(candidate.path)),
        );
        continue;
      }
      if (existing.verified) {
        if (existing.length != candidate.length ||
            existing.sourceModifiedMs != candidate.modifiedMs) {
          changes.add(
            existing.copyWith(
              receipts: _receiptsWith(existing),
              phase: MacArchivePhase.pending,
              clearContentHash: true,
              clearVerified: true,
              displayName: candidate.displayName,
              originalExtension: candidate.extension,
              length: candidate.length,
              sourceModifiedMs: candidate.modifiedMs,
              recordedAt: candidate.recordedAt,
              error: null,
              clearError: true,
              updatedAt: now,
            ),
          );
        }
        continue;
      }
      final metadataChanged =
          existing.displayName != candidate.displayName ||
          existing.originalExtension != candidate.extension ||
          existing.length != candidate.length ||
          existing.sourceModifiedMs != candidate.modifiedMs;
      if (existing.phase == MacArchivePhase.failed &&
          !metadataChanged &&
          !_explicitPaths.contains(candidate.path)) {
        continue;
      }
      if (metadataChanged) {
        changes.add(
          existing.copyWith(
            phase: MacArchivePhase.pending,
            clearContentHash: existing.phase == MacArchivePhase.failed,
            clearVerified: true,
            displayName: candidate.displayName,
            originalExtension: candidate.extension,
            length: candidate.length,
            sourceModifiedMs: candidate.modifiedMs,
            recordedAt: candidate.recordedAt,
            error: null,
            clearError: true,
            updatedAt: now,
          ),
        );
      }
    }
    for (final record in phoneStore.records) {
      if (seen.contains(record.localPath)) continue;
      if (record.verified || record.phase == MacArchivePhase.failed) continue;
      if (File(record.localPath).existsSync()) continue;
      changes.add(
        record.copyWith(
          phase: MacArchivePhase.failed,
          error: '原件已删除，无法归档',
          updatedAt: now,
        ),
      );
    }
    if (changes.isNotEmpty) {
      await phoneStore.upsertAll(changes);
      _notify();
    }
  }

  bool _shouldAutoQueue(ArchiveCandidate candidate) {
    if (!phoneStore.autoArchive) return false;
    final from = phoneStore.autoArchiveFrom;
    if (from == null) return true;
    return candidate.modifiedMs >= from.millisecondsSinceEpoch;
  }

  ArchivePhoneRecord _newRecord(ArchiveCandidate candidate, DateTime now) =>
      ArchivePhoneRecord(
        localPath: candidate.path,
        displayName: candidate.displayName,
        originalExtension: candidate.extension,
        deskId: phoneStore.pairing?.deskId,
        length: candidate.length,
        sourceModifiedMs: candidate.modifiedMs,
        recordedAt: candidate.recordedAt,
        updatedAt: now,
      );

  ArchivePhoneRecord? _nextProcessable() {
    if (_manualPaused) return null;
    final now = _clock();
    final records =
        phoneStore.records
            .where((record) => record.phase == MacArchivePhase.pending)
            .toList()
          ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    for (final record in records) {
      if (record.deskId != phoneStore.pairing?.deskId) continue;
      if (_inFlightPath == record.localPath) continue;
      final automatic =
          phoneStore.autoArchive && !_manualPaused && _autoEligible(record);
      if (!record.manual && !automatic) continue;
      final due = _nextAttempt[record.localPath];
      if (due != null && due.isAfter(now)) continue;
      return record;
    }
    return null;
  }

  bool _autoEligible(ArchivePhoneRecord record) {
    final from = phoneStore.autoArchiveFrom;
    if (from == null) return true;
    return record.sourceModifiedMs >= from.millisecondsSinceEpoch;
  }

  Future<void> _process(ArchivePhoneRecord initial) async {
    final path = initial.localPath;
    _inFlightPath = path;
    String? attemptedHash;
    try {
      final candidate = await source.archiveCandidate(path);
      if (candidate == null) {
        await _markFailed(initial, '原件已删除，无法归档');
        return;
      }
      String? hash;
      try {
        hash = await archiveFileHash(path);
      } on ArchiveSourceChangedException {
        await _markChanged(initial, hash: attemptedHash);
        return;
      }
      if (hash == null) {
        await _markFailed(initial, '原件无法读取，请稍后重试');
        return;
      }
      attemptedHash = hash;
      final file = File(path);
      final stat = await file.stat();
      var current = phoneStore.recordForPath(path);
      if (current == null) return;
      current = current.copyWith(
        contentHash: hash,
        length: stat.size,
        sourceModifiedMs: stat.modified.millisecondsSinceEpoch,
        displayName: candidate.displayName,
        originalExtension: candidate.extension,
        recordedAt: candidate.recordedAt,
        phase: MacArchivePhase.verifying,
        error: null,
        clearError: true,
        attempts: current.attempts + 1,
        updatedAt: _clock(),
      );
      await phoneStore.upsert(current);
      _notify();
      if (_manualPaused) {
        await _markPending(current, '等待连接');
        return;
      }
      final targetDeskId = phoneStore.pairing?.deskId;
      if (targetDeskId == null || current.deskId != targetDeskId) return;
      final client = await _ensureWorkerClient(expectedDeskId: targetDeskId);
      var latest = phoneStore.recordForPath(path);
      if (latest == null ||
          latest.contentHash != hash ||
          latest.deskId != targetDeskId ||
          phoneStore.pairing?.deskId != targetDeskId) {
        return;
      }
      latest = latest.copyWith(
        phase: MacArchivePhase.uploading,
        error: null,
        clearError: true,
        updatedAt: _clock(),
      );
      await phoneStore.upsert(latest);
      _notify();
      final result = await client.uploadFile(
        path: path,
        contentHash: hash,
        length: stat.size,
        extension: candidate.extension,
        displayName: candidate.displayName,
        clientId: phoneStore.clientId,
        recordedAt: candidate.recordedAt,
        onProgress: (sent, total) {
          if (total <= 0) return;
          _transferProgress[path] = sent / total;
          _notify();
        },
        onSentAll: () async {
          final record = phoneStore.recordForPath(path);
          if (record == null || record.contentHash != hash) return;
          await phoneStore.upsert(
            record.copyWith(
              phase: MacArchivePhase.verifying,
              updatedAt: _clock(),
            ),
          );
          _notify();
        },
      );
      final settled = phoneStore.recordForPath(path);
      if (settled == null ||
          settled.contentHash != hash ||
          settled.deskId != targetDeskId ||
          phoneStore.pairing?.deskId != targetDeskId) {
        // A newer version, a target change or a local deletion superseded this
        // transfer; the old completion must never overwrite the newer state.
        return;
      }
      final receipts = _receiptsWith(settled);
      receipts[targetDeskId] = ArchiveDeskReceipt(
        contentHash: hash,
        length: result.length,
        extension: candidate.extension,
        verifiedAt: result.verifiedAt,
        sourceLength: settled.length,
        sourceModifiedMs: settled.sourceModifiedMs,
      );
      await phoneStore.upsert(
        settled.copyWith(
          phase: MacArchivePhase.verified,
          verifiedAt: result.verifiedAt,
          verifiedLength: result.length,
          receipts: receipts,
          error: null,
          clearError: true,
          manual: false,
          updatedAt: _clock(),
        ),
      );
      _nextAttempt.remove(path);
      _transferProgress.remove(path);
      _notify();
    } on ArchiveAuthException catch (error) {
      _authFailed = true;
      _linkPhase = ArchiveLinkPhase.failed;
      _phoneError = error.message;
      await _closeWorkerClient();
      await _markFailed(initial, error.message, hash: attemptedHash);
    } on ArchiveRemoteException catch (error) {
      await _closeWorkerClient();
      await _markFailed(initial, error.message, hash: attemptedHash);
    } on ArchiveSourceChangedException {
      await _closeWorkerClient();
      await _markChanged(initial, hash: attemptedHash);
    } on ArchiveException catch (error) {
      await _closeWorkerClient();
      _linkPhase = ArchiveLinkPhase.waiting;
      _phoneError = error.message;
      final current = phoneStore.recordForPath(path);
      if (current != null &&
          (current.contentHash == null ||
              current.contentHash == initial.contentHash ||
              initial.contentHash == null)) {
        await _markPending(current, '等待 Mac 连接，稍后自动重试');
        _nextAttempt[path] = _clock().add(
          Duration(seconds: 5 * (current.attempts.clamp(1, 6))),
        );
      }
      _notify();
    } catch (error) {
      debugPrint('[MacArchive] transfer failed: $error');
      await _closeWorkerClient();
      await _markFailed(initial, '归档失败，请重试', hash: attemptedHash);
    } finally {
      _inFlightPath = null;
      _transferProgress.remove(path);
      _explicitPaths.remove(path);
      _notify();
    }
  }

  Future<void> _markFailed(
    ArchivePhoneRecord expected,
    String message, {
    String? hash,
  }) async {
    final current = phoneStore.recordForPath(expected.localPath);
    if (current == null) return;
    final expectedHash = hash ?? expected.contentHash;
    if (expectedHash != null &&
        current.contentHash != null &&
        current.contentHash != expectedHash) {
      return;
    }
    await phoneStore.upsert(
      current.copyWith(
        phase: MacArchivePhase.failed,
        error: message,
        updatedAt: _clock(),
      ),
    );
    _notify();
  }

  Future<void> _markPending(
    ArchivePhoneRecord expected,
    String message, {
    String? hash,
  }) async {
    final current = phoneStore.recordForPath(expected.localPath);
    if (current == null) return;
    final expectedHash = hash ?? expected.contentHash;
    if (expectedHash != null &&
        current.contentHash != null &&
        current.contentHash != expectedHash) {
      return;
    }
    await phoneStore.upsert(
      current.copyWith(
        phase: MacArchivePhase.pending,
        error: message,
        updatedAt: _clock(),
      ),
    );
    _notify();
  }

  Future<void> _markChanged(ArchivePhoneRecord expected, {String? hash}) async {
    final current = phoneStore.recordForPath(expected.localPath);
    if (current == null) return;
    final expectedHash = hash ?? expected.contentHash;
    if (expectedHash != null &&
        current.contentHash != null &&
        current.contentHash != expectedHash) {
      return;
    }
    await phoneStore.upsert(
      current.copyWith(
        phase: MacArchivePhase.pending,
        clearContentHash: true,
        clearVerified: true,
        error: '原件已变化，等待重新校验',
        clearError: false,
        updatedAt: _clock(),
      ),
    );
    _notify();
  }

  void _requireActive() {
    if (_disposed) throw const ArchiveException('归档服务已关闭');
  }

  void _requirePhoneStorage() {
    if (phoneStore.storageUnavailable) {
      throw ArchiveException(phoneStore.loadError ?? '无法访问应用私有归档目录');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String _formatDateTime(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _connectionEpoch++;
    unawaited(_closeWorkerClient());
    unawaited(_closeInteractiveClient());
    final server = _server;
    if (server != null) unawaited(server.stop());
    super.dispose();
  }
}
