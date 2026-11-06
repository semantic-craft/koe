import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/widgets.dart';
import 'files_screen.dart';
import '../widgets/koe_icon_button.dart';

/// 30-day trash for original materials (#132).
///
/// Restoring only clears the trash marker. Permanent deletion is explicit and
/// removes the original, transcript and derived state after confirmation.
class TrashScreen extends StatelessWidget {
  const TrashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final items = c.trashedAssets;
    return Scaffold(
      key: const ValueKey('trash-screen'),
      backgroundColor: AppColors.bgElevated,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: const Text('回收站'),
        actions: [
          if (items.isNotEmpty)
            TextButton(
              key: const ValueKey('trash-empty'),
              onPressed: () => _emptyTrash(context, c),
              child: const Text('清空'),
            ),
        ],
      ),
      body: items.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.delete_outline_rounded,
                      size: 48,
                      color: AppColors.textSecondary,
                    ),
                    SizedBox(height: 12),
                    Text(
                      '回收站为空',
                      style: TextStyle(
                        fontSize: AppFontSizes.md,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      '移到回收站的资料会保留 30 天，原件不会被立刻删除。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final asset = items[index];
                final view = c.recordingView(
                  RecordingReference(
                    fileId: c.fileIdFromPath(asset.path),
                    path: asset.path,
                  ),
                );
                final days = c.trashDaysRemaining(asset);
                return SurfaceCard(
                  key: ValueKey('trash-row-${asset.path}'),
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.audio_file_outlined,
                        color: AppColors.textSecondary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              view.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              days > 0
                                  ? asset.deletedAt == null
                                        ? '在回收站中，还可恢复 $days 天'
                                        : '删除于 ${FilesBody.formatDateTime(asset.deletedAt!)}，还可恢复 $days 天'
                                  : '已超过 30 天保留期，等待清理',
                              style: const TextStyle(
                                fontSize: AppFontSizes.xs,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        key: ValueKey('trash-restore-${asset.path}'),
                        onPressed: days > 0
                            ? () => _restore(context, c, asset.path)
                            : null,
                        child: const Text('恢复'),
                      ),
                      KoeIconButton(
                        key: ValueKey('trash-delete-${asset.path}'),
                        tooltip: '彻底删除',
                        onPressed: () =>
                            _deletePermanently(context, c, asset.path),
                        icon: const Icon(
                          Icons.delete_forever_outlined,
                          color: AppColors.coral,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Future<void> _restore(
    BuildContext context,
    RecorderController controller,
    String path,
  ) async {
    try {
      await controller.restoreTrashed(path);
      if (!context.mounted) return;
      _notice(context, '已恢复，可在资料中继续回听');
    } catch (error) {
      if (!context.mounted) return;
      _notice(context, error is StateError ? error.message : '恢复失败，请重试');
    }
  }

  Future<void> _deletePermanently(
    BuildContext context,
    RecorderController controller,
    String path,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('彻底删除这份资料？'),
        content: const Text('原件、转写、发言人与关联内容都会被删除，且无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('彻底删除', style: TextStyle(color: AppColors.coral)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final result = await controller.emptyTrash(paths: [path]);
    if (!context.mounted) return;
    _notice(context, result.failed.isEmpty ? '已彻底删除，无法恢复' : '部分内容未能删除，请重试');
  }

  Future<void> _emptyTrash(
    BuildContext context,
    RecorderController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空回收站？'),
        content: const Text('回收站中的原件、转写与关联内容都会被删除，且无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空', style: TextStyle(color: AppColors.coral)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final result = await controller.emptyTrash();
    if (!context.mounted) return;
    _notice(
      context,
      result.failed.isEmpty ? '回收站已清空' : '${result.failed.length} 个资料未能删除，请重试',
    );
  }

  void _notice(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
