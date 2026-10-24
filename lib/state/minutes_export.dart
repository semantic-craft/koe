import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'meeting_minutes.dart';
import 'minutes_document.dart';
import 'recording.dart';
import 'recording_analysis.dart';

/// Multi-format export (`.md`, `.docx`, `.pdf`, Rich Text HTML) and subtitle
/// (`.srt`, `.vtt`) export/import for #492 (Parent #375, S11 / S32).
///
/// Subtitle formatting and document export structure reference Shiyin
/// (`Sources/Shiyin/IO/Exporters.swift` @ `7ffd7d4`, MIT).
enum MinutesExportFormat {
  markdown('md', 'Markdown', 'text/markdown'),
  docx(
    'docx',
    'Word (.docx)',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  ),
  pdf('pdf', 'PDF (.pdf)', 'application/pdf');

  const MinutesExportFormat(this.extension, this.label, this.mimeType);
  final String extension;
  final String label;
  final String mimeType;
}

/// Formats [segments] as SubRip (`.srt`) subtitle text (`HH:MM:SS,mmm --> HH:MM:SS,mmm`).
String formatTranscriptSrt(
  List<TranscriptSegment> segments, {
  Map<String, String> aliases = const {},
  bool includeSpeakers = true,
}) {
  if (segments.isEmpty) return '';
  final buffer = StringBuffer();
  var index = 0;
  for (var i = 0; i < segments.length; i++) {
    final seg = segments[i];
    final text = seg.text.trim();
    if (text.isEmpty) continue;
    index++;
    final start = seg.start;
    final nextStart = (i + 1 < segments.length) ? segments[i + 1].start : null;
    final end = _resolveCueEnd(start, seg.end, nextStart);
    final speaker = includeSpeakers
        ? _resolveSpeakerName(seg.speaker, aliases)
        : null;
    final cueBody = (speaker != null && speaker.isNotEmpty)
        ? '$speaker：$text'
        : text;
    if (index > 1) buffer.writeln();
    buffer
      ..writeln(index)
      ..writeln('${_formatSrtTime(start)} --> ${_formatSrtTime(end)}')
      ..writeln(cueBody);
  }
  return buffer.toString();
}

/// Formats [segments] as WebVTT (`.vtt`) subtitle text (`WEBVTT` + `HH:MM:SS.mmm --> HH:MM:SS.mmm`).
String formatTranscriptVtt(
  List<TranscriptSegment> segments, {
  Map<String, String> aliases = const {},
  bool includeSpeakers = true,
}) {
  final buffer = StringBuffer('WEBVTT\n');
  var index = 0;
  for (var i = 0; i < segments.length; i++) {
    final seg = segments[i];
    final text = seg.text.trim();
    if (text.isEmpty) continue;
    index++;
    final start = seg.start;
    final nextStart = (i + 1 < segments.length) ? segments[i + 1].start : null;
    final end = _resolveCueEnd(start, seg.end, nextStart);
    final speaker = includeSpeakers
        ? _resolveSpeakerName(seg.speaker, aliases)
        : null;
    final cueBody = (speaker != null && speaker.isNotEmpty)
        ? '<v $speaker>$text'
        : text;
    buffer
      ..writeln()
      ..writeln(index)
      ..writeln('${_formatVttTime(start)} --> ${_formatVttTime(end)}')
      ..writeln(cueBody);
  }
  return buffer.toString();
}

Duration _resolveCueEnd(
  Duration start,
  Duration? explicitEnd,
  Duration? nextStart,
) {
  if (explicitEnd != null && explicitEnd > start) return explicitEnd;
  if (nextStart != null && nextStart > start) return nextStart;
  return start + const Duration(seconds: 3);
}

String? _resolveSpeakerName(String? rawSpeaker, Map<String, String> aliases) {
  if (rawSpeaker == null) return null;
  final trimmed = rawSpeaker.trim();
  if (trimmed.isEmpty) return null;
  final alias = aliases[trimmed]?.trim();
  if (alias != null && alias.isNotEmpty) return alias;
  if (RegExp(r'^\d+$').hasMatch(trimmed)) {
    final numAlias = aliases['说话人 $trimmed']?.trim();
    if (numAlias != null && numAlias.isNotEmpty) return numAlias;
    return '说话人 $trimmed';
  }
  return trimmed;
}

