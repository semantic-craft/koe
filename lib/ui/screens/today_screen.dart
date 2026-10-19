import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../recording_navigation.dart';
import '../widgets/context_timeline.dart';
import '../widgets/mobile_header.dart';
import '../widgets/scan_sheet.dart';
import '../widgets/widgets.dart';
import 'new_recording_sheet.dart';
import 'topics_screen.dart';

/// Phone "Today" section (#131).
///
/// The day's context items form a timeline in the order they happened (#134);
/// each one opens its original recording and its topic links can be fixed.
class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final now = DateTime.now();
    final today = c.contextItemsForDay(now);
    final currentTopic = c.topicsEnabled ? c.topics.currentTopic : null;
    final pending = c.topicsEnabled
        ? c.topics.pendingRecordings.where((key) {
            final path = c.exportedPaths.where((path) {
              return c.analysisKey(
                    RecordingReference(
                      fileId: c.fileIdFromPath(path),
                      path: path,
                    ),
                  ) ==
                  key;
            }).firstOrNull;
            return path != null;
          }).length
        : 0;
    final continuePath = c.continuePath;

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
                Text(
                  _dateLine(now),
                  style: const TextStyle(
                    fontSize: 12,
                    letterSpacing: 0.4,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '把心力留给\n重要的事。',
                  style: TextStyle(
                    fontSize: 30,
                    height: 1.15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.6,
                  ),
                ),
                const SizedBox(height: 18),
                _FocusCard(
                  topicTitle: currentTopic?.title,
                  onOpenProjects: () =>
                      RecordingNavigation.of(context)?.onSelectTab?.call(1),
                  onOpenTopic: c.topicsEnabled
                      ? () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            settings: const RouteSettings(name: 'topics'),
                            builder: (_) => const TopicsScreen(),
                          ),
                        )
                      : null,
                ),
                const SizedBox(height: 12),
                _DeviceStatusCard(
                  connected: c.connected,
                  name: c.displayDeviceName,
                  status: c.statusMessage,
                  onScan: () => showScanDevicesSheet(context),
                  onOpenLibrary: () =>
                      RecordingNavigation.of(context)?.onSelectTab?.call(2),
                ),
                const SizedBox(height: 22),
                const SectionLabel('下一步行动'),
                _NextActionCard(
                  pending: pending,
                  onOpenProjects: () =>
                      RecordingNavigation.of(context)?.onSelectTab?.call(1),
                ),
                const SizedBox(height: 22),
                const SectionLabel('继续回听'),
                _ContinueListeningCard(
                  path: continuePath,
                  playing: c.playingPath == continuePath && c.isPlaying,
                  onToggle: () => c.playingPath == continuePath
                      ? c.togglePlayPause()
                      : c.toggleLatestPlayback(),
                  onOpen: continuePath == null
                      ? null
                      : () => RecordingNavigation.open(
                          context,
                          RecordingReference(
                            fileId: c.fileIdFromPath(continuePath),
                            path: continuePath,
                          ),
                        ),
                  title: continuePath == null
                      ? null
                      : c
                            .recordingView(
                              RecordingReference(
                                fileId: c.fileIdFromPath(continuePath),
                                path: continuePath,
                              ),
                            )
                            .title,
                  subtitle: continuePath == null
                      ? '还没有回听中的资料'
                      : c.continueDetail,
                  onOpenLibrary: () =>
                      RecordingNavigation.of(context)?.onSelectTab?.call(2),
                ),
                const SizedBox(height: 22),
                SectionLabel(
                  '今日时间线',
                  trailing: today.isEmpty
                      ? null
                      : TextButton(
                          onPressed: () => RecordingNavigation.of(
                            context,
                          )?.onSelectTab?.call(2),
                          child: const Text('全部资料'),
                        ),
                ),
                if (today.isEmpty)
                  _TodayEmpty(
                    onNewRecording: () => _newRecording(context),
                    onLibrary: () =>
                        RecordingNavigation.of(context)?.onSelectTab?.call(2),
                  )
                else
                  for (final item in today) ContextTimelineRow(item: item),
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
}

String _dateLine(DateTime now) {
  const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
  return '${now.month} 月 ${now.day} 日 · 星期${weekdays[now.weekday - 1]}';
}

class _FocusCard extends StatelessWidget {
  const _FocusCard({
    required this.topicTitle,
    required this.onOpenProjects,
    this.onOpenTopic,
  });

  final String? topicTitle;
  final VoidCallback onOpenProjects;
  final VoidCallback? onOpenTopic;

