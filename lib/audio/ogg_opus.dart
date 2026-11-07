import 'dart:io';
import 'dart:typed_data';

import '../native/koe_core_ffi.dart';
import '../util/off_ui.dart';
import 'recording_audio.dart';

/// Wrap D3200 raw AES-decrypted Opus frames (fixed 160-byte slices) into an
/// Ogg Opus file playable by AVFoundation / just_audio.
///
/// Device stream is not Ogg-containerized — bare concatenation of 160-B frames
/// (PROTOCOL duration heuristic ≈ 20 ms/frame @ 48 kHz mono).
class OggOpus {
  OggOpus._();

  static const frameSize = 160;
  static const sampleRate = 48000;
  static const samplesPerFrame = 960; // 20 ms @ 48 kHz

  static bool isOgg(List<int> bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x4F &&
      bytes[1] == 0x67 &&
      bytes[2] == 0x67 &&
      bytes[3] == 0x53;

  static bool isWav(List<int> bytes) =>
      bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x41 &&
      bytes[10] == 0x56 &&
      bytes[11] == 0x45;

  /// Raw files at least this large are muxed on a background isolate.
  static const backgroundThreshold = 256 * 1024;

  /// Returns path to a playable Ogg file (creates sidecar `*.ogg` if needed).
  ///
  /// A fresh sidecar is reused from file metadata alone; the source is only
  /// read (streamed, off the UI isolate when large) when it must be muxed.
  static Future<String> ensurePlayable(String path) async {
    final file = File(path);
    final rawStat = await file.stat();
    if (rawStat.type != FileSystemEntityType.file) {
      throw StateError('文件不存在：$path');
    }
    if (rawStat.size == 0) {
      throw StateError('文件为空');
    }
    // Only device originals are bare Opus frames. Imported m4a/mp3/aac are
    // containers the player opens as they are; a sidecar left by an older
    // build must not be reused for them.
    final audio = RecordingAudio.of(path);
    if (!audio.isDeviceFrames) return path;
    final oggPath = audio.oggSidecar;
    // Rebuild if missing or older/smaller than source.
    final oggStat = await File(oggPath).stat();
    if (oggStat.type == FileSystemEntityType.file &&
        oggStat.modified.isAfter(rawStat.modified) &&
        oggStat.size > 64) {
      return oggPath;
    }

    final input = await file.open();
    final List<int> header;
    try {
      header = await input.read(12);
    } finally {
      await input.close();
    }
    if (isOgg(header) || isWav(header)) return path;

    return runOffUi(
      () => _muxFile(path, oggPath, partSuffix: '.play-part'),
      size: rawStat.size,
      threshold: backgroundThreshold,
      debugName: 'OggOpus.ensurePlayable',
    );
  }

  /// Bounded-memory variant for large uploads. Partial output is never reused.
  static Future<String> prepareUpload(
    String path, {
    bool Function()? isCurrent,
  }) async {
    void check() {
      if (isCurrent != null && !isCurrent()) throw StateError('已取消');
    }

    check();
    final input = await File(path).open();
    final List<int> header;
    try {
      header = await input.read(12);
    } finally {
      await input.close();
    }
    if (header.isEmpty) throw StateError('文件为空');
    if (isWav(header) || isOgg(header)) return path;
    final audio = RecordingAudio.of(path);
    if (!audio.isDeviceFrames) throw StateError('不支持的音频格式');
    return _muxFile(
      path,
      audio.oggSidecar,
      partSuffix: '.upload-part',
      check: check,
    );
  }

  /// Streams raw frames from [path] into an Ogg file at [destination],
  /// writing to a partial file first so an interrupted run is never reused.
  static Future<String> _muxFile(
    String path,
    String destination, {
    required String partSuffix,
    void Function()? check,
  }) async {
    final input = await File(path).open();
    File? partial;
    RandomAccessFile? output;
    try {
      partial = File('$destination$partSuffix');
      output = await partial.open(mode: FileMode.write);
      const serial = 0x41524b52;
      var sequence = 0;
      var granule = 0;
      await output.writeFrom(
        _page(
          packets: [_opusHead(channels: 1, sampleRate: sampleRate)],
          serial: serial,
          sequence: sequence++,
          granule: 0,
          bos: true,
        ),
      );
      await output.writeFrom(
        _page(
          packets: [_opusTags()],
          serial: serial,
          sequence: sequence++,
          granule: 0,
        ),
      );
      final length = await input.length();
      while (await input.position() < length) {
        check?.call();
        final bytes = await input.read(frameSize * 50);
        final packets = <Uint8List>[];
        for (var offset = 0; offset < bytes.length; offset += frameSize) {
          packets.add(
            _trimTrailingZeros(
              Uint8List.sublistView(
                bytes,
                offset,
                (offset + frameSize).clamp(0, bytes.length),
              ),
            ),
          );
        }
        granule += samplesPerFrame * packets.length;
        await output.writeFrom(
          _page(
            packets: packets,
            serial: serial,
            sequence: sequence++,
            granule: granule,
            eos: await input.position() >= length,
          ),
        );
      }
      check?.call();
      await output.flush();
      await output.close();
      output = null;
      await partial.rename(destination);
      partial = null;
      return destination;
    } finally {
      await input.close();
      await output?.close();
      if (partial != null && await partial.exists()) await partial.delete();
    }
  }

  /// Mux fixed-size (or trailing partial) frames into Ogg Opus bytes.
  static Uint8List muxRawFrames(Uint8List raw) {
    if (raw.isEmpty) {
      throw StateError('无音频数据');
    }
    final ffi = KoeCoreFfi.instance;
    if (ffi != null) {
      return ffi.oggOpusMuxRawFrames(raw);
    }
    // Prefer exact 160-byte framing; otherwise treat whole buffer as one stream
    // of opaque packets of 160 with a possible short tail.
    final frames = <Uint8List>[];
    if (raw.length >= frameSize) {
      var o = 0;
      while (o + frameSize <= raw.length) {
        frames.add(Uint8List.sublistView(raw, o, o + frameSize));
        o += frameSize;
      }
      if (o < raw.length) {
        frames.add(Uint8List.sublistView(raw, o));
      }
    } else {
      frames.add(raw);
    }

    final serial = 0x41524B52; // 'ARKR'
    final out = BytesBuilder(copy: false);
    var seq = 0;
    out.add(
      _page(
        packets: [_opusHead(channels: 1, sampleRate: sampleRate)],
        serial: serial,
        sequence: seq++,
        granule: 0,
        bos: true,
      ),
    );
    out.add(
      _page(
        packets: [_opusTags()],
        serial: serial,
        sequence: seq++,
        granule: 0,
      ),
    );

    var granule = 0;
    const perPage = 50;
    for (var i = 0; i < frames.length; i += perPage) {
      final batch = frames.sublist(
        i,
        i + perPage > frames.length ? frames.length : i + perPage,
      );
      final packets = batch.map(_trimTrailingZeros).toList();
      granule += samplesPerFrame * packets.length;
      final eos = i + perPage >= frames.length;
      out.add(
        _page(
          packets: packets,
          serial: serial,
          sequence: seq++,
          granule: granule,
          eos: eos,
        ),
      );
    }
    return out.toBytes();
  }

  static Uint8List _trimTrailingZeros(Uint8List f) {
    var n = f.length;
    while (n > 1 && f[n - 1] == 0) {
      n--;
    }
    return n == f.length ? f : Uint8List.sublistView(f, 0, n);
  }

  static Uint8List _opusHead({required int channels, required int sampleRate}) {
    final b = BytesBuilder(copy: false);
    b.add(ascii('OpusHead'));
    b.addByte(1); // version
    b.addByte(channels);
    b.add(_u16le(3840)); // pre-skip
    b.add(_u32le(sampleRate));
    b.add(_u16le(0)); // output gain
    b.addByte(0); // channel mapping family
    return b.toBytes();
  }

  static Uint8List _opusTags() {
    final b = BytesBuilder(copy: false);
    b.add(ascii('OpusTags'));
    final vendor = ascii('AnkerRecorder');
    b.add(_u32le(vendor.length));
    b.add(vendor);
    b.add(_u32le(0)); // user comment list length
    return b.toBytes();
  }

  static Uint8List ascii(String s) => Uint8List.fromList(s.codeUnits);

  static Uint8List _u16le(int v) =>
      Uint8List.fromList([v & 0xFF, (v >> 8) & 0xFF]);

  static Uint8List _u32le(int v) => Uint8List.fromList([
    v & 0xFF,
    (v >> 8) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 24) & 0xFF,
  ]);

