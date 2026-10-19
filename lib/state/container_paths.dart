import 'dart:io';

import 'package:flutter/foundation.dart';

/// iOS gives an app a new data-container directory on reinstall and on some
/// updates. Stores that saved absolute paths (phone recordings, imports,
/// their transcripts and library entries) would then point at a container
/// that no longer exists. Rewrites the container id in those saved paths to
/// the current one before any store loads.
final RegExp _containerId = RegExp(
  r'(/var/mobile/Containers/Data/Application/)([0-9A-Fa-f-]{36})(?=/)',
);

/// The container id of [documentsPath], or null off iOS.
String? containerIdOf(String documentsPath) =>
    _containerId.firstMatch(documentsPath)?.group(2);

/// [raw] with every saved container id replaced by [currentId].
String relocateContainerPaths(String raw, String currentId) =>
    raw.replaceAllMapped(_containerId, (m) => '${m[1]}$currentId');

/// Rewrites the JSON stores directly under [dataDir] in place. Files are
/// replaced atomically and only when something changed.
Future<int> relocateStoredPaths(Directory dataDir, String documentsPath) async {
  final currentId = containerIdOf(documentsPath);
  if (currentId == null || !await dataDir.exists()) return 0;
  var changed = 0;
  await for (final entity in dataDir.list()) {
    if (entity is! File || !entity.path.endsWith('.json')) continue;
    try {
      final raw = await entity.readAsString();
      final next = relocateContainerPaths(raw, currentId);
      if (next == raw) continue;
      final temp = File('${entity.path}.relocate-part');
      await temp.writeAsString(next, flush: true);
      await temp.rename(entity.path);
      changed++;
    } catch (error) {
      debugPrint('[ContainerPaths] ${entity.path}: $error');
    }
  }
  return changed;
}
