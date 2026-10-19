import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../recording_navigation.dart';
import '../widgets/context_export_sheet.dart';
import '../widgets/context_timeline.dart';
import '../widgets/mobile_header.dart';
import '../widgets/morning_brief_card.dart';
import '../widgets/scan_sheet.dart';
import '../widgets/widgets.dart';
import 'diary_screen.dart';
import 'new_recording_sheet.dart';
import 'project_detail_screen.dart';
import 'todos_screen.dart';
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
    final focus = c.focusProject;
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
                  project: focus,
                  progress: focus == null ? null : c.projectProgress(focus.id),
                  topicTitle: currentTopic?.title,
                  onOpenProjects: () => focus == null
                      ? RecordingNavigation.of(context)?.onSelectTab?.call(1)
                      : openProject(context, focus.id),
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
                if (c.organizeStore.queued.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _OrganizeProgressCard(
                    progress: c.organizeProgress,
                    onOpenLibrary: () =>
                        RecordingNavigation.of(context)?.onSelectTab?.call(2),
                  ),
                ],
                const SizedBox(height: 22),
                const SectionLabel('下一步行动'),
                _ActionsSection(
                  today: today,
                  pendingTopics: pending,
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
                const MorningBriefCard(),
                const SizedBox(height: 22),
                const SectionLabel('日记'),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('today-diary'),
                      onPressed: () => openDiary(context, weekly: false),
                      icon: const Icon(Icons.menu_book_outlined, size: 18),
                      label: const Text('今天的日记'),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('today-week'),
                      onPressed: () => openDiary(context, weekly: true),
                      icon: const Icon(Icons.date_range_outlined, size: 18),
                      label: const Text('本周小结'),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                SectionLabel(
                  '今日时间线',
                  trailing: today.isEmpty
                      ? null
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              key: const ValueKey('today-export'),
                              tooltip: '导出给外部 AI',
                              onPressed: () => showContextExportSheet(
                                context,
                                DayExport(now),
                              ),
                              icon: const Icon(
                                Icons.ios_share_rounded,
                                size: 20,
                              ),
                            ),
                            TextButton(
                              onPressed: () => RecordingNavigation.of(
                                context,
                              )?.onSelectTab?.call(2),
                              child: const Text('全部资料'),
                            ),
                          ],
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
    required this.project,
    required this.progress,
    required this.topicTitle,
    required this.onOpenProjects,
    this.onOpenTopic,
  });

  final Project? project;
  final ProjectProgress? progress;
  final String? topicTitle;
  final VoidCallback onOpenProjects;
  final VoidCallback? onOpenTopic;

  @override
  Widget build(BuildContext context) {
    final hasTopic = topicTitle != null && topicTitle!.trim().isNotEmpty;
    final String eyebrow;
    final String title;
    final String body;
    if (project != null) {
      eyebrow = '正在推进 · 最近有进展的项目';
      title = project!.title;
      body = projectNextLabel(progress!);
    } else if (hasTopic) {
      eyebrow = '正在推进 · 当前主题';
      title = topicTitle!;
      body = '录音归入主题后，可以在主题里继续找回原声。';
    } else {
      eyebrow = '当前重点项目';
      title = '今天还没有重点项目';
      body = '新建一个项目，把跨天的录音和待办放在一起。';
    }
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
            eyebrow,
            style: const TextStyle(
              fontSize: 12,
              letterSpacing: 0.4,
              color: Color(0xFFD7E5DA),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            style: const TextStyle(
              fontSize: 22,
              height: 1.25,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
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
                child: Text(project == null ? '打开项目 ›' : '打开这个项目 ›'),
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

/// Automatic organizing at a glance; the library rows carry the detail.
class _OrganizeProgressCard extends StatelessWidget {
  const _OrganizeProgressCard({
    required this.progress,
    required this.onOpenLibrary,
  });

  final ({int waiting, int working, int attention}) progress;
  final VoidCallback onOpenLibrary;

  @override
  Widget build(BuildContext context) {
    final parts = [
      if (progress.working > 0) '${progress.working} 条整理中',
      if (progress.waiting > 0) '${progress.waiting} 条待整理',
      if (progress.attention > 0) '${progress.attention} 条需要你处理',
    ];
    return Material(
      key: const ValueKey('today-organize'),
      color: AppColors.bgCard,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onOpenLibrary,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(
                progress.attention > 0
                    ? Icons.error_outline_rounded
                    : Icons.auto_awesome_outlined,
                color: progress.attention > 0
                    ? AppColors.coral
                    : AppColors.textSecondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '自动整理：${parts.isEmpty ? '处理中' : parts.join(' · ')}',
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
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

/// My open todos with completion controls, unclear sentences waiting for
/// the user, and an on-demand extraction from today's transcripts.
class _ActionsSection extends StatefulWidget {
  const _ActionsSection({
    required this.today,
    required this.pendingTopics,
    required this.onOpenProjects,
  });

  final List<ContextItem> today;
  final int pendingTopics;
  final VoidCallback onOpenProjects;

  @override
  State<_ActionsSection> createState() => _ActionsSectionState();
}

class _ActionsSectionState extends State<_ActionsSection> {
  bool _extracting = false;

  @override
  void initState() {
    super.initState();
    context.read<RecorderController>().syncSystemLinks();
  }

  Future<void> _extract() async {
    final c = context.read<RecorderController>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _extracting = true);
    var added = 0;
    String? problem;
    try {
      for (final item in widget.today) {
        final ref = c.contextReference(item);
        final path = ref?.path;
        if (ref == null || path == null) continue;
        if ((c.transcriptForPath(path) ?? '').trim().isEmpty) continue;
        var retry = false;
        if (c.todoExtractionUnknown(ref)) {
          retry = await _confirmRetry(item.title);
          if (!retry) continue;
        }
        try {
          added += await c.extractTodos(ref, confirmRetry: retry);
        } on StateError catch (error) {
          problem = error.message.toString();
        } catch (_) {
          problem = '「${item.title}」提取失败，可稍后重试';
        }
        if (!mounted) return;
      }
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(problem ?? (added == 0 ? '没有发现新的承诺' : '新增 $added 条待办')),
      ),
    );
  }

  Future<bool> _confirmRetry(String title) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('上次提取结果未知'),
        content: Text('「$title」上次提取没有返回结果，可能已经计费。确认重新提取？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('跳过'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('重新提取'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final mine = c.todos.openMine;
    final asks = c.todos.clarifications.length;
    final canExtract = widget.today.any((item) {
      final path = c.contextReference(item)?.path;
      return path != null &&
          (c.transcriptForPath(path) ?? '').trim().isNotEmpty;
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (mine.isEmpty)
          const SurfaceCard(
            key: ValueKey('today-no-todos'),
            padding: EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Text(
              '还没有待办。转写后点「提取待办」，Koe 只会记下你明确答应要做的事。',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          )
        else
          for (final todo in mine.take(5)) TodoRow(todo: todo),
        if (asks > 0)
          _ActionLink(
            label: '$asks 条需要确认是哪件事',
            action: '处理',
            onTap: () => openTodos(context),
          ),
        if (widget.pendingTopics > 0)
          _ActionLink(
            label: '${widget.pendingTopics} 条录音待归类',
            action: '处理',
            onTap: widget.onOpenProjects,
          ),
        Wrap(
          spacing: 8,
          children: [
            if (canExtract)
              TextButton.icon(
                key: const ValueKey('today-extract-todos'),
                onPressed: _extracting ? null : _extract,
                icon: _extracting
                    ? const SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_outlined, size: 18),
                label: Text(_extracting ? '提取中…' : '提取待办'),
              ),
            TextButton(
              key: const ValueKey('today-all-todos'),
              onPressed: () => openTodos(context),
              child: const Text('全部待办'),
            ),
          ],
        ),
      ],
    );
  }
}

class _ActionLink extends StatelessWidget {
  const _ActionLink({
    required this.label,
    required this.action,
    required this.onTap,
  });

  final String label;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SurfaceCard(
        padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              onPressed: onTap,
              style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
              child: Text(action),
            ),
          ],
        ),
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
