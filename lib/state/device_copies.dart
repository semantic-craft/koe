import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ble/ble_file_pull.dart';
import '../protocol/models.dart';
import 'atomic_file.dart';

/// What the local copy of one device file amounts to (see GLOSSARY 副本状态).
enum DeviceCopyStatus {
  /// No local copy, and nothing stops a retrieval.
  none,

  /// The local copy holds everything the device file has.
  downloaded,

  /// The recorder is still recording or paused on this file; a BLE pull
  /// cannot succeed until it is ended on the recorder (#253).
  unfinished,

  /// The local copy is in the trash (or was deleted from it); it is not
  /// retrieved again automatically.
  dismissed,

  /// The latest retrieval was kept without every byte, or the live copy has
  /// a gap from a dropped link (#231). Retrieved again in full.
  partial,

  /// The device file grew after the local copy was taken: pause/resume
  /// appends to the same file (#92). Retrieved again.
  outgrown,
}

/// What [DeviceCopies] reads from the rest of the app.
abstract interface class DeviceCopyContext {
  String? localPathFor(int fileId);

  /// Whether the local copy of [fileId] is in the trash or was deleted there.
  bool isDismissed(int fileId);

  /// Recorder status as last reported: 0 stopped, 1 recording, 2 paused.
  int get recorderStatus;

  /// Device file id of the take the recorder is on, when known.
  int? get currentRecordingFileId;

  /// Whether the audio is still being recorded or finalized locally.
  bool isAudioLocked(int? fileId, String? path);
}

/// The one place that decides whether a recorder file's local copy is
/// complete, stale or retrievable, and whether downstream work (speech,
/// organize, archive) may use it.
///
/// Partial ids and retrieved sizes are saved under `AnkerRecorder/` as
/// `incomplete_retrievals.json` (sorted id list) and `retrieved_sizes.json`
/// (`{"<id>": bytes}`), so they survive a restart. An unreadable file only
/// loses a re-pull hint, never billed work, so loading never fails.
class DeviceCopies {
  DeviceCopies({this.directory, this.inMemory = false});

  final Directory? directory;
  final bool inMemory;
  late DeviceCopyContext _context;

  final Set<int> _partial = {};
  final Map<int, int> _retrievedSizes = {};
  final Set<int> _unfinished = {};
  final Set<int> _retrieving = {};
  final Map<String, String> _completenessFailures = {};
  Future<void>? _loading;
  Future<void> _writing = Future.value();

  /// Must be called once before any query.
  void bind(DeviceCopyContext context) => _context = context;

