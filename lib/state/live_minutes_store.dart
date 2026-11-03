import 'dart:convert';
import 'dart:io';
import 'context/context_file.dart';

/// A single local journal for live minutes and captions. Credentials never enter it.
class LiveMinutesStore {
  LiveMinutesStore({File? file, bool inMemory = false})
    : _doc = ContextFile('live_meetings.json', file: file, inMemory: inMemory);
  final ContextFile _doc;
  final _forgotten = <String>{};
  Future<void> forget(String id) {
    _forgotten.add(id);
    return _doc.serialize(() async {
      await _load();
      final next = {..._sessions!}..remove(id);
      await _doc.replace(jsonEncode({'version': 1, 'sessions': next}));
      _sessions = next;
    });
  }

  Map<String, dynamic>? _sessions;
  Future<void> _load() async {
    if (_sessions != null) return;
    final raw = await _doc.read();
    if (raw != null && raw['version'] != 1) {
      throw const FormatException('不支持的实时资料版本');
    }
    _sessions = Map<String, dynamic>.from(raw?['sessions'] as Map? ?? {});
  }

  Future<Map<String, dynamic>?> read(String id) => _doc.serialize(() async {
    await _load();
    final value = _sessions![id];
    return value == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
  });
  Future<List<Map<String, dynamic>>> all() => _doc.serialize(() async {
    await _load();
    return [
      for (final v in _sessions!.values)
        Map<String, dynamic>.from(jsonDecode(jsonEncode(v)) as Map),
    ];
  });
  Future<void> _commits = Future.value();

  /// Capture after prior publication, and publish only after durable storage.
  Future<void> commit(
    String id,
    Map<String, dynamic> Function() snapshot, {
    void Function()? accepted,
  }) {
    final next = _commits.then((_) async {
      await write(id, snapshot());
      accepted?.call();
    });
    _commits = next.catchError((Object _) {});
    return next;
  }

  Future<void> write(String id, Map<String, dynamic> snapshot) {
    final copy = jsonDecode(jsonEncode(snapshot));
    return _doc.serialize(() async {
      await _load();
      if (_forgotten.contains(id)) return;
      final next = {..._sessions!, id: copy};
      await _doc.replace(jsonEncode({'version': 1, 'sessions': next}));
      _sessions = next;
    });
  }
}
