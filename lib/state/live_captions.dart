import 'dart:async';
import 'package:flutter/foundation.dart';
import 'live_segments.dart';
import 'live_minutes_store.dart';

class LiveCaptions extends ChangeNotifier {
  LiveCaptions({
    required this.sessionId,
    required this.store,
    required this.target,
    required this.translate,
    DateTime Function()? clock,
    bool Function()? configurationCurrent,
    this.recordingKey,
    this.onTranslated,
  }) : clock = clock ?? DateTime.now,
       configurationCurrent = configurationCurrent ?? (() => true);
  final String sessionId;
  final LiveMinutesStore store;
  final Future<String> Function(LiveSegment, String) translate;
  final DateTime Function() clock;
  final bool Function() configurationCurrent;
  final void Function(LiveSegment)? onTranslated;
  String target;
  String? recordingKey, error;
  final _entries = <String, LiveSegment>{};
  final _journal = <String, String>{};
  final _requests = <DateTime>[];
  bool paused = false,
      closed = false,
      closing = false,
      _busy = false,
      _disposed = false;
  int _generation = 0;
  final _started = Completer<void>();
  Future<void> get requestStarted => _started.future;
  List<LiveSegment> get entries => List.unmodifiable(_entries.values);
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  String _key(LiveSegment s) => '${s.id}/${s.revision}/$target';
  Map<String, dynamic> _snapshot() => {
    'id': sessionId,
    'kind': 'captions',
    'recordingKey': recordingKey,
    'target': target,
    'entries': [for (final e in entries) e.toJson()],
    'journal': _journal,
    'requests': [for (final t in _requests) t.toIso8601String()],
    'closed': closed,
    'error': error,
  };
  Future<void> persist() => store.commit('$sessionId/captions', _snapshot);
  Future<void> restore() async {
    final j = await store.read('$sessionId/captions');
    if (j == null) return;
    target = j['target'] as String;
    recordingKey = j['recordingKey'] as String?;
    for (final raw in j['entries'] as List) {
      final e = LiveSegment.fromJson(Map<String, dynamic>.from(raw as Map));
      _entries[e.id] = e;
    }
    _journal.addAll(Map<String, String>.from(j['journal'] as Map));
    _journal.updateAll((_, v) => v == 'pending' ? 'unknown' : v);
    closed = true;
    paused = true;
    error = _journal.containsValue('unknown')
        ? '上次翻译结果未知，未自动重发'
        : j['error'] as String?;
    _changed();
  }

  Future<void> update(List<LiveSegment> incoming) async {
    if (closed) return;
    var changed = false;
    var total = _entries.values.fold<int>(0, (n, e) => n + e.text.length);
    for (final s in incoming) {
      final old = _entries[s.id];
      if (old != null && old.revision > s.revision) continue;
      if (total - (old?.text.length ?? 0) + s.text.length > 2000000) {
        paused = true;
        error = '实时原文达到上限，请在会后处理';
        break;
      }
      total += s.text.length - (old?.text.length ?? 0);
      final supplied = s.targetLanguage == target && s.translation != null;
      if (!supplied &&
          old != null &&
          old.text == s.text &&
          old.revision == s.revision &&
          old.targetLanguage == target) {
        continue;
      }
      if (old != null &&
          old.text == s.text &&
          old.revision == s.revision &&
          old.targetLanguage == target &&
          old.translation == s.translation) {
        continue;
      }
      changed = true;
      final updated = LiveSegment(
        id: s.id,
        text: s.text,
        revision: s.revision,
        sourceLanguage: s.sourceLanguage,
        translation: supplied ? s.translation : null,
        targetLanguage: target,
        provider: s.provider,
      );
      _entries[s.id] = updated;
      if (supplied) onTranslated?.call(updated);
    }
    try {
      if (changed) await persist();
    } catch (_) {
      paused = true;
      error = '字幕未能保存，翻译已暂停';
      _changed();
      return;
    }
    _changed();
    await _drain();
  }

