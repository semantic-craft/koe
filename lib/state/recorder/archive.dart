part of '../recorder_controller.dart';

/// Mac archive wiring: the [MacArchiveController] the controller owns, the
/// archive-only view of the library, and the [ArchiveSource] adapter.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderArchive on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  abstract bool _disposed;
  bool _isTrashedPath(String path);
  // END DEPS

  late final MacArchiveController archive;
  late final bool _ownsArchive;

  void _onArchiveChanged() {
    if (!_disposed) notifyListeners();
  }

  /// Verified Mac copies whose phone original is no longer present. These rows
  /// remain visible so the user can explicitly restore and verify the original.
  List<String> get archiveOnlyPaths {
    final paths = <String>[];
    for (final record in archive.records) {
      final currentVerified = record.verified && record.hasVersion;
      final hasReceipt = record.receipts.isNotEmpty;
      if (!currentVerified && !hasReceipt) continue;
      if (File(record.localPath).existsSync()) continue;
      if (_isTrashedPath(record.localPath)) continue;
      paths.add(record.localPath);
    }
    return ExportCatalog.newestPathsFirst(paths);
  }
}

/// Adapts the existing recording library to the archive coordinator without
/// moving protocol or queue logic into [RecorderController].
class _RecorderArchiveSource implements ArchiveSource {
  _RecorderArchiveSource(this.controller);

  final RecorderController controller;

  @override
  Future<List<ArchiveCandidate>> archiveCandidates() async {
    await controller._libraryLoaded;
    final paths = <String>{...controller.exportedPaths};
    for (final asset in controller.library.assets) {
      if (asset.trashed || asset.permanentlyDeleted) continue;
      if (File(asset.path).existsSync()) paths.add(asset.path);
    }
    final candidates = <ArchiveCandidate>[];
    for (final path in paths) {
      final candidate = await archiveCandidate(path);
      if (candidate != null) candidates.add(candidate);
    }
    return candidates;
  }

  @override
  Future<ArchiveCandidate?> archiveCandidate(String path) async {
    final lower = path.toLowerCase();
    final extension = lower.endsWith('.opus.bin')
        ? '.opus.bin'
        : p.extension(lower);
    if (!archiveAllowedSourceExtensions.contains(extension)) return null;
    if (controller._isTrashedPath(path)) return null;
    final id = controller.fileIdFromPath(path);
    if (controller._isRecordingAudioLocked(id, path)) return null;
    final asset = controller.library.assetForPath(path);
    if (asset?.originalComplete == false) return null;
    if (id != null && controller._incompleteRetrievalIds.contains(id)) {
      return null;
    }
    if (controller._blePull.isIncomplete(path)) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) return null;
    final label = ExportCatalog.editableLabelFromPath(path).trim();
    final displayName = asset?.displayName.isNotEmpty == true
        ? asset!.displayName
        : label.isNotEmpty
        ? label
        : p.basenameWithoutExtension(path);
    return ArchiveCandidate(
      path: path,
      displayName: displayName.isEmpty ? '录音' : displayName,
      extension: extension,
      length: stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
      recordedAt: asset?.recordedAt ?? controller._recordedAtFromFileId(id),
    );
  }

  @override
  Future<String> archiveRestoreTarget(ArchivePhoneRecord record) async {
    // Restore in place whenever possible: transcripts, bookmarks and topics
    // are keyed by the original path and stay attached to the same material.
    if (record.localPath.isNotEmpty &&
        archiveIsAllowedSourceExtension(record.localPath)) {
      return record.localPath;
    }
    final directory = await controller._importDirectory();
    await directory.create(recursive: true);
    final extension =
        archiveAllowedSourceExtensions.contains(
          record.originalExtension.toLowerCase(),
        )
        ? record.originalExtension.toLowerCase()
        : '.wav';
    final hash = (record.contentHash ?? 'unknown').padRight(12, '0');
    return p.join(
      directory.path,
      '${DateTime.now().millisecondsSinceEpoch}_${hash.substring(0, 12)}_restored$extension',
    );
  }

  @override
  Future<bool> archiveDidRestore(
    ArchivePhoneRecord record,
    String path, {
    required int length,
    required String contentHash,
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) return false;
    final existing = controller.library.assetForPath(path);
    final asset = existing == null
        ? RecordingAsset(
            path: path,
            displayName: record.displayName,
            source: RecordingSource.localImport,
            recordedAt: record.recordedAt,
            importedAt: DateTime.now(),
            contentHash: contentHash,
          )
        : existing.copyWith(contentHash: contentHash, originalComplete: true);
    await controller.library.upsert(asset);
    if (!isCurrent()) {
      // Only remove the exact object this restore wrote; a later user write
      // (trash rename/new file) must win and is not rolled back from a stale
      // snapshot.
      final stored = controller.library.assetForPath(path);
      if (identical(stored, asset)) {
        try {
          if (existing != null) {
            // Restore the exact pre-restore metadata; a failed/renamed/cancelled
            // restore must not discard the user's original asset record.
            await controller.library.upsert(existing, strict: false);
          } else {
            await controller.library.remove(path, strict: false);
          }
        } catch (_) {}
      }
      return false;
    }
    controller._registerExportedPaths([...controller.exportedPaths, path]);
    controller._invalidateLocalDuration(path);
    controller.statusMessage = '已从 Mac 恢复并校验原件';
    controller.errorMessage = null;
    controller.notifyListeners();
    return true;
  }
}