String _formatSrtTime(Duration d) => _formatCueTimestamp(d, separator: ',');
String _formatVttTime(Duration d) => _formatCueTimestamp(d, separator: '.');

String _formatCueTimestamp(Duration d, {required String separator}) {
  final totalMs = d.inMilliseconds < 0 ? 0 : d.inMilliseconds;
  final hours = totalMs ~/ 3600000;
  final minutes = (totalMs % 3600000) ~/ 60000;
  final seconds = (totalMs % 60000) ~/ 1000;
  final millis = totalMs % 1000;
  String two(int n) => n.toString().padLeft(2, '0');
  String three(int n) => n.toString().padLeft(3, '0');
  return '${two(hours)}:${two(minutes)}:${two(seconds)}$separator${three(millis)}';
}

final RegExp _cueTimeRangePattern = RegExp(
  r'^\s*(\d{1,2}:\d{2}(?::\d{2})?(?:[.,]\d{1,3})?)\s*-->\s*(\d{1,2}:\d{2}(?::\d{2})?(?:[.,]\d{1,3})?)(?:\s+.*)?$',
);

/// Returns true when [raw] looks like an `.srt` or `.vtt` subtitle document.
bool looksLikeSubtitleContent(String fileName, String raw) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.srt') || lower.endsWith('.vtt')) return true;
  final trimmed = raw.trimLeft();
  if (trimmed.startsWith('WEBVTT')) return true;
  for (final line in const LineSplitter().convert(trimmed).take(8)) {
    if (_cueTimeRangePattern.hasMatch(line)) return true;
  }
  return false;
}

/// Parses `.srt` or `.vtt` subtitle text into [MinutesSegment] items,
/// preserving start/end timestamps and speaker labels (`<v Speaker>text` or `Speaker：text`).
List<MinutesSegment> parseSubtitleMinutesSegments(String raw) {
  final lines = const LineSplitter().convert(raw);
  final segments = <MinutesSegment>[];
  var i = 0;
  // Skip optional UTF-8 BOM and WEBVTT header block.
  while (i < lines.length) {
    final trimmed = lines[i].replaceFirst('\uFEFF', '').trim();
    if (trimmed.isEmpty) {
      i++;
      continue;
    }
    if (trimmed.startsWith('WEBVTT')) {
      i++;
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        if (_cueTimeRangePattern.hasMatch(lines[i])) break;
        i++;
      }
      continue;
    }
    if (trimmed.startsWith('NOTE') || trimmed.startsWith('STYLE')) {
      i++;
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        i++;
      }
      continue;
    }
    break;
  }

  while (i < lines.length) {
    final line = lines[i].trim();
    if (line.isEmpty) {
      i++;
      continue;
    }
    var timeMatch = _cueTimeRangePattern.firstMatch(line);
    if (timeMatch == null && i + 1 < lines.length) {
      final nextMatch = _cueTimeRangePattern.firstMatch(lines[i + 1].trim());
      if (nextMatch != null) {
        i++;
        timeMatch = nextMatch;
      }
    }
    if (timeMatch == null) {
      i++;
      continue;
    }
    final start = _parseCueClock(timeMatch.group(1)!);
    final end = _parseCueClock(timeMatch.group(2)!);
    i++;
    final textLines = <String>[];
    while (i < lines.length && lines[i].trim().isNotEmpty) {
      if (_cueTimeRangePattern.hasMatch(lines[i].trim())) break;
      // Stop if this line is a numeric cue index immediately preceding a timecode line.
      if (RegExp(r'^\d+$').hasMatch(lines[i].trim()) &&
          i + 1 < lines.length &&
          _cueTimeRangePattern.hasMatch(lines[i + 1].trim())) {
        break;
      }
      textLines.add(lines[i].trim());
      i++;
    }
    final joined = textLines.join('\n').trim();
    if (joined.isEmpty || start == null) continue;
    final parsedSpeaker = _extractCueSpeaker(joined);
    if (parsedSpeaker.text.isEmpty) continue;
    segments.add(
      MinutesSegment(
        text: parsedSpeaker.text,
        start: start,
        end: (end != null && end >= start) ? end : null,
        speaker: parsedSpeaker.speaker,
      ),
    );
  }
  return segments;
}

