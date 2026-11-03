import 'package:flutter/material.dart';

import '../../state/meeting_minutes.dart';

class MinutesTerms extends StatelessWidget {
  const MinutesTerms({super.key, required this.terms, required this.sources});
  final List<MinuteTerm> terms;
  final Widget Function(List<String>) sources;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Text('人名和术语', style: Theme.of(context).textTheme.titleMedium),
      ),
      Text('以下为本场候选解释，尚未改写原文。', style: Theme.of(context).textTheme.bodySmall),
      for (final term in terms)
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
                sources(term.sources),
              ],
            ),
          ),
        ),
    ],
  );
}