  @override
  Widget build(BuildContext context) {
    final hasTopic = topicTitle != null && topicTitle!.trim().isNotEmpty;
    return Container(
      key: const ValueKey('today-focus'),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
      decoration: BoxDecoration(
        color: AppColors.mint,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            hasTopic ? '正在推进 · 当前主题' : '当前重点项目',
            style: const TextStyle(
              fontSize: 12,
              letterSpacing: 0.4,
              color: Color(0xFFD7E5DA),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hasTopic ? topicTitle! : '今天还没有重点项目',
            style: const TextStyle(
              fontSize: 22,
              height: 1.25,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            hasTopic ? '录音归入主题后，可以在项目里继续找回原声。' : '项目会在后续版本接入；现在先用主题归档今天的录音。',
            style: const TextStyle(
              fontSize: 13,
              height: 1.4,
              color: Color(0xFFD7E5DA),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton(
                key: const ValueKey('today-open-projects'),
                onPressed: onOpenProjects,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  minimumSize: const Size(44, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('打开项目 ›'),
              ),
              if (onOpenTopic != null)
                TextButton(
                  onPressed: onOpenTopic,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFD7E5DA),
                    minimumSize: const Size(44, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text('打开主题 ›'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeviceStatusCard extends StatelessWidget {
  const _DeviceStatusCard({
    required this.connected,
    required this.name,
    required this.status,
    required this.onScan,
    required this.onOpenLibrary,
  });

  final bool connected;
  final String name;
  final String? status;
  final VoidCallback onScan;
  final VoidCallback onOpenLibrary;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      key: const ValueKey('today-device-status'),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          Icon(
            connected ? Icons.headphones_rounded : Icons.link_off_rounded,
            color: connected ? AppColors.mint : AppColors.textMuted,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  connected ? name : '未连接设备',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  connected
                      ? (status == null || status!.isEmpty ? '已连接' : status!)
                      : '扫描后连接录音豆；也可以直接导入本地音频。',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: connected ? onOpenLibrary : onScan,
            style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
            child: Text(connected ? '资料' : '扫描'),
          ),
        ],
      ),
    );
  }
}

class _NextActionCard extends StatelessWidget {
  const _NextActionCard({required this.pending, required this.onOpenProjects});

  final int pending;
  final VoidCallback onOpenProjects;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.borderStrong),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pending > 0 ? '$pending 条录音待归类' : '还没有下一步行动',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  pending > 0 ? '把它们放进主题，之后更容易找回原话。' : '行动与待办将在后续版本开放。',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (pending > 0)
            TextButton(
              onPressed: onOpenProjects,
              style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
              child: const Text('处理'),
            ),
        ],
      ),
    );
  }
}

class _ContinueListeningCard extends StatelessWidget {
  const _ContinueListeningCard({
    required this.path,
    required this.playing,
    required this.onToggle,
    required this.onOpen,
    required this.title,
    required this.subtitle,
    required this.onOpenLibrary,
  });

  final String? path;
  final bool playing;
  final VoidCallback onToggle;
  final VoidCallback? onOpen;
  final String? title;
  final String subtitle;
  final VoidCallback onOpenLibrary;

  @override
  Widget build(BuildContext context) {
    if (path == null) {
      return SurfaceCard(
        key: const ValueKey('continue-listening-empty'),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            const Icon(
              Icons.play_circle_outline_rounded,
              color: AppColors.textMuted,
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                '还没有回听中的资料',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              onPressed: onOpenLibrary,
              style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
              child: const Text('去资料'),
            ),
          ],
        ),
      );
    }
    return SurfaceCard(
      key: const ValueKey('continue-listening'),
      padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
      onTap: onOpen,
      child: Row(
        children: [
          IconButton(
            tooltip: playing ? '暂停播放' : '继续播放',
            onPressed: onToggle,
            style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: AppColors.mint,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title ?? '录音',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
    );
  }
}

class _TodayEmpty extends StatelessWidget {
  const _TodayEmpty({required this.onNewRecording, required this.onLibrary});

  final VoidCallback onNewRecording;
  final VoidCallback onLibrary;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      key: const ValueKey('today-empty'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '今天还没有记录',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            '录一段、导入一个文件，或从录音豆取回今天的录音。',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: onNewRecording,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('新记录'),
              ),
              OutlinedButton(onPressed: onLibrary, child: const Text('去资料')),
            ],
          ),
        ],
      ),
    );
  }
}