/// Parses `.srt` or `.vtt` subtitle text into [TranscriptSegment] items.
List<TranscriptSegment> parseSubtitleTranscriptSegments(String raw) => [
  for (final s in parseSubtitleMinutesSegments(raw))
    TranscriptSegment(
      text: s.text,
      start: s.start,
      end: s.end,
      speaker: s.speaker,
    ),
];

({String text, String? speaker}) _extractCueSpeaker(String rawCue) {
  // WebVTT voice tag: `<v Speaker Name>Text</v>` or `<v Speaker Name>Text`
  final vttMatch = RegExp(
    r'^<v(?:\.[^>\s]+)*\s+([^>]+)>([\s\S]*?)(?:<\/v>)?$',
    caseSensitive: false,
  ).firstMatch(rawCue.trim());
  if (vttMatch != null) {
    final speaker = vttMatch.group(1)!.trim();
    final text = vttMatch.group(2)!.trim();
    if (text.isNotEmpty) {
      return (
        text: text,
        speaker: speaker.isEmpty ? null : speaker,
      );
    }
  }
  // Prefix style: `张三：内容` or `说话人 1: 内容`
  final prefixMatch = RegExp(
    r'^\s*((?:说话人\s*\d+)|(?:Speaker\s*\d+)|[^\s：:]{1,16})\s*[：:]\s*([\s\S]+)$',
  ).firstMatch(rawCue);
  if (prefixMatch != null) {
    final speaker = prefixMatch.group(1)!.trim();
    final text = prefixMatch.group(2)!.trim();
    if (text.isNotEmpty) {
      return (text: text, speaker: speaker);
    }
  }
  return (text: rawCue.trim(), speaker: null);
}

Duration? _parseCueClock(String value) {
  final normalized = value.trim().replaceAll(',', '.');
  final match = RegExp(
    r'^(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\.(\d{1,3}))?$',
  ).firstMatch(normalized);
  if (match == null) return null;
  final first = int.parse(match.group(1)!);
  final second = int.parse(match.group(2)!);
  final third = int.tryParse(match.group(3) ?? '');
  final millis = int.tryParse((match.group(4) ?? '').padRight(3, '0')) ?? 0;
  if (third != null) {
    return Duration(
      hours: first,
      minutes: second,
      seconds: third,
      milliseconds: millis,
    );
  }
  return Duration(minutes: first, seconds: second, milliseconds: millis);
}

/// Builds semantic Rich Text HTML for [minutes] and [result] (#492 / S32).
String buildMinutesHtml(MeetingMinutes minutes, AnalysisResult result) {
  String esc(String s) =>
      const HtmlEscape(HtmlEscapeMode.element).convert(s);
  final b = StringBuffer()
    ..writeln('<!DOCTYPE html>')
    ..writeln('<html lang="zh"><head><meta charset="utf-8">')
    ..writeln('<title>${esc(minutes.title)}</title></head><body>')
    ..writeln('<h1>${esc(minutes.title)}</h1>')
    ..writeln(
      '<p><small>生成模型：${esc(result.model)} · 生成时间：${esc(result.createdAt.toIso8601String())}'
      '${result.editedAt != null ? ' · 手动编辑：${esc(result.editedAt!.toIso8601String())}' : ''}</small></p>',
    )
    ..writeln('<h2>会议概览</h2>')
    ..writeln('<p>${esc(minutes.overview)}</p>');

  if (minutes.reviewItems.isNotEmpty) {
    b.writeln('<h2>待确认问题</h2><ul>');
    for (final q in minutes.reviewItems) {
      b.writeln('<li>${esc(q)}</li>');
    }
    b.writeln('</ul>');
  }

  for (final (sectionTitle, items) in minutes.sections) {
    b.writeln('<h2>${esc(sectionTitle)}</h2>');
    if (items.isEmpty) {
      b.writeln('<p>未提及</p>');
      continue;
    }
    if (sectionTitle == '待办') {
      b
        ..writeln('<table border="1" cellspacing="0" cellpadding="6">')
        ..writeln(
          '<thead><tr><th>事项</th><th>负责人</th><th>期限</th><th>出处</th></tr></thead><tbody>',
        );
      for (final item in items) {
        final cites = item.sources.map((s) => '[$s]').join(' ');
        b.writeln(
          '<tr><td>${esc(item.text)}</td>'
          '<td>${esc(item.owner ?? '未提及')}</td>'
          '<td>${esc(item.due ?? '未提及')}</td>'
          '<td>${esc(cites)}</td></tr>',
        );
      }
      b.writeln('</tbody></table>');
    } else {
      b.writeln('<ul>');
      for (final item in items) {
        final cites = item.sources.map((s) => '[$s]').join(' ');
        b.writeln('<li>${esc(item.text)} ${esc(cites)}</li>');
      }
      b.writeln('</ul>');
    }
  }

  b.writeln('<h2>原文片段</h2>');
  for (var i = 0; i < result.sources.length; i++) {
    b
      ..writeln('<h3>[S${i + 1}]</h3>')
      ..writeln('<p>${esc(result.sources[i].trim())}</p>');
  }
  b.writeln('</body></html>');
  return b.toString();
}

