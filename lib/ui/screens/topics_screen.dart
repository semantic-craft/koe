import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../state/recorder_controller.dart';
import '../../state/recording_analysis.dart';
import '../../state/topic_export.dart';
import '../../theme/app_theme.dart';
import '../recording_navigation.dart';
import '../widgets/widgets.dart';

/// Library entry for topics (#50). Rendered only where topics are enabled
/// (first version: iPhone); the Mac library is unchanged.
class TopicsEntry extends StatelessWidget {
  const TopicsEntry({
    super.key,
    this.padding = const EdgeInsets.fromLTRB(20, 4, 20, 4),
  });

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final c = context.read<RecorderController>();
    if (!c.topicsEnabled) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: c.topics,
      builder: (context, _) {
        final current = c.topics.currentTopic;
        final pending = _existingKeys(c, c.topics.pendingRecordings).length;
        return Padding(
          padding: padding,
          child: SurfaceCard(
            key: const ValueKey('topics-entry'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                settings: const RouteSettings(name: 'topics'),
                builder: (_) => const TopicsScreen(),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.bookmarks_outlined, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    current == null ? '主题 · 今天未设当前主题' : '当前主题：${current.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (pending > 0)
                  Text(
                    '待归类 $pending',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Library recordings keyed by their recording key (same key as transcripts
/// and analysis), newest first.
Map<String, String> _libraryByKey(RecorderController c) => {
  for (final path in c.exportedPaths)
    c.analysisKey(
      RecordingReference(fileId: c.fileIdFromPath(path), path: path),
    ): path,
};

List<String> _existingKeys(RecorderController c, Iterable<String> keys) {
  final library = _libraryByKey(c);
  return [
    for (final key in keys)
      if (library.containsKey(key)) key,
  ];
}

class TopicsScreen extends StatelessWidget {
  const TopicsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final store = c.topics;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final current = store.currentTopic;
        final pending = _existingKeys(c, store.pendingRecordings).length;
        return GradientScaffold(
          appBar: AppBar(
            title: const Text('主题'),
            actions: [
              IconButton(
                tooltip: '新建主题',
                onPressed: () => showCreateTopicDialog(context, store),
                icon: const Icon(Icons.add_rounded),
              ),
            ],
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              if (store.recoveryNotice != null)
                _Notice(text: store.recoveryNotice!),
              if (store.saveError != null) _Notice(text: store.saveError!),
              SurfaceCard(
                key: const ValueKey('current-topic-card'),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '当前主题（仅今天有效）',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            current?.title ?? '未设定，取回的录音进入待归类',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                    if (current != null)
                      TextButton(
                        onPressed: () => store.setCurrentTopic(null),
                        child: const Text('清除'),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                key: const ValueKey('pending-entry'),
                leading: const Icon(Icons.inbox_outlined),
                title: const Text('待归类'),
                trailing: Text('$pending'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PendingRecordingsScreen(),
                  ),
                ),
              ),
              const _SectionTitle('进行中'),
              if (store.openTopics.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    '还没有主题，点右上角新建书籍或普通主题',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ),
              for (final topic in store.openTopics)
                _TopicTile(topic: topic, current: topic.id == current?.id),
              if (store.closedTopics.isNotEmpty) ...[
                const _SectionTitle('已读完 / 已归档'),
                for (final topic in store.closedTopics)
                  _TopicTile(topic: topic, current: false),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(text, style: const TextStyle(color: AppColors.coral)),
  );
}

/// A topic summary is an explicit paid action. Reopening this screen never
/// starts analysis; it only reads the locally persisted result/checkpoints.
class _TopicSummaryPanel extends StatefulWidget {
  const _TopicSummaryPanel({required this.topicId});
  final String topicId;

  @override
  State<_TopicSummaryPanel> createState() => _TopicSummaryPanelState();
}

class _TopicSummaryPanelState extends State<_TopicSummaryPanel> {
  @override
  void initState() {
    super.initState();
    unawaited(context.read<RecorderController>().analysis.load());
  }

  Future<void> _generate({required bool replace}) async {
    final controller = context.read<RecorderController>();
    final slot = TopicSummary.slotKey(widget.topicId);
    TopicSummaryRetry intent = TopicSummaryRetry.auto;
    if (replace) {
      final sourceChanged =
          controller.analysis.errors[slot]?.contains('旧检查点不能复用') == true;
      final unsafeRetry =
          controller.analysis.errors[slot]?.contains('未确认') == true ||
          controller.analysis.errors[slot]?.contains('校验失败') == true ||
          sourceChanged;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(unsafeRetry ? '重新开始汇总？' : '重新生成汇总？'),
          content: Text(
            sourceChanged
                ? '笔记内容已变化，旧检查点不能复用。重新开始会重新发送全部笔记并产生新的模型调用，且覆盖已有汇总。'
                : unsafeRetry
                ? '上次请求的结果未确认，可能已经计费。重新开始可能再次计费，并会覆盖已有汇总。'
                : '重新生成会覆盖当前汇总，包括手动修改，并产生新的模型调用。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('继续'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      intent = unsafeRetry
          ? TopicSummaryRetry.confirmedRetry
          : TopicSummaryRetry.overwrite;
    }
    try {
      await controller.generateTopicSummary(widget.topicId, retry: intent);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _editItem(
    AnalysisResult result,
    TopicSummary summary,
    String section,
    int? index,
  ) async {
    final original = index == null ? null : summary.sections[section]![index];
    final updated = await showDialog<TopicSummaryItem>(
      context: context,
      builder: (_) => _SummaryItemDialog(
        section: section,
        original: original,
        sources: summary.sources,
      ),
    );
    if (updated == null || !mounted) return;
    final sections = {
      for (final key in TopicSummary.sectionKeys(summary.kind))
        key: [...summary.sections[key]!],
    };
    if (index == null) {
      sections[section]!.add(updated);
    } else {
      sections[section]![index] = updated;
    }
    try {
      await context.read<RecorderController>().analysis.editResult(
        TopicSummary.slotKey(widget.topicId),
        result,
        TopicSummary(
          kind: summary.kind,
          topicId: summary.topicId,
          sources: summary.sources,
          sections: sections,
        ).encode(),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _deleteItem(
    AnalysisResult result,
    TopicSummary summary,
    String section,
    int index,
  ) async {
    final sections = {
      for (final key in TopicSummary.sectionKeys(summary.kind))
        key: [...summary.sections[key]!],
    };
    sections[section]!.removeAt(index);
    try {
      await context.read<RecorderController>().analysis.editResult(
        TopicSummary.slotKey(widget.topicId),
        result,
        TopicSummary(
          kind: summary.kind,
          topicId: summary.topicId,
          sources: summary.sources,
          sections: sections,
        ).encode(),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  void _openSource(TopicSummarySource source) {
    _openRecordingKey(source.recordingKey);
  }

  String _recordingTitle(RecorderController c, String key) {
    final path = _libraryByKey(c)[key];
    if (path == null) return key;
    return c
        .recordingView(
          RecordingReference(fileId: c.fileIdFromPath(path), path: path),
        )
        .title;
  }

  void _openRecordingKey(String recordingKey) {
    final c = context.read<RecorderController>();
    final path = _libraryByKey(c)[recordingKey];
    if (path == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('来源录音已不在资料库中')));
      return;
    }
    RecordingNavigation.open(
      context,
      RecordingReference(fileId: c.fileIdFromPath(path), path: path),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.read<RecorderController>();
    return ListenableBuilder(
      listenable: c.analysis,
      builder: (context, _) {
        final topic = c.topics.topicById(widget.topicId);
        if (topic == null) return const SizedBox.shrink();
        final slot = TopicSummary.slotKey(widget.topicId);
        final result = c.analysis.results[slot];
        final summary = result == null
            ? null
            : TopicSummary.tryParse(result.text);
        final busy = c.analysis.busy(slot);
        final error = c.analysis.errors[slot];
        final unsafeRetry =
            error?.contains('未确认') == true ||
            error?.contains('校验失败') == true ||
            error?.contains('旧检查点不能复用') == true;
        final stale = c.isTopicSummaryStale(widget.topicId);
        final input = c.topicSummaryInput(widget.topicId);
        final noteCount = input.sources.length;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: SurfaceCard(
            key: const ValueKey('topic-summary-panel'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '汇总',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (stale)
                      const Text(
                        '已过期',
                        style: TextStyle(color: AppColors.coral),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (busy) Text(c.analysis.progress[slot] ?? '正在生成…'),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      error,
                      style: const TextStyle(color: AppColors.coral),
                    ),
                  ),
                if (summary == null && !busy) Text('已有 $noteCount 条笔记可汇总'),
                if (input.invalidKeys.isNotEmpty) ...[
                  Text(
                    '有 ${input.invalidKeys.length} 条笔记已过期或无法解析（转写或音频可能有变化），'
                    '请先打开对应录音重新生成笔记，再生成汇总。',
                    style: const TextStyle(color: AppColors.coral),
                  ),
                  for (final key in input.invalidKeys)
                    TextButton(
                      onPressed: () => _openRecordingKey(key),
                      child: Text('打开 ${_recordingTitle(c, key)}'),
                    ),
                ],
                if (summary != null) ...[
                  for (final section in TopicSummary.sectionKeys(
                    summary.kind,
                  )) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            TopicSummary.sectionLabel(section),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        IconButton(
                          tooltip: '添加${TopicSummary.sectionLabel(section)}',
                          onPressed: busy
                              ? null
                              : () =>
                                    _editItem(result!, summary, section, null),
                          icon: const Icon(Icons.add_rounded, size: 18),
                        ),
                      ],
                    ),
                    if (summary.sections[section]!.isEmpty)
                      const Text(
                        '未提及',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                    for (final entry in summary.sections[section]!.indexed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(entry.$2.text),
                            Wrap(
                              spacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                for (final sourceId in entry.$2.sources)
                                  ActionChip(
                                    label: Text(sourceId),
                                    tooltip: '打开来源笔记',
                                    onPressed: () {
                                      final source = summary.sources
                                          .where((s) => s.id == sourceId)
                                          .firstOrNull;
                                      if (source != null) _openSource(source);
                                    },
                                  ),
                                IconButton(
                                  tooltip: '编辑条目',
                                  onPressed: busy
                                      ? null
                                      : () => _editItem(
                                          result!,
                                          summary,
                                          section,
                                          entry.$1,
                                        ),
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 18,
                                  ),
                                ),
                                IconButton(
                                  tooltip: '删除条目',
                                  onPressed: busy
                                      ? null
                                      : () => _deleteItem(
                                          result!,
                                          summary,
                                          section,
                                          entry.$1,
                                        ),
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ],
                const SizedBox(height: 8),
                if (!busy)
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(
                        key: const ValueKey('topic-summary-generate'),
                        onPressed:
                            noteCount == 0 || input.invalidKeys.isNotEmpty
                            ? null
                            : () => _generate(
                                replace: result != null || unsafeRetry,
                              ),
                        child: Text(summary == null ? '生成汇总' : '重新生成'),
                      ),
                      if (error != null &&
                          !unsafeRetry &&
                          result == null &&
                          input.invalidKeys.isEmpty)
                        TextButton(
                          onPressed: () => _generate(replace: false),
                          child: const Text('继续重试'),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SummaryItemDialog extends StatefulWidget {
  const _SummaryItemDialog({
    required this.section,
    required this.original,
    required this.sources,
  });

  final String section;
  final TopicSummaryItem? original;
  final List<TopicSummarySource> sources;

  @override
  State<_SummaryItemDialog> createState() => _SummaryItemDialogState();
}

class _SummaryItemDialogState extends State<_SummaryItemDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.original?.text ?? '',
  );
  late final Set<String> _selected = {...?widget.original?.sources};

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('编辑${TopicSummary.sectionLabel(widget.section)}'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('topic-summary-edit-text'),
              controller: _text,
              minLines: 3,
              maxLines: 10,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: '内容'),
            ),
            const SizedBox(height: 12),
            const Text('依据笔记'),
            Wrap(
              spacing: 6,
              children: [
                for (final source in widget.sources)
                  FilterChip(
                    label: Text(source.id),
                    selected: _selected.contains(source.id),
                    onSelected: (value) => setState(() {
                      if (value) {
                        _selected.add(source.id);
                      } else {
                        _selected.remove(source.id);
                      }
                    }),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _text.text.trim().isEmpty || _selected.isEmpty
            ? null
            : () => Navigator.pop(
                context,
                TopicSummaryItem(
                  text: _text.text.trim(),
                  sources: _selected.toList(),
                ),
              ),
        child: const Text('保存'),
      ),
    ],
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: AppColors.textSecondary,
      ),
    ),
  );
}

String _kindLabel(Topic topic) => topic.kind == TopicKind.book ? '书籍' : '普通';

String _subtitle(Topic topic) => [
  _kindLabel(topic),
  if (topic.kind == TopicKind.book && topic.author.isNotEmpty) topic.author,
  if (topic.closed) '已${topic.closedLabel}',
].join(' · ');

class _TopicTile extends StatelessWidget {
  const _TopicTile({required this.topic, required this.current});
  final Topic topic;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final c = context.read<RecorderController>();
    final count = _existingKeys(c, c.topics.recordingsIn(topic.id)).length;
    return ListTile(
      leading: Icon(
        topic.kind == TopicKind.book
            ? Icons.menu_book_outlined
            : Icons.lightbulb_outline_rounded,
      ),
      title: Text(topic.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(current ? '${_subtitle(topic)} · 当前' : _subtitle(topic)),
      trailing: Text('$count'),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TopicDetailScreen(topicId: topic.id),
        ),
      ),
    );
  }
}

Future<String?> _askText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  bool allowEmpty = false,
}) => showDialog<String>(
  context: context,
  builder: (_) => _TextDialog(
    title: title,
    label: label,
    initial: initial,
    allowEmpty: allowEmpty,
  ),
);

/// Owns its controller so the closing animation never touches a disposed one.
class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.allowEmpty,
  });
  final String title;
  final String label;
  final String initial;
  final bool allowEmpty;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: 100,
      decoration: InputDecoration(labelText: widget.label),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      TextButton(
        onPressed: () {
          final text = _controller.text.trim();
          if (text.isEmpty && !widget.allowEmpty) return;
          Navigator.pop(context, text);
        },
        child: const Text('保存'),
      ),
    ],
  );
}

Future<void> showCreateTopicDialog(
  BuildContext context,
  TopicStore store,
) async {
  final draft = await showDialog<_TopicDraft>(
    context: context,
    builder: (_) => const _CreateTopicDialog(),
  );
  if (draft != null) {
    await store.createTopic(
      kind: draft.kind,
      title: draft.title,
      author: draft.author,
    );
  }
}

typedef _TopicDraft = ({TopicKind kind, String title, String author});

class _CreateTopicDialog extends StatefulWidget {
  const _CreateTopicDialog();

  @override
  State<_CreateTopicDialog> createState() => _CreateTopicDialogState();
}

class _CreateTopicDialogState extends State<_CreateTopicDialog> {
  final _title = TextEditingController();
  final _author = TextEditingController();
  var _kind = TopicKind.book;

  @override
  void dispose() {
    _title.dispose();
    _author.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('新建主题'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<TopicKind>(
            segments: const [
              ButtonSegment(value: TopicKind.book, label: Text('书籍')),
              ButtonSegment(value: TopicKind.general, label: Text('普通')),
            ],
            selected: {_kind},
            onSelectionChanged: (value) => setState(() => _kind = value.first),
          ),
          TextField(
            key: const ValueKey('topic-title-field'),
            controller: _title,
            maxLength: 100,
            decoration: InputDecoration(
              labelText: _kind == TopicKind.book ? '书名' : '主题名',
            ),
          ),
          if (_kind == TopicKind.book)
            TextField(
              key: const ValueKey('topic-author-field'),
              controller: _author,
              maxLength: 100,
              decoration: const InputDecoration(labelText: '作者（可选）'),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      TextButton(
        onPressed: () {
          if (_title.text.trim().isEmpty) return;
          Navigator.pop<_TopicDraft>(context, (
            kind: _kind,
            title: _title.text,
            author: _author.text,
          ));
        },
        child: const Text('创建'),
      ),
    ],
  );
}

/// Default assignment choices: only topics that are neither 读完 nor 归档.
Future<Topic?> pickOpenTopic(
  BuildContext context,
  TopicStore store, {
  String? exclude,
  String? suggestedTopicId,
}) => showModalBottomSheet<Topic>(
  context: context,
  builder: (sheetContext) {
    final choices = [
      for (final t in store.openTopics)
        if (t.id != exclude) t,
    ];
    if (suggestedTopicId != null) {
      choices.sort((a, b) {
        final aMatch = a.id == suggestedTopicId ? 0 : 1;
        final bMatch = b.id == suggestedTopicId ? 0 : 1;
        return aMatch.compareTo(bMatch);
      });
    }
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('归入主题')),
          if (choices.isEmpty) const ListTile(title: Text('没有可选的进行中主题')),
          for (final topic in choices)
            ListTile(
              selected: topic.id == suggestedTopicId,
              title: Text(topic.title),
              subtitle: Text(_subtitle(topic)),
              trailing: topic.id == suggestedTopicId
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () => Navigator.pop(sheetContext, topic),
            ),
        ],
      ),
    );
  },
);

class _RecordingRow extends StatelessWidget {
  const _RecordingRow({
    required this.recordingKey,
    required this.path,
    required this.actions,
    this.banner,
  });
  final String recordingKey;
  final String path;
  final List<(String, Future<void> Function())> actions;
  final Widget? banner;

  @override
  Widget build(BuildContext context) {
    final c = context.read<RecorderController>();
    final reference = RecordingReference(
      fileId: c.fileIdFromPath(path),
      path: path,
    );
    final title = c.recordingView(reference).title;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.graphic_eq_rounded),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => RecordingNavigation.open(context, reference),
          trailing: PopupMenuButton<int>(
            tooltip: '更多',
            onSelected: (index) => actions[index].$2(),
            itemBuilder: (_) => [
              for (var i = 0; i < actions.length; i++)
                PopupMenuItem(value: i, child: Text(actions[i].$1)),
            ],
          ),
        ),
        if (banner != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 0, 16, 8),
            child: banner!,
          ),
      ],
    );
  }
}

class _RecommendationBanner extends StatelessWidget {
  const _RecommendationBanner({
    required this.recordingKey,
    required this.recommendation,
  });
  final String recordingKey;
  final TopicRecommendation recommendation;

  @override
  Widget build(BuildContext context) {
    final store = context.read<RecorderController>().topics;
    final String label;
    if (recommendation.kind == TopicRecommendationKind.existingTopic) {
      final topic = store.topicById(recommendation.topicId);
      if (topic == null || topic.closed) return const SizedBox.shrink();
      label = '推荐归入《${topic.title}》';
    } else {
      final author =
          recommendation.suggestedKind == TopicKind.book &&
              recommendation.suggestedAuthor.isNotEmpty
          ? ' · ${recommendation.suggestedAuthor}'
          : '';
      label = '建议新建主题《${recommendation.suggestedTitle}》$author';
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        TextButton(
          key: ValueKey('confirm-recommend-$recordingKey'),
          onPressed: () => store.confirmRecommendation(recordingKey),
          child: const Text('确认'),
        ),
        TextButton(
          key: ValueKey('change-recommend-$recordingKey'),
          onPressed: () async {
            final topic = await pickOpenTopic(
              context,
              store,
              suggestedTopicId: recommendation.topicId,
            );
            if (topic != null) {
              await store.moveRecording(recordingKey, topic.id);
            }
          },
          child: const Text('改选'),
        ),
        TextButton(
          key: ValueKey('dismiss-recommend-$recordingKey'),
          onPressed: () => store.dismissRecommendation(recordingKey),
          child: const Text('忽略'),
        ),
      ],
    );
  }
}

class _DriftBanner extends StatelessWidget {
  const _DriftBanner({
    required this.recordingKey,
    required this.topicId,
    required this.prompt,
  });
  final String recordingKey;
  final String topicId;
  final String prompt;

