import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/mobile_header.dart';
import '../widgets/widgets.dart';
import 'new_recording_sheet.dart';
import 'topics_screen.dart';

/// Phone "Projects" section (#131).
///
/// Cross-day projects belong to a later ticket. This page keeps the existing
/// book/topic flow reachable and describes the empty project list honestly.
class ProjectsScreen extends StatelessWidget {
  const ProjectsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    return GradientScaffold(
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
                    fontSize: 30,
                    height: 1.15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.6,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '把跨天的讨论、目标和承诺放在一起。',
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.45,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 22),
                const SectionLabel('进行中项目'),
                SurfaceCard(
                  key: const ValueKey('projects-empty'),
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '还没有进行中的项目',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        '跨天项目会在后续版本接入。现在可以先用主题把录音归到一起，'
                        '书籍和普通主题仍可继续使用。',
                        style: TextStyle(
                          fontSize: 13,
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
                            key: const ValueKey('create-project'),
                            onPressed: () => _showProjectNotice(context),
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
                ),
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
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _newRecording(BuildContext context) async {
    final action = await showNewRecordingSheet(context);
    if (action == null || !context.mounted) return;
    await handleNewRecordingAction(context, action);
  }

  Future<void> _showProjectNotice(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('项目尚未开放'),
        content: const Text(
          '跨天项目、行动和承诺会在后续版本接入。现在可以用主题归档录音，'
          '待归类与当前主题不会丢失。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  settings: const RouteSettings(name: 'topics'),
                  builder: (_) => const TopicsScreen(),
                ),
              );
            },
            child: const Text('打开主题'),
          ),
        ],
      ),
    );
  }
}