/// Builds an Office Open XML Word (`.docx`) file as bytes (#492 / S32).
///
/// Produces a valid PKZIP archive containing `[Content_Types].xml`,
/// `_rels/.rels`, `word/_rels/document.xml.rels`, `word/styles.xml`, and
/// `word/document.xml` with structured headings, bullet items, an action-items
/// table, and `[S#]` source citations.
Uint8List buildMinutesDocxBytes(
  MeetingMinutes minutes,
  AnalysisResult result,
) {
  String escXml(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  String wParagraph(String text, {String? style, bool bold = false}) {
    final pPr = style != null ? '<w:pPr><w:pStyle w:val="$style"/></w:pPr>' : '';
    final rPr = bold ? '<w:rPr><w:b/></w:rPr>' : '';
    return '<w:p>$pPr<w:r>$rPr<w:t xml:space="preserve">${escXml(text)}</w:t></w:r></w:p>';
  }

  String wCell(String text, {bool header = false}) =>
      '<w:tc><w:tcPr><w:tcW w:w="2200" w:type="dxa"/></w:tcPr>'
      '${wParagraph(text, bold: header)}</w:tc>';

  final body = StringBuffer()
    ..write(wParagraph(minutes.title, style: 'Heading1', bold: true))
    ..write(
      wParagraph(
        '生成模型：${result.model} · 生成时间：${result.createdAt.toIso8601String()}'
        '${result.editedAt != null ? ' · 手动编辑：${result.editedAt!.toIso8601String()}' : ''}',
      ),
    )
    ..write(wParagraph('会议概览', style: 'Heading2', bold: true))
    ..write(wParagraph(minutes.overview));

  if (minutes.reviewItems.isNotEmpty) {
    body.write(wParagraph('待确认问题', style: 'Heading2', bold: true));
    for (final q in minutes.reviewItems) {
      body.write(wParagraph('• $q'));
    }
  }

  for (final (sectionTitle, items) in minutes.sections) {
    body.write(wParagraph(sectionTitle, style: 'Heading2', bold: true));
    if (items.isEmpty) {
      body.write(wParagraph('未提及'));
      continue;
    }
    if (sectionTitle == '待办') {
      body.write('<w:tbl><w:tblPr><w:tblW w:w="8800" w:type="dxa"/></w:tblPr>');
      body.write(
        '<w:tr>'
        '${wCell('事项', header: true)}'
        '${wCell('负责人', header: true)}'
        '${wCell('期限', header: true)}'
        '${wCell('出处', header: true)}'
        '</w:tr>',
      );
      for (final item in items) {
        final cites = item.sources.map((s) => '[$s]').join(' ');
        body.write(
          '<w:tr>'
          '${wCell(item.text)}'
          '${wCell(item.owner ?? '未提及')}'
          '${wCell(item.due ?? '未提及')}'
          '${wCell(cites)}'
          '</w:tr>',
        );
      }
      body.write('</w:tbl>');
    } else {
      for (final item in items) {
        final cites = item.sources.map((s) => '[$s]').join(' ');
        body.write(wParagraph('• ${item.text} $cites'));
      }
    }
  }

  body.write(wParagraph('原文片段', style: 'Heading2', bold: true));
  for (var i = 0; i < result.sources.length; i++) {
    body
      ..write(wParagraph('[S${i + 1}]', style: 'Heading3', bold: true))
      ..write(wParagraph(result.sources[i].trim()));
  }

  const contentTypesXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/word/document.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '<Override PartName="/word/styles.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
      '</Types>';

  const rootRelsXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
      'Target="word/document.xml"/>'
      '</Relationships>';

  const docRelsXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" '
      'Target="styles.xml"/>'
      '</Relationships>';

  const stylesXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:style w:type="paragraph" w:styleId="Heading1">'
      '<w:name w:val="heading 1"/><w:rPr><w:b/><w:sz w:val="36"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Heading2">'
      '<w:name w:val="heading 2"/><w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Heading3">'
      '<w:name w:val="heading 3"/><w:rPr><w:b/><w:sz w:val="24"/></w:rPr></w:style>'
      '</w:styles>';

  final documentXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>$body'
      '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr>'
      '</w:body></w:document>';

  return buildZipArchive({
    '[Content_Types].xml': utf8.encode(contentTypesXml),
    '_rels/.rels': utf8.encode(rootRelsXml),
    'word/_rels/document.xml.rels': utf8.encode(docRelsXml),
    'word/styles.xml': utf8.encode(stylesXml),
    'word/document.xml': utf8.encode(documentXml),
  });
}

/// Builds a multi-page PDF 1.4 document (`%PDF-1.4`) containing [minutes] and
/// [result] (#492 / S32).
///
/// Uses a CIDFontType0 (`/UniGB-UTF16-H` / `/STSong-Light`) for CJK + ASCII
/// rendering with automatic pagination and includes an embedded UTF-8 markdown
/// text stream so both PDF viewers and text/structure inspectors can read it.
Uint8List buildMinutesPdfBytes(
  MeetingMinutes minutes,
  AnalysisResult result, {
  int linesPerPage = 36,
}) {
  final lines = <({String text, int fontSize})>[
    (text: minutes.title, fontSize: 18),
    (
      text:
          '生成模型：${result.model} · 生成时间：${result.createdAt.toIso8601String()}'
          '${result.editedAt != null ? ' · 手动编辑：${result.editedAt!.toIso8601String()}' : ''}',
      fontSize: 9,
    ),
    (text: '', fontSize: 11),
    (text: '会议概览', fontSize: 14),
    for (final line in _wrapPdfLines(minutes.overview, 42))
      (text: line, fontSize: 11),
  ];

  if (minutes.reviewItems.isNotEmpty) {
    lines.add((text: '', fontSize: 11));
    lines.add((text: '待确认问题', fontSize: 14));
    for (final q in minutes.reviewItems) {
      for (final wrapped in _wrapPdfLines('• $q', 42)) {
        lines.add((text: wrapped, fontSize: 11));
      }
    }
  }

  for (final (sectionTitle, items) in minutes.sections) {
    lines.add((text: '', fontSize: 11));
    lines.add((text: sectionTitle, fontSize: 14));
    if (items.isEmpty) {
      lines.add((text: '• 未提及', fontSize: 11));
      continue;
    }
    for (final item in items) {
      final cites = item.sources.map((s) => '[$s]').join(' ');
      final meta = item.owner != null
          ? '（负责人：${item.owner}，期限：${item.due}）'
          : '';
      for (final wrapped in _wrapPdfLines('• ${item.text}$meta $cites', 42)) {
        lines.add((text: wrapped, fontSize: 11));
      }
    }
  }

  lines.add((text: '', fontSize: 11));
  lines.add((text: '原文片段', fontSize: 14));
  for (var i = 0; i < result.sources.length; i++) {
    lines.add((text: '[S${i + 1}]', fontSize: 12));
    for (final wrapped in _wrapPdfLines(result.sources[i].trim(), 44)) {
      lines.add((text: wrapped, fontSize: 10));
    }
  }

  final effectiveLinesPerPage = linesPerPage < 5 ? 5 : linesPerPage;
  final pages = <List<({String text, int fontSize})>>[];
  for (var i = 0; i < lines.length; i += effectiveLinesPerPage) {
    final end = (i + effectiveLinesPerPage < lines.length)
        ? i + effectiveLinesPerPage
        : lines.length;
    pages.add(lines.sublist(i, end));
  }
  if (pages.isEmpty) {
    pages.add([(text: minutes.title, fontSize: 16)]);
  }

  // Object numbering:
  // 1: Catalog
  // 2: Pages
  // 3: Font (Type0 / UniGB-UTF16-H)
  // 4: Descendant CIDFontType0
  // 5: Embedded UTF-8 Markdown representation (Metadata / PieceInfo stream)
  // For each page p (0..pages.length-1):
  //   pageObj = 6 + p * 2
  //   contentObj = 7 + p * 2
  final objects = <int, List<int>>{};
  final pageObjectIds = <int>[];

  for (var p = 0; p < pages.length; p++) {
    final pageObjId = 6 + p * 2;
    final contentObjId = 7 + p * 2;
    pageObjectIds.add(pageObjId);

    final stream = StringBuffer()..writeln('BT');
    var y = 780;
    for (final line in pages[p]) {
      if (line.text.isNotEmpty) {
        final hex = _encodeUtf16BeHex(line.text);
        stream
          ..writeln('/F1 ${line.fontSize} Tf')
          ..writeln('1 0 0 1 52 $y Tm')
          ..writeln('<$hex> Tj');
      }
      y -= (line.fontSize + 7);
    }
    stream.writeln('ET');
    final streamBytes = utf8.encode(stream.toString());
    objects[contentObjId] = [
      ...utf8.encode('<< /Length ${streamBytes.length} >>\nstream\n'),
      ...streamBytes,
      ...utf8.encode('endstream'),
    ];
    objects[pageObjId] = utf8.encode(
      '<< /Type /Page /Parent 2 0 R '
      '/MediaBox [0 0 595 842] '
      '/Resources << /Font << /F1 3 0 R >> >> '
      '/Contents $contentObjId 0 R >>',
    );
  }

  objects[1] = utf8.encode(
    '<< /Type /Catalog /Pages 2 0 R /Metadata 5 0 R >>',
  );
  final kids = pageObjectIds.map((id) => '$id 0 R').join(' ');
  objects[2] = utf8.encode(
    '<< /Type /Pages /Kids [ $kids ] /Count ${pageObjectIds.length} >>',
  );
  objects[3] = utf8.encode(
    '<< /Type /Font /Subtype /Type0 /BaseFont /STSong-Light '
    '/Encoding /UniGB-UTF16-H /DescendantFonts [ 4 0 R ] >>',
  );
  objects[4] = utf8.encode(
    '<< /Type /Font /Subtype /CIDFontType0 /BaseFont /STSong-Light '
    '/CIDSystemInfo << /Registry (Adobe) /Ordering (GB1) /Supplement 4 >> >>',
  );
  final markdownBytes = utf8.encode(minutes.export(result));
  objects[5] = [
    ...utf8.encode(
      '<< /Type /Metadata /Subtype /Markdown /Length ${markdownBytes.length} >>\nstream\n',
    ),
    ...markdownBytes,
    ...utf8.encode('\nendstream'),
  ];

  final totalObjects = 5 + pages.length * 2;
  final out = BytesBuilder();
  out.add(utf8.encode('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n'));
  final offsets = List<int>.filled(totalObjects + 1, 0);
  for (var id = 1; id <= totalObjects; id++) {
    offsets[id] = out.length;
    out.add(utf8.encode('$id 0 obj\n'));
    out.add(objects[id]!);
    out.add(utf8.encode('\nendobj\n'));
  }
  final xrefOffset = out.length;
  out.add(utf8.encode('xref\n0 ${totalObjects + 1}\n'));
  out.add(utf8.encode('0000000000 65535 f \n'));
  for (var id = 1; id <= totalObjects; id++) {
    final off = offsets[id].toString().padLeft(10, '0');
    out.add(utf8.encode('$off 00000 n \n'));
  }
  out.add(
    utf8.encode(
      'trailer\n<< /Size ${totalObjects + 1} /Root 1 0 R >>\n'
      'startxref\n$xrefOffset\n%%EOF\n',
    ),
  );
  return out.toBytes();
}

List<String> _wrapPdfLines(String text, int maxRunesPerLine) {
  final result = <String>[];
  for (final rawLine in const LineSplitter().convert(text)) {
    final runes = rawLine.runes.toList();
    if (runes.isEmpty) {
      result.add('');
      continue;
    }
    for (var i = 0; i < runes.length; i += maxRunesPerLine) {
      final end = (i + maxRunesPerLine < runes.length)
          ? i + maxRunesPerLine
          : runes.length;
      result.add(String.fromCharCodes(runes.sublist(i, end)));
    }
  }
  return result;
}

String _encodeUtf16BeHex(String text) {
  final sb = StringBuffer('FEFF');
  for (final unit in text.codeUnits) {
    sb.write(unit.toRadixString(16).toUpperCase().padLeft(4, '0'));
  }
  return sb.toString();
}

/// Builds a standard PKZIP archive from [entries] (filename -> bytes).
Uint8List buildZipArchive(Map<String, List<int>> entries) {
  final out = BytesBuilder();
  final centralDirectory = BytesBuilder();
  var count = 0;

  for (final entry in entries.entries) {
    count++;
    final nameBytes = utf8.encode(entry.key);
    final rawBytes = Uint8List.fromList(entry.value);
    final crc = _crc32(rawBytes);
    final compressed = Uint8List.fromList(
      ZLibCodec(raw: true).encode(rawBytes),
    );
    final localHeaderOffset = out.length;

    // Local file header (`PK\x03\x04`)
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little) // version needed: 2.0
      ..setUint16(6, 0x0800, Endian.little) // UTF-8 filename flag
      ..setUint16(8, 8, Endian.little) // compression method: deflate (8)
      ..setUint16(10, 0, Endian.little)
      ..setUint16(12, 0, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, compressed.length, Endian.little)
      ..setUint32(22, rawBytes.length, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little)
      ..setUint16(28, 0, Endian.little);
    out
      ..add(local.buffer.asUint8List())
      ..add(nameBytes)
      ..add(compressed);

    // Central directory header (`PK\x01\x02`)
    final central = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, 0x0800, Endian.little)
      ..setUint16(10, 8, Endian.little)
      ..setUint16(12, 0, Endian.little)
      ..setUint16(14, 0, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, compressed.length, Endian.little)
      ..setUint32(24, rawBytes.length, Endian.little)
      ..setUint16(28, nameBytes.length, Endian.little)
      ..setUint16(30, 0, Endian.little)
      ..setUint16(32, 0, Endian.little)
      ..setUint16(34, 0, Endian.little)
      ..setUint16(36, 0, Endian.little)
      ..setUint32(38, 0, Endian.little)
      ..setUint32(42, localHeaderOffset, Endian.little);
    centralDirectory
      ..add(central.buffer.asUint8List())
      ..add(nameBytes);
  }

  final centralOffset = out.length;
  final centralBytes = centralDirectory.toBytes();
  out.add(centralBytes);

  // End of central directory record (`PK\x05\x06`)
  final eocd = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(4, 0, Endian.little)
    ..setUint16(6, 0, Endian.little)
    ..setUint16(8, count, Endian.little)
    ..setUint16(10, count, Endian.little)
    ..setUint32(12, centralBytes.length, Endian.little)
    ..setUint32(16, centralOffset, Endian.little)
    ..setUint16(20, 0, Endian.little);
  out.add(eocd.buffer.asUint8List());
  return out.toBytes();
}

