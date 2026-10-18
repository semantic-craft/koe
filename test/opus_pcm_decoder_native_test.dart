import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/audio/opus_pcm_decoder.dart';

/// First audio packet of a 20 ms mono Opus encode (ffmpeg + libopus 1.5.2,
/// 440 Hz sine, 24 kbps, VoIP mode). libopus decodes it to 320 samples at
/// 16 kHz and 960 samples at 48 kHz.
const String _opus20msPacketHex =
    '7881a75d6c9e99ac0000067e5639f73b1ea2dc310f523839393ea3d08447cbe1'
    'b6b8ff44143d7621af0734dd0787ec99fec0f544189d5f482942ded82f85b618'
    'f43b6492de947050e097687d6c10d0af638553a27165e791290180531504';

Uint8List _packetBytes() => Uint8List.fromList(<int>[
  for (var i = 0; i < _opus20msPacketHex.length; i += 2)
    int.parse(_opus20msPacketHex.substring(i, i + 2), radix: 16),
]);

Directory _packageRoot(String packageName) {
  final configFile = File(
    '${Directory.current.path}/.dart_tool/package_config.json',
  );
  final config =
      jsonDecode(configFile.readAsStringSync()) as Map<String, Object?>;
  final packages = config['packages'] as List<Object?>;
  for (final entry in packages) {
    final package = entry as Map<String, Object?>;
    if (package['name'] != packageName) continue;
    final rootUri = configFile.parent.uri.resolve(package['rootUri'] as String);
    return Directory(rootUri.toFilePath());
  }
  throw StateError('Package $packageName not found in ${configFile.path}');
}

void _expectDecodesAt(
  int sampleRate,
  int expectedBytes, {
  int? knownSampleIndex,
  int? knownSampleValue,
}) {
  final decoder = OpusPcmDecoder(outputSampleRate: sampleRate);
  addTearDown(decoder.dispose);

  expect(decoder.ensureStarted(), isTrue);
  final first = decoder.decodeFrame(_packetBytes());
  expect(first, isNotNull);
  final firstPcm = first!;
  expect(firstPcm.length, expectedBytes);
  expect(firstPcm.any((byte) => byte != 0), isTrue);
  if (knownSampleIndex != null && knownSampleValue != null) {
    // Independently decoded with the same libopus 1.5.2 macOS xcframework:
    // sample 130 is -4130 (0xEFDE), so its little-endian bytes are DE EF.
    final sample = ByteData.sublistView(
      firstPcm,
    ).getInt16(knownSampleIndex * 2, Endian.little);
    expect(sample, closeTo(knownSampleValue, 16));
  }
  expect(decoder.framesDecoded, 1);

  decoder.reset();
  expect(decoder.isReady, isFalse);
  expect(decoder.framesDecoded, 0);

  expect(decoder.ensureStarted(), isTrue);
  final second = decoder.decodeFrame(_packetBytes());
  expect(second, isNotNull);
  final secondPcm = second!;
  expect(secondPcm, firstPcm);
  expect(secondPcm.length, expectedBytes);
  expect(secondPcm.any((byte) => byte != 0), isTrue);
  expect(decoder.framesDecoded, 1);
}

void main() {
  test(
    'decodes a real Opus packet at 16 kHz and 48 kHz across reset',
    () async {
      final packageRoot = _packageRoot('opus_codec_macos');
      final binaries = Directory('${packageRoot.path}/macos/opus.xcframework')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('/opus.framework/opus'))
          .toList();
      expect(binaries, hasLength(1), reason: 'macOS opus xcframework missing');

      OpusPcmDecoder.debugUseOpusLibrary(
        DynamicLibrary.open(binaries.single.path),
      );
      _expectDecodesAt(
        16000,
        640,
        knownSampleIndex: 130,
        knownSampleValue: -4130,
      );
      _expectDecodesAt(48000, 1920);
    },
    skip: Platform.isMacOS ? false : 'requires the macOS opus xcframework',
  );
}
