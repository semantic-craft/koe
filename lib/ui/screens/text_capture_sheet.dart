import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/highlight.dart';
import '../widgets/status_indicators.dart';

/// Text-only capture: listens until the user ends it, showing the text as
/// the speech service recognizes it. Like a phone take, the sheet cannot be
/// swiped away while listening, so the controls stay in reach; capture keeps
/// going with the screen locked.
/// With [allDay] it starts all-day listening (#319), which keeps running
/// after the sheet is put away.
Future<void> showTextCaptureSheet(
  BuildContext context, {
  bool allDay = false,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final controller = context.read<RecorderController>();
  final dismissible = allDay || controller.textCaptureAllDay;
  final outcome = await showModalBottomSheet<TextCaptureOutcome>(
    context: context,
    sheetAnimationStyle: AppMotion.sheetStyle(context),
    isDismissible: dismissible,
    enableDrag: dismissible,
    isScrollControlled: true,
    builder: (_) => TextCapturePanel(allDay: allDay),
  );
  if (outcome != null) {
    messenger.showSnackBar(SnackBar(content: Text(outcome.message)));
  }
}

class TextCapturePanel extends StatefulWidget {
  const TextCapturePanel({super.key, this.allDay = false});

  final bool allDay;

  @override
  State<TextCapturePanel> createState() => _TextCapturePanelState();
}

class _TextCapturePanelState extends State<TextCapturePanel> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = context.read<RecorderController>();
      if (!controller.textCaptureActive) {
        unawaited(controller.startTextCapture(allDay: widget.allDay));
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _stop({required bool keepAudio}) async {
    final outcome = await context.read<RecorderController>().stopTextCapture(
      keepAudio: keepAudio,
    );
    if (!mounted || outcome == null) return;
    Navigator.of(context).pop(outcome);
  }

  Future<void> _discard() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('放弃这次记录？'),
        content: const Text('识别出的文字会被删除，无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('继续记录'),
          ),
          TextButton(
            key: const ValueKey('confirm-discard-text-capture'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<RecorderController>().discardTextCapture();
    if (mounted) Navigator.of(context).pop();
  }

  /// System back while listening (not all day, which just collapses):
  /// leaving ends the capture, so confirm first and save the text on yes.
  Future<void> _confirmLeave() async {
    if (context.read<RecorderController>().textCaptureStopping) return;
    final leave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('正在记录'),
        content: const Text('返回会结束这次记录并保存文字。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('继续记录'),
          ),
          TextButton(
            key: const ValueKey('confirm-leave-text-capture'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('结束并保存'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) await _stop(keepAudio: false);
  }

  String _clock(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final hours = d.inHours;
    final rest =
        '${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
    return hours > 0 ? '$hours:$rest' : rest;
  }

  String _status(RecorderController c) {
    if (c.textCaptureStopping) return '正在收尾，保存文字…';
    if (c.textCaptureError != null) return c.textCaptureError!;
    if (c.textCapturePaused) return '系统暂停了麦克风（如来电），结束后会自动继续';
    if (c.textCaptureResting) {
      final saved = c.textCaptureFinishedRecords;
      return saved > 0 ? '安静中，说话时自动接上 · 已分出 $saved 条' : '安静中，说话时自动接上';
    }
    if (!c.textCaptureConnected) return '正在连接语音服务…';
    final backlog = c.textCaptureBacklogSeconds;
    if (backlog >= 2) return '正在补识别断线时的 $backlog 秒';
    return '正在识别 · 只留文字，不存录音';
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<RecorderController>();
    final active = controller.textCaptureActive;
    final stopping = controller.textCaptureStopping;
    final text = controller.textCaptureText;
    final lines = controller.textCaptureLines;
    final listening = active && !controller.textCapturePaused;
    final allDay = controller.textCaptureAllDay || widget.allDay;
    return PopScope(
      canPop: !active || allDay,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmLeave());
      },
      child: SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.72,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (listening) ...[
                      const BreathingDot(),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      allDay
                          ? (active ? '全天监听中' : '全天监听')
                          : (active ? '纯文字记录中' : '纯文字记录'),
                      key: const ValueKey('text-capture-title'),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _clock(controller.textCaptureElapsed),
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  _status(controller),
                  key: const ValueKey('text-capture-status'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.bgPanel,
                      borderRadius: BorderRadius.circular(AppRadii.card),
                    ),
                    child: SingleChildScrollView(
                      reverse: true,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Text.rich(
                          TextSpan(
                            children: text.isEmpty
                                ? const [TextSpan(text: '开口说吧，识别出的文字会出现在这里。')]
                                : [
                                    for (final (index, (line, marked))
                                        in lines.indexed)
                                      TextSpan(
                                        text: index == 0 ? line : '\n$line',
                                        style: marked
                                            ? highlightTextStyle(context)
                                            : null,
                                      ),
                                  ],
                          ),
                          key: const ValueKey('text-capture-text'),
                          style: TextStyle(
                            fontSize: 16,
                            height: 1.5,
                            color: text.isEmpty
                                ? AppColors.textSecondary
                                : AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (active) ...[
                  OutlinedButton.icon(
                    key: const ValueKey('mark-text-capture'),
                    onPressed: stopping || text.isEmpty
                        ? null
                        : controller.markTextCaptureHighlight,
                    icon: const Icon(Icons.star_outline_rounded),
                    label: const Text('标记这句为重点'),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    key: const ValueKey('stop-text-capture'),
                    onPressed: stopping ? null : () => _stop(keepAudio: false),
                    icon: const Icon(Icons.stop_rounded),
                    label: Text(allDay ? '结束全天监听并保存' : '结束并保存文字'),
                  ),
                  if (allDay)
                    TextButton(
                      key: const ValueKey('hide-text-capture'),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('收起，继续在后台监听'),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          key: const ValueKey('stop-text-capture-keep-audio'),
                          onPressed: stopping
                              ? null
                              : () => _stop(keepAudio: true),
                          child: const Text('结束，这次也保留原声'),
                        ),
                      ),
                      Expanded(
                        child: TextButton(
                          key: const ValueKey('discard-text-capture'),
                          onPressed: stopping ? null : _discard,
                          child: const Text('放弃这次记录'),
                        ),
                      ),
                    ],
                  ),
                ] else
                  TextButton(
                    key: const ValueKey('close-text-capture'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
