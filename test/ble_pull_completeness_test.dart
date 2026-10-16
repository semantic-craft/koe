import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ble/ble_file_pull.dart';
import 'package:koe/crypto/device_crypto.dart';
import 'package:koe/protocol/commands.dart';
import 'package:koe/protocol/frame.dart';
import 'package:koe/protocol/models.dart';

// #13: a BLE pull accepted at >= 95% without the device's done signal keeps
// the file for playback but is flagged incomplete, so it never reaches
// automatic transcription. A pull that ends with the done signal or the full
// announced size is complete, and a later complete pull clears the flag.

/// Fake recorder: on each file request sends a head, [slices] 160-byte slices
/// and, when [done], the done signal.
class _Device {
  _Device() {
    puller = BleFilePull(
      packets: _packets.stream,
      write: _write,
      crypto: DeviceCrypto(),
    );
  }

  final _packets = StreamController<DecodedPacket>.broadcast();
  final _scheduled = <Future<void>>[];
  late final BleFilePull puller;
  int slices = 0;
  bool done = false;

  Future<void> _write(List<int> _) async {
    _packets.add(_packet(RxCmd.fileHeadId, Uint8List(10)));
    for (var i = 0; i < slices; i++) {
      _scheduled.add(
        Future<void>.delayed(Duration(milliseconds: 20 * (i + 1)), () {
          _packets.add(_packet(RxCmd.fileSliceId, _sliceFrame(i)));
        }),
      );
    }
    if (done) {
      _scheduled.add(
        Future<void>.delayed(Duration(milliseconds: 20 * (slices + 1)), () {
          _packets.add(_packet(RxCmd.fileDoneId, Uint8List(10)));
        }),
      );
    }
  }

  Future<String> pull(int fileId, int sizeBytes) async {
    final path = await puller.pullFile(
      OfflineFileEntry(fileId: fileId, sizeBytes: sizeBytes),
      timeout: const Duration(milliseconds: 150),
    );
    await Future.wait(_scheduled);
    return path;
  }

  Future<void> close() => _packets.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Device device;
  late int fileId;
  setUp(() {
    device = _Device();
    fileId = DateTime.now().microsecondsSinceEpoch;
  });
  tearDown(() async {
    await device.close();
    final file = File(
      '${Directory.systemTemp.path}/AnkerRecorder/exports/$fileId.opus',
    );
    if (await file.exists()) await file.delete();
  });

  test('full announced size is complete', () async {
    device.slices = 2;
    final path = await device.pull(fileId, 320);
    expect(await File(path).length(), 320);
    expect(device.puller.isIncomplete(path), isFalse);
  });

  test('done signal below the announced size is complete', () async {
    device
      ..slices = 2
      ..done = true;
    final path = await device.pull(fileId, 330);
    expect(device.puller.isIncomplete(path), isFalse);
  });

  test('timeout at >= 95% without done keeps the file but flags it', () async {
    device.slices = 2;
    final path = await device.pull(fileId, 330);
    expect(await File(path).length(), 320, reason: 'file kept for playback');
    expect(device.puller.isIncomplete(path), isTrue);
  });

  test('a later complete pull of the same file clears the flag', () async {
    device.slices = 2;
    final first = await device.pull(fileId, 330);
    expect(device.puller.isIncomplete(first), isTrue);
    final again = await device.pull(fileId, 320);
    expect(again, first);
    expect(device.puller.isIncomplete(again), isFalse);
  });
}

DecodedPacket _packet(int commandId, Uint8List raw) => DecodedPacket(
  raw: raw,
  statusByte: 1,
  cmdType: RxCmd.transportType,
  cmdId: commandId,
  payload: Uint8List(0),
);

Uint8List _sliceFrame(int sequence) {
  final raw = Uint8List(175);
  raw.setRange(9, 13, u32Le(sequence));
  raw[13] = 0;
  raw.fillRange(14, 174, sequence + 1);
  return raw;
}
