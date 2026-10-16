import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'topic_recommendation.dart';

export 'topic_recommendation.dart';

/// 书籍主题（书名、作者）或普通主题。术语见 GLOSSARY.md。
enum TopicKind { book, general }

class Topic {
  Topic({
    required this.id,
    required this.kind,
    required this.title,
    this.author = '',
    this.closed = false,
    required this.createdAt,
  });

  final String id;
  final TopicKind kind;
  String title;

  /// Only meaningful for [TopicKind.book]; general topics keep it empty.
  String author;

  /// 书籍“读完”或普通主题“归档”。Closed topics are excluded from the default
  /// assignment choices and can no longer be the current topic.
  bool closed;
  final DateTime createdAt;

  String get closedLabel => kind == TopicKind.book ? '读完' : '归档';

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'title': title,
    if (kind == TopicKind.book) 'author': author,
    'closed': closed,
    'createdAt': createdAt.toIso8601String(),
  };

  static Topic? decode(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final title = json['title'];
    final kind = TopicKind.values
        .where((k) => k.name == json['kind'])
        .firstOrNull;
    if (id is! String || id.isEmpty || title is! String || kind == null) {
      return null;
    }
    if (title.trim().isEmpty) return null;
    final author = json['author'];
    return Topic(
      id: id,
      kind: kind,
      title: title,
      author: kind == TopicKind.book && author is String ? author : '',
      closed: json['closed'] == true,
      createdAt:
          DateTime.tryParse('${json['createdAt']}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Where one recording belongs. A recording key maps to exactly one value, so
/// a recording can never sit in two topics at once.
sealed class TopicPlacement {
  const TopicPlacement();
}

/// 待归类：retrieved while no current topic was set; waits for the user.
class PendingPlacement extends TopicPlacement {
  const PendingPlacement();
}

/// The user moved the recording out of every topic; it behaves like any
/// recording that never had a topic and later retrievals leave it alone.
class NoTopicPlacement extends TopicPlacement {
  const NoTopicPlacement();
}

class InTopicPlacement extends TopicPlacement {
  const InTopicPlacement(this.topicId);
  final String topicId;
}

/// Topics, the current topic and recording placements for the iPhone topic
/// notes feature (#49/#50). Persisted next to the transcript store as
/// `topics.json`; see docs/adr/0001-topic-placement-store.md.
///
/// Recording audio, transcripts and analysis never live here: losing or
/// discarding this file can only lose placements, never a recording.
class TopicStore extends ChangeNotifier {
  TopicStore({this.file, this.inMemory = false, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final File? file;
  final bool inMemory;
  final DateTime Function() _now;

  final List<Topic> _topics = [];
  final Map<String, TopicPlacement> _placements = {};
  final Map<String, TopicRecommendation> _recommendations = {};
  final Map<String, TopicDriftHint> _driftHints = {};
  final Map<String, String> _evaluatedAssist = {};
  String? _currentTopicId;
  String? _currentDay;
  Timer? _dayTimer;
  Future<void>? _loading;
  Future<void> _pendingSave = Future<void>.value();
  bool _disposed = false;

  /// Set when the persisted record could not be read in full. The unreadable
  /// file is kept as a backup; recordings themselves are unaffected.
  String? recoveryNotice;

  /// Last persistence failure; in-memory state still holds for this session.
  String? saveError;

  List<Topic> get topics => List.unmodifiable(_topics);

  /// Default assignment choices: topics that are neither 读完 nor 归档.
  List<Topic> get openTopics => [
    for (final t in _topics)
      if (!t.closed) t,
  ];
  List<Topic> get closedTopics => [
    for (final t in _topics)
      if (t.closed) t,
  ];

  Topic? topicById(String? id) =>
      id == null ? null : _topics.where((t) => t.id == id).firstOrNull;

  static String dayOf(DateTime time) {
    final local = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }

  /// 当前主题. Only valid on the local day it was set; reading it on a later
  /// day clears it (and persists the clearing) before returning null.
  Topic? get currentTopic {
    _expireIfNewDay();
    return topicById(_currentTopicId);
  }

  TopicPlacement? placementOf(String recordingKey) => _placements[recordingKey];

  Topic? topicOf(String recordingKey) {
    final placement = _placements[recordingKey];
    return placement is InTopicPlacement ? topicById(placement.topicId) : null;
  }

  bool isPending(String recordingKey) =>
      _placements[recordingKey] is PendingPlacement;

  List<String> recordingsIn(String topicId) => [
    for (final entry in _placements.entries)
      if (entry.value case InTopicPlacement(
        topicId: final placed,
      ) when placed == topicId)
        entry.key,
  ];

  List<String> get pendingRecordings => [
    for (final entry in _placements.entries)
      if (entry.value is PendingPlacement) entry.key,
  ];

  TopicRecommendation? recommendationFor(String recordingKey) {
    if (!isPending(recordingKey)) return null;
    final rec = _recommendations[recordingKey];
    if (rec == null) return null;
    if (rec.kind == TopicRecommendationKind.existingTopic) {
      final topic = topicById(rec.topicId);
      if (topic == null || topic.closed) return null;
    }
    return rec;
  }

  TopicDriftHint? driftHintFor(String recordingKey) {
    final placement = _placements[recordingKey];
    if (placement is! InTopicPlacement) return null;
    final hint = _driftHints[recordingKey];
    if (hint == null || hint.topicId != placement.topicId) return null;
    final topic = topicById(placement.topicId);
    if (topic == null || topic.closed) return null;
    if (hint.suggestedTopicId != null) {
      final suggested = topicById(hint.suggestedTopicId);
      if (suggested == null ||
          suggested.closed ||
          suggested.id == placement.topicId) {
        return TopicDriftHint(
          topicId: hint.topicId,
          sourceHash: hint.sourceHash,
        );
      }
    }
    return hint;
  }

  String? driftPromptFor(String recordingKey) {
    final hint = driftHintFor(recordingKey);
    if (hint == null) return null;
    final topic = topicById(hint.topicId);
    return topic == null ? null : '这条好像不属于《${topic.title}》';
  }

  bool hasEvaluatedAssist(String recordingKey, String token) =>
      _evaluatedAssist[recordingKey] == token;

  Future<void> markAssistEvaluated(String recordingKey, String token) async {
    await load();
    _evaluatedAssist[recordingKey] = token;
    await save();
  }

  /// Removes [token] when it is still the mark for [recordingKey]. An attempt
  /// that was superseded, or that finished after the recording left 待归类 or
  /// its original topic, must not block a later evaluation of that excerpt.
  Future<void> clearAssistEvaluated(String recordingKey, String token) async {
    await load();
    if (_evaluatedAssist[recordingKey] != token) return;
    _evaluatedAssist.remove(recordingKey);
    await save();
  }

  Future<void> setRecommendation(
    String recordingKey,
    TopicRecommendation recommendation,
  ) async {
    await load();
    if (!isPending(recordingKey)) return;
    if (recommendation.kind == TopicRecommendationKind.existingTopic) {
      final topic = topicById(recommendation.topicId);
      if (topic == null || topic.closed) return;
    }
    _recommendations[recordingKey] = recommendation;
    await _commit();
  }

  Future<Topic?> confirmRecommendation(String recordingKey) async {
    await load();
    final rec = recommendationFor(recordingKey);
    _recommendations.remove(recordingKey);
    if (rec == null) {
      await _commit();
      return null;
    }
    if (rec.kind == TopicRecommendationKind.existingTopic) {
      final topic = topicById(rec.topicId);
      if (topic == null || topic.closed) {
        await _commit();
        return null;
      }
      _placements[recordingKey] = InTopicPlacement(topic.id);
      _driftHints.remove(recordingKey);
      _carryEvaluatedHashToTopic(recordingKey, topic.id);
      await _commit();
      return topic;
    }
    final name = _requireTitle(rec.suggestedTitle);
    final created = _now();
    var id = 't${created.microsecondsSinceEpoch}';
    while (topicById(id) != null) {
      id = '${id}x';
    }
    final topic = Topic(
      id: id,
      kind: rec.suggestedKind,
      title: name,
      author: rec.suggestedKind == TopicKind.book
          ? rec.suggestedAuthor.trim()
          : '',
      createdAt: created,
    );
    _topics.add(topic);
    _placements[recordingKey] = InTopicPlacement(topic.id);
    _driftHints.remove(recordingKey);
    _carryEvaluatedHashToTopic(recordingKey, topic.id);
    await _commit();
    return topic;
  }

  void _carryEvaluatedHashToTopic(String recordingKey, String topicId) {
    final prev = _evaluatedAssist[recordingKey];
    if (prev == null) return;
    final colon = prev.lastIndexOf(':');
    if (colon < 0 || colon + 1 >= prev.length) return;
    _evaluatedAssist[recordingKey] = 'drift:$topicId:${prev.substring(colon + 1)}';
  }

  Future<void> dismissRecommendation(String recordingKey) async {
    await load();
    if (_recommendations.remove(recordingKey) != null) await _commit();
  }

  Future<void> setDriftHint(String recordingKey, TopicDriftHint hint) async {
    await load();
    if (topicOf(recordingKey)?.id != hint.topicId) return;
    final topic = topicById(hint.topicId);
    if (topic == null || topic.closed) return;
    final suggested = topicById(hint.suggestedTopicId);
    _driftHints[recordingKey] = TopicDriftHint(
      topicId: hint.topicId,
      suggestedTopicId:
          suggested != null && !suggested.closed && suggested.id != hint.topicId
          ? suggested.id
          : null,
      sourceHash: hint.sourceHash,
    );
    await _commit();
  }

  Future<void> dismissDriftHint(String recordingKey) async {
    await load();
    if (_driftHints.remove(recordingKey) != null) await _commit();
  }

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final target = inMemory ? null : (file ?? await _defaultFile());
    if (target != null && await target.exists()) {
      String? raw;
      try {
        raw = await target.readAsString();
        _decode(jsonDecode(raw));
      } catch (error) {
        // Fail open: placements are not paid work, and refusing to start
        // would hide the library. Keep the unreadable bytes for inspection
        // and never overwrite them with the empty state.
        _topics.clear();
        _placements.clear();
        _recommendations.clear();
        _driftHints.clear();
        _evaluatedAssist.clear();
        _currentTopicId = null;
        _currentDay = null;
        await _preserveCorrupt(target);
        recoveryNotice = '主题记录无法读取，已备份原文件并重新开始；录音未受影响';
        debugPrint('[TopicStore] load failed: $error');
      }
    }
    _expireIfNewDay(save: true);
    _scheduleDayBoundary();
    if (!_disposed) notifyListeners();
  }

  void _decode(Object? json) {
    if (json is! Map) throw const FormatException('Topic record is not a map');
    _topics.clear();
    _placements.clear();
    _recommendations.clear();
    _driftHints.clear();
    _evaluatedAssist.clear();
    _currentTopicId = null;
    _currentDay = null;
    var partial = false;
    final topics = json['topics'];
    if (topics is List) {
      final seen = <String>{};
      for (final item in topics) {
        final topic = Topic.decode(item);
        if (topic == null || !seen.add(topic.id)) {
          partial = true;
          continue;
        }
        _topics.add(topic);
      }
    } else if (topics != null) {
      partial = true;
    }
    final placements = json['placements'];
    if (placements is Map) {
      for (final entry in placements.entries) {
        final key = entry.key;
        if (key is! String || key.isEmpty) continue;
        final value = entry.value;
        if (value == 'pending') {
          _placements[key] = const PendingPlacement();
        } else if (value == 'none') {
          _placements[key] = const NoTopicPlacement();
        } else if (value is String &&
            value.startsWith('topic:') &&
            topicById(value.substring(6)) != null) {
          _placements[key] = InTopicPlacement(value.substring(6));
        } else {
          // The recording was placed somewhere we can no longer resolve
          // (damaged entry or missing topic). Surface it in 待归类 so the
          // user can place it again instead of it silently vanishing.
          _placements[key] = const PendingPlacement();
          partial = true;
        }
      }
    } else if (placements != null) {
      partial = true;
    }
    final recommendations = json['recommendations'];
    if (recommendations is Map) {
      for (final entry in recommendations.entries) {
        final key = entry.key;
        if (key is! String || key.isEmpty || !isPending(key)) continue;
        final decoded = TopicRecommendation.decode(
          entry.value,
          lookupTopic: topicById,
        );
        if (decoded != null) _recommendations[key] = decoded;
      }
    }
    final driftHints = json['driftHints'];
    if (driftHints is Map) {
      for (final entry in driftHints.entries) {
        final key = entry.key;
        if (key is! String || key.isEmpty) continue;
        final decoded = TopicDriftHint.decode(
          entry.value,
          lookupTopic: topicById,
        );
        if (decoded != null && topicOf(key)?.id == decoded.topicId) {
          _driftHints[key] = decoded;
        }
      }
    }
    final evaluated = json['evaluatedAssist'];
    if (evaluated is Map) {
      for (final entry in evaluated.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && key.isNotEmpty && value is String) {
          _evaluatedAssist[key] = value;
        }
      }
    }
    final current = json['current'];
    if (current is Map &&
        current['topicId'] is String &&
        current['day'] is String) {
      final topic = topicById(current['topicId'] as String);
      if (topic != null && !topic.closed) {
        _currentTopicId = topic.id;
        _currentDay = current['day'] as String;
      }
    }
    if (partial) {
      recoveryNotice = '部分主题记录无法读取，相关录音已移到“待归类”';
    }
  }

  Future<void> _preserveCorrupt(File target) async {
    try {
      final stamp = _now().millisecondsSinceEpoch;
      await target.rename('${target.path}.corrupt-$stamp');
    } catch (error) {
      debugPrint('[TopicStore] could not back up corrupt record: $error');
    }
  }

  static Future<File> _defaultFile() async {
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    final dir = Directory(p.join(base.path, 'AnkerRecorder'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, 'topics.json'));
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'topics': [for (final t in _topics) t.toJson()],
    'placements': {
      for (final entry in _placements.entries)
        entry.key: switch (entry.value) {
          PendingPlacement() => 'pending',
          NoTopicPlacement() => 'none',
          InTopicPlacement(:final topicId) => 'topic:$topicId',
        },
    },
    if (_recommendations.isNotEmpty)
      'recommendations': {
        for (final entry in _recommendations.entries)
          if (recommendationFor(entry.key) != null)
            entry.key: entry.value.toJson(),
      },
    if (_driftHints.isNotEmpty)
      'driftHints': {
        for (final entry in _driftHints.entries)
          if (driftHintFor(entry.key) != null)
            entry.key: driftHintFor(entry.key)!.toJson(),
      },
    if (_evaluatedAssist.isNotEmpty) 'evaluatedAssist': _evaluatedAssist,
    if (_currentTopicId != null)
      'current': {'topicId': _currentTopicId, 'day': _currentDay},
  };

  Future<void> save() {
    if (inMemory) return Future<void>.value();
    final snapshot = const JsonEncoder.withIndent('  ').convert(toJson());
    final operation = _pendingSave.then((_) async {
      try {
        final target = file ?? await _defaultFile();
        await target.parent.create(recursive: true);
        final temporary = File('${target.path}.tmp');
        await temporary.writeAsString(snapshot, flush: true);
        await temporary.rename(target.path);
        saveError = null;
      } catch (error) {
        saveError = '主题记录保存失败，请检查存储空间';
        debugPrint('[TopicStore] save failed: $error');
      }
    });
    _pendingSave = operation;
    return operation;
  }

  // ---- Day boundary ------------------------------------------------------

  /// Re-checks the day, e.g. when the app returns to the foreground.
  void checkDay() {
    if (_expireIfNewDay(save: true)) notifyListeners();
    _scheduleDayBoundary();
  }

  bool _expireIfNewDay({bool save = true}) {
    if (_currentTopicId == null) return false;
    if (_currentDay == dayOf(_now())) return false;
    _currentTopicId = null;
    _currentDay = null;
    _dayTimer?.cancel();
    if (save) unawaited(this.save());
    return true;
  }

  /// While the app stays in the foreground across midnight no read may
  /// happen, so a timer clears the current topic and notifies listeners.
  void _scheduleDayBoundary() {
    _dayTimer?.cancel();
    if (_currentTopicId == null || _disposed) return;
    final now = _now().toLocal();
    final midnight = DateTime(now.year, now.month, now.day + 1);
    _dayTimer = Timer(midnight.difference(now), () {
      if (_disposed) return;
      if (_expireIfNewDay(save: true)) {
        notifyListeners();
      } else {
        _scheduleDayBoundary();
      }
    });
  }

  // ---- Topic editing -----------------------------------------------------

  Future<Topic> createTopic({
    required TopicKind kind,
    required String title,
    String author = '',
  }) async {
    await load();
    final name = _requireTitle(title);
    final created = _now();
    var id = 't${created.microsecondsSinceEpoch}';
    while (topicById(id) != null) {
      id = '${id}x';
    }
    final topic = Topic(
      id: id,
      kind: kind,
      title: name,
      author: kind == TopicKind.book ? author.trim() : '',
      createdAt: created,
    );
    _topics.add(topic);
    await _commit();
    return topic;
  }

  Future<void> renameTopic(String id, String title) async {
    await load();
    _require(id).title = _requireTitle(title);
    await _commit();
  }

  Future<void> setAuthor(String id, String author) async {
    await load();
    final topic = _require(id);
    if (topic.kind != TopicKind.book) {
      throw StateError('只有书籍主题有作者');
    }
    topic.author = author.trim();
    await _commit();
  }

  /// 读完（书籍）/ 归档（普通主题）。A closed topic stops being current.
  Future<void> closeTopic(String id) async {
    await load();
    _require(id).closed = true;
    if (_currentTopicId == id) {
      _currentTopicId = null;
      _currentDay = null;
      _dayTimer?.cancel();
    }
    _recommendations.removeWhere(
      (_, r) =>
          r.kind == TopicRecommendationKind.existingTopic && r.topicId == id,
    );
    _driftHints.removeWhere((_, h) => h.topicId == id);
    await _commit();
  }

  Future<void> reopenTopic(String id) async {
    await load();
    _require(id).closed = false;
    await _commit();
  }

  Future<void> setCurrentTopic(String? id) async {
    await load();
    if (id == null) {
      _currentTopicId = null;
      _currentDay = null;
    } else {
      final topic = _require(id);
      if (topic.closed) throw StateError('请先重新打开该主题');
      _currentTopicId = id;
      _currentDay = dayOf(_now());
    }
    _scheduleDayBoundary();
    await _commit();
  }

  // ---- Recording placement ----------------------------------------------

  /// Called once a device retrieval completed. A recording that already has a
  /// placement keeps it (re-retrieval never moves it); otherwise it goes to
  /// today's current topic, or to 待归类 when there is none.
  Future<void> placeRetrieved(String recordingKey) async {
    await load();
    if (_placements.containsKey(recordingKey)) return;
    final current = currentTopic;
    _placements[recordingKey] = current == null
        ? const PendingPlacement()
        : InTopicPlacement(current.id);
    await _commit();
  }

  /// Manual move into [topicId]; replaces any previous placement.
  Future<void> moveRecording(String recordingKey, String topicId) async {
    await load();
    _require(topicId);
    _placements[recordingKey] = InTopicPlacement(topicId);
    _recommendations.remove(recordingKey);
    _driftHints.remove(recordingKey);
    _carryEvaluatedHashToTopic(recordingKey, topicId);
    await _commit();
  }

  /// 移出主题: the recording no longer belongs to any topic.
  Future<void> removeFromTopic(String recordingKey) async {
    await load();
    if (!_placements.containsKey(recordingKey)) return;
    _placements[recordingKey] = const NoTopicPlacement();
    _recommendations.remove(recordingKey);
    _driftHints.remove(recordingKey);
    await _commit();
  }

  /// The recording itself was deleted.
  Future<void> forgetRecording(String recordingKey) async {
    await load();
    final removed = _placements.remove(recordingKey) != null;
    final recRemoved = _recommendations.remove(recordingKey) != null;
    final driftRemoved = _driftHints.remove(recordingKey) != null;
    final evalRemoved = _evaluatedAssist.remove(recordingKey) != null;
    if (removed || recRemoved || driftRemoved || evalRemoved) {
      await _commit();
    }
  }

  Future<void> renameRecordingKey(String from, String to) async {
    await load();
    if (from == to) return;
    final placement = _placements.remove(from);
    if (placement == null) return;
    _placements[to] = placement;
    final rec = _recommendations.remove(from);
    if (rec != null) _recommendations[to] = rec;
    final drift = _driftHints.remove(from);
    if (drift != null) _driftHints[to] = drift;
    final eval = _evaluatedAssist.remove(from);
    if (eval != null) _evaluatedAssist[to] = eval;
    await _commit();
  }

  Topic _require(String id) {
    final topic = topicById(id);
    if (topic == null) throw StateError('主题不存在');
    return topic;
  }

  static String _requireTitle(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) throw ArgumentError('请输入名称');
    if (trimmed.length > 100) throw ArgumentError('名称不能超过 100 个字符');
    return trimmed;
  }

  Future<void> _commit() async {
    if (!_disposed) notifyListeners();
    await save();
  }

  @override
  void dispose() {
    _disposed = true;
    _dayTimer?.cancel();
    super.dispose();
  }
}
