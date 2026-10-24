import 'package:file_selector/file_selector.dart';

/// File picker filters shared by every import entry.
///
/// iOS filters only by uniform type identifiers: a group with extensions alone
/// makes the picker throw before it opens, so each group names its UTIs too.
const audioFileTypes = XTypeGroup(
  label: '音频',
  extensions: ['wav', 'm4a', 'mp3', 'aac', 'flac', 'ogg', 'opus'],
  mimeTypes: ['audio/*'],
  uniformTypeIdentifiers: ['public.audio'],
);

/// Feishu Minutes exports: plain text or JSON.
const minutesTextFileTypes = XTypeGroup(
  label: '妙记文字',
  extensions: ['json', 'txt', 'srt', 'vtt', 'md'],
  uniformTypeIdentifiers: [
    'public.plain-text',
    'public.json',
    'public.text',
    'net.daringfireball.markdown',
  ],
);

/// Koe material packs (`.koepack`). The type is not declared to the system,
/// so iOS offers any file and the import checks the contents.
const materialPackFileTypes = XTypeGroup(
  label: 'Koe 资料包',
  extensions: ['koepack'],
  uniformTypeIdentifiers: ['public.data'],
);
