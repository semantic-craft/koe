import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ble/realtime_stream.dart';
import 'package:koe/crypto/device_crypto.dart';
import 'package:koe/protocol/commands.dart';
import 'package:koe/protocol/frame.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('realtime-stream-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await directory.delete(recursive: true);
  });

  test('a paused take settles after the device finishes sending its backlog '
      '(#230)', () async {
    final packets = StreamController<DecodedPacket>.broadcast();
    final stream = RealtimeBleStream(
      packets: packets.stream,
      write: (_) async {},
      crypto: DeviceCrypto(),
      idleFinalizeDelay: const Duration(milliseconds: 80),
    );
    addTearDown(() async {
      await stream.dispose();
      await packets.close();
    });

    await stream.startForFile(1792390000);
    packets.add(_slice(0));
    await Future<void>.delayed(Duration.zero);

    // Pause. The recorder still owes audio recorded before the pause and
    // keeps sending it for a while; the take must settle once that ends.
    stream.onRecordingStopped();
    for (var i = 1; i <= 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      packets.add(_slice(i));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(stream.state.active, isFalse);
    expect(stream.state.bytesReceived, 4 * 160);
    expect(await File(stream.state.path!).length(), 4 * 160);
  });
}

DecodedPacket _slice(int sequence) {
  final raw = Uint8List(175);
  raw.setRange(9, 13, u32Le(sequence));
  raw.fillRange(14, 174, sequence + 1);
  return DecodedPacket(
    raw: raw,
    statusByte: 1,
    cmdType: RxCmd.transportType,
    cmdId: RxCmd.fileSliceId,
    payload: Uint8List(0),
  );
}
