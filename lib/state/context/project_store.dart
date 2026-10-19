import 'dart:io';

import 'package:flutter/foundation.dart';

import 'context_file.dart';

/// Only the user moves a project between these; Koe never decides that a
/// goal was reached.
enum ProjectStatus { active, done, archived }

String projectStatusLabel(ProjectStatus status) => switch (status) {
  ProjectStatus.active => '进行中',
  ProjectStatus.done => '已完成',
  ProjectStatus.archived => '已归档',
};

/// A goal the user follows across days. Its material is whatever context
/// items and todos the user linked to it; nothing is copied into it.
class Project {
  const Project({
    required this.id,
    required this.title,
    required this.createdAt,
    this.goal = '',
    this.status = ProjectStatus.active,
  });

  final String id;
  final String title;
  final String goal;
  final ProjectStatus status;
  final DateTime createdAt;

  Project copyWith({String? title, String? goal, ProjectStatus? status}) =>
      Project(
        id: id,
        title: title ?? this.title,
        goal: goal ?? this.goal,
        status: status ?? this.status,
        createdAt: createdAt,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    if (goal.isNotEmpty) 'goal': goal,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
  };

  static Project? decode(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final title = value['title'];
    final createdAt = decodeTime(value['createdAt']);
    if (id is! String || title is! String || createdAt == null) return null;
    final goal = value['goal'];
    return Project(
      id: id,
      title: title,
      goal: goal is String ? goal : '',
      status:
          ProjectStatus.values
              .where((item) => item.name == value['status'])
              .firstOrNull ??
          ProjectStatus.active,
      createdAt: createdAt,
    );
  }
}

/// Persists projects in `projects.json`. A failed save restores the
/// previous list and rethrows.
class ProjectStore extends ChangeNotifier {
  ProjectStore({File? file, bool inMemory = false})
    : _file = ContextFile(fileName, file: file, inMemory: inMemory);

  static const fileName = 'projects.json';

  final ContextFile _file;
  List<Project> _projects = [];
  Future<void>? _loading;
  bool _disposed = false;
  String? recoveryNotice;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final json = await _file.read();
      for (final entry in json?['projects'] as List? ?? const []) {
        final project = Project.decode(entry);
        if (project != null) _projects.add(project);
      }
    } on FormatException {
      recoveryNotice = '项目记录无法读取，已另存旧文件';
    } catch (error) {
      recoveryNotice = '项目记录无法读取';
      debugPrint('[ProjectStore] load failed: $error');
    }
    notifyListeners();
  }

  List<Project> get projects => List.unmodifiable(_projects);

  List<Project> get active => [
    for (final project in _projects)
      if (project.status == ProjectStatus.active) project,
  ];

  Project? projectById(String? id) =>
      id == null ? null : _projects.where((p) => p.id == id).firstOrNull;

  Future<Project> create(String title, {String goal = ''}) async {
    final name = title.trim();
    if (name.isEmpty) throw StateError('项目名称不能为空');
    final now = DateTime.now();
    var id = 'p${now.microsecondsSinceEpoch}';
    while (projectById(id) != null) {
      id = '${id}x';
    }
    final project = Project(
      id: id,
      title: name,
      goal: goal.trim(),
      createdAt: now,
    );
    await _commit([..._projects, project]);
    return project;
  }

  Future<void> update(Project project) => _commit([
    for (final item in _projects) item.id == project.id ? project : item,
  ]);

  Future<void> remove(String id) => _commit([
    for (final item in _projects)
      if (item.id != id) item,
  ]);

  Future<void> _commit(List<Project> next) async {
    final previous = _projects;
    _projects = next;
    try {
      await _file.write({
        'version': 1,
        'projects': [for (final item in next) item.toJson()],
      });
    } catch (error) {
      _projects = previous;
      debugPrint('[ProjectStore] save failed: $error');
      notifyListeners();
      throw StateError('项目保存失败，已恢复原状态，请重试');
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
