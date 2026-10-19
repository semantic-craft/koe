part of '../recorder_controller.dart';

/// Recording places: manual labels and the automatic place attached when a
/// phone recording is saved.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderPlace on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  abstract bool _disposed;
  abstract final Future<void> _libraryLoaded;
  DateTime? _localFileTimestamp(String? path);
  abstract final PlaceCapture _placeCapture;
  DateTime? _recordedAtFromFileId(int? id);
  int? fileIdFromPath(String path);
  // ignore: unused_element_parameter
  String _recordingTitleForPath(String path, {String? archiveName});
  abstract final RecordingLibraryStore library;
  // END DEPS

  /// Adds or corrects a place label from the user. A manual label always wins
  /// over a later automatic capture.
  Future<void> setRecordingPlace(String path, String label) async {
    await _libraryLoaded;
    final trimmed = label.trim();
    if (trimmed.isEmpty) throw ArgumentError('地点不能为空');
    final id = fileIdFromPath(path);
    final asset =
        library.assetForPath(path) ??
        RecordingAsset(
          path: path,
          displayName: _recordingTitleForPath(path),
          source: RecordingSource.device,
          recordedAt: _recordedAtFromFileId(id),
          importedAt: _localFileTimestamp(path) ?? DateTime.now(),
        );
    await library.upsert(
      asset.copyWith(
        place: RecordingPlace(
          label: trimmed,
          source: RecordingPlaceSource.manual,
          capturedAt: DateTime.now(),
        ),
      ),
    );
    notifyListeners();
  }

  /// Removes the place note without touching the original audio.
  Future<void> clearRecordingPlace(String path) async {
    await _libraryLoaded;
    final asset = library.assetForPath(path);
    if (asset == null) throw StateError('找不到这条资料');
    await library.upsert(asset.copyWith(clearPlace: true));
    notifyListeners();
  }

  /// Best-effort coarse place for a phone recording.
  ///
  /// Imported files and device recordings never receive the import/retrieval
  /// location: their recording place stays unknown. A denied permission or a
  /// capture failure simply leaves the place blank.
  Future<void> attachAutomaticPlace(String path) async {
    await _libraryLoaded;
    final asset = library.assetForPath(path);
    if (asset == null || asset.source != RecordingSource.phone) return;
    if (asset.place?.source == RecordingPlaceSource.manual) return;
    final captured = await _placeCapture.capture();
    if (captured == null || _disposed) return;
    final current = library.assetForPath(path);
    if (current == null ||
        current.place?.source == RecordingPlaceSource.manual) {
      return;
    }
    try {
      await library.upsert(current.copyWith(place: captured));
      notifyListeners();
    } catch (_) {
      // Location is optional; the recording remains saved and readable.
    }
  }
}
