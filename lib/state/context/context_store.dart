import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'context_file.dart';
import 'context_item.dart';

export 'context_item.dart';

/// Persists the user's context items and the corrections made to them.
///
/// Recording and text-material items are rebuilt from what currently exists
/// via [sync]. A recording that leaves the library (trash) hides its item; an
/// item the user corrected stays stored so the correction returns with the
/// recording when it is restored.
class ContextStore extends ChangeNotifier {
  ContextStore({File? file, bool inMemory = false})
    : _file = ContextFile(fileName, file: file, inMemory: inMemory);

  static const fileName = 'context_items.json';

  final ContextFile _file;
  final Map<String, ContextItem> _items = {};
  Set<String> _live = const {};
  bool _loaded = false;
  Future<void>? _loading;

  String? recoveryNotice;
  String? saveError;

  bool get loaded => _loaded;

  /// Completes once background writes queued so far have finished.
  Future<void> get idle => _file.idle;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final json = await _file.read();
      final items = json?['items'];
      if (items is List) {
        for (final entry in items) {
          final item = ContextItem.decode(entry);
          if (item != null) _items[item.id] = item;
        }
      }
    } on FormatException {
      recoveryNotice = '时间线记录无法读取，已另存旧文件；录音本身不受影响';
    } catch (error) {
      recoveryNotice = '时间线记录无法读取；录音本身不受影响';
      debugPrint('[ContextStore] load failed: $error');
    }
    _loaded = true;
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  ContextItem? itemById(String id) => _visible(_items[id]);

  ContextItem? _visible(ContextItem? item) {
    if (item == null) return null;
    if (item.derived && !_live.contains(item.id)) {
      return null;
    }
    return item;
  }

  Iterable<ContextItem> get _visibleItems =>
      _items.values.where((item) => _visible(item) != null);

  /// Every visible item, in time order.
  List<ContextItem> get allItems =>
      _visibleItems.toList()..sort(compareContextItems);

  /// Items that happened on [day] (local calendar day), in time order.
  /// Items with an unknown time are listed after the timed ones, on the day
  /// Koe received them.
  List<ContextItem> itemsForDay(DateTime day) =>
      _visibleItems.where((item) => sameLocalDay(item.dayAnchor, day)).toList()
        ..sort(compareContextItems);

  /// Items the user linked to [projectId], across all days, in time order.
  List<ContextItem> itemsForProject(String projectId) =>
      _visibleItems
          .where((item) => item.projectIds.contains(projectId))
          .toList()
        ..sort(compareContextItems);

  /// Replaces the derived items with [derived], keeping user links.
  ///
  /// Does not notify: it runs while the UI reads the timeline. Changes are
  /// written in the background; nothing is merged before [load] finishes, so
  /// a stale empty store can never overwrite saved corrections.
  void sync(Iterable<ContextItem> derived) {
    if (!_loaded) return;
    var changed = false;
    final live = <String>{};
    for (final next in derived) {
      live.add(next.id);
      final existing = _items[next.id];
      final merged = existing == null
          ? next
          : next.copyWith(
              // Arrival is fixed once known; later fallbacks must not move it.
              addedAt: existing.addedAt,
              topicIds: existing.userEdited ? existing.topicIds : next.topicIds,
              projectIds: existing.projectIds,
              userEdited: existing.userEdited,
            );
      if (existing == null ||
          !existing.sameDerivedFields(merged) ||
          !sameIds(existing.topicIds, merged.topicIds)) {
        _items[next.id] = merged;
        changed = true;
      }
    }
    _items.removeWhere((id, item) {
      final drop =
          item.derived &&
          !live.contains(id) &&
          !item.userEdited &&
          item.projectIds.isEmpty;
      if (drop) changed = true;
      return drop;
    });
    _live = live;
    if (changed) unawaited(_save().catchError((Object _) {}));
  }

  /// The user's correction of an item's topics. Restored on save failure.
  Future<void> setTopics(String id, List<String> topicIds) => _update(
    id,
    (item) => item.copyWith(topicIds: topicIds, userEdited: true),
  );

  Future<void> setProjects(String id, List<String> projectIds) =>
      _update(id, (item) => item.copyWith(projectIds: projectIds));

  /// Drops [projectId] from every item, e.g. when the project is deleted.
  Future<void> unlinkProject(String projectId) async {
    final before = Map<String, ContextItem>.of(_items);
    for (final item in before.values) {
      if (!item.projectIds.contains(projectId)) continue;
      _items[item.id] = item.copyWith(
        projectIds: [
          for (final id in item.projectIds)
            if (id != projectId) id,
        ],
      );
    }
    try {
      await _save();
    } catch (_) {
      _items
        ..clear()
        ..addAll(before);
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<void> _update(
    String id,
    ContextItem Function(ContextItem item) change,
  ) async {
    final previous = _items[id];
    if (previous == null) throw StateError('找不到这条记录');
    _items[id] = change(previous);
    notifyListeners();
    try {
      await _save();
    } catch (_) {
      _items[id] = previous;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _save() async {
    try {
      await _file.write({
        'version': 1,
        'items': [for (final item in _items.values) item.toJson()],
      });
      saveError = null;
    } catch (error) {
      saveError = '时间线保存失败，请检查存储空间后重试';
      debugPrint('[ContextStore] save failed: $error');
      rethrow;
    }
  }
}
