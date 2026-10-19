import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/recorder_controller.dart';
import 'recording_navigation.dart';

/// Opens the original recording at the sentence a source points to and
/// plays from there. Opening a source never changes the thing citing it.
Future<void> openContextSource(
  BuildContext context,
  ContextSource source,
) async {
  final c = context.read<RecorderController>();
  final ref = c.referenceForSource(source);
  final path = ref == null ? null : c.recordingView(ref).path;
  if (ref == null || path == null || !c.exportedPaths.contains(path)) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('原录音已不在资料里（可能在回收站）')));
    return;
  }
  final segments = c.transcriptSegmentsForPath(path);
  final index = segments.indexWhere((s) => s.start == source.start);
  RecordingNavigation.open(
    context,
    ref,
    initialParagraph: index < 0 ? null : index,
  );
  try {
    await c.playFrom(path, source.start, fileId: ref.fileId);
  } catch (_) {
    // The reader still opens at the sentence; playback errors show there.
  }
}

String _two(int value) => value.toString().padLeft(2, '0');

/// `10月20日 15:00`, `10月20日`, or 时间未定 when the words gave no date.
String todoDueLabel(Todo todo) {
  final due = todo.due?.toLocal();
  if (due == null) return '时间未定';
  final day = '${due.month}月${due.day}日';
  return todo.dueHasTime ? '$day ${_two(due.hour)}:${_two(due.minute)}' : day;
}

String offsetLabel(Duration offset) {
  final minutes = offset.inMinutes;
  final seconds = offset.inSeconds % 60;
  return '${_two(minutes)}:${_two(seconds)}';
}
