part of '../recorder_controller.dart';

/// Where a project stands, derived only from what the user linked to it.
class ProjectProgress {
  const ProjectProgress({required this.latest, required this.next});

  /// The most recent linked item, or null when nothing is linked yet.
  final ContextItem? latest;

  /// The earliest open todo of mine in the project; null means no clear
  /// next step has been said yet.
  final Todo? next;
}

/// Projects across days (#135): context items and todos the user linked.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderProjects on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  abstract final ContextStore contextItems;
  List<ContextItem> contextItemsForProject(String projectId);
  abstract final TodoStore todos;
  // END DEPS

  late final ProjectStore projects;

  Future<Project> createProject(String title, {String goal = ''}) =>
      projects.create(title, goal: goal);

  Future<void> updateProject(Project project) => projects.update(project);

  /// Deletes the project and its links. Recordings and todos stay.
  Future<void> deleteProject(String id) async {
    await contextItems.unlinkProject(id);
    for (final todo in todos.todosForProject(id)) {
      await todos.put(
        todo.copyWith(
          projectIds: [
            for (final other in todo.projectIds)
              if (other != id) other,
          ],
        ),
      );
    }
    await projects.remove(id);
  }

  /// Links or unlinks one item. One item may belong to several projects;
  /// only the relation is stored, the audio is never copied.
  Future<void> setContextItemProjects(String itemId, List<String> projectIds) =>
      contextItems.setProjects(itemId, projectIds);

  ProjectProgress projectProgress(String projectId) {
    final items = contextItemsForProject(projectId);
    final next = [
      for (final todo in todos.todosForProject(projectId))
        if (todo.open && todo.kind == TodoKind.mine) todo,
    ];
    return ProjectProgress(
      latest: items.isEmpty ? null : items.last,
      next: next.firstOrNull,
    );
  }

  /// The active project with the most recent linked activity, for Today.
  Project? get focusProject {
    Project? best;
    DateTime? bestAt;
    for (final project in projects.active) {
      final latest = projectProgress(project.id).latest?.dayAnchor;
      final at = latest ?? project.createdAt;
      if (bestAt == null || at.isAfter(bestAt)) {
        best = project;
        bestAt = at;
      }
    }
    return best;
  }
}