  static Uint8List _u64le(int v) {
    final o = ByteData(8)..setUint64(0, v, Endian.little);
    return o.buffer.asUint8List();
  }

  static Uint8List _page({
    required List<Uint8List> packets,
    required int serial,
    required int sequence,
    required int granule,
    bool bos = false,
    bool eos = false,
    bool cont = false,
  }) {
    final segs = <int>[];
    final body = BytesBuilder(copy: false);
    for (final pkt in packets) {
      body.add(pkt);
      var n = pkt.length;
      while (n >= 255) {
        segs.add(255);
        n -= 255;
      }
      segs.add(n);
    }
    var headerType = 0;
    if (cont) headerType |= 0x01;
    if (bos) headerType |= 0x02;
    if (eos) headerType |= 0x04;

    final header = BytesBuilder(copy: false);
    header.add(ascii('OggS'));
    header.addByte(0); // version
    header.addByte(headerType);
    header.add(_u64le(granule));
    header.add(_u32le(serial));
    header.add(_u32le(sequence));
    header.add(_u32le(0)); // CRC placeholder
    header.addByte(segs.length);
    header.add(Uint8List.fromList(segs));

    final page = BytesBuilder(copy: false)
      ..add(header.toBytes())
      ..add(body.toBytes());
    final bytes = Uint8List.fromList(page.toBytes());
    // zero CRC field then compute
    bytes[22] = 0;
    bytes[23] = 0;
    bytes[24] = 0;
    bytes[25] = 0;
    final crc = _oggCrc(bytes);
    bytes[22] = crc & 0xFF;
    bytes[23] = (crc >> 8) & 0xFF;
    bytes[24] = (crc >> 16) & 0xFF;
    bytes[25] = (crc >> 24) & 0xFF;
    return bytes;
  }

  /// Ogg CRC-32 (poly 0x04C11DB7, non-reflected, init 0).
  static int _oggCrc(Uint8List data) {
    final ffi = KoeCoreFfi.instance;
    if (ffi != null) {
      return ffi.oggCrc32(data);
    }
    var crc = 0;
    for (final byte in data) {
      crc ^= (byte & 0xFF) << 24;
      for (var i = 0; i < 8; i++) {
        if ((crc & 0x80000000) != 0) {
          crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF;
        } else {
          crc = (crc << 1) & 0xFFFFFFFF;
        }
      }
    }
    return crc;
  }
}
