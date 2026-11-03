import 'package:flutter/material.dart';

import '../../state/meeting_minutes.dart';

class MinutesTerms extends StatelessWidget {
  const MinutesTerms({
    super.key,
    required this.terms,
    required this.sources,
    this.onVocabulary,
    this.onReplace,
    this.onEvidence,
    this.replacementCount,
  });
  final List<MinuteTerm> terms;
  final Widget Function(List<String>) sources;
  final void Function(int)? onVocabulary, onReplace, onEvidence;
  final int Function(MinuteTerm)? replacementCount;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Text('人名和术语', style: Theme.of(context).textTheme.titleMedium),
      ),
      Text('候选解释需要你确认；订正仅影响本场。', style: Theme.of(context).textTheme.bodySmall),
      for (final (index, term) in terms.indexed)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(term.name, style: Theme.of(context).textTheme.titleSmall),
                SelectableText(term.note),
                if (term.heard.isNotEmpty)
                  SelectableText('原文中的识别写法：${term.heard.join('、')}'),
                if (term.adoption case final decision?)
                  Text(
                    '${decision.kind == 'vocabulary' ? '已加入词表' : '已订正原文'} · ${decision.at.toLocal().toIso8601String().split('T').first}',
                  ),
                sources(term.sources),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed:
                          onVocabulary == null ||
                              term.name.runes.length > 40 ||
                              term.adoption?.kind == 'vocabulary'
                          ? null
                          : () => onVocabulary!(index),
                      child: const Text('仅加入词表'),
                    ),
                    TextButton(
                      onPressed:
                          onReplace == null ||
                              (replacementCount?.call(term) ?? 0) == 0
                          ? null
                          : () => onReplace!(index),
                      child: const Text('订正本场原文'),
                    ),
                    if (term.adoption != null)
                      TextButton(
                        onPressed: onEvidence == null
                            ? null
                            : () => onEvidence!(index),
                        child: const Text('采纳前原文'),
                      ),
                  ],
                ),
                if (term.name.runes.length > 40)
                  const Text('名称超过 40 字，不能加入词表。'),
              ],
            ),
          ),
        ),
    ],
  );
}
