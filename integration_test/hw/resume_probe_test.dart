// Unattended hardware probe for #218: does the D3200 honour
// `already_transferred_size` when a BLE file transfer starts?
//
// Run with `KOE_HW_TESTS=1 scripts/hw-check`. It connects this Mac to a real
// recorder, pulls one small file twice (from 0 and from 160 × N bytes) and
// compares the decrypted bytes and slice sequences. The script launches the app with `open` so
// macOS asks Koe itself for Bluetooth access; the probe writes its result to
// [resultFileName] in the app's temporary folder and quits. Status is one of:
//
//   supported      second pull equals the first pull's bytes after the offset
//   not_supported  device ignored the offset and sent the whole file again
//   inconclusive   anything else (details recorded)
//   skipped        no recorder found, it is recording, no suitable file, or
//                  connecting failed — never counted as verified
//
// A recorder that is connected to (owned by) another host does not advertise
// and is reported as skipped. Connecting from this Mac can take the recorder
// away from the phone until it disconnects again (see #218).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:koe/ble/ble_file_pull.dart';
import 'package:koe/ble/ble_service.dart';
import 'package:koe/protocol/frame.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Read by scripts/hw-check from the app container's tmp folder.
const resultFileName = 'koe-hw-resume_probe.json';

/// Slices to skip in the resumed pull. The offset unit is the 166-byte slice
/// record (PROTOCOL.md); 160- and 165-byte units were tried on 2026-10-19 and
/// land mid-record. Add sizes here to probe other units again.
const _offsetSlices = 100;
const _recordSizes = [BleFilePull.sliceRecordBytes];
const _offsetBytes = 160 * _offsetSlices;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final result = <String, Object?>{};

  testWidgets('resume_probe', (tester) async {
    final documents = await Directory.systemTemp.createTemp('koe-hw-');
    PathProviderPlatform.instance = _TempPathProvider(documents.path);
    final ble = BleService();
    final controller = RecorderController(
      ble: ble,
      loadPersistedState: false,
      persistedDeviceLoader: () async =>
          (bound: false, manuallyDisconnected: false, device: null, info: null),
    );
    // No automatic transfers or live pulls while probing.
    controller.autoRealtime = false;

    void skip(String reason) {
      result
        ..['status'] = 'skipped'
        ..['reason'] = reason;
    }

    try {
      await controller.startScan();
      final device = await _waitFor(
        () => controller.devices.firstOrNull,
        const Duration(seconds: 30),
      );
      if (device == null) {
        skip('设备不在线：30 秒内没有扫描到录音豆（不在范围内、关机，或已被其他设备连着）');
        return;
      }
      result['device'] = device.displayName;

      await controller.connect(device);
      final ready = await _waitFor(
        () =>
            controller.connected &&
                controller.encryptReady &&
                controller.files.isNotEmpty
            ? true
            : null,
        const Duration(seconds: 45),
      );
      if (ready == null) {
        skip('连接、加密握手或读取文件列表未完成：${controller.errorMessage ?? '超时'}');
        return;
      }
      if (controller.recording || controller.info?.recording == true) {
        skip('录音豆正在录音，未做取回');
        return;
      }

      final candidates =
          controller.files
              .where((f) => f.sizeBytes >= _offsetBytes * 4)
              .toList()
            ..sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));
      final file = candidates.firstOrNull;
      if (file == null) {
        skip('录音豆上没有至少 ${_offsetBytes * 4} 字节的录音');
        return;
      }
      result['file'] = {'id': file.fileId, 'size': file.sizeBytes};

      final full = await _pull(ble, controller, file, 0);
      result['first_pull'] = full.summary;
      final attempts = <Map<String, Object?>>[];
      String? supportedUnit;
      var resumedAtAll = false;
      for (final record in _recordSizes) {
        final offset = record * _offsetSlices;
        final resumed = await _pull(ble, controller, file, offset);
        final decrypted = _decryptedAlignment(full.bytes, resumed.bytes);
        final rawSlice = _rawAlignment(full.slices, resumed.slices);
        attempts.add({
          'offset_bytes': offset,
          'record_bytes': record,
          ...resumed.summary,
          'decrypted_alignment_bytes': decrypted,
          'raw_alignment_slices': rawSlice,
        });
        if (resumed.bytes.length < full.bytes.length) resumedAtAll = true;
        if (decrypted == _offsetBytes &&
            resumed.slices.firstOrNull?.sequence == _offsetSlices) {
          supportedUnit ??= '$record';
        }
      }
      result['attempts'] = attempts;
      if (supportedUnit != null) {
        result['status'] = 'supported';
        result['offset_unit_bytes'] = supportedUnit;
      } else if (!resumedAtAll) {
        result['status'] = 'not_supported';
      } else {
        result['status'] = 'inconclusive';
      }
    } catch (error) {
      result
        ..['status'] = 'skipped'
        ..['reason'] = '探测中出错，未得出结论：$error';
    } finally {
      await controller.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      controller.dispose();
      // ignore: avoid_print
      print('[hw] resume_probe $result');
      if (await documents.exists()) await documents.delete(recursive: true);
      await File(
        '${Directory.systemTemp.path}/$resultFileName',
      ).writeAsString(jsonEncode(result));
      exit(0);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

class _Slice {
  _Slice(this.sequence, this.data);

  final int sequence;
  final Uint8List data;
}

class _Pull {
  _Pull(this.bytes, this.slices, this.error);

  /// Decrypted file as BleFilePull saved it.
  final Uint8List bytes;

  /// Raw (still encrypted) slices in arrival order.
  final List<_Slice> slices;
  final String? error;

  Map<String, Object?> get summary => {
    'bytes': bytes.length,
    'raw_slices': slices.length,
    'first_sequences': [for (final s in slices.take(3)) s.sequence],
    'head_hex': _hex(bytes.take(32)),
    if (error != null) 'error': error,
  };
}

/// Pulls [file] starting at [offset]; returns the decrypted bytes and the raw
/// slices the recorder sent.
Future<_Pull> _pull(
  BleService ble,
  RecorderController controller,
  OfflineFileEntry file,
  int offset,
) async {
  final slices = <_Slice>[];
  final sub = ble.packets.listen((packet) {
    if (!BleService.isAudioSlice(packet)) return;
    // Same layout BleFilePull decodes: after the 9-byte header, repeated
    // [u32 sequence][flags][160 bytes] with one separator byte between.
    final raw = packet.raw;
    var i = 9;
    while (raw.length - i >= 165) {
      final sequence = readU32Le(raw, i);
      final data = Uint8List.fromList(raw.sublist(i + 5, i + 165));
      slices.add(_Slice(sequence, data));
      i += 165;
      if (i < raw.length) i += 1;
    }
  });
  final puller = BleFilePull(
    packets: ble.packets,
    write: ble.writeCommand,
    crypto: controller.debugCrypto,
  );
  String? error;
  var bytes = Uint8List(0);
  try {
    final path = await puller.pullFile(
      file,
      timeout: const Duration(seconds: 30),
      alreadyTransferred: offset,
    );
    bytes = await File(path).readAsBytes();
    await File(path).delete();
  } catch (e) {
    error = '$e';
  } finally {
    await sub.cancel();
  }
  await Future<void>.delayed(const Duration(seconds: 1));
  return _Pull(bytes, slices, error);
}

/// Byte offset into [full] at which [part] lines up, searched on 160-byte
/// boundaries; null when it lines up nowhere.
int? _decryptedAlignment(Uint8List full, Uint8List part) {
  if (part.isEmpty) return null;
  for (var k = 0; k + part.length <= full.length; k += 160) {
    if (listEquals(part, Uint8List.sublistView(full, k, k + part.length))) {
      return k;
    }
  }
  return null;
}

/// Index in [full] of the raw slice [part] starts with, when the next slices
/// match too; null otherwise.
int? _rawAlignment(List<_Slice> full, List<_Slice> part) {
  if (part.isEmpty) return null;
  for (var k = 0; k < full.length; k++) {
    if (!listEquals(full[k].data, part.first.data)) continue;
    final n = [
      part.length,
      full.length - k,
      20,
    ].reduce((a, b) => a < b ? a : b);
    var ok = true;
    for (var j = 1; j < n; j++) {
      if (!listEquals(full[k + j].data, part[j].data)) {
        ok = false;
        break;
      }
    }
    if (ok) return k;
  }
  return null;
}

Future<T?> _waitFor<T>(T? Function() probe, Duration limit) async {
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    final value = probe();
    if (value != null) return value;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return null;
}

String _hex(Iterable<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getLibraryPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;
}