  @override
  Widget build(BuildContext context) {
    final store = context.read<RecorderController>().topics;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        Text(
          prompt,
          style: const TextStyle(fontSize: 13, color: AppColors.coral),
        ),
        TextButton(
          key: ValueKey('drift-move-$recordingKey'),
          onPressed: () async {
            final target = await pickOpenTopic(
              context,
              store,
              exclude: topicId,
              suggestedTopicId: store
                  .driftHintFor(recordingKey)
                  ?.suggestedTopicId,
            );
            if (target != null) {
              await store.moveRecording(recordingKey, target.id);
            }
          },
          child: const Text('移到…'),
        ),
        TextButton(
          key: ValueKey('drift-keep-$recordingKey'),
          onPressed: () => store.dismissDriftHint(recordingKey),
          child: const Text('保留'),
        ),
      ],
    );
  }
}

class PendingRecordingsScreen extends StatelessWidget {
  const PendingRecordingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final store = c.topics;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final library = _libraryByKey(c);
        final keys = _existingKeys(c, store.pendingRecordings);
        return GradientScaffold(
          appBar: AppBar(title: const Text('待归类')),
          child: keys.isEmpty
              ? const Center(child: Text('没有待归类的录音'))
              : ListView(
                  children: [
                    for (final key in keys)
                      _RecordingRow(
                        recordingKey: key,
                        path: library[key]!,
                        banner: switch (store.recommendationFor(key)) {
                          final rec? => _RecommendationBanner(
                            recordingKey: key,
                            recommendation: rec,
                          ),
                          null => null,
                        },
                        actions: [
                          (
                            '归入主题…',
                            () async {
                              final topic = await pickOpenTopic(context, store);
                              if (topic != null) {
                                await store.moveRecording(key, topic.id);
                              }
                            },
                          ),
                          ('不归主题', () => store.removeFromTopic(key)),
                        ],
                      ),
                  ],
                ),
        );
      },
    );
  }
}

