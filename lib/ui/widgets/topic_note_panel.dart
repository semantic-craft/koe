import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../state/recorder_controller.dart';
import '../../state/recording_analysis.dart';
import '../../theme/app_theme.dart';
import 'koe_icon_button.dart';
import '../../platform/device_kind.dart';

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
  final Map<String, TextEditingController> _editors = {};
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.refreshCachedAudioVersion(widget.reference));
  }

  @override
  void didUpdateWidget(TopicNotePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reference.key != widget.reference.key) {
      _editing = false;
      unawaited(widget.controller.refreshCachedAudioVersion(widget.reference));
    }
  }

  @override
  void dispose() {
    for (final controller in _editors.values) {
      controller.dispose();
    }
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

  void _beginEdit(TopicNote note) {
    for (final controller in _editors.values) {
      controller.dispose();
    }
    _editors.clear();
    void add(String id, String text) {
      _editors[id] = TextEditingController(text: text);
    }

    add('overview', note.overview);
    for (var i = 0; i < note.excerpts.length; i++) {
      add('excerpt-$i', note.excerpts[i].text);
      add('excerpt-page-$i', note.excerpts[i].page ?? '');
    }
    for (var i = 0; i < note.comments.length; i++) {
      add('comment-$i', note.comments[i].text);
      add('comment-excerpt-$i', note.comments[i].excerpt ?? '');
    }
    for (var i = 0; i < note.ideas.length; i++) {
      add('idea-$i', note.ideas[i].text);
      add('idea-reason-$i', note.ideas[i].reason ?? '');
    }
    for (final section in [
      ('change', note.changes),
      ('question', note.questions),
      ('association', note.associations),
      ('to-check', note.toCheck),
      ('todo', note.todos),
    ]) {
      for (var i = 0; i < section.$2.length; i++) {
        add('${section.$1}-$i', section.$2[i].text);
      }
    }
    if (note.conclusion != null) add('conclusion', note.conclusion!.text);
    setState(() => _editing = true);
  }

  void _cancelEdit() {
    setState(() => _editing = false);
  }

  Future<void> _saveNote(
    String slotKey,
    AnalysisResult result,
    TopicNote note,
  ) async {
    String required(String id) => _editors[id]!.text.trim();
    String? optional(String id) {
      final value = _editors[id]!.text.trim();
      return value.isEmpty ? null : value;
    }

    final overview = required('overview');
    final requiredIds = <String>[
      'overview',
      for (var i = 0; i < note.excerpts.length; i++) 'excerpt-$i',
      for (var i = 0; i < note.comments.length; i++) 'comment-$i',
      for (var i = 0; i < note.ideas.length; i++) 'idea-$i',
      for (final section in [
        ('change', note.changes),
        ('question', note.questions),
        ('association', note.associations),
        ('to-check', note.toCheck),
        ('todo', note.todos),
      ])
        for (var i = 0; i < section.$2.length; i++) '${section.$1}-$i',
      if (note.conclusion != null) 'conclusion',
    ];
    if (overview.isEmpty ||
        requiredIds.any((id) => _editors[id]!.text.trim().isEmpty)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('笔记内容不能为空')));
      return;
    }

    final updated = note.copyWith(
      overview: overview,
      excerpts: note.kind == TopicKind.book
          ? [
              for (var i = 0; i < note.excerpts.length; i++)
                TopicExcerpt(
                  text: required('excerpt-$i'),
                  page: optional('excerpt-page-$i'),
                  sources: note.excerpts[i].sources,
                ),
            ]
          : null,
      comments: note.kind == TopicKind.book
          ? [
              for (var i = 0; i < note.comments.length; i++)
                TopicComment(
                  text: required('comment-$i'),
                  excerpt: optional('comment-excerpt-$i'),
                  sources: note.comments[i].sources,
                ),
            ]
          : null,
      ideas: note.kind == TopicKind.general
          ? [
              for (var i = 0; i < note.ideas.length; i++)
                TopicIdea(
                  text: required('idea-$i'),
                  reason: optional('idea-reason-$i'),
                  sources: note.ideas[i].sources,
                ),
            ]
          : null,
      changes: _editedItems(note.changes, 'change', required),
      questions: _editedItems(note.questions, 'question', required),
      associations: _editedItems(note.associations, 'association', required),
      toCheck: _editedItems(note.toCheck, 'to-check', required),
      todos: _editedItems(note.todos, 'todo', required),
      conclusion: note.conclusion == null
          ? null
          : TopicNoteItem(required('conclusion'), note.conclusion!.sources),
    );
    await widget.controller.analysis.editResult(
      slotKey,
      result,
      updated.encode(),
    );
    if (mounted) {
      setState(() => _editing = false);
    }
  }

  List<TopicNoteItem> _editedItems(
    List<TopicNoteItem> items,
    String prefix,
    String Function(String id) read,
  ) => [
    for (var i = 0; i < items.length; i++)
      TopicNoteItem(read('$prefix-$i'), items[i].sources),
  ];

  Future<void> _shareNote(
    AnalysisResult result,
    TopicNote note,
    Topic? topic,
  ) async {
    final text = note.export(result, topic: topic);
    if (runsOnPhone) {
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
              if (index == null) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('未能定位原文')));
                return;
              }
              widget.onSelectParagraph?.call(index);
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

  Widget _editField(String id, String label, {int? maxLines = 1}) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextField(
      key: ValueKey('topic-note-edit-$id'),
      controller: _editors[id],
      maxLines: maxLines,
      decoration: InputDecoration(labelText: label, isDense: true),
    ),
  );

  Widget _buildEditItems(
    String title,
    List<TopicNoteItem> items,
    String prefix,
  ) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionTitle(title),
        for (var i = 0; i < items.length; i++)
          _editField('$prefix-$i', '条目 ${i + 1}', maxLines: null),
      ],
    );
  }

  Widget _buildBookEditSections(TopicNote note) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (note.excerpts.isNotEmpty) ...[
          _buildSectionTitle('原文摘录'),
          for (var i = 0; i < note.excerpts.length; i++) ...[
            _editField('excerpt-$i', '摘录 ${i + 1}', maxLines: null),
            _editField('excerpt-page-$i', '页码（可选）'),
            const SizedBox(height: 4),
          ],
        ],
        if (note.comments.isNotEmpty) ...[
          _buildSectionTitle('我的评论'),
          for (var i = 0; i < note.comments.length; i++) ...[
            _editField('comment-$i', '评论 ${i + 1}', maxLines: null),
            _editField('comment-excerpt-$i', '配对的摘录（可选）', maxLines: null),
            const SizedBox(height: 4),
          ],
        ],
        _buildEditItems('疑问', note.questions, 'question'),
        _buildEditItems('联想', note.associations, 'association'),
        _buildEditItems('待查', note.toCheck, 'to-check'),
      ],
    );
  }

  Widget _buildThinkingEditSections(TopicNote note) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (note.ideas.isNotEmpty) ...[
          _buildSectionTitle('主要想法'),
          for (var i = 0; i < note.ideas.length; i++) ...[
            _editField('idea-$i', '观点 ${i + 1}', maxLines: null),
            _editField('idea-reason-$i', '理由（可选）', maxLines: null),
            const SizedBox(height: 4),
          ],
        ],
        _buildEditItems('与此前笔记的变化', note.changes, 'change'),
        _buildEditItems('疑问', note.questions, 'question'),
        _buildEditItems('联想', note.associations, 'association'),
        _buildEditItems('待办/待查', note.todos, 'todo'),
        if (note.conclusion != null) ...[
          _buildSectionTitle('倾向的结论'),
          _editField('conclusion', '结论', maxLines: null),
        ],
      ],
    );
  }

  Widget _buildEditToolbar(
    String slotKey,
    AnalysisResult result,
    TopicNote note,
  ) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(onPressed: _cancelEdit, child: const Text('取消')),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () => _saveNote(slotKey, result, note),
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );

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
        final running = analysis.running(slotKey);
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

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_editing && note != null && result != null)
              _buildEditToolbar(slotKey, result, note),
            Expanded(
              child: SingleChildScrollView(
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
                            onPressed: () => _beginEdit(note),
                            child: const Text('编辑'),
                          ),
                          const SizedBox(width: 4),
                          OutlinedButton(
                            onPressed: () => _confirmRegenerate(context),
                            child: const Text('重生成'),
                          ),
                          KoeIconButton(
                            tooltip: '复制笔记',
                            icon: const Icon(Icons.copy_outlined),
                            onPressed: () => Clipboard.setData(
                              ClipboardData(
                                text: note.export(result!, topic: topic),
                              ),
                            ),
                          ),
                          KoeIconButton(
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
                          '原文、所属主题或模板已变化，当前笔记可能已过期',
                          style: TextStyle(
                            color: AppColors.coral,
                            fontSize: 13,
                          ),
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
                            if (running)
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
                                  : () => note != null
                                        ? _confirmRegenerate(context)
                                        : widget.controller.generateTopicNote(
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
                          onPressed: () => widget.controller.generateTopicNote(
                            widget.reference,
                          ),
                          child: const Text('生成主题笔记'),
                        ),
                      ),
                    if (note != null && result != null) ...[
                      const SizedBox(height: 12),
                      if (_editing) ...[
                        _editField('overview', '本次概要', maxLines: null),
                      ] else
                        Text(
                          note.overview,
                          style: const TextStyle(fontSize: 16, height: 1.55),
                        ),
                      if (_editing)
                        note.kind == TopicKind.book
                            ? _buildBookEditSections(note)
                            : _buildThinkingEditSections(note)
                      else if (note.kind == TopicKind.book) ...[
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
                          _buildSimpleSection('倾向的结论', [
                            note.conclusion!,
                          ], result),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
