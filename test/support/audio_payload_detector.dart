import 'dart:convert';
import 'dart:typed_data';

/// Shared 24-byte non-zero PCM sample signature used by local-only audio tests.
final Uint8List defaultTestPcmPattern = Uint8List.fromList([
  0x5A,
  0xA5,
  0x3C,
  0xC3,
  0x7E,
  0xE7,
  0x18,
  0x81,
  0x42,
  0x24,
  0x99,
  0x66,
  0xBD,
  0xDB,
  0xAA,
  0x55,
  0x13,
  0x37,
  0xDE,
  0xAD,
  0xBE,
  0xEF,
  0xCA,
  0xFE,
]);

final List<Uint8List> _containerSignatures = [
  Uint8List.fromList(ascii.encode('RIFF')),
  Uint8List.fromList(ascii.encode('WAVE')),
  Uint8List.fromList(ascii.encode('ftyp')),
  Uint8List.fromList(ascii.encode('M4A ')),
  Uint8List.fromList(ascii.encode('OggS')),
  Uint8List.fromList(ascii.encode('OpusHead')),
];

final Uint8List _wavFmtSignature = Uint8List.fromList(ascii.encode('WAVEfmt '));

bool containsByteSublist(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || haystack.length < needle.length) return false;
  final limit = haystack.length - needle.length;
  for (var i = 0; i <= limit; i++) {
    var matched = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return true;
  }
  return false;
}

/// Returns true if [bodyBytes] carries raw or Base64-encoded audio container
/// headers or PCM sample bytes (across any byte offset mod 3, short slices,
/// URL-safe Base64, or line-wrapped Base64).
bool requestCarriesAudioBytes(
  Uint8List bodyBytes, {
  List<int>? pcmPattern,
}) {
  final pattern = pcmPattern == null
      ? defaultTestPcmPattern
      : Uint8List.fromList(pcmPattern);
  final doubledPattern = Uint8List.fromList([...pattern, ...pattern]);
  const windowBytes = 12;

  bool bytesHaveAudio(List<int> bytes) {
    for (final sig in _containerSignatures) {
      if (containsByteSublist(bytes, sig)) return true;
    }
    if (pattern.length < windowBytes) {
      return containsByteSublist(bytes, pattern);
    }
    for (var start = 0; start < pattern.length; start++) {
      final window = doubledPattern.sublist(start, start + windowBytes);
      if (containsByteSublist(bytes, window)) return true;
    }
    return false;
  }

  if (bytesHaveAudio(bodyBytes)) return true;

  final rawText = utf8.decode(bodyBytes, allowMalformed: true);
  // Strip line breaks inside Base64 blocks and normalize URL-safe alphabet.
  final normalizedText = rawText
      .replaceAll('\r', '')
      .replaceAll('\n', '')
      .replaceAll('-', '+')
      .replaceAll('_', '/');

  // 1. Check all 3 Base64 triplet alignments (0, 1, 2 byte prefix) for
  // WAVEfmt and every 12-byte window of the repeating PCM pattern.
  Iterable<String> alignedBase64Fragments(List<int> slice) sync* {
    for (var pad = 0; pad < 3; pad++) {
      final padded = <int>[for (var i = 0; i < pad; i++) 0, ...slice];
      final fullGroups = padded.length ~/ 3;
      if (fullGroups <= 1) continue;
      final encoded = base64Encode(padded.sublist(0, fullGroups * 3));
      // If pad > 0, the first 4 chars depend on the unknown prefix bytes.
      final stable = pad == 0 ? encoded : encoded.substring(4);
      if (stable.length >= 8) yield stable;
    }
  }

  for (final frag in alignedBase64Fragments(_wavFmtSignature)) {
    if (normalizedText.contains(frag)) return true;
  }
  if (pattern.length >= windowBytes) {
    for (var start = 0; start < pattern.length; start++) {
      final window = doubledPattern.sublist(start, start + windowBytes);
      for (final frag in alignedBase64Fragments(window)) {
        if (normalizedText.contains(frag)) return true;
      }
    }
  }

  // 2. Decode candidate Base64 runs under all 4 character offsets (covering
  // arbitrary slicing of a Base64 stream) and check decoded bytes for headers
  // or PCM sample windows.
  final tokenRegex = RegExp(r'[A-Za-z0-9+/]{16,}={0,2}');
  for (final match in tokenRegex.allMatches(normalizedText)) {
    final token = match.group(0)!;
    final core = token.replaceAll('=', '');
    for (var charShift = 0; charShift < 4; charShift++) {
      if (core.length - charShift < 12) continue;
      final sub = core.substring(charShift);
      final usableLen = (sub.length ~/ 4) * 4;
      if (usableLen < 12) continue;
      try {
        final decoded = base64Decode(sub.substring(0, usableLen));
        if (bytesHaveAudio(decoded)) return true;
      } catch (_) {}
    }
  }

  return false;
}
