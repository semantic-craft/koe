import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../recording_navigation.dart';
import 'widgets.dart';

String _two(int value) => value.toString().padLeft(2, '0');

/// `09:30–10:05`, or 时间未知 when the moment it happened is not known.
String contextTimeLabel(ContextItem item) {
  final start = item.start?.toLocal();
  if (start == null) return '时间未知';
  final end = item.end?.toLocal();
  final from = '${_two(start.hour)}:${_two(start.minute)}';
  if (end == null || !end.isAfter(start)) return from;
  return '$from–${_two(end.hour)}:${_two(end.minute)}';
}

/// One timeline row: time, title, place and linked topics. Tapping opens
/// the original recording; the link button corrects the topic links.
class ContextTimelineRow extends StatelessWidget {
  const ContextTimelineRow({super.key, required this.item});

  final ContextItem item;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final ref = c.contextReference(item);
    final topicTitles = [
      for (final id in item.topicIds) ?c.topics.topicById(id)?.title,
    ];
    final projectTitles = [
      for (final id in item.projectIds) ?c.projects.projectById(id)?.title,
    ];
    final details = [contextTimeLabel(item), ?item.location];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SurfaceCard(
        key: ValueKey('timeline-item-${item.id}'),
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        onTap: ref == null
            ? null
            : () => RecordingNavigation.open(context, ref),
        child: Row(
          children: [
            const Icon(Icons.graphic_eq_rounded, color: AppColors.mint),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    details.join(' · '),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  if (topicTitles.isNotEmpty || projectTitles.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final title in topicTitles)
                          Text(
                            '# $title',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.mint,
                            ),
                          ),
                        for (final title in projectTitles)
                          Text(
                            '▸ $title',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              key: ValueKey('timeline-links-${item.id}'),
              tooltip: '修改关联',
              onPressed: () => showContextLinksSheet(context, item),
              icon: const Icon(Icons.sell_outlined, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lets the user correct which topics and projects an item belongs to.
/// Saving changes only this item's links; the recording keeps its own single
/// topic and is never copied.
Future<void> showContextLinksSheet(BuildContext context, ContextItem item) {
  final c = context.read<RecorderController>();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => _ContextLinksSheet(controller: c, item: item),
  );
}

class _ContextLinksSheet extends StatefulWidget {
  const _ContextLinksSheet({required this.controller, required this.item});

  final RecorderController controller;
  final ContextItem item;

  @override
  State<_ContextLinksSheet> createState() => _ContextLinksSheetState();
}

class _ContextLinksSheetState extends State<_ContextLinksSheet> {
  late final Set<String> _topics = {...widget.item.topicIds};
  late final Set<String> _projects = {...widget.item.projectIds};
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final c = widget.controller;
    final item = widget.item;
    final topics = [
      for (final topic in c.topics.topics)
        if (_topics.contains(topic.id)) topic.id,
    ];
    final projects = [
      for (final project in c.projects.projects)
        if (_projects.contains(project.id)) project.id,
    ];
    try {
      if (c.topicsEnabled && !sameIds(topics, item.topicIds)) {
        await c.setContextItemTopics(item.id, topics);
      }
      if (!sameIds(projects, item.projectIds)) {
        await c.setContextItemProjects(item.id, projects);
      }
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败，关联保持原样，请重试';
      });
    }
  }

  Widget _choice(String key, String title, Set<String> chosen, String id) =>
      CheckboxListTile(
        key: ValueKey(key),
        value: chosen.contains(id),
        title: Text(title),
        onChanged: _saving
            ? null
            : (checked) => setState(() {
                if (checked == true) {
                  chosen.add(id);
                } else {
                  chosen.remove(id);
                }
              }),
      );

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final topics = c.topicsEnabled
        ? [
            for (final topic in c.topics.topics)
              if (!topic.closed || _topics.contains(topic.id)) topic,
          ]
        : const <Topic>[];
    final projects = [
      for (final project in c.projects.projects)
        if (project.status == ProjectStatus.active ||
            _projects.contains(project.id))
          project,
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '关联主题和项目',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              '只改「${widget.item.title}」的关联，不移动录音本身的主题，也不复制录音。',
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (c.topicsEnabled) ...[
                    const SectionLabel('主题'),
                    if (topics.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('还没有主题。'),
                      ),
                    for (final topic in topics)
                      _choice(
                        'link-topic-${topic.id}',
                        topic.title,
                        _topics,
                        topic.id,
                      ),
                  ],
                  const SectionLabel('项目'),
                  if (projects.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('还没有项目。在「项目」页新建后可在这里关联。'),
                    ),
                  for (final project in projects)
                    _choice(
                      'link-project-${project.id}',
                      project.title,
                      _projects,
                      project.id,
                    ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 8),
            FilledButton(
              key: const ValueKey('save-context-links'),
              onPressed: _saving || (topics.isEmpty && projects.isEmpty)
                  ? null
                  : _save,
              child: Text(_saving ? '保存中…' : '保存'),
            ),
          ],
        ),
      ),
    );
  }
}
