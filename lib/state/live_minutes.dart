import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'live_segments.dart';
import 'live_minutes_store.dart';
import 'meeting_minutes.dart';
import 'recording_analysis.dart';

class LiveMinutesRequest {
  const LiveMinutesRequest({
    required this.sources,
    required this.from,
    required this.previous,
    required this.abort,
  });
  final List<String> sources;
  final int from;
  final String? previous;
  final Future<void> abort;
  String get input => [
    if (previous != null) '上一版纪要（数据）\n$previous',
    for (var i = from; i < sources.length; i++) '[S${i + 1}] ${sources[i]}',
  ].join('\n');
}

Set<String> liveMinuteCitations(String text) {
  final ids = <String>{};
  void walk(dynamic v) {
    if (v is Map) {
      for (final e in v.entries) {
        if (e.key == 'sources' && e.value is List) {
          ids.addAll((e.value as List).cast<String>());
        } else {
          walk(e.value);
        }
      }
    } else if (v is List) {
      for (final e in v) {
        walk(e);
      }
    }
  }

  walk(jsonDecode(text));
  return ids;
}

String validateLiveMinutes(
  String raw,
  List<String> sources,
  Set<String> allowed,
) {
  final json =
      jsonDecode(validateMinutes(raw, sources)) as Map<String, dynamic>;
  for (final term in json['terms'] as List? ?? []) {
    (term as Map).remove('adoption');
  }
  final encoded = jsonEncode(json);
  if (!allowed.containsAll(liveMinuteCitations(encoded))) {
    throw const FormatException('实时纪要引用了本次未提供的来源');
  }
  return encoded;
}

/// Scheduling is separate from audio capture. Every paid call has a durable intent.
class LiveMinutes extends ChangeNotifier {
  LiveMinutes({
    required this.sessionId,
    required this.store,
    required this.request,
    DateTime Function()? clock,
    bool Function()? configurationCurrent,
    this.model = 'live',
    this.configuration = '',
    this.recordingKey,
  }) : clock = clock ?? DateTime.now,
       configurationCurrent = configurationCurrent ?? (() => true);
  final String sessionId, model, configuration;
  String? recordingKey;
  final LiveMinutesStore store;
  final Future<String> Function(LiveMinutesRequest) request;
  final DateTime Function() clock;
  final bool Function() configurationCurrent;
  final List<LiveSegment> _segments = [];
  final List<String> _sources = [];
  final List<DateTime> _requests = [];
  final List<int> _uncertainRequests = [];
  int _attempt = 0;
  bool _editedAbort = false;
  DateTime? _firstAt;
  int watermark = 0, _generation = 0;
  bool paused = false,
      closed = false,
      closing = false,
      edited = false,
      busy = false,
      _disposed = false;
  String? error, machine, active, candidate;
  String requestStatus = 'idle';
  final Completer<void> _started = Completer<void>();
  Completer<void>? _abort;
  Future<void> get requestStarted => _started.future;
  List<String> get sources => List.unmodifiable(_sources);
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Map<String, dynamic> _snapshot() => {
    'id': sessionId,
    'kind': 'minutes',
    'recordingKey': recordingKey,
    'sources': _sources,
    'segments': [for (final s in _segments) s.toJson()],
    'watermark': watermark,
    'machine': machine,
    'active': active,
    'candidate': candidate,
    'edited': edited,
    'closed': closed,
    'requestStatus': requestStatus,
    'attempt': _attempt,
    'uncertainRequests': _uncertainRequests,
    'error': error,
    'configuration': configuration,
    'model': model,
    'requests': [for (final t in _requests) t.toIso8601String()],
  };
  Future<void> persist() => store.commit(sessionId, _snapshot);
  Future<void> restore() async {
    final j = await store.read(sessionId);
    if (j == null) return;
    _sources.addAll((j['sources'] as List).cast<String>());
    _segments.addAll([
      for (final s in j['segments'] as List? ?? [])
        LiveSegment.fromJson(Map<String, dynamic>.from(s as Map)),
    ]);
    for (final raw in j['requests'] as List? ?? []) {
      if (raw is String) {
        final parsed = DateTime.tryParse(raw);
        if (parsed != null) _requests.add(parsed);
      }
    }
    watermark = j['watermark'] as int;
    machine = j['machine'] as String?;
    active = j['active'] as String?;
    candidate = j['candidate'] as String?;
    edited = j['edited'] == true;
    recordingKey = j['recordingKey'] as String?;
    closed = true;
    paused = true;
    requestStatus = j['requestStatus'] == 'pending'
        ? 'unknown'
        : j['requestStatus'] as String? ?? 'idle';
    error = requestStatus == 'unknown'
        ? '上次请求结果未知，未自动重发'
        : j['error'] as String?;
    _changed();
  }

  void add(List<LiveSegment> incoming) {
    if (closed) return;
    var added = false;
    for (final s in incoming) {
      final index = _segments.indexWhere((e) => e.id == s.id);
      if (index >= 0) {
        if (_segments[index].text != s.text) invalidate('已确认原文被修订，请在会后整理');
        continue;
      }
      if (_sources.fold<int>(0, (n, s) => n + s.length) + s.text.length >
          2000000) {
        invalidate('实时原文达到上限，请在会后整理');
        break;
      }
      added = true;
      _segments.add(s);
      _sources.addAll(analysisSourceBlocks(s.text, maxRunes: 6000));
      _firstAt ??= clock();
    }
    if (!added) return;
    unawaited(
      persist().catchError((Object e) {
        invalidate('实时资料未保存，请检查存储');
      }),
    );
    _changed();
  }

