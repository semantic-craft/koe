import 'dart:typed_data';

/// A finished 16 kHz mono PCM16 WAV whose header matches [pcm].
///
/// [declaredDataSize] overrides the data chunk size (e.g. larger than the
/// payload to model a truncated transfer); [riffSize] overrides the RIFF size.
/// [extraChunk] inserts a chunk between `fmt ` and `data`.
Uint8List wavBytes(
  List<int> pcm, {
  int? declaredDataSize,
  int? riffSize,
  ({String id, List<int> body})? extraChunk,
}) {
  final extra = extraChunk == null
      ? Uint8List(0)
      : _chunk(extraChunk.id, extraChunk.body);
  final dataSize = declaredDataSize ?? pcm.length;
  final header = ByteData(44);
  void ascii(int offset, String value) {
    for (var i = 0; i < 4; i++) {
      header.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(
    4,
    riffSize ?? 36 + extra.length + pcm.length,
    Endian.little,
  );
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, 16000, Endian.little);
  header.setUint32(28, 32000, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, dataSize, Endian.little);
  final bytes = header.buffer.asUint8List();
  return Uint8List.fromList([
    ...bytes.sublist(0, 36),
    ...extra,
    ...bytes.sublist(36),
    ...pcm,
  ]);
}

Uint8List _chunk(String id, List<int> body) {
  final head = ByteData(8);
  for (var i = 0; i < 4; i++) {
    head.setUint8(i, id.codeUnitAt(i));
  }
  head.setUint32(4, body.length, Endian.little);
  return Uint8List.fromList([
    ...head.buffer.asUint8List(),
    ...body,
    if (body.length.isOdd) 0,
  ]);
}