  Future<Directory> _dir() async =>
      directory ??
      Directory(
        p.join(
          (await getApplicationDocumentsDirectory()).path,
          'AnkerRecorder',
        ),
      );

  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    if (inMemory) return;
    final dir = await _dir();
    try {
      final file = File(p.join(dir.path, 'incomplete_retrievals.json'));
      if (await file.exists()) {
        _partial.addAll(
          (jsonDecode(await file.readAsString()) as List).whereType<int>(),
        );
      }
    } catch (_) {}
    try {
      final file = File(p.join(dir.path, 'retrieved_sizes.json'));
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final id = int.tryParse('${entry.key}');
            final size = entry.value;
            if (id != null && size is int) _retrievedSizes[id] = size;
          }
        }
      }
    } catch (_) {}
  }

  DeviceCopyStatus statusOf(OfflineFileEntry file) {
    final id = file.fileId;
    final hasLocal = _context.localPathFor(id) != null;
    final retrievedAt = _retrievedSizes[id];
    final partial = _partial.contains(id);
    final outgrown = retrievedAt != null && file.sizeBytes > retrievedAt;
    if (hasLocal && !partial && !outgrown) return DeviceCopyStatus.downloaded;
    if (_isUnfinished(file)) return DeviceCopyStatus.unfinished;
    if (!hasLocal && _context.isDismissed(id)) {
      return DeviceCopyStatus.dismissed;
    }
    if (hasLocal && partial) return DeviceCopyStatus.partial;
    if (hasLocal && outgrown) return DeviceCopyStatus.outgrown;
    return DeviceCopyStatus.none;
  }

  bool _isUnfinished(OfflineFileEntry file) {
    if (file.sizeBytes == BleFilePull.unfinishedFileSize) return true;
    if (_context.recorderStatus == 0) return false;
    return _unfinished.contains(file.fileId) ||
        _context.currentRecordingFileId == file.fileId;
  }

  /// Whether the latest retrieval of [fileId] is known to be incomplete.
  bool isPartial(int? fileId) => fileId != null && _partial.contains(fileId);

  /// Whether speech, organize or archive may use the local audio now: not
  /// being recorded or retrieved, not partial, and not stopped by the
  /// completeness check of its last retrieval ([recordingKey]).
  bool usableForProcessing({int? fileId, String? path, String? recordingKey}) {
    if (_context.isAudioLocked(fileId, path)) return false;
    if (fileId != null &&
        (_partial.contains(fileId) || _retrieving.contains(fileId))) {
      return false;
    }
    return recordingKey == null ||
        !_completenessFailures.containsKey(recordingKey);
  }

  /// Runs a device transfer of [fileId] (pull plus completion). While it
  /// runs, the copy is not [usableForProcessing]: until [recordRetrieval]
  /// the raw file on disk may be partial without being marked yet.
  Future<T> retrieving<T>(int fileId, Future<T> Function() transfer) async {
    _retrieving.add(fileId);
    try {
      return await transfer();
    } finally {
      _retrieving.remove(fileId);
    }
  }

  /// Records the outcome of a retrieval. A complete one with [listedBytes]
  /// becomes the baseline [statusOf] compares later listings to.
  Future<void> recordRetrieval(
    int fileId, {
    required bool complete,
    int? listedBytes,
  }) async {
    await load();
    if (complete && listedBytes != null && _hasSize(listedBytes)) {
      await _setRetrievedSize(fileId, listedBytes);
    } else if (!complete) {
      await _setRetrievedSize(fileId, null);
    }
    final changed = complete ? _partial.remove(fileId) : _partial.add(fileId);
    if (changed) await _savePartial();
  }

  /// The link dropped during a live take: audio captured meanwhile exists
  /// only on the recorder, so the live copy is [DeviceCopyStatus.partial].
  Future<void> markInterrupted(int fileId) =>
      recordRetrieval(fileId, complete: false);

  /// The recorder answered a pull of [fileId] with an unknown size.
  void noteUnfinished(int fileId) => _unfinished.add(fileId);

  /// The recorder closed its file: unfinished ones can be pulled now.
  void recorderStopped() => _unfinished.clear();

  /// Gives copies retrieved before sizes were recorded a baseline, once:
  /// a decoded WAV of at least 95% of the listed size counts as complete,
  /// a smaller one as partial. Returns whether any status changed.
  Future<bool> reconcile(Iterable<OfflineFileEntry> files) async {
    await load();
    var changed = false;
    for (final file in files) {
      final id = file.fileId;
      if (!_hasSize(file.sizeBytes)) continue;
      if (_retrievedSizes.containsKey(id) || _partial.contains(id)) continue;
      final path = _context.localPathFor(id);
      if (path == null) continue;
      try {
        final local = File(path);
        if (!await local.exists()) continue;
        final size = await local.length();
        if (size >= (file.sizeBytes * 0.95).floor()) {
          await _setRetrievedSize(id, file.sizeBytes);
        } else {
          await recordRetrieval(id, complete: false);
          changed = true;
        }
      } catch (_) {}
    }
    return changed;
  }

  /// The retrieval check found the audio under [recordingKey] cut short or
  /// still growing.
  void blockForCompleteness(String recordingKey, String reason) =>
      _completenessFailures[recordingKey] = reason;

  /// Clears a completeness failure; returns the reason it carried.
  String? clearCompleteness(String recordingKey) =>
      _completenessFailures.remove(recordingKey);

  static bool _hasSize(int bytes) =>
      bytes > 0 && bytes != BleFilePull.unfinishedFileSize;

  Future<void> _setRetrievedSize(int fileId, int? bytes) {
    if (_retrievedSizes[fileId] == bytes) return Future.value();
    if (bytes == null) {
      _retrievedSizes.remove(fileId);
    } else {
      _retrievedSizes[fileId] = bytes;
    }
    return _save('retrieved_sizes.json', {
      for (final entry in _retrievedSizes.entries) '${entry.key}': entry.value,
    });
  }

  Future<void> _savePartial() =>
      _save('incomplete_retrievals.json', _partial.toList()..sort());

  Future<void> _save(String name, Object value) {
    if (inMemory) return Future.value();
    final snapshot = jsonEncode(value);
    final operation = _writing.then((_) async {
      final dir = await _dir();
      await dir.create(recursive: true);
      await writeFileAtomically(File(p.join(dir.path, name)), snapshot);
    });
    _writing = operation.catchError((Object _) {});
    return operation;
  }

  /// Completes once every save queued so far has finished.
  Future<void> flush() => _writing;
}
