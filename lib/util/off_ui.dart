import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

/// Times background work fell back to the current isolate (its work could
/// not cross isolates, or a native library was unavailable there). Tests
/// assert it stays at zero, so work does not silently move back onto the UI
/// thread.
int offUiFallbacks = 0;

/// Runs [work] on a background isolate when its input is large, and on the
/// current isolate when it is small.
///
/// The UI isolate builds and paints every frame. Work that grows with the
/// user's history (long recordings, transcript files, the ask index) must not
/// run there. Spawning an isolate costs a few milliseconds, so inputs below
/// [threshold] stay inline. [size] is the input size in the unit [threshold]
/// uses (bytes, characters, items).
///
/// [work] runs in a fresh isolate: it must not touch plugins, platform
/// channels or state set up on the UI isolate, and it may run twice (once in
/// the background, once inline) when a captured value cannot be sent. An
/// [ArgumentError] thrown by [work] itself is retried once inline, which
/// rethrows it.
///
/// Adapted from omi `app/lib/utils/off_ui_isolate.dart` (MIT).
Future<R> runOffUi<R>(
  FutureOr<R> Function() work, {
  required int size,
  required int threshold,
  String debugName = 'runOffUi',
}) async {
  if (kIsWeb || size < threshold) return await work();
  try {
    return await Isolate.run(work, debugName: debugName);
  } on ArgumentError catch (e) {
    offUiFallbacks++;
    debugPrint('[OffUi] $debugName ran inline: $e');
    return await work();
  }
}
