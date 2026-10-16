import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../state/recorder_controller.dart';
import '../../state/recording_analysis.dart';
import '../../theme/app_theme.dart';

class TopicNotePanel extends StatefulWidget {
  const TopicNotePanel({
    super.key,
    required this.controller,
    required this.reference,
    this.onSelectParagraph,
  });

  final RecorderController controller;
  final RecordingReference reference;
  final ValueChanged<int>? onSelectParagraph;

  @override
  State<TopicNotePanel> createState() => _TopicNotePanelState();
}

class _TopicNotePanelState extends State<TopicNotePanel> {
  final _overviewController = TextEditingController();
  bool _editing = false;

  @override
  void dispose() {
    _overviewController.dispose();
    super.dispose();
  }

  Future<void> _confirmRegenerate(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重生成主题笔记？'),
        content: const Text('重新生成会覆盖当前内容（包括手动修改）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('重生成'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await widget.controller.generateTopicNote(widget.reference);
    }
  }

  Future<void> _saveOverview(
    String slotKey,
    AnalysisResult result,
    TopicNote note,
  ) async {
    final nextOverview = _overviewController.text.trim();
    if (nextOverview.isEmpty) return;
    final updated = note.copyWith(overview: nextOverview);
    await widget.controller.analysis.editResult(
      slotKey,
      result,
      updated.encode(),
    );
    if (mounted) {
      setState(() => _editing = false);
    }
  }

  Future<void> _shareNote(
    AnalysisResult result,
    TopicNote note,
    Topic? topic,
  ) async {
    final text = note.export(result, topic: topic);
    if (Platform.isIOS) {
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          text: text,
          title: topic?.title ?? '主题笔记',
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } else {
      await Clipboard.setData(ClipboardData(text: text));
    }
  }

