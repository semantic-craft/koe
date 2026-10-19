import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../util/off_ui.dart';

/// One JSON document under the app's `AnkerRecorder` folder, written the way
/// the other local stores write theirs: serialised snapshot, `.tmp` file,
/// rename. Writes are queued so a later snapshot never lands before an
/// earlier one.
///
/// A file that exists but cannot be decoded is renamed to `.corrupt-<ms>` on
/// load so the next save never overwrites what the user may still want back.
class ContextFile {
  ContextFile(this.fileName, {this.file, this.inMemory = false});

  final String fileName;
  final File? file;
  final bool inMemory;
  Future<void> _pending = Future<void>.value();

  /// Length of the last document read or written; once it reaches
  /// [backgroundEncodeThreshold] the next snapshot is encoded off the UI
  /// isolate.
  int _lastLength = 0;

  static const backgroundEncodeThreshold = 256 * 1024;

  Future<File> _target() async {
    if (file != null) return file!;
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    final dir = Directory(p.join(base.path, 'AnkerRecorder'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, fileName));
  }

  /// The stored object, or null when nothing was saved yet. Throws
  /// [FormatException] after preserving an unreadable file.
  Future<Map<String, Object?>?> read() async {
    if (inMemory) return null;
    final target = await _target();
    if (!await target.exists()) return null;
    try {
      final text = await target.readAsString();
      _lastLength = text.length;
      final value = jsonDecode(text);
      if (value is Map<String, Object?>) return value;
    } catch (_) {}
    try {
      await target.rename(
        '${target.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}',
      );
    } catch (error) {
      debugPrint('[ContextFile] could not keep unreadable $fileName: $error');
    }
    throw const FormatException('unreadable');
  }

  /// Completes once every write queued so far has finished.
  Future<void> get idle => _pending;

  Future<void> write(Map<String, Object?> json) {
    if (inMemory) return Future<void>.value();
    // Started now so the snapshot is taken before callers change [json].
    final snapshot = runOffUi(
      () => jsonEncode(json),
      size: _lastLength,
      threshold: backgroundEncodeThreshold,
      debugName: 'ContextFile.encode',
    );
    // An encode error reaches the caller through [operation]; this keeps it
    // from counting as uncaught while an earlier write is still running.
    unawaited(snapshot.then((_) {}, onError: (Object _) {}));
    final operation = _pending.then((_) async {
      final contents = await snapshot;
      _lastLength = contents.length;
      final target = await _target();
      await target.parent.create(recursive: true);
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsString(contents, flush: true);
      await temporary.rename(target.path);
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }
}

DateTime? decodeTime(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

List<String> decodeIds(Object? value) => value is List
    ? [
        for (final item in value)
          if (item is String && item.isNotEmpty) item,
      ]
    : const [];
