import 'dart:io';

import 'package:flutter/foundation.dart';

import 'context_file.dart';
import 'source_pack.dart';

export 'source_pack.dart';

/// A day, or the Monday-to-Sunday week containing a day.
class DiaryPeriod {
  DiaryPeriod.day(DateTime day)
    : weekly = false,
      start = DateTime(day.year, day.month, day.day),
      end = DateTime(day.year, day.month, day.day + 1);

  DiaryPeriod.week(DateTime day)
    : weekly = true,
      start = DateTime(day.year, day.month, day.day - (day.weekday - 1)),
      end = DateTime(day.year, day.month, day.day - (day.weekday - 1) + 7);

  final bool weekly;
  final DateTime start;

  /// Exclusive.
  final DateTime end;

  /// One stored entry per day and per week: `day:2026-10-19`,
  /// `week:2026-10-19` (the Monday).
  String get key {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${weekly ? 'week' : 'day'}:'
        '${start.year}-${two(start.month)}-${two(start.day)}';
  }

  List<DateTime> get days => [
    for (
      var d = start;
      d.isBefore(end);
      d = DateTime(d.year, d.month, d.day + 1)
    )
      d,
  ];

  String get label {
    if (!weekly) return '${start.month}月${start.day}日';
    final last = end.subtract(const Duration(days: 1));
    return '${start.month}月${start.day}日–${last.month}月${last.day}日';
  }
}

/// One generated text with the sentences it may cite.
class DiaryDraft {
  const DiaryDraft({
    required this.text,
    required this.sources,
    required this.fingerprint,
    required this.generatedAt,
  });

  final String text;
  final List<SourceLine> sources;

  /// Hash of the material it was written from; the same material is never
  /// sent again.
  final String fingerprint;
  final DateTime generatedAt;

  Map<String, Object?> toJson() => {
    'text': text,
    'sources': [for (final line in sources) line.toJson()],
    'fingerprint': fingerprint,
    'generatedAt': generatedAt.toIso8601String(),
  };

  static DiaryDraft? decode(Object? value) {
    if (value is! Map) return null;
    final text = value['text'];
    final fingerprint = value['fingerprint'];
    final at = decodeTime(value['generatedAt']);
    if (text is! String || fingerprint is! String || at == null) return null;
    return DiaryDraft(
      text: text,
      sources: SourceLine.decodeAll(value['sources']),
      fingerprint: fingerprint,
      generatedAt: at,
    );
  }
}

/// The diary or weekly summary for one period.
///
/// [current] is the version shown. When the user edits it, [edited] is set
/// and later generations land in [newer] for comparison instead of
/// replacing the user's words.
class DiaryEntry {
  const DiaryEntry({
    required this.key,
    this.current,
    this.edited = false,
    this.newer,
    this.pendingFingerprint,
  });

  final String key;
  final DiaryDraft? current;
  final bool edited;
  final DiaryDraft? newer;

  /// A paid request for this material started but never reported back.
  final String? pendingFingerprint;

  DiaryEntry copyWith({
    DiaryDraft? current,
    bool? edited,
    DiaryDraft? newer,
    bool clearNewer = false,
    String? pendingFingerprint,
    bool clearPending = false,
  }) => DiaryEntry(
    key: key,
    current: current ?? this.current,
    edited: edited ?? this.edited,
    newer: clearNewer ? null : (newer ?? this.newer),
    pendingFingerprint: clearPending
        ? null
        : (pendingFingerprint ?? this.pendingFingerprint),
  );

  Map<String, Object?> toJson() => {
    'key': key,
    if (current != null) 'current': current!.toJson(),
    if (edited) 'edited': true,
    if (newer != null) 'newer': newer!.toJson(),
    if (pendingFingerprint != null) 'pendingFingerprint': pendingFingerprint,
  };

  static DiaryEntry? decode(Object? value) {
    if (value is! Map || value['key'] is! String) return null;
    final pending = value['pendingFingerprint'];
    return DiaryEntry(
      key: value['key'] as String,
      current: DiaryDraft.decode(value['current']),
      edited: value['edited'] == true,
      newer: DiaryDraft.decode(value['newer']),
      pendingFingerprint: pending is String ? pending : null,
    );
  }
}

/// Diaries and weekly summaries in `diary.json`, one entry per period key.
class DiaryStore extends ChangeNotifier {
  DiaryStore({File? file, bool inMemory = false})
    : _file = ContextFile(fileName, file: file, inMemory: inMemory);

  static const fileName = 'diary.json';

  final ContextFile _file;
  Map<String, DiaryEntry> _entries = {};
  Future<void>? _loading;
  bool _disposed = false;
  String? recoveryNotice;

  Future<void> get idle => _file.idle;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final json = await _file.read();
      for (final value in json?['entries'] as List? ?? const []) {
        final entry = DiaryEntry.decode(value);
        if (entry != null) _entries[entry.key] = entry;
      }
    } on FormatException {
      recoveryNotice = '日记记录无法读取，已另存旧文件';
    } catch (error) {
      recoveryNotice = '日记记录无法读取';
      debugPrint('[DiaryStore] load failed: $error');
    }
    notifyListeners();
  }

  DiaryEntry? entryFor(String key) => _entries[key];

  List<DiaryEntry> get entries => List.unmodifiable(_entries.values);

  Future<void> put(DiaryEntry entry) async {
    final previous = _entries;
    _entries = {...previous, entry.key: entry};
    try {
      await _file.write({
        'version': 1,
        'entries': [for (final item in _entries.values) item.toJson()],
      });
    } catch (error) {
      _entries = previous;
      debugPrint('[DiaryStore] save failed: $error');
      notifyListeners();
      throw StateError('日记保存失败，已保留原来的版本，请重试');
    }
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