  Widget _buildSourceChips({
    required List<String> sources,
    required String itemText,
    required AnalysisResult result,
  }) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final sourceId in sources)
          ActionChip(
            key: ValueKey('topic-note-source-$sourceId'),
            label: Text(sourceId, style: const TextStyle(fontSize: 12)),
            visualDensity: VisualDensity.compact,
            onPressed: () {
              final transcript = widget.controller
                  .recordingView(widget.reference)
                  .text;
              final index = locateTranscriptParagraph(
                transcript,
                [sourceId],
                itemText: itemText,
                sourceBlocks: result.sources,
              );
              if (index >= 0) {
                widget.onSelectParagraph?.call(index);
              }
            },
          ),
      ],
    );
  }

  Widget _buildSectionTitle(String title) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 8),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
    ),
  );

  Widget _buildSimpleSection(
    String title,
    List<TopicNoteItem> items,
    AnalysisResult result,
  ) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionTitle(title),
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.text, style: const TextStyle(height: 1.5)),
                const SizedBox(height: 4),
                _buildSourceChips(
                  sources: item.sources,
                  itemText: item.text,
                  result: result,
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.controller,
        widget.controller.topics,
        widget.controller.analysis,
      ]),
      builder: (context, _) {
        final key = widget.controller.recordingKeyFor(widget.reference);
        final topic = widget.controller.topics.topicOf(key);
        final slotKey = TopicNote.slotKey(key);
        final analysis = widget.controller.analysis;
        final busy = analysis.busy(slotKey);
        final progress = analysis.progress[slotKey];
        final error = analysis.errors[slotKey];
        final result = analysis.results[slotKey];
        final note = result == null
            ? null
            : TopicNote.tryParse(
                result.text,
                result.sources.isEmpty ? 1 : result.sources.length,
                fallbackKind: topic?.kind,
                fallbackTopicId: topic?.id,
              );
        final stale = widget.controller.isTopicNoteStale(widget.reference);

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      topic == null ? '主题笔记' : '${topic.title} · 主题笔记',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (note != null && !busy && !_editing) ...[
                    TextButton(
                      onPressed: () {
                        _overviewController.text = note.overview;
                        setState(() => _editing = true);
                      },
                      child: const Text('编辑'),
                    ),
                    const SizedBox(width: 4),
                    OutlinedButton(
                      onPressed: () => _confirmRegenerate(context),
                      child: const Text('重生成'),
                    ),
                    IconButton(
                      tooltip: '复制笔记',
                      icon: const Icon(Icons.copy_outlined),
                      onPressed: () => Clipboard.setData(
                        ClipboardData(
                          text: note.export(result!, topic: topic),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '分享笔记',
                      icon: const Icon(Icons.ios_share_rounded),
                      onPressed: () => _shareNote(result!, note, topic),
                    ),
                  ],
                ],
              ),
              if (stale && note != null)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    '原文或所属主题已变化，当前笔记可能已过期',
                    style: TextStyle(color: AppColors.coral, fontSize: 13),
                  ),
                ),
              if (busy)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(progress ?? '正在生成主题笔记…'),
                      const SizedBox(height: 8),
                      const LinearProgressIndicator(minHeight: 3),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => analysis.cancel(slotKey),
                          child: const Text('取消'),
                        ),
                      ),
                    ],
                  ),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          error,
                          style: const TextStyle(color: AppColors.coral),
                        ),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => widget.controller.generateTopicNote(
                                widget.reference,
                              ),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              if (note == null && !busy)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: FilledButton(
                    onPressed: () =>
                        widget.controller.generateTopicNote(widget.reference),
                    child: const Text('生成主题笔记'),
                  ),
                ),
              if (note != null && result != null) ...[
                const SizedBox(height: 12),
                if (_editing) ...[
                  TextField(
                    key: const ValueKey('topic-note-edit-overview'),
                    controller: _overviewController,
                    maxLines: null,
                    decoration: const InputDecoration(labelText: '本次概要'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => setState(() => _editing = false),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () => _saveOverview(slotKey, result, note),
                        child: const Text('保存'),
                      ),
                    ],
                  ),
                ] else
                  Text(
                    note.overview,
                    style: const TextStyle(fontSize: 16, height: 1.55),
                  ),
                if (note.kind == TopicKind.book) ...[
                  if (note.excerpts.isNotEmpty) ...[
                    _buildSectionTitle('原文摘录'),
                    for (final excerpt in note.excerpts)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (excerpt.page != null)
                              Text(
                                excerpt.page!,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            Text(
                              excerpt.text,
                              style: const TextStyle(height: 1.5),
                            ),
                            const SizedBox(height: 4),
                            _buildSourceChips(
                              sources: excerpt.sources,
                              itemText: excerpt.text,
                              result: result,
                            ),
                          ],
                        ),
                      ),
                  ],
                  if (note.comments.isNotEmpty) ...[
                    _buildSectionTitle('我的评论'),
                    for (final comment in note.comments)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              comment.text,
                              style: const TextStyle(height: 1.5),
                            ),
                            if (comment.excerpt != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  '对应摘录：${comment.excerpt}',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ),
                            const SizedBox(height: 4),
                            _buildSourceChips(
                              sources: comment.sources,
                              itemText: comment.excerpt ?? comment.text,
                              result: result,
                            ),
                          ],
                        ),
                      ),
                  ],
                  _buildSimpleSection('疑问', note.questions, result),
                  _buildSimpleSection('联想', note.associations, result),
                  _buildSimpleSection('待查', note.toCheck, result),
                ] else ...[
                  if (note.ideas.isNotEmpty) ...[
                    _buildSectionTitle('主要想法'),
                    for (final idea in note.ideas)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              idea.text,
                              style: const TextStyle(height: 1.5),
                            ),
                            if (idea.reason != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  '理由：${idea.reason}',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ),
                            const SizedBox(height: 4),
                            _buildSourceChips(
                              sources: idea.sources,
                              itemText: idea.text,
                              result: result,
                            ),
                          ],
                        ),
                      ),
                  ],
                  _buildSimpleSection('与此前笔记的变化', note.changes, result),
                  _buildSimpleSection('疑问', note.questions, result),
                  _buildSimpleSection('联想', note.associations, result),
                  _buildSimpleSection('待办/待查', note.todos, result),
                  if (note.conclusion != null)
                    _buildSimpleSection(
                      '倾向的结论',
                      [note.conclusion!],
                      result,
                    ),
                ],
              ],
            ],
          ),
        );
      },
    );
  }
}
