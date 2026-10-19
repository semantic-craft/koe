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
  abstract final QwenSttService _qwenStt;
  List<TranscriptSegment> quotableSegmentsForPath(String path);
  String? transcriptForPath(String path);
  // END DEPS

  late final ContextStore contextItems;

  /// Test seam: one fake answers every personal-context prompt.
  late final AnalysisService? _contextServiceOverride;
  final Map<String, AnalysisService> _contextServices = {};

  /// The existing Qwen chat path, with the system prompt of one feature.
  /// Used by other parts through their abstract declarations.
  // ignore: unused_element
  AnalysisService _contextService(String systemPrompt) =>
      _contextServiceOverride ??
      _contextServices.putIfAbsent(
        systemPrompt,
        () => QwenAnalysisService(
          origin: () => _qwenStt.baseUrl,
          systemPrompt: systemPrompt,
          instructionLabel: '要求',
          sourceLabel: '资料',
        ),
      );

  void _disposeContextServices() {
    for (final service in _contextServices.values) {
      service.dispose();
    }
  }

  static String contextIdForRecording(String recordingKey) =>
      'recording:$recordingKey';

  /// The day's context items in time order; unknown-time items come last.
  List<ContextItem> contextItemsForDay(DateTime day) {
    _syncContextItems();
    return contextItems.itemsForDay(day);
  }

  /// Every context item, in time order.
  List<ContextItem> allContextItems() {
    _syncContextItems();
    return contextItems.allItems;
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
    return source == null ? null : referenceForSource(source);
  }

  /// The recording a source points at, resolved to its current path (the
  /// stored path is only a hint and may predate a rename).
  RecordingReference? referenceForSource(ContextSource source) {
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

  /// Numbered transcript sentences of [items] for a model prompt, at most
  /// about [maxChars] characters in all, shared fairly between items.
  /// Items without text contribute nothing; callers report them separately.
  List<SourceLine> contextSourceLines(
    List<ContextItem> items, {
    int maxChars = 12000,
  }) {
    final withText = [
      for (final item in items)
        if (_itemText(item).isNotEmpty) item,
    ];
    if (withText.isEmpty) return const [];
    final share = (maxChars ~/ withText.length).clamp(400, maxChars);
    final lines = <SourceLine>[];
    for (final item in withText) {
      final ref = contextReference(item)!;
      final path = ref.path!;
      final key = item.source!.recordingKey;
      final segments = quotableSegmentsForPath(path);
      var used = 0;
      for (final segment in segments) {
        if (used >= share) break;
        final text = segment.text.length > share - used
            ? '${segment.text.substring(0, share - used)}…'
            : segment.text;
        used += text.length;
        lines.add(
          SourceLine(
            label: 'S${lines.length + 1}',
            title: item.title,
            text: text,
            at: item.start?.add(segment.start),
            source: ContextSource(
              recordingKey: key,
              path: path,
              start: segment.start,
              end: segment.end,
            ),
          ),
        );
      }
    }
    return lines;
  }

  /// Whether an item has transcript text Koe can read.
  bool contextItemHasText(ContextItem item) => _itemText(item).isNotEmpty;

  String _itemText(ContextItem item) {
    final path = contextReference(item)?.path;
    if (path == null) return '';
    return transcriptForPath(path)?.trim() ?? '';
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
