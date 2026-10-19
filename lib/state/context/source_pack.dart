import 'context_file.dart';
import 'context_item.dart';

/// One numbered sentence handed to the model, and where it came from. The
/// label (`S3`) is what the model cites; the source replays the audio.
class SourceLine {
  const SourceLine({
    required this.label,
    required this.title,
    required this.text,
    required this.source,
    this.at,
  });

  final String label;

  /// The recording's title, for showing the citation.
  final String title;
  final String text;
  final ContextSource source;

  /// When the recording started, when known.
  final DateTime? at;

  Map<String, Object?> toJson() => {
    'label': label,
    'title': title,
    'text': text,
    'source': source.toJson(),
    if (at != null) 'at': at!.toIso8601String(),
  };

  static SourceLine? decode(Object? value) {
    if (value is! Map) return null;
    final label = value['label'];
    final title = value['title'];
    final text = value['text'];
    final source = ContextSource.decode(value['source']);
    if (label is! String ||
        title is! String ||
        text is! String ||
        source == null) {
      return null;
    }
    return SourceLine(
      label: label,
      title: title,
      text: text,
      source: source,
      at: decodeTime(value['at']),
    );
  }

  static List<SourceLine> decodeAll(Object? value) => [
    for (final entry in value is List ? value : const [])
      ?SourceLine.decode(entry),
  ];
}

/// The model input for [lines]: `[S1] 10:05 周会：句子`.
String renderSourceLines(List<SourceLine> lines) {
  String two(int value) => value.toString().padLeft(2, '0');
  return [
    for (final line in lines)
      '[${line.label}] '
          '${line.at == null ? '' : '${line.at!.month}/${line.at!.day} ${two(line.at!.hour)}:${two(line.at!.minute)} '}'
          '${line.title}：${line.text}',
  ].join('\n');
}

final _citation = RegExp(r'\[(S\d+)\]');

/// Labels cited in [text], in order of first appearance.
List<String> citedLabels(String text) {
  final seen = <String>{};
  return [
    for (final match in _citation.allMatches(text))
      if (seen.add(match.group(1)!)) match.group(1)!,
  ];
}

/// Splits [text] into plain runs and citation labels, for rendering.
List<(String text, String? label)> splitCitations(String text) {
  final parts = <(String, String?)>[];
  var cursor = 0;
  for (final match in _citation.allMatches(text)) {
    if (match.start > cursor) {
      parts.add((text.substring(cursor, match.start), null));
    }
    parts.add((match.group(0)!, match.group(1)));
    cursor = match.end;
  }
  if (cursor < text.length) parts.add((text.substring(cursor), null));
  return parts;
}
