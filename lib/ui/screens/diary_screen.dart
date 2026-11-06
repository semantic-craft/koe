import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/cited_text.dart';
import '../widgets/status_indicators.dart';
import '../widgets/widgets.dart';
import '../widgets/koe_icon_button.dart';

void openDiary(BuildContext context, {required bool weekly}) {
  final now = DateTime.now();
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: RouteSettings(name: weekly ? 'diary/week' : 'diary/day'),
      builder: (_) => DiaryScreen(
        initial: weekly ? DiaryPeriod.week(now) : DiaryPeriod.day(now),
      ),
    ),
  );
}

/// What a diary line is: an exact quote, Koe's summary, or a suggestion.
(String? tag, String body) diaryLineTag(String line) {
  for (final tag in const ['原话', '整理', '建议']) {
    final mark = '【$tag】';
    if (line.startsWith(mark)) return (tag, line.substring(mark.length).trim());
  }
  return (null, line);
}

/// The diary of a day or the summary of a week, with every claim's source.
class DiaryScreen extends StatefulWidget {
  const DiaryScreen({super.key, required this.initial});

  final DiaryPeriod initial;

  @override
  State<DiaryScreen> createState() => _DiaryScreenState();
}

class _DiaryScreenState extends State<DiaryScreen> {
  late DiaryPeriod _period = widget.initial;
  String? _error;

  void _shift(int direction) {
    final step = _period.weekly ? 7 : 1;
    final day = DateTime(
      _period.start.year,
      _period.start.month,
      _period.start.day + step * direction,
    );
    setState(() {
      _error = null;
      _period = _period.weekly ? DiaryPeriod.week(day) : DiaryPeriod.day(day);
    });
  }

  Future<void> _generate({bool confirmRetry = false}) async {
    final c = context.read<RecorderController>();
    setState(() => _error = null);
    try {
      await c.generateDiary(_period, confirmRetry: confirmRetry);
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
            : '生成失败，上一版保留不变，可重试',
      );
    }
  }

  Future<void> _edit(DiaryEntry entry) async {
    final controller = TextEditingController(text: entry.current!.text);
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('修改'),
        content: TextField(
          key: const ValueKey('diary-edit-text'),
          controller: controller,
          maxLines: 12,
          minLines: 6,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('diary-edit-save'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    final c = context.read<RecorderController>();
    try {
      await c.editDiary(entry.key, controller.text);
    } catch (error) {
      if (mounted) setState(() => _error = '保存失败，原来的版本保留');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final material = c.diaryMaterial(_period);
    final entry = c.diary.entryFor(_period.key);
    final current = entry?.current;
    final busy = c.diaryGenerating(_period);
    final name = _period.weekly ? '本周小结' : '日记';
    final changed =
        current != null &&
        material.sources.isNotEmpty &&
        current.fingerprint != material.fingerprint(_period.weekly) &&
        entry?.newer == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        actions: [
          if (current != null)
            KoeIconButton(
              key: const ValueKey('diary-edit'),
              tooltip: '修改',
              onPressed: busy ? null : () => _edit(entry!),
              icon: const Icon(Icons.edit_outlined),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Row(
            children: [
              KoeIconButton(
                tooltip: _period.weekly ? '上一周' : '前一天',
                onPressed: () => _shift(-1),
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Expanded(
                child: Text(
                  _period.label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: AppFontSizes.md,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              KoeIconButton(
                tooltip: _period.weekly ? '下一周' : '后一天',
                onPressed: () => _shift(1),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
          Text(
            [
              '纳入 ${material.items.length} 条资料',
              if (material.withoutText > 0) '${material.withoutText} 条还没有文字',
              if (entry?.edited == true) '已手动修改',
            ].join('，'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: AppFontSizes.xs,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          if (entry?.newer != null) _NewerBanner(entry: entry!),
          if (current == null && !busy)
            SurfaceCard(
              key: const ValueKey('diary-empty'),
              padding: const EdgeInsets.all(16),
              child: Text(
                material.items.isEmpty
                    ? '这段时间还没有资料。'
                    : material.sources.isEmpty
                    ? '这段时间的录音还没有文字，转写后再生成$name。'
                    : '还没有生成$name。生成后每条事实都能点出处回听原话。',
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: ThinkingDots(dotSize: 6)),
            ),
          if (current != null) ...[
            for (final raw in current.text.split('\n'))
              if (raw.trim().isNotEmpty)
                _DiaryLine(raw.trim(), current.sources),
            const SizedBox(height: 16),
            const SectionLabel('出处'),
            SourceList(sources: current.sources),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('diary-generate'),
            onPressed: busy || material.sources.isEmpty ? null : _generate,
            child: Text(
              busy
                  ? '生成中…'
                  : current == null
                  ? '生成$name'
                  : changed
                  ? '有新资料，更新$name'
                  : '已是最新',
            ),
          ),
        ],
      ),
    );
  }
}

class _DiaryLine extends StatelessWidget {
  const _DiaryLine(this.line, this.sources);

  final String line;
  final List<SourceLine> sources;

  @override
  Widget build(BuildContext context) {
    final (tag, body) = diaryLineTag(line);
    final color = switch (tag) {
      '原话' => AppColors.accent,
      _ => AppColors.textSecondary,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (tag != null)
            Container(
              margin: const EdgeInsets.only(right: 8, top: 2),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                border: Border.all(color: color),
                borderRadius: BorderRadius.circular(AppRadii.xs),
              ),
              child: Text(
                tag,
                style: TextStyle(fontSize: AppFontSizes.xs, color: color),
              ),
            ),
          Expanded(
            child: CitedText(
              text: body,
              sources: sources,
              style: const TextStyle(fontSize: AppFontSizes.sm, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _NewerBanner extends StatelessWidget {
  const _NewerBanner({required this.entry});

  final DiaryEntry entry;

  @override
  Widget build(BuildContext context) {
    final c = context.read<RecorderController>();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: SurfaceCard(
        key: const ValueKey('diary-newer'),
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '有新资料，已另外生成新稿；你改过的版本没有被覆盖。',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            Wrap(
              spacing: 4,
              children: [
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('新稿'),
                      content: SingleChildScrollView(
                        child: CitedText(
                          text: entry.newer!.text,
                          sources: entry.newer!.sources,
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('关闭'),
                        ),
                      ],
                    ),
                  ),
                  child: const Text('对照新稿'),
                ),
                TextButton(
                  key: const ValueKey('diary-adopt'),
                  onPressed: () => c.adoptNewerDiary(entry.key),
                  child: const Text('采用新稿'),
                ),
                TextButton(
                  key: const ValueKey('diary-keep'),
                  onPressed: () => c.keepEditedDiary(entry.key),
                  child: const Text('保留我的'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
