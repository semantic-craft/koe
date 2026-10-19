part of '../recorder_controller.dart';

/// Personal context: one timeline item per recording, with its place and
/// topic links, plus the corrections the user makes to those links.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderContext on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  String _recordingKey({int? fileId, String? path});
  abstract List<String> exportedPaths;
  int? fileIdFromPath(String path);
  abstract final RecordingLibraryStore library;
  Duration? localDurationForPath(String path);
  abstract final Map<int, String> localPathsByFileId;
  RecordingViewData recordingView(RecordingReference ref);
  abstract final TopicStore topics;
  abstract final bool topicsEnabled;
  // END DEPS

  late final ContextStore contextItems;

  static String contextIdForRecording(String recordingKey) =>
      'recording:$recordingKey';

  /// The day's context items in time order; unknown-time items come last.
  List<ContextItem> contextItemsForDay(DateTime day) {
    _syncContextItems();
    return contextItems.itemsForDay(day);
  }

  /// Items the user linked to [projectId], across days, in time order.
  List<ContextItem> contextItemsForProject(String projectId) {
    _syncContextItems();
    return contextItems.itemsForProject(projectId);
  }

  /// Corrects which topics an item belongs to. The recording's own topic
  /// placement is left as it was, and no audio or text is copied.
  Future<void> setContextItemTopics(String itemId, List<String> topicIds) =>
      contextItems.setTopics(itemId, topicIds);

  /// The recording an item points at, resolved to its current path.
  RecordingReference? contextReference(ContextItem item) {
    final source = item.source;
    if (source == null) return null;
    final key = source.recordingKey;
    if (key.startsWith('file:')) {
      final id = int.tryParse(key.substring(5));
      if (id != null) {
        return RecordingReference(
          fileId: id,
          path: localPathsByFileId[id] ?? source.path,
        );
      }
    }
    final path =
        source.path ?? (key.startsWith('path:') ? key.substring(5) : null);
    if (path == null) return null;
    return RecordingReference(fileId: fileIdFromPath(path), path: path);
  }

  void _syncContextItems() {
    if (!contextItems.loaded) return;
    final now = DateTime.now();
    contextItems.sync([
      for (final path in exportedPaths) _recordingContextItem(path, now),
    ]);
  }

  ContextItem _recordingContextItem(String path, DateTime now) {
    final id = fileIdFromPath(path);
    final key = _recordingKey(fileId: id, path: path);
    final view = recordingView(RecordingReference(fileId: id, path: path));
    final duration = localDurationForPath(path);
    final start = view.recordedAt;
    final topicId = topicsEnabled ? topics.topicOf(key)?.id : null;
    return ContextItem(
      id: contextIdForRecording(key),
      kind: ContextKind.recording,
      title: view.title,
      start: start,
      end: start == null || duration == null ? null : start.add(duration),
      addedAt: view.importedAt ?? now,
      source: ContextSource(recordingKey: key, path: path, end: duration),
      location: library.assetForPath(path)?.place?.label,
      topicIds: [?topicId],
    );
  }
}
