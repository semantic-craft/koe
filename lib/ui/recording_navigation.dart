import 'package:flutter/material.dart';

import '../state/recording.dart';
import 'screens/recording_detail_screen.dart';

/// The shell owns navigation so recording shortcuts and row taps share a route.
class RecordingNavigation extends InheritedWidget {
  const RecordingNavigation({
    super.key,
    required this.onOpen,
    this.tabIndex = 0,
    this.wide = false,
    this.selected,
    required super.child,
  });

  final ValueChanged<RecordingReference> onOpen;
  final int tabIndex;
  final bool wide;
  final RecordingReference? selected;

  static RecordingNavigation? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RecordingNavigation>();

  static bool isSelected(BuildContext context, RecordingReference reference) {
    final selected = of(context)?.selected;
    return selected != null &&
        (selected.key == reference.key ||
            selected.fileId != null && selected.fileId == reference.fileId ||
            selected.path != null && selected.path == reference.path);
  }

  static void open(BuildContext context, RecordingReference reference) {
    final navigation = context
        .dependOnInheritedWidgetOfExactType<RecordingNavigation>();
    if (navigation != null) {
      navigation.onOpen(reference);
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RecordingDetailScreen(reference: reference),
        ),
      );
    }
  }

  @override
  bool updateShouldNotify(RecordingNavigation oldWidget) =>
      onOpen != oldWidget.onOpen ||
      tabIndex != oldWidget.tabIndex ||
      wide != oldWidget.wide ||
      selected != oldWidget.selected;
}