class TopicDetailScreen extends StatelessWidget {
  const TopicDetailScreen({super.key, required this.topicId});
  final String topicId;

  String _markdown(RecorderController c, Topic topic) {
    final input = c.topicSummaryInput(topicId);
    final notes = <TopicExportNote>[];
    var unavailable = input.invalidKeys.length;
    for (final source in input.sources) {
      final result = c.analysis.results[TopicNote.slotKey(source.recordingKey)];
      if (result == null) {
        unavailable++;
        continue;
      }
      final note = TopicNote.tryParse(
        result.text,
        result.sources.isEmpty ? 1 : result.sources.length,
        fallbackTopicId: topicId,
      );
      if (note == null ||
          note.kind != topic.kind ||
          (note.topicId.isNotEmpty && note.topicId != topicId)) {
        unavailable++;
        continue;
      }
      notes.add(
        TopicExportNote(
          title: source.title,
          recordedAt: source.recordedAt,
          page: source.page,
          note: note,
        ),
      );
    }
    final result = c.analysis.results[TopicSummary.slotKey(topicId)];
    final summary = result == null ? null : TopicSummary.tryParse(result.text);
    return buildTopicMarkdown(
      topic: topic,
      recordingCount: _existingKeys(c, c.topics.recordingsIn(topicId)).length,
      exportedAt: DateTime.now(),
      notes: notes,
      summary: summary,
      summaryStale: c.isTopicSummaryStale(topicId),
      unavailableNoteCount: unavailable,
    );
  }

