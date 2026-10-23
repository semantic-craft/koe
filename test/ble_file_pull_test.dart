import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:koe/ble/ble_file_pull.dart';
import 'package:koe/crypto/device_crypto.dart';
import 'package:koe/protocol/commands.dart';
import 'package:koe/protocol/frame.dart';
import 'package:koe/protocol/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('active BLE transfer can outlive the inactivity timeout', () async {
    final packets = StreamController<DecodedPacket>();
    final lastSliceSent = Completer<void>();
    final file = OfflineFileEntry(
      fileId: DateTime.now().microsecondsSinceEpoch,
      durationMs: 80,
    );
    // Each slice comes half a timeout after the one before, so the next one
    // is always due before the timeout runs out.
    void sendSlice(int sequence) {
      packets.add(_packet(RxCmd.fileSliceId, _sliceFrame(sequence)));
      if (sequence == 3) {
        lastSliceSent.complete();
      } else {
        Timer(const Duration(milliseconds: 25), () => sendSlice(sequence + 1));
      }
    }

    final pull = BleFilePull(
      packets: packets.stream,
      write: (_) async {
        packets.add(_packet(RxCmd.fileHeadId, Uint8List(10)));
        Timer(const Duration(milliseconds: 25), () => sendSlice(0));
      },
      crypto: DeviceCrypto(),
    );
    addTearDown(() async {
      await lastSliceSent.future;
      await packets.close();
    });

    final path = await pull.pullFile(
      file,
      timeout: const Duration(milliseconds: 50),
      onProgress: (received, _) {
        // The app is busy for twice the timeout while the last slice is due,
        // as on a loaded test machine.
        if (received == 498) sleep(const Duration(milliseconds: 100));
      },
    );
    addTearDown(() async {
      final output = File(path);
      if (await output.exists()) await output.delete();
    });

    expect(await File(path).length(), 640);
  });

  test('cancelled pull drops slices the recorder sends afterwards', () async {
    final packets = StreamController<DecodedPacket>.broadcast();
    addTearDown(packets.close);
    late final BleFilePull pull;
    pull = BleFilePull(
      packets: packets.stream,
      write: (_) async {
        // The app gives up on the file right away, and the recorder sends it
        // anyway.
        pull.cancel();
        Timer.run(() {
          packets.add(_packet(RxCmd.fileHeadId, Uint8List(10)));
          packets.add(_packet(RxCmd.fileSliceId, _sliceFrame(0)));
        });
      },
      crypto: DeviceCrypto(),
    );

    await expectLater(
      pull.pullFile(
        OfflineFileEntry(
          fileId: DateTime.now().microsecondsSinceEpoch,
          durationMs: 80,
        ),
      ),
      throwsA(isA<BleFilePullCancelled>()),
    );
  });
}

DecodedPacket _packet(int commandId, Uint8List raw) {
  return DecodedPacket(
    raw: raw,
    statusByte: 1,
    cmdType: RxCmd.transportType,
    cmdId: commandId,
    payload: Uint8List(0),
  );
}

Uint8List _sliceFrame(int sequence) {
  final raw = Uint8List(175);
  final sequenceBytes = u32Le(sequence);
  raw.setRange(9, 13, sequenceBytes);
  raw[13] = 0;
  raw.fillRange(14, 174, sequence + 1);
  return raw;
}
