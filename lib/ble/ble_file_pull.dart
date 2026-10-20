import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../audio/retrieved_audio.dart';
import '../crypto/device_crypto.dart';
import '../protocol/commands.dart';
import '../protocol/frame.dart';
import '../protocol/slice_marks.dart';
import '../protocol/models.dart';

class BleFilePullCancelled implements Exception {
  const BleFilePullCancelled();
}

/// The recorder has not finished this file: it is still recording or paused
/// on it. Its head reports an unknown size and no slices follow, so a pull
/// can only time out (#253). Once the recording ends the file pulls normally.
class BleFileUnfinished implements Exception {
  const BleFileUnfinished(this.fileId);
  final int fileId;

  @override
  String toString() => 'BleFileUnfinished($fileId)';
}

/// Pull one offline recording over BLE (0x1A/0x07 head → 0x08 slices → 0x0A done).
///
/// Prefer this for playback of small/medium files; use Wi‑Fi SoftAP for batch.
class BleFilePull {
  BleFilePull({
    required this.packets,
    required this.write,
    required this.crypto,
  });

  final Stream<DecodedPacket> packets;
  final Future<void> Function(List<int> frame) write;
  final DeviceCrypto crypto;
  bool _cancelled = false;
  Completer<void>? _cancelCompleter;