/// Reads entries from a PKZIP archive (supports stored `0` and deflate `8`).
Map<String, Uint8List> readZipArchive(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final result = <String, Uint8List>{};
  var offset = 0;
  while (offset + 30 <= bytes.length) {
    final sig = data.getUint32(offset, Endian.little);
    if (sig != 0x04034b50) break;
    final method = data.getUint16(offset + 8, Endian.little);
    final compressedSize = data.getUint32(offset + 18, Endian.little);
    final nameLen = data.getUint16(offset + 26, Endian.little);
    final extraLen = data.getUint16(offset + 28, Endian.little);
    final nameStart = offset + 30;
    final dataStart = nameStart + nameLen + extraLen;
    final dataEnd = dataStart + compressedSize;
    if (dataEnd > bytes.length) break;
    final name = utf8.decode(bytes.sublist(nameStart, nameStart + nameLen));
    final payload = bytes.sublist(dataStart, dataEnd);
    if (method == 0) {
      result[name] = Uint8List.fromList(payload);
    } else if (method == 8) {
      result[name] = Uint8List.fromList(ZLibCodec(raw: true).decode(payload));
    }
    offset = dataEnd;
  }
  return result;
}

final List<int> _crc32Table = List<int>.generate(256, (index) {
  var c = index;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
  }
  return c;
});

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final b in bytes) {
    crc = _crc32Table[(crc ^ b) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