  Future<void> _drain() async {
    if (_busy || paused || closed || closing) return;
    final waiting = _entries.values
        .where((s) => s.translation == null && !_journal.containsKey(_key(s)))
        .toList();
    if (waiting.length > 100) {
      paused = true;
      error = '字幕翻译跟不上，已暂停；原文已保留';
      _changed();
      return;
    }
    _busy = true;
    try {
      for (final s in waiting) {
        if (paused || closed || closing) break;
        bool latest() =>
            _entries[s.id]?.revision == s.revision &&
            _entries[s.id]?.text == s.text &&
            _entries[s.id]?.translation == null;
        if (!latest() || _journal.containsKey(_key(s))) continue;
        final now = clock();
        _requests.removeWhere(
          (t) => now.difference(t) >= const Duration(hours: 1),
        );
        if (_requests.length >= 120) {
          paused = true;
          error = '翻译已达每小时120次上限，请稍后恢复';
          break;
        }
        if (s.text.length > 12000) {
          _journal[_key(s)] = 'failed';
          error = '此句过长，请在会后翻译';
          continue;
        }
        if (!configurationCurrent()) {
          paused = true;
          error = '文字服务配置已变化，本场翻译已暂停';
          break;
        }
        final generation = _generation, key = _key(s), language = target;
        _journal[key] = 'pending';
        _requests.add(now);
        try {
          await persist();
          if (generation != _generation ||
              paused ||
              !latest() ||
              closing ||
              closed ||
              !configurationCurrent()) {
            _journal.remove(key);
            _requests.remove(now);
            await persist();
            continue;
          }
          if (!_started.isCompleted) _started.complete();
          final translated = await translate(s, language);
          final entry = _entries[s.id];
          if (generation != _generation ||
              closed ||
              entry?.text != s.text ||
              entry?.revision != s.revision ||
              !configurationCurrent()) {
            _journal[key] = 'unknown';
            await persist();
            continue;
          }
          if (translated.trim().isEmpty) throw const FormatException('空译文');
          final translatedEntry = LiveSegment(
            id: s.id,
            text: s.text,
            revision: s.revision,
            sourceLanguage: s.sourceLanguage,
            translation: translated,
            targetLanguage: language,
            provider: '文字分析服务',
          );
          bool current() =>
              generation == _generation &&
              !closed &&
              latest() &&
              configurationCurrent();
          var published = false;
          await store.commit(
            '$sessionId/captions',
            () => current()
                ? {
                    ..._snapshot(),
                    'entries': [
                      for (final e in entries)
                        (e.id == s.id ? translatedEntry : e).toJson(),
                    ],
                    'journal': {..._journal, key: 'complete'},
                  }
                : _snapshot(),
            accepted: () {
              if (!current()) return;
              _entries[s.id] = translatedEntry;
              _journal[key] = 'complete';
              published = true;
            },
          );
          if (!published) {
            _journal[key] = 'cancelled';
            await persist();
          } else {
            onTranslated?.call(translatedEntry);
          }
        } catch (_) {
          _journal[key] = 'unknown';
          error = '翻译未完成，原文已保留；未自动重发';
          paused = true;
          try {
            await persist();
          } catch (_) {}
        }
        _changed();
      }
    } finally {
      _busy = false;
      _changed();
    }
    // A newer snapshot may have arrived during the request, without spawning a second worker.
    if (!paused &&
        !closed &&
        !closing &&
        _entries.values.any(
          (s) => s.translation == null && !_journal.containsKey(_key(s)),
        )) {
      await _drain();
    }
  }

  void changeTarget(String language) {
    if (language == target) return;
    _generation++;
    paused = true;
    target = language;
    for (final s in _entries.values.toList()) {
      _entries[s.id] = LiveSegment(
        id: s.id,
        text: s.text,
        revision: s.revision,
        sourceLanguage: s.sourceLanguage,
        targetLanguage: language,
      );
    }
    _changed();
  }

  Future<void> resume() async {
    if (closed || !configurationCurrent()) return;
    paused = false;
    error = null;
    await _drain();
  }

  void beginClosing() {
    closing = true;
  }

  Future<void> end() async {
    closing = true;
    closed = true;
    _generation++;
    _journal.updateAll((_, s) => s == 'pending' ? 'unknown' : s);
    await persist();
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    closed = true;
    _generation++;
    super.dispose();
  }
}
