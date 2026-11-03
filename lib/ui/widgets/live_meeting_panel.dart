import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/recorder_controller.dart';
import '../../state/meeting_minutes.dart';

class LiveMeetingPanel extends StatelessWidget {
  const LiveMeetingPanel({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    if (c.liveMeetingId == null) return const SizedBox.shrink();
    final m = c.liveMinutes, captions = c.liveCaptions;
    return ExpansionTile(
      title: const Text('实时纪要与双语字幕'),
      subtitle: Text(c.liveMeetingClosing ? '本场已收尾' : '本场手动开启 · 使用已配置的文字服务'),
      children: [
        SizedBox(
          height: 320,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!kIsWeb &&
                    defaultTargetPlatform == TargetPlatform.macOS) ...[
                  Wrap(
                    children: [
                      TextButton(
                        onPressed: c.cycleLiveDisplay,
                        child: const Text('字幕条 / 纪要窗口 / 隐藏'),
                      ),
                      TextButton(
                        onPressed: () => c.setLiveDisplayMode('hidden'),
                        child: const Text('立即隐藏'),
                      ),
                    ],
                  ),
                  const Text('字幕窗口穿透鼠标；屏幕共享可能仍可见，请按会议软件验证。'),
                ],
                if (c.liveMeetingNotice != null) Text(c.liveMeetingNotice!),
                SwitchListTile(
                  title: const Text('实时整理'),
                  subtitle: const Text('最多每小时120次增量请求'),
                  value: c.liveMinutesEnabled,
                  onChanged: c.liveMeetingAvailable && !c.liveMeetingClosing
                      ? (v) => c.setLiveMinutesEnabled(v)
                      : null,
                ),
                SwitchListTile(
                  title: const Text('双语字幕'),
                  subtitle: Text(
                    '目标语种：${c.translationTargetLanguage} · 其它语种在设置中选择',
                  ),
                  value: c.liveCaptionsEnabled,
                  onChanged: c.liveMeetingAvailable && !c.liveMeetingClosing
                      ? (v) => c.setLiveCaptionsEnabled(v)
                      : null,
                ),
                if (captions?.error != null) Text(captions!.error!),
                if (captions?.paused == true && !c.liveMeetingClosing)
                  TextButton(
                    onPressed: () => captions!.resume(),
                    child: const Text('恢复字幕翻译'),
                  ),
                for (final entry in captions?.entries ?? [])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${entry.sourceLanguage} · ${entry.provider.isEmpty ? '所选语种' : entry.provider}',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        SelectableText(entry.text),
                        if (entry.translation != null)
                          SelectableText(entry.translation!),
                      ],
                    ),
                  ),
                if (c.liveMeetingId?.startsWith('phone:') == true &&
                    !c.liveMeetingClosing) ...[
                  const Divider(),
                  SwitchListTile(
                    title: const Text('本场会议自动结束'),
                    subtitle: Text(c.meetingEndWatch.status),
                    value: c.meetingEndWatch.enabled,
                    onChanged: (v) {
                      if (!v) {
                        c.setMeetingAutoEnd(false);
                      } else {
                        c.setMeetingAutoEnd(true);
                        if (!c.meetingEndWatch.enabled) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('须先检测到唯一会议应用和可用的麦克风状态'),
                            ),
                          );
                        }
                      }
                    },
                  ),
                  if (c.meetingEndWatch.remainingSeconds != null)
                    TextButton(
                      onPressed: c.meetingEndWatch.cancelCountdown,
                      child: const Text('继续录音，取消本次倒计时'),
                    ),
                ],
                if (m != null) ...[
                  const Divider(),
                  Text(
                    m.busy
                        ? '速记更新中…'
                        : m.paused
                        ? '实时整理已暂停'
                        : '实时速记 · 未校对',
                  ),
                  if (m.error != null) Text(m.error!),
                  if (m.result case final result?)
                    SelectableText(
                      MeetingMinutes.parse(
                        result.text,
                        result.sources.length,
                        sourceTexts: result.sources,
                      ).export(result),
                    ),
                  if (m.active != null && !c.liveMeetingClosing)
                    Wrap(
                      children: [
                        TextButton(
                          onPressed: () => _edit(context, c),
                          child: const Text('编辑速记（暂停自动更新）'),
                        ),
                        if (m.paused)
                          TextButton(
                            onPressed: () => m.resume(),
                            child: const Text('恢复生成候选（新请求）'),
                          ),
                        if (m.candidate != null)
                          TextButton(
                            onPressed: () async {
                              final take = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('切换到机器候选？'),
                                  content: SingleChildScrollView(
                                    child: Text(m.candidate!),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('保留手改'),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('采用候选'),
                                    ),
                                  ],
                                ),
                              );
                              if (take == true) await m.acceptCandidate();
                            },
                            child: const Text('查看机器候选'),
                          ),
                      ],
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, RecorderController c) async {
    final m = c.liveMinutes!;
    try {
      await m.pauseForEdit();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂停状态未保存，暂不能编辑')));
      }
      return;
    }
    if (!context.mounted) return;
    final body = jsonDecode(m.active!) as Map<String, dynamic>;
    final title = TextEditingController(text: body['title'] as String),
        overview = TextEditingController(text: body['overview'] as String);
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑速记'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: '标题'),
              ),
              TextField(
                controller: overview,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(labelText: '概览'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (save == true) {
      body['title'] = title.text;
      body['overview'] = overview.text;
      try {
        await m.edit(jsonEncode(body));
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('速记保存失败，原版仍保留')));
        }
      }
    }
    // Dialog route may finish its exit animation after the result future.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    title.dispose();
    overview.dispose();
  }
}
