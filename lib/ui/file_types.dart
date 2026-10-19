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
  extensions: ['json', 'txt'],
  uniformTypeIdentifiers: ['public.plain-text', 'public.json'],
);
