import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../context_source.dart';
import '../screens/diary_screen.dart';
import '../screens/todos_screen.dart';
import 'cited_text.dart';
import 'widgets.dart';

/// Today's brief: open todos, others' commitments that are due, and
/// yesterday's key points. Nothing is generated until the user taps.
class MorningBriefCard extends StatefulWidget {
  const MorningBriefCard({super.key});

  @override
  State<MorningBriefCard> createState() => _MorningBriefCardState();
}

class _MorningBriefCardState extends State<MorningBriefCard> {
  String? _error;

  Future<void> _generate({bool confirmRetry = false}) async {
    final c = context.read<RecorderController>();
    setState(() => _error = null);
    try {
      await c.generateBriefKeyPoints(
        DateTime.now(),
        confirmRetry: confirmRetry,
      );
    } on DiaryResultUnknown {
      if (!mounted) return;
      final retry = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('上次生成结果未知'),
          content: const Text('上次请求没有返回，可能已经计费。确认重新生成？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('先不'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('重新生成'),
            ),
          ],
        ),
      );
      if (retry == true) await _generate(confirmRetry: true);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is StateError
            ? error.message.toString()
            : '生成失败，可稍后重试',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final now = DateTime.now();
    final brief = c.morningBrief(now);
    final points = brief.keyPoints?.current;
    final busy = c.briefGenerating(now);
    final small = const TextStyle(fontSize: 13, color: AppColors.textSecondary);
    return SurfaceCard(
      key: const ValueKey('morning-brief'),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '晨报 · ${now.month}月${now.day}日',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            brief.openMine.isEmpty
                ? '没有未完成的待办'
                : '${brief.openMine.length} 条待办未完成',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          for (final todo in brief.openMine.take(3))
            InkWell(
              onTap: () => openTodo(context, todo.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '· ${todo.title}（${todoDueLabel(todo)}）',
                  style: small,
                ),
              ),
            ),
          if (brief.followUps.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('需要跟进', style: TextStyle(fontWeight: FontWeight.w600)),
            for (final todo in brief.followUps)
              InkWell(
                key: ValueKey('brief-follow-${todo.id}'),
                onTap: () => openTodo(context, todo.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '· ${todo.owner ?? '对方'}答应「${todo.title}」，${todoDueLabel(todo)}到期',
                    style: small,
                  ),
                ),
              ),
          ],
          const SizedBox(height: 8),
          const Text('昨天要点', style: TextStyle(fontWeight: FontWeight.w600)),
          if (points != null) ...[
            for (final line in points.text.split('\n'))
              if (line.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: CitedText(
                    text: diaryLineTag(line.trim()).$2,
                    sources: points.sources,
                    style: const TextStyle(fontSize: 13, height: 1.45),
                  ),
                ),
          ] else if (brief.yesterday.sources.isEmpty)
            Text(
              brief.yesterday.items.isEmpty ? '昨天没有资料' : '昨天的录音还没有文字',
              style: small,
            ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          if (points == null && brief.yesterday.sources.isNotEmpty)
            TextButton.icon(
              key: const ValueKey('brief-generate'),
              onPressed: busy ? null : _generate,
              icon: busy
                  ? const SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_outlined, size: 18),
              label: Text(busy ? '生成中…' : '生成昨天要点'),
            ),
        ],
      ),
    );
  }
}