  void invalidate(String reason) {
    paused = true;
    error = reason;
    _generation++;
    _cancel();
    _changed();
  }

  void _cancel() {
    final a = _abort;
    if (a != null && !a.isCompleted) a.complete();
  }

  Future<void> pauseForEdit() => pause(forEdit: true);

  Future<void> pause({bool forEdit = false}) async {
    paused = true;
    edited = edited || forEdit;
    _generation++;
    _cancel();
    await persist();
    _changed();
  }

  Future<void> edit(String text) async {
    await pauseForEdit();
    final validated = validateMinutes(text, _sources);
    final generation = _generation;
    await store.commit(
      sessionId,
      () => {..._snapshot(), 'active': validated},
      accepted: () {
        if (generation == _generation) active = validated;
      },
    );
    _changed();
  }

  Future<void> resume() async {
    if (closed ||
        (requestStatus == 'unknown' && !_editedAbort) ||
        requestStatus == 'pending' ||
        !configurationCurrent()) {
      return;
    }
    paused = false;
    _editedAbort = false;
    error = null;
    await persist();
    _changed();
  }

  Future<void> acceptCandidate() async {
    if (candidate == null) return;
    final selected = candidate;
    final generation = _generation;
    await store.commit(
      sessionId,
      () => {..._snapshot(), 'active': selected},
      accepted: () {
        if (generation == _generation) active = selected;
      },
    );
    _changed();
  }

  void beginClosing() {
    closing = true;
    _changed();
  }

  Future<void> end() async {
    closing = true;
    closed = true;
    paused = true;
    _generation++;
    _cancel();
    if (requestStatus == 'pending') requestStatus = 'unknown';
    await persist();
    _changed();
  }

  Future<void> tick() async {
    if (busy || paused || closed || closing || watermark >= _sources.length) {
      return;
    }
    if (!configurationCurrent()) {
      invalidate('文字服务配置已变化，本场实时整理已暂停');
      return;
    }
    final now = clock();
    _requests.removeWhere((t) => now.difference(t) >= const Duration(hours: 1));
    if (_requests.length >= 120) {
      invalidate('实时整理已达每小时120次上限，请稍后恢复');
      return;
    }
    final added = _sources.skip(watermark).fold<int>(0, (n, s) => n + s.length);
    if (_requests.isEmpty) {
      if (added < 200 &&
          now.difference(_firstAt ?? now) < const Duration(seconds: 30)) {
        return;
      }
    } else if (added < 200 ||
        now.difference(_requests.last) < const Duration(seconds: 30)) {
      return;
    }
    if ((machine?.length ?? 0) > 12000) {
      invalidate('速记超过实时上限，请在会后生成完整版');
      return;
    }
    var end = watermark, chars = 0;
    while (end < _sources.length && chars + _sources[end].length <= 12000) {
      chars += _sources[end].length;
      end++;
    }
    final input = List<String>.unmodifiable(_sources.take(end));
    final from = watermark;
    final generation = _generation;
    busy = true;
    _abort = Completer<void>();
    requestStatus = 'pending';
    _attempt++;
    _requests.add(now);
    _changed();
    try {
      await persist();
      if (generation != _generation ||
          closing ||
          closed ||
          !configurationCurrent()) {
        throw StateError('实时请求已取消或配置变化');
      }
      if (!_started.isCompleted) _started.complete();
      final raw = await request(
        LiveMinutesRequest(
          sources: input,
          from: from,
          previous: machine,
          abort: _abort!.future,
        ),
      );
      if (generation != _generation || closed || !configurationCurrent()) {
        requestStatus = 'cancelled';
        await persist();
        return;
      }
      final allowed = {
        for (var i = from; i < end; i++) 'S${i + 1}',
        if (machine != null) ...liveMinuteCitations(machine!),
      };
      final validated = validateLiveMinutes(raw, input, allowed);
      bool current() =>
          generation == _generation && !closed && configurationCurrent();
      var published = false;
      await store.commit(
        sessionId,
        () => current()
            ? {
                ..._snapshot(),
                'machine': validated,
                if (edited) 'candidate': validated else 'active': validated,
                'watermark': end,
                'requestStatus': 'complete',
              }
            : _snapshot(),
        accepted: () {
          if (!current()) return;
          machine = validated;
          if (edited) {
            candidate = validated;
          } else {
            active = validated;
          }
          watermark = end;
          requestStatus = 'complete';
          published = true;
        },
      );
      if (!published) {
        requestStatus = 'cancelled';
        await persist();
      }
    } catch (_) {
      requestStatus = 'unknown';
      _uncertainRequests.add(_attempt);
      _editedAbort = generation != _generation && edited && !closed;
      paused = true;
      error = _editedAbort
          ? '编辑中止了整理，原请求结果未知；恢复将发起新的候选请求'
          : '实时请求未完成，未自动重发；录音仍在保存';
      try {
        await persist();
      } catch (_) {}
    } finally {
      busy = false;
      _abort = null;
      _changed();
    }
  }

  AnalysisResult? get result {
    if (active == null) return null;
    final stamp = _requests.isNotEmpty ? _requests.last : clock();
    return AnalysisResult(
      text: active!,
      sourceHash: analysisFingerprint(_sources.take(watermark).join('\n')),
      model: model,
      instruction: '实时速记',
      sources: List.unmodifiable(_sources.take(watermark)),
      createdAt: stamp,
      editedAt: edited ? stamp : null,
      isDraft: true,
      templateId: minutesTemplateId,
    );
  }
  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _cancel();
    super.dispose();
  }
}
