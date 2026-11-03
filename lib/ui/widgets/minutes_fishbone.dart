import 'package:flutter/material.dart';

import '../../state/meeting_minutes.dart';

/// The same cited causes appear as a list on phones and as branches on a
/// vertical spine when there is enough room. The model never supplies layout.
class MinutesFishbone extends StatelessWidget {
  const MinutesFishbone({
    super.key,
    required this.fishbone,
    required this.sources,
  });

  final MinuteFishbone fishbone;
  final Widget Function(List<String>) sources;

  Widget _cause(BuildContext context, MinuteCause cause, int index) => Padding(
    padding: const EdgeInsets.all(8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(cause.text, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        SelectableText(cause.detail),
        sources(cause.sources),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 12),
      Text('原因分析', style: Theme.of(context).textTheme.labelLarge),
      SelectableText(fishbone.question),
      LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 600 || fishbone.branches.length < 2) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final entry in fishbone.branches.indexed)
                  _cause(context, entry.$2, entry.$1),
              ],
            );
          }
          return Column(
            children: [
              for (var index = 0; index < fishbone.branches.length; index += 2)
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _cause(context, fishbone.branches[index], index),
                      ),
                      _BranchSpine(color: Theme.of(context).dividerColor),
                      Expanded(
                        child: index + 1 < fishbone.branches.length
                            ? _cause(
                                context,
                                fishbone.branches[index + 1],
                                index + 1,
                              )
                            : const SizedBox(),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    ],
  );
}

class _BranchSpine extends StatelessWidget {
  const _BranchSpine({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 24,
    child: Stack(
      fit: StackFit.expand,
      children: [
        Align(
          alignment: Alignment.center,
          child: VerticalDivider(width: 1, color: color),
        ),
        Align(
          alignment: Alignment.center,
          child: Divider(height: 1, color: color),
        ),
      ],
    ),
  );
}
