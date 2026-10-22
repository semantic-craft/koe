import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:share_plus/share_plus.dart';

import '../../state/meeting_minutes.dart';
import '../../state/recording_analysis.dart';
import '../../state/recorder_controller.dart';
import '../../state/transcript_chapters.dart';
import '../transcript_jump.dart';
import 'minutes_mind_map.dart';
import '../../platform/device_kind.dart';

class MinutesPanel extends StatefulWidget {
  const MinutesPanel({
    super.key,
    required this.controller,
    required this.reference,
    this.onOpenSource,
  });
  final RecorderController controller;
  final RecordingReference reference;
  final ValueChanged<TranscriptJump>? onOpenSource;
  @override
  State<MinutesPanel> createState() => _MinutesPanelState();
}

class _MinutesPanelState extends State<MinutesPanel> {
  bool ready = false;
  String? loadError;
  RecordingAnalysis get manager => widget.controller.analysis;
  String get key =>
      '${widget.controller.analysisKey(widget.reference)}/minutes';
  @override
  void initState() {
    super.initState();
    manager.load().then(
      (_) {
        if (mounted) setState(() => ready = true);
      },
      onError: (Object _) {
        if (mounted) setState(() => loadError = '无法读取纪要，请重试');
      },
    );
  }

  Future<void> generate(AnalysisResult? previous) async {
    if (previous != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('重新生成纪要？'),
          content: const Text('生成成功后将替换当前纪要，包括手动修改。取消或生成失败会保留原纪要。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('保留'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('重新生成'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    final source = widget.controller.recordingView(widget.reference).text;
    final template = manager.requireTemplate(minutesTemplateId);
    await manager.run(
      recording: widget.controller.analysisKey(widget.reference),
      source: source,
      apiKey: widget.controller.analysisApiKey,
      custom: true,
      templateId: template.id,
      resultSlot: 'minutes',
      instruction: template.prompt,
      validateResult: validateMinutes,
      userNotes: widget.controller.analysisNotesFor(widget.reference),
      currentSource: () =>
          widget.controller.recordingAudioChanged(widget.reference)
          ? ''
          : widget.controller.recordingView(widget.reference).text,
    );
  }

  Future<void> export(MeetingMinutes minutes, AnalysisResult result) async {
    try {
      final content = minutes.export(result);
      if (runsOnPhone) {
        final box = context.findRenderObject() as RenderBox?;
        await SharePlus.instance.share(
          ShareParams(
            text: content,
            title: '会议纪要',
            sharePositionOrigin: box == null
                ? null
                : box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      } else {
        final location = await getSaveLocation(suggestedName: '会议纪要.md');
        if (location != null) await File(location.path).writeAsString(content);
      }
    } catch (_) {
      if (mounted) message('导出失败，请重试');
    }
  }

  void message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _openSource(
    int sourceIndex,
    String source,
    TranscriptSourceMatch? match,
  ) {
    if (match != null && widget.onOpenSource != null) {
      widget.onOpenSource!(
        TranscriptJump(
          segmentIndex: match.segmentIndex,
          start: match.start,
          snippet: match.snippet,
        ),
      );
      return;
    }
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('原文 [S${sourceIndex + 1}]'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (match == null)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text('无法可靠定位到原声；以下是模型使用的原文片段。'),
                ),
              SelectableText(source),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _compare(AnalysisResult current, AnalysisResult previous) async {
    String readable(AnalysisResult result) {
      try {
        return MeetingMinutes.parse(
          result.text,
          result.sources.length,
        ).export(result);
      } catch (_) {
        return result.text;
      }
    }

    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('与上一版对比'),
        content: SizedBox(
          width: 720,
          height: 480,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '上一版${previous.editedAt == null ? '（生成）' : '（人工编辑）'}',
                      style: Theme.of(c).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        child: SelectableText(readable(previous)),
                      ),
                    ),
                  ],
                ),
              ),
              const VerticalDivider(width: 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '当前版本${current.editedAt == null ? '（生成）' : '（人工编辑）'}',
                      style: Theme.of(c).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        child: SelectableText(readable(current)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> edit(MeetingMinutes minutes, AnalysisResult result) async {
    final title = TextEditingController(text: minutes.title);
    final overview = TextEditingController(text: minutes.overview);
    final fields =
        <
          (
            MinuteItem,
            TextEditingController,
            TextEditingController?,
            TextEditingController?,
          )
        >[
          for (final section in minutes.sections)
            for (final item in section.$2)
              (
                item,
                TextEditingController(text: item.text),
                item.owner == null
                    ? null
                    : TextEditingController(text: item.owner),
                item.due == null ? null : TextEditingController(text: item.due),
              ),
        ];
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('编辑纪要'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: '主题'),
                ),
                TextField(
                  controller: overview,
                  minLines: 2,
                  maxLines: null,
                  decoration: const InputDecoration(labelText: '概览'),
                ),
                for (final section in minutes.sections) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: Text(section.$1),
                  ),
                  for (final item in section.$2) ...[
                    TextField(
                      controller: fields
                          .firstWhere((f) => identical(f.$1, item))
                          .$2,
                      minLines: 1,
                      maxLines: null,
                      decoration: const InputDecoration(labelText: '内容'),
                    ),
                    if (item.owner != null) ...[
                      TextField(
                        controller: fields
                            .firstWhere((f) => identical(f.$1, item))
                            .$3,
                        decoration: const InputDecoration(labelText: '负责人'),
                      ),
                      TextField(
                        controller: fields
                            .firstWhere((f) => identical(f.$1, item))
                            .$4,
                        decoration: const InputDecoration(labelText: '期限'),
                      ),
                    ],
                  ],
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('保存修改'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      try {
        List<MinuteItem> edited(List<MinuteItem> items) => items.map((item) {
          final f = fields.firstWhere((f) => identical(f.$1, item));
          return MinuteItem(
            f.$2.text,
            item.sources,
            owner: f.$3?.text,
            due: f.$4?.text,
          );
        }).toList();
        final changed = MeetingMinutes(
          title: title.text,
          overview: overview.text,
          topics: edited(minutes.topics),
          decisions: edited(minutes.decisions),
          actions: edited(minutes.actions),
          questions: edited(minutes.questions),
        );
        await manager.editResult(
          key,
          result,
          validateMinutes(changed.encode(), result.sources),
        );
      } catch (_) {
        message('保存失败，请确认字段不为空，并重新打开最新纪要');
      }
    }
    // Dialog route finishes its exit animation before disposing its controllers.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    title.dispose();
    overview.dispose();
    for (final f in fields) {
      f.$2.dispose();
      f.$3?.dispose();
      f.$4?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([manager, widget.controller]),
    builder: (context, _) {
      final view = widget.controller.recordingView(widget.reference);
      final result = manager.results[key];
      final previous = manager.previousResults[key];
      MeetingMinutes? minutes;
      if (result != null) {
        try {
          minutes = MeetingMinutes.parse(result.text, result.sources.length);
        } catch (_) {}
      }
      final busy = manager.busy(key);
      final running = manager.running(key);
      final notes = widget.controller.bookmarksFor(widget.reference).length;
      final sourceMatches = <int, TranscriptSourceMatch>{};
      if (result != null &&
          result.sourceHash == analysisFingerprint(view.text) &&
          !widget.controller.recordingAudioChanged(widget.reference) &&
          view.originalPresent &&
          view.path != null) {
        final aliases = widget.controller.speakerAliasesForPath(view.path!);
        final timed =
            transcriptSegmentsMatchText(
              view.segments,
              view.text,
              aliases: aliases,
            ) &&
            transcriptSegmentsLocatable(
              view.segments,
              duration: widget.controller.localDurationForPath(view.path!),
            );
        if (timed) {
          for (final match in matchTranscriptSources(
            sources: result.sources,
            segments: view.segments,
            aliases: aliases,
            duration: widget.controller.localDurationForPath(view.path!),
          )) {
            sourceMatches[match.sourceIndex] = match;
          }
        }
      }
      return Scaffold(
        appBar: AppBar(
          title: const Text('结构化纪要'),
          actions: [
            TextButton(
              onPressed: minutes == null
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => MinutesMindMap(
                          controller: widget.controller,
                          reference: widget.reference,
                        ),
                      ),
                    ),
              child: const Text('思维导图'),
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(view.title, style: Theme.of(context).textTheme.titleLarge),
              const Text('千问 Qwen3.8-Flash · 通用会议纪要'),
              if (loadError != null) Text(loadError!),
              if (view.text.trim().isEmpty) const Text('请先完成转写'),
              if (widget.controller.analysisApiKey.isEmpty)
                const Text('请先在设置中配置千问 API Key'),
              const SizedBox(height: 12),
              if (busy) ...[
                const LinearProgressIndicator(),
                Text(manager.progress[key] ?? '正在整理纪要'),
                if (running)
                  TextButton(
                    onPressed: () => manager.cancel(key),
                    child: const Text('取消生成'),
                  ),
              ] else
                FilledButton(
                  onPressed:
                      !ready ||
                          widget.controller.recordingAudioChanged(
                            widget.reference,
                          ) ||
                          view.live ||
                          view.text.trim().isEmpty ||
                          widget.controller.analysisApiKey.isEmpty
                      ? null
                      : () => generate(result),
                  child: Text(result == null ? '生成纪要' : '重新生成纪要'),
                ),
              if (!busy && notes > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '生成时一并参考这条录音的 $notes 条书签（笔记和重点）。',
                    key: const ValueKey('minutes-notes-hint'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (manager.errors[key] != null) Text(manager.errors[key]!),
              if (result != null &&
                  (widget.controller.recordingAudioChanged(widget.reference) ||
                      result.sourceHash != analysisFingerprint(view.text)))
                const Text('原文已更新，这份纪要已过期，请重新生成。'),
              if (result != null && minutes == null)
                const Text('纪要格式无效，请重新生成；原数据仍保留。'),
              if (result != null && minutes != null) ...[
                const SizedBox(height: 16),
                Text(
                  minutes.title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                SelectableText(minutes.overview),
                Text(
                  '${result.model} · ${result.editedAt == null ? '已生成' : '已手动编辑'}',
                ),
                Wrap(
                  spacing: 12,
                  children: [
                    TextButton(
                      onPressed: busy ? null : () => edit(minutes!, result),
                      child: const Text('编辑纪要'),
                    ),
                    TextButton(
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: minutes!.export(result)),
                      ),
                      child: const Text('复制纪要'),
                    ),
                    TextButton(
                      onPressed: () => export(minutes!, result),
                      child: const Text('导出纪要'),
                    ),
                    if (previous != null)
                      TextButton(
                        onPressed: () => _compare(result, previous),
                        child: const Text('对比上一版'),
                      ),
                  ],
                ),
                for (final section in minutes.sections) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      section.$1,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (section.$2.isEmpty) const Text('未提及'),
                  for (final item in section.$2)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(item.text),
                            if (item.owner != null)
                              Text('负责人：${item.owner} · 期限：${item.due}'),
                            Wrap(
                              spacing: 4,
                              children: [
                                for (final sourceIndex
                                    in item.sources
                                        .map(
                                          (id) =>
                                              int.parse(id.substring(1)) - 1,
                                        )
                                        .where(
                                          (index) =>
                                              index >= 0 &&
                                              index < result.sources.length,
                                        ))
                                  TextButton(
                                    onPressed: () => _openSource(
                                      sourceIndex,
                                      result.sources[sourceIndex],
                                      sourceMatches[sourceIndex],
                                    ),
                                    child: Text(
                                      sourceMatches[sourceIndex] == null
                                          ? '出处 [S${sourceIndex + 1}]'
                                          : '出处 [S${sourceIndex + 1}] '
                                                '${_time(sourceMatches[sourceIndex]!.start)}',
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ],
            ],
          ),
        ),
      );
    },
  );
}

String _time(Duration value) {
  final total = value.inSeconds.clamp(0, 359999);
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int part) => part.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}
