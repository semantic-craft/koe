import 'package:flutter/material.dart';

import '../../state/meeting_minutes.dart';
import 'minutes_fishbone.dart';

class MinutesTopicCard extends StatelessWidget {
  const MinutesTopicCard({
    super.key,
    required this.topic,
    required this.sources,
    this.sourcePosition,
  });
  final MinuteTopic topic;
  final Widget Function(List<String>) sources;

  /// Only verified source starts, not a model-invented topic duration.
  final String? sourcePosition;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(topic.text, style: Theme.of(context).textTheme.titleMedium),
          if (sourcePosition != null)
            Text(
              '出处位置 $sourcePosition',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 6),
          SelectableText(topic.summary),
          sources(topic.sources),
          for (final point in topic.points.indexed)
            Padding(
              key: ValueKey('minutes-topic-point-${point.$1}'),
              padding: const EdgeInsets.only(top: 8, left: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(point.$2.text),
                  sources(point.$2.sources),
                ],
              ),
            ),
          if (topic.fishbone != null)
            MinutesFishbone(fishbone: topic.fishbone!, sources: sources),
        ],
      ),
    ),
  );
}
