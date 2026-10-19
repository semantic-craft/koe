import 'dart:io';

var _sequence = 0;

/// Replaces [target] with [contents] through a temporary file in the same
/// folder, so a reader never sees half a file.
///
/// Each write gets its own temporary name: two writers sharing `<name>.tmp`
/// (a relaunch opening a second journal, or overlapping store saves) could
/// rename the other's file away and fail with "Cannot rename file".
Future<void> writeFileAtomically(File target, String contents) async {
  final temporary = File('${target.path}.$pid-${_sequence++}.tmp');
  try {
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(target.path);
  } catch (_) {
    try {
      if (await temporary.exists()) await temporary.delete();
    } catch (_) {}
    rethrow;
  }
}
