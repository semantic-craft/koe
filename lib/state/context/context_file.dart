import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../util/off_ui.dart';
import '../atomic_file.dart';

/// One JSON document under the app's `AnkerRecorder` folder. Every local
/// store goes through this: it finds the file, reads it, sets an unreadable
/// copy aside, and replaces it atomically through [writeFileAtomically].
/// Writes share one queue so a later snapshot never lands before an earlier
/// one.
///
/// Unreadable files are always kept the same way: renamed (or copied, when
/// the readable part stays in use) to `<name>.corrupt-<ms>` before anything
/// can overwrite them. What to tell the user, and whether to keep saving when
/// that fails, stays with each store.
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

  /// The file this document lives in; the `AnkerRecorder` folder is created
  /// on first use.
  Future<File> target() async {
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

  /// The raw text, or null when nothing was saved yet.
  Future<String?> readText() async {
    if (inMemory) return null;
    final target = await this.target();
    if (!await target.exists()) return null;
    final text = await target.readAsString();
    _lastLength = text.length;
    return text;
  }

  /// The stored object, or null when nothing was saved yet. Throws
  /// [FormatException] after preserving an unreadable file.
  Future<Map<String, Object?>?> read() async {
    final String? text;
    try {
      text = await readText();
    } catch (_) {
      await _setAsideQuietly();
      throw const FormatException('unreadable');
    }
    if (text == null) return null;
    try {
      final value = jsonDecode(text);
      if (value is Map<String, Object?>) return value;
    } catch (_) {}
    await _setAsideQuietly();
    throw const FormatException('unreadable');
  }

  /// Keeps the current file as `<name>.corrupt-<ms>` so no later save can
  /// erase it. With [keepOriginal] the file is copied and stays in place.
  /// Throws when the copy could not be made; nothing is written then.
  Future<void> setAside({bool keepOriginal = false, DateTime? at}) async {
    if (inMemory) return;
    final target = await this.target();
    if (!await target.exists()) return;
    final stamp = (at ?? DateTime.now()).millisecondsSinceEpoch;
    final aside = '${target.path}.corrupt-$stamp';
    if (keepOriginal) {
      await target.copy(aside);
    } else {
      await target.rename(aside);
    }
  }

  Future<void> _setAsideQuietly() async {
    try {
      await setAside();
    } catch (error) {
      debugPrint('[ContextFile] could not keep unreadable $fileName: $error');
    }
  }

  /// Completes once every write queued so far has finished.
  Future<void> get idle => _pending;

  /// Runs [work] after every earlier queued write or [serialize] call.
  /// Stores that must write before they change memory run both steps here.
  Future<T> serialize<T>(Future<T> Function() work) {
    final operation = _pending.then((_) => work());
    _pending = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  /// Replaces the file with [contents] now, outside the queue; call it from
  /// inside [serialize].
  Future<void> replace(String contents) async {
    if (inMemory) return;
    final target = await this.target();
    await target.parent.create(recursive: true);
    await writeFileAtomically(target, contents);
    _lastLength = contents.length;
  }

  /// Queues [contents] as the next version of the file.
  Future<void> writeText(String contents) =>
      serialize(() => replace(contents));

  /// Queues [json] as the next version of the file. Large documents are
  /// encoded off the UI isolate.
  Future<void> write(Map<String, Object?> json) {
    if (inMemory) return Future<void>.value();
    // Started now so the snapshot is taken before callers change [json].
    final snapshot = runOffUi(
      () => jsonEncode(json),
      size: _lastLength,
      threshold: backgroundEncodeThreshold,
      debugName: 'ContextFile.encode',
    );
    // An encode error reaches the caller through the queued write; this keeps
    // it from counting as uncaught while an earlier write is still running.
    unawaited(snapshot.then((_) {}, onError: (Object _) {}));
    return serialize(() async => replace(await snapshot));
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