  void cancel() {
    _cancelled = true;
    final completer = _cancelCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void _log(String m) => debugPrint('[BlePull] $m');

  final Set<String> _incompletePaths = {};

  /// Whether the last pull that saved [path] ended without the device's done
  /// signal and below the announced size (kept at >= 95% for playback); see
  /// [retrievedTransferComplete].
  bool isIncomplete(String path) => _incompletePaths.contains(path);

  /// One slice record as the recorder counts transferred bytes: sequence,
  /// flags, 160 audio bytes and a separator (PROTOCOL.md).
  static const sliceRecordBytes = 166;

  /// File size the recorder reports for a file it has not finished.
  static const unfinishedFileSize = 0xFFFFFFFF;

  Future<String> pullFile(
    OfflineFileEntry file, {
    // Maximum time without a file packet, not a cap on total transfer time.
    Duration timeout = const Duration(seconds: 90),
    void Function(int received, int expected)? onProgress,
    // Slices the user marked on the bean by double-tapping, by sequence.
    void Function(int sequence)? onMark,
    // Protocol `already_transferred_size`: a byte offset into the device's
    // slice record stream, so resuming after N slices is
    // [sliceRecordBytes] × N (PROTOCOL.md, #218). The app passes 0.
    int alreadyTransferred = 0,
  }) async {
    _cancelled = false;
    _cancelCompleter = Completer<void>();
    // Audio bytes the device skips for this offset.
    final skipped = alreadyTransferred ~/ sliceRecordBytes * 160;
    final dir = await _exportDir();
    final path = p.join(dir.path, '${file.fileId}.opus');
    final sink = File(path).openWrite();

    var received = 0;
    var expected = file.sizeBytes;
    var decryptOn = false;
    var unfinished = false;
    final fileIdStr = '${file.fileId}';
    final head = Completer<void>();
    final done = Completer<void>();
    final inactivity = Stopwatch()..start();
    final sub = packets.listen((pkt) {
      if (pkt.cmdType != RxCmd.transportType &&
          pkt.cmdType != RxCmd.transportTypeAlt) {
        return;
      }
      if (pkt.cmdId == RxCmd.fileHeadId) {
        inactivity.reset();
        final secret = AudioFileSecretKey.parseFrame(pkt.raw);
        if (secret != null && secret.fileSize == unfinishedFileSize) {
          _log('head id=${secret.fileId} unfinished on the recorder');
          unfinished = true;
          if (!head.isCompleted) head.complete();
          return;
        }
        if (secret != null) {
          if (secret.fileSize > 0) expected = secret.fileSize;
          decryptOn = crypto.initFileDecrypt(
            fileId: fileIdStr,
            encryptedFileKey: secret.encryptedFileKey,
            sessionNonce: secret.sessionNonce,
            nonce: secret.nonce,
          );
          _log('head id=${secret.fileId} size=$expected decrypt=$decryptOn');
        }
        if (!head.isCompleted) head.complete();
        return;
      }
      if (pkt.cmdId == RxCmd.fileSliceId ||
          pkt.cmdId == RxCmd.fileSliceMarkId) {
        inactivity.reset();
        received += _writeSlices(
          pkt.raw,
          sink,
          fileId: fileIdStr,
          decrypt: decryptOn,
          onMark: onMark,
        );
        onProgress?.call(received, expected);
        return;
      }
      if (pkt.cmdId == RxCmd.fileDoneId) {
        inactivity.reset();
        if (!done.isCompleted) done.complete();
      }
    });

    try {
      await write(
        DeviceCommands.startTransportAudioFile(
          fileId: file.fileId,
          alreadyTransferred: alreadyTransferred,
          realtimeFlag: 0,
        ),
      );
      _log('requested file ${file.fileId}');

      try {
        await Future.any([
          head.future,
          _cancelCompleter!.future,
        ]).timeout(const Duration(seconds: 15));
      } on TimeoutException {
        _log('no file head yet — waiting for slices');
      }
      if (_cancelled) throw const BleFilePullCancelled();
      if (unfinished) throw BleFileUnfinished(file.fileId);

      while (!_cancelled && inactivity.elapsed < timeout) {
        if (done.isCompleted) break;
        if (expected > 0 && received >= expected - skipped) break;
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }

      if (_cancelled) throw const BleFilePullCancelled();

      if (expected > 0 && received < (expected - skipped) * 0.95) {
        throw StateError('Incomplete BLE export: $received/$expected bytes');
      }

      await sink.flush();
      await sink.close();
      crypto.clearFile(fileIdStr);

      if (received == 0) {
        try {
          await File(path).delete();
        } catch (_) {}
        throw StateError(
          'No audio data received for ${file.fileId}. '
          'Keep BLE connected and try again.',
        );
      }
      // Saved files below 100% without the device's done signal are kept for
      // playback but must not be treated as a finished recording.
      final complete = retrievedTransferComplete(
        doneSignal: done.isCompleted,
        received: received,
        expected: expected,
      );
      if (complete) {
        _incompletePaths.remove(path);
      } else {
        _incompletePaths.add(path);
      }
      _log(
        'saved $path ($received bytes, decrypt=$decryptOn'
        '${complete ? '' : ', incomplete $received/$expected'})',
      );
      return path;
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        await File(path).delete();
      } catch (_) {}
      crypto.clearFile(fileIdStr);
      rethrow;
    } finally {
      await sub.cancel();
      _cancelCompleter = null;
    }
  }

  int _writeSlices(
    Uint8List frame,
    IOSink sink, {
    required String fileId,
    required bool decrypt,
    void Function(int sequence)? onMark,
  }) {
    var written = 0;
    var i = 9;
    while (frame.length - i >= 165) {
      final seq = readU32Le(frame, i);
      i += 4;
      final flags = frame[i];
      i += 1;
      final dataEnd = i + 160;
      if (dataEnd > frame.length) break;
      var chunk = Uint8List.fromList(frame.sublist(i, dataEnd));
      i = dataEnd;
      if (i < frame.length) i += 1;
      if (SliceMark.isMark(flags)) onMark?.call(seq);

      if (decrypt) {
        final plain = crypto.decryptChunk(
          fileId: fileId,
          sequence: seq,
          data: chunk,
        );
        if (plain != null) chunk = plain;
      }
      sink.add(chunk);
      written += chunk.length;
    }
    return written;
  }

  Future<Directory> _exportDir() async {
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    final dir = Directory(p.join(base.path, 'AnkerRecorder', 'exports'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
