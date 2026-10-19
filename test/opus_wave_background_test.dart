import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/audio/opus_wave.dart';
import 'package:koe/util/off_ui.dart';

/// First audio packet of a 20 ms mono Opus encode (see
/// opus_pcm_decoder_native_test.dart); decodes to 960 samples at 48 kHz.
const String _opus20msPacketHex =
    '7881a75d6c9e99ac0000067e5639f73b1ea2dc310f523839393ea3d08447cbe1'
    'b6b8ff44143d7621af0734dd0787ec99fec0f544189d5f482942ded82f85b618'
    'f43b6492de947050e097687d6c10d0af638553a27165e791290180531504';

typedef _DlopenNative = Pointer<Void> Function(Pointer<Utf8>, Int32);
typedef _Dlopen = Pointer<Void> Function(Pointer<Utf8>, int);

/// Loads the macOS opus framework with global symbol visibility, the way the
/// app links it, so `DynamicLibrary.process()` resolves libopus on every
/// isolate exactly as in production.
void _linkOpusGlobally() {
  final configFile = File(
    '${Directory.current.path}/.dart_tool/package_config.json',
  );
  final config =
      jsonDecode(configFile.readAsStringSync()) as Map<String, Object?>;
  final package = (config['packages'] as List<Object?>)
      .cast<Map<String, Object?>>()
      .firstWhere((entry) => entry['name'] == 'opus_codec_macos');
  final root = configFile.parent.uri.resolve(package['rootUri'] as String);
  final binary = Directory('${root.toFilePath()}/macos/opus.xcframework')
      .listSync(recursive: true)
      .whereType<File>()
      .firstWhere((file) => file.path.endsWith('/opus.framework/opus'));
  final dlopen = DynamicLibrary.process()
      .lookupFunction<_DlopenNative, _Dlopen>('dlopen');
  const rtldLazy = 0x1, rtldGlobal = 0x8;
  final handle = dlopen(binary.path.toNativeUtf8(), rtldLazy | rtldGlobal);
  expect(handle.address, isNot(0), reason: 'opus framework failed to load');
}

void main() {
  test('长录音在后台 isolate 解码成 WAV，不退回 UI 线程', () async {
    _linkOpusGlobally();
    offUiFallbacks = 0;
    final dir = await Directory.systemTemp.createTemp('opus-wave-bg');
    addTearDown(() => dir.delete(recursive: true));

    final packet = <int>[
      for (var i = 0; i < _opus20msPacketHex.length; i += 2)
        int.parse(_opus20msPacketHex.substring(i, i + 2), radix: 16),
    ];
    final frame = Uint8List(160)..setAll(0, packet);
    final frames = OpusWave.backgroundThreshold ~/ 160 + 1;
    final raw = BytesBuilder(copy: false);
    for (var i = 0; i < frames; i++) {
      raw.add(frame);
    }
    final source = File('${dir.path}/1783822462.opus');
    await source.writeAsBytes(raw.takeBytes());

    final wav = await OpusWave.convertRawFile(source.path);

    expect(wav, '${dir.path}/1783822462.wav');
    // 44-byte header + 960 PCM16 samples per 20 ms frame.
    expect(await File(wav).length(), 44 + frames * 960 * 2);
    expect(offUiFallbacks, 0);
  }, skip: Platform.isMacOS ? false : 'requires the macOS opus xcframework');
}
