import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/mobile_header.dart';
import '../widgets/widgets.dart';
import 'new_recording_sheet.dart';
import 'project_detail_screen.dart';
import 'topics_screen.dart';

/// Phone "Projects" section (#131).
///
/// Cross-day projects (#135): each lists its latest linked material and the
/// next step said so far. Books and topics stay reachable below.
class ProjectsScreen extends StatelessWidget {
  const ProjectsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final closed = [
      for (final project in c.projects.projects)
        if (project.status != ProjectStatus.active) project,
    ];
    // Starts below the status bar like Today, so scrolled projects stop there
    // instead of sliding under it.
    return GradientScaffold(
      child: SafeArea(
        left: false,
        right: false,
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 108),
          children: [
            KoeMobileHeader(
              onNewRecording: () => _newRecording(context),
              onOpenSettings: () => openMobileSettings(context),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '项目',
                    style: TextStyle(
                      fontSize: AppFontSizes.lg,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SectionLabel(
                    '进行中项目',
                    trailing: TextButton(
                      key: const ValueKey('create-project'),
                      onPressed: () => _createProject(context),
                      child: const Text('新建项目'),
                    ),
                  ),
                  if (c.projects.active.isEmpty)
                    SurfaceCard(
                      key: const ValueKey('projects-empty'),
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '还没有进行中的项目',
                            style: TextStyle(
                              fontSize: AppFontSizes.md,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            '新建一个目标项目，再把不同日子的录音和待办关联进来。',
                            style: TextStyle(
                              fontSize: AppFontSizes.sm,
                              height: 1.45,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton(
                                key: const ValueKey('create-project-empty'),
                                onPressed: () => _createProject(context),
                                child: const Text('新建项目'),
                              ),
                              if (c.topicsEnabled)
                                OutlinedButton(
                                  key: const ValueKey('create-topic'),
                                  onPressed: () =>
                                      showCreateTopicDialog(context, c.topics),
                                  child: const Text('新建主题'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    )
                  else
                    for (final project in c.projects.active)
                      _ProjectCard(project: project),
                  if (closed.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    const SectionLabel('已完成或归档'),
                    for (final project in closed)
                      _ProjectCard(project: project),
                  ],
                  const SizedBox(height: 22),
                  const SectionLabel('书籍与主题'),
                  if (c.topicsEnabled)
                    TopicsEntry(
                      padding: EdgeInsets.zero,
                      key: const ValueKey('projects-topics-entry'),
                    )
                  else
                    const SurfaceCard(
                      padding: EdgeInsets.all(14),
                      child: Text(
                        '主题在当前平台暂不可用；录音与资料仍可正常使用。',
                        style: TextStyle(
                          fontSize: AppFontSizes.sm,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _newRecording(BuildContext context) async {
    final action = await showNewRecordingSheet(context);
    if (action == null || !context.mounted) return;
    await handleNewRecordingAction(context, action);
  }

  Future<void> _createProject(BuildContext context) async {
    final created = await showProjectDialog(context);
    if (created == null || !context.mounted) return;
    final c = context.read<RecorderController>();
    try {
      final project = await c.createProject(created.$1, goal: created.$2);
      if (context.mounted) openProject(context, project.id);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is StateError ? error.message.toString() : '保存失败，请重试',
          ),
        ),
      );
    }
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final progress = c.projectProgress(project.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SurfaceCard(
        key: ValueKey('project-${project.id}'),
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        onTap: () => openProject(context, project.id),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    project.title,
                    style: const TextStyle(
                      fontSize: AppFontSizes.md,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (project.goal.isNotEmpty)
                    Text(
                      project.goal,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: AppFontSizes.sm),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    projectLatestLabel(progress),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: AppFontSizes.xs,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  Text(
                    projectNextLabel(progress),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: AppFontSizes.xs,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    );
  }
}
