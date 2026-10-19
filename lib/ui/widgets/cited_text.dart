import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../context_source.dart';

/// Model text whose `[S3]` citations open the cited sentence and play it.
/// A label with no matching source is shown struck through, never linked to
/// some other material.
class CitedText extends StatefulWidget {
  const CitedText({
    super.key,
    required this.text,
    required this.sources,
    this.style,
  });

  final String text;
  final List<SourceLine> sources;
  final TextStyle? style;

  @override
  State<CitedText> createState() => _CitedTextState();
}

class _CitedTextState extends State<CitedText> {
  final List<TapGestureRecognizer> _taps = [];

  TapGestureRecognizer _tap(VoidCallback onTap) {
    final recognizer = TapGestureRecognizer()..onTap = onTap;
    _taps.add(recognizer);
    return recognizer;
  }

  @override
  void dispose() {
    for (final tap in _taps) {
      tap.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final tap in _taps) {
      tap.dispose();
    }
    _taps.clear();
    final byLabel = {for (final line in widget.sources) line.label: line};
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          for (final (text, label) in splitCitations(widget.text))
            if (label == null)
              TextSpan(text: text)
            else if (byLabel[label] case final line?)
              TextSpan(
                text: '[$label]',
                style: const TextStyle(
                  color: AppColors.mint,
                  fontWeight: FontWeight.w600,
                ),
                recognizer: _tap(() => openContextSource(context, line.source)),
              )
            else
              TextSpan(
                text: '[$label]',
                style: const TextStyle(
                  color: AppColors.textMuted,
                  decoration: TextDecoration.lineThrough,
                ),
              ),
        ],
      ),
    );
  }
}

/// The cited sentences under a text, each tappable to replay it.
class SourceList extends StatelessWidget {
  const SourceList({super.key, required this.sources});

  final List<SourceLine> sources;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final line in sources)
          InkWell(
            key: ValueKey('source-${line.label}'),
            onTap: () => openContextSource(context, line.source),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '[${line.label}] ${line.title} ▶︎ ${offsetLabel(line.source.start)}\n「${line.text}」',
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
