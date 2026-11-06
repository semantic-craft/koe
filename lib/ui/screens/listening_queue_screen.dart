import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../recording_navigation.dart';
import '../widgets/widgets.dart';
import '../widgets/koe_icon_button.dart';

/// Ordered continuous listening of original recordings.
///
/// The queue is only a playlist: each material keeps its own pause point in the
/// existing playback history. Missing or deleted audio is shown with its real
/// state and can be skipped or retried; it is never replaced by another file.
class ListeningQueueScreen extends StatelessWidget {
  const ListeningQueueScreen({super.key});

  static String _clock(Duration value) {
    final total = value.inSeconds.clamp(0, 359999);
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    String two(int part) => part.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<RecorderController>();
    final entries = controller.queueEntries;
    return Scaffold(
      backgroundColor: AppColors.bgElevated,
      appBar: AppBar(title: const Text('收听队列')),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (controller.listeningQueue.recoveryNotice != null)
                  _QueueBanner(
                    message: controller.listeningQueue.recoveryNotice!,
                  ),
                if (controller.queueNotice != null)
                  _QueueBanner(message: controller.queueNotice!),
                Expanded(
                  child: entries.isEmpty
                      ? const _QueueEmpty()
                      : ReorderableListView.builder(
                          key: const ValueKey('listening-queue-list'),
                          buildDefaultDragHandles: false,
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          itemCount: entries.length,
                          onReorderItem: (oldIndex, newIndex) {
                            controller.moveQueueEntry(oldIndex, newIndex);
                          },
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            return _QueueTile(
                              key: ValueKey('queue-row-${entry.key}'),
                              entry: entry,
                              index: index,
                              controller: controller,
                              clock: _clock,
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QueueEmpty extends StatelessWidget {
  const _QueueEmpty();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const ValueKey('queue-empty'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.queue_music_rounded,
              size: 44,
              color: AppColors.textMuted,
            ),
            const SizedBox(height: 16),
            const Text(
              '收听队列还是空的',
              style: TextStyle(
                fontSize: AppFontSizes.lg,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '在资料详情里点“加入收听队列”，就能按顺序连续收听原声。',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, height: 1.45),
            ),
            const SizedBox(height: 20),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('返回资料'),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueueBanner extends StatelessWidget {
  const _QueueBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: SurfaceCard(
        padding: const EdgeInsets.all(12),
        borderColor: AppColors.border,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.info_outline_rounded,
              size: 18,
              color: AppColors.textSecondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontSize: AppFontSizes.xs, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({
    super.key,
    required this.entry,
    required this.index,
    required this.controller,
    required this.clock,
  });

  final ListeningQueueEntry entry;
  final int index;
  final RecorderController controller;
  final String Function(Duration) clock;

  @override
  Widget build(BuildContext context) {
    final reference = RecordingReference(
      fileId: entry.fileId ?? controller.fileIdFromPath(entry.path),
      path: entry.path,
    );
    final view = controller.recordingView(reference);
    final current = controller.queueCurrentKey == entry.key;
    final availability = controller.queueAvailabilityFor(entry);
    final path = availability.path ?? entry.path;
    final loaded = controller.playingPath == path;
    final playing = loaded && controller.isPlaying;
    final point = controller.playbackHistory.forRecording(
      fileId: availability.fileId ?? entry.fileId,
      path: path,
    );
    String status;
    if (!availability.playable) {
      status = availability.reason;
    } else if (current && playing) {
      status = '当前，正在播放';
    } else if (current && loaded && controller.playbackCompleted) {
      status = '当前，已听完';
    } else if (current && loaded) {
      status = '当前，已暂停';
    } else if (point != null && point.completed) {
      status = '已听完';
    } else if (point != null && point.duration > Duration.zero) {
      status = '上次听到 ${clock(point.position)} / ${clock(point.duration)}';
    } else {
      status = '待收听';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: current ? AppColors.accentSoft : AppColors.bgCard,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.lg),
            border: Border.all(
              color: current ? AppColors.accent : AppColors.border,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(
                    Icons.drag_indicator_rounded,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
              KoeIconButton(
                key: ValueKey('queue-play-${entry.key}'),
                tooltip: playing ? '暂停播放' : '播放这一项',
                onPressed: availability.playable
                    ? () {
                        if (current && loaded) {
                          controller.togglePlayPause();
                        } else {
                          controller.playQueueEntry(entry.key);
                        }
                      }
                    : null,
                icon: Icon(
                  playing
                      ? Icons.pause_circle_filled_rounded
                      : Icons.play_circle_fill_rounded,
                  color: availability.playable
                      ? AppColors.accent
                      : AppColors.textMuted,
                  size: 30,
                ),
              ),
              Expanded(
                child: InkWell(
                  key: ValueKey('queue-open-${entry.key}'),
                  borderRadius: BorderRadius.circular(AppRadii.panel),
                  onTap: () => RecordingNavigation.open(
                    context,
                    controller.recordingView(reference).reference,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (current) ...[
                              Container(
                                key: ValueKey('queue-current-${entry.key}'),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.accent,
                                  borderRadius: BorderRadius.circular(
                                    AppRadii.button,
                                  ),
                                ),
                                child: const Text(
                                  '当前',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: AppFontSizes.xs,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            Expanded(
                              child: Text(
                                view.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: AppFontSizes.md,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          status,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppFontSizes.xs,
                            height: 1.35,
                            color: availability.playable
                                ? AppColors.textSecondary
                                : AppColors.coral,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (current && !availability.playable)
                KoeIconButton(
                  key: ValueKey('queue-skip-${entry.key}'),
                  tooltip: '跳过这一项',
                  onPressed: () => controller.skipQueueEntry(entry.key),
                  icon: const Icon(Icons.skip_next_rounded),
                ),
              if (!availability.playable)
                KoeIconButton(
                  key: ValueKey('queue-retry-${entry.key}'),
                  tooltip: '重试',
                  onPressed: () => controller.retryQueueEntry(entry.key),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              KoeIconButton(
                key: ValueKey('queue-remove-${entry.key}'),
                tooltip: '移出队列',
                onPressed: () => _remove(context, reference),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _remove(
    BuildContext context,
    RecordingReference reference,
  ) async {
    final current = controller.queueCurrentKey == entry.key;
    var playNext = false;
    if (current) {
      final choice = await showDialog<_RemoveChoice>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('移除当前收听项？'),
          content: Text(
            '“${controller.recordingView(reference).title}”会移出队列。'
            '当前播放会先暂停并保存断点。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog, _RemoveChoice.pause),
              child: const Text('仅移除并暂停'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, _RemoveChoice.playNext),
              child: const Text('移除并播放下一项'),
            ),
          ],
        ),
      );
      if (choice == null) return;
      playNext = choice == _RemoveChoice.playNext;
    }
    final removed = await controller.removeFromListeningQueue(
      entry.key,
      playNext: playNext,
    );
    if (!context.mounted) return;
    final notice =
        controller.queueNotice ??
        (!removed
            ? '未能移除，队列可能已变化'
            : playNext
            ? '已移除当前项，继续下一项'
            : '已移出收听队列');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(notice)));
  }
}

enum _RemoveChoice { pause, playNext }