  Future<void> _export(
    BuildContext context,
    RecorderController c,
    Topic topic, {
    required bool share,
  }) async {
    try {
      final markdown = _markdown(c, topic);
      if (share) {
        if (!context.mounted) return;
        final filename = topicExportFileName(topic, c.topics.topics);
        await shareTopicMarkdownFile(
          markdown: markdown,
          filename: filename,
          share: (file) async {
            if (!context.mounted) return;
            final box = context.findRenderObject() as RenderBox?;
            await SharePlus.instance.share(
              ShareParams(
                files: [
                  XFile(file.path, name: filename, mimeType: 'text/markdown'),
                ],
                title: filename,
                sharePositionOrigin: box == null
                    ? null
                    : box.localToGlobal(Offset.zero) & box.size,
              ),
            );
          },
        );
      } else {
        await Clipboard.setData(ClipboardData(text: markdown));
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已复制主题 Markdown')));
        }
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('导出失败，请重试')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final store = c.topics;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final topic = store.topicById(topicId);
        if (topic == null) {
          return GradientScaffold(
            appBar: AppBar(),
            child: const Center(child: Text('主题不存在')),
          );
        }
        final library = _libraryByKey(c);
        final keys = _existingKeys(c, store.recordingsIn(topicId));
        final isCurrent = store.currentTopic?.id == topicId;
        return GradientScaffold(
          appBar: AppBar(
            title: Text(topic.title),
            actions: [
              IconButton(
                key: const ValueKey('topic-export-copy'),
                tooltip: '复制主题 Markdown',
                onPressed: () => _export(context, c, topic, share: false),
                icon: const Icon(Icons.copy_outlined),
              ),
              IconButton(
                key: const ValueKey('topic-export-share'),
                tooltip: '分享主题 Markdown 文件',
                onPressed: () => _export(context, c, topic, share: true),
                icon: const Icon(Icons.ios_share_rounded),
              ),
              PopupMenuButton<String>(
                tooltip: '编辑主题',
                onSelected: (value) async {
                  switch (value) {
                    case 'rename':
                      final name = await _askText(
                        context,
                        title: '改名',
                        label: topic.kind == TopicKind.book ? '书名' : '主题名',
                        initial: topic.title,
                      );
                      if (name != null) await store.renameTopic(topicId, name);
                    case 'author':
                      final author = await _askText(
                        context,
                        title: '编辑作者',
                        label: '作者',
                        initial: topic.author,
                        allowEmpty: true,
                      );
                      if (author != null) {
                        await store.setAuthor(topicId, author);
                      }
                    case 'close':
                      await store.closeTopic(topicId);
                    case 'reopen':
                      await store.reopenTopic(topicId);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'rename', child: Text('改名')),
                  if (topic.kind == TopicKind.book)
                    const PopupMenuItem(value: 'author', child: Text('编辑作者')),
                  if (topic.closed)
                    const PopupMenuItem(value: 'reopen', child: Text('重新打开'))
                  else
                    PopupMenuItem(
                      value: 'close',
                      child: Text(topic.kind == TopicKind.book ? '标为读完' : '归档'),
                    ),
                ],
              ),
            ],
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 32),
            children: [
              ListTile(title: Text(_subtitle(topic))),
              if (!topic.closed)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: isCurrent
                      ? OutlinedButton(
                          onPressed: () => store.setCurrentTopic(null),
                          child: const Text('今天的当前主题 · 点按清除'),
                        )
                      : FilledButton(
                          onPressed: () => store.setCurrentTopic(topicId),
                          child: const Text('设为今天的当前主题'),
                        ),
                ),
              _TopicSummaryPanel(topicId: topicId),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
                child: Row(
                  children: [
                    Expanded(child: Text('录音 ${keys.length}')),
                    TextButton.icon(
                      onPressed: () => _addRecording(context, c, topicId),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('添加录音'),
                    ),
                  ],
                ),
              ),
              for (final key in keys)
                _RecordingRow(
                  recordingKey: key,
                  path: library[key]!,
                  banner: switch (store.driftPromptFor(key)) {
                    final prompt? => _DriftBanner(
                      recordingKey: key,
                      topicId: topicId,
                      prompt: prompt,
                    ),
                    null => null,
                  },
                  actions: [
                    (
                      '移到其他主题…',
                      () async {
                        final target = await pickOpenTopic(
                          context,
                          store,
                          exclude: topicId,
                        );
                        if (target != null) {
                          await store.moveRecording(key, target.id);
                        }
                      },
                    ),
                    ('移出主题', () => store.removeFromTopic(key)),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  static Future<void> _addRecording(
    BuildContext context,
    RecorderController c,
    String topicId,
  ) async {
    final store = c.topics;
    final library = _libraryByKey(c);
    final candidates = [
      for (final entry in library.entries)
        if (store.topicOf(entry.key)?.id != topicId) entry,
    ];
    final key = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('选择录音')),
            if (candidates.isEmpty) const ListTile(title: Text('没有可添加的录音')),
            for (final entry in candidates)
              ListTile(
                title: Text(
                  c
                      .recordingView(
                        RecordingReference(
                          fileId: c.fileIdFromPath(entry.value),
                          path: entry.value,
                        ),
                      )
                      .title,
                ),
                subtitle: Text(switch (store.placementOf(entry.key)) {
                  InTopicPlacement() => '在「${store.topicOf(entry.key)?.title}」',
                  PendingPlacement() => '待归类',
                  _ => '未归主题',
                }),
                onTap: () => Navigator.pop(sheetContext, entry.key),
              ),
          ],
        ),
      ),
    );
    if (key != null) await store.moveRecording(key, topicId);
  }
}
