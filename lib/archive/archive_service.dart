import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart';

import 'archive_handshake.dart';
import 'archive_pairing.dart';
import 'archive_store.dart';
import 'archive_wire.dart';

/// Mac-side direct receiver. It binds an authenticated TCP service; no
/// unauthenticated request can read, list or write recordings.
class ArchiveDeskServer {
  ArchiveDeskServer({
    required this.store,
    this.maxConnections = 8,
    this.onVerified,
  });

  final ArchiveDeskStore store;
  final int maxConnections;
  VoidCallback? onVerified;

  ServerSocket? _serverSocket;
  final Set<Socket> _sockets = <Socket>{};
  List<String> _addresses = const <String>[];
  String? lastError;

  bool get running => _serverSocket != null;
  int? get port => _serverSocket?.port;
  List<String> get addresses => List.unmodifiable(_addresses);

  ArchivePairing? get pairing {
    final actualPort = port;
    if (!running || actualPort == null) return null;
    return ArchivePairing(
      deskId: store.config.deskId,
      key: store.config.pairingKey,
      hosts: _addresses.isEmpty ? const <String>['127.0.0.1'] : _addresses,
      port: actualPort,
    );
  }

  Future<void> start({int? port}) async {
    if (running) return;
    lastError = null;
    final preferred = port ?? store.config.preferredPort;
    ServerSocket? socket;
    Object? bindError;
    for (final candidate in <int>[preferred, 0]) {
      try {
        socket = await ServerSocket.bind(InternetAddress.anyIPv4, candidate);
        break;
      } on SocketException catch (error) {
        bindError = error;
        if (candidate == 0) rethrow;
      }
    }
    if (socket == null) {
      throw ArchiveException('无法启动 Mac 接收服务：$bindError');
    }
    _serverSocket = socket;
    _addresses = await _localAddresses();
    socket.listen(
      _accept,
      onError: (Object error) {
        lastError = '接收服务暂时不可用';
        debugPrint('[ArchiveDesk] accept failed: $error');
      },
    );
    // Keep the OS-assigned port stable for the next launch so a copied pairing
    // code remains usable. A user can always reveal a fresh code.
    if (socket.port != store.config.preferredPort) {
      await store.updatePreferredPort(socket.port);
    }
  }

  Future<void> stop() async {
    final socket = _serverSocket;
    _serverSocket = null;
    _addresses = const <String>[];
    for (final client in _sockets.toList()) {
      client.destroy();
    }
    _sockets.clear();
    if (socket != null) {
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  void _accept(Socket socket) {
    if (_sockets.length >= maxConnections) {
      socket.destroy();
      return;
    }
    _sockets.add(socket);
    unawaited(_handle(socket));
  }

  Future<void> _handle(Socket socket) async {
    ArchiveSecureSession? session;
    try {
      session = await ArchiveHandshake.server(
        wire: ArchiveWire.adopt(socket),
        deskId: store.config.deskId,
        pairingKey: ArchivePairing.decodeKey(store.config.pairingKey),
      );
      while (true) {
        final message = await session.readControl(
          timeout: const Duration(seconds: 120),
        );
        switch (message['t']) {
          case 'ping':
            await session.sendControl(<String, Object?>{'t': 'pong'});
          case 'upload.begin':
            await _handleUpload(session, message);
          case 'verify':
            await _handleVerify(session, message);
          case 'fetch':
            await _handleFetch(session, message);
          default:
            await session.sendControl(<String, Object?>{
              't': 'error',
              'message': '不支持的请求',
            });
        }
      }
    } on ArchiveException catch (error) {
      // Never include pairing material or file paths in logs.
      debugPrint('[ArchiveDesk] session ended: ${error.message}');
    } catch (error) {
      debugPrint('[ArchiveDesk] session ended: $error');
    } finally {
      _sockets.remove(socket);
      try {
        await session?.close();
      } catch (_) {}
      socket.destroy();
    }
  }

  Future<void> _handleUpload(
    ArchiveSecureSession session,
    Map<String, Object?> message,
  ) async {
    final hash = message['contentHash'];
    final length = message['length'];
    final extension = message['extension'];
    final displayName = message['displayName'];
    final clientId = message['clientId'];
    if (!archiveIsValidContentHash(hash) ||
        length is! int ||
        length <= 0 ||
        length > archiveMaxAudioBytes ||
        extension is! String ||
        displayName is! String ||
        clientId is! String) {
      await session.sendControl(<String, Object?>{
        't': 'upload.rejected',
        'reason': 'invalid',
        'message': '归档请求参数不合法',
      });
      return;
    }
    final String storedExtension;
    try {
      storedExtension = archiveStoredExtension(extension);
    } on ArchiveException catch (error) {
      await session.sendControl(<String, Object?>{
        't': 'upload.rejected',
        'reason': 'extension',
        'message': error.message,
      });
      return;
    }
    final contentHash = hash as String;

    final existing = store.entryForHash(contentHash);
    if (existing != null) {
      final intact = await store.verifyEntry(existing);
      if (intact && existing.length == length) {
        await session.sendControl(<String, Object?>{
          't': 'upload.verified',
          'contentHash': contentHash,
          'length': existing.length,
          'extension': existing.extension,
          'duplicate': true,
          'verifiedAt': existing.verifiedAt.toIso8601String(),
        });
        return;
      }
      // A corrupt existing entry is repaired by commitVerified under its
      // transaction lock; the old bytes are moved aside, never overwritten.
    }

    final incoming = await store.incomingDirectory();
    await incoming.create(recursive: true);
    final temporary = File(
      p.join(incoming.path, '$contentHash.${archiveRandomHex(8)}.part'),
    );
    RandomAccessFile? handle;
    var committed = false;
    try {
      handle = await temporary.open(mode: FileMode.writeOnly);
      await session.sendControl(<String, Object?>{
        't': 'upload.ready',
        'contentHash': contentHash,
      });
      session.resetDataOrder();
      final digest = SHA256Digest();
      var received = 0;
      while (true) {
        final incomingFrame = await session.readIncoming(
          timeout: const Duration(seconds: 120),
        );
        if (incomingFrame.kind == ArchiveFrameKind.control) {
          final control = incomingFrame.control!;
          if (control['t'] == 'upload.finish') break;
          if (control['t'] == 'upload.cancel') {
            await session.sendControl(<String, Object?>{
              't': 'upload.cancelled',
            });
            return;
          }
          throw const ArchiveProtocolException('上传过程中收到未知控制消息');
        }
        final chunk = incomingFrame.data!;
        if (received + chunk.length > length) {
          throw const ArchiveProtocolException('上传内容超过声明长度');
        }
        await handle.writeFrom(chunk);
        digest.update(chunk, 0, chunk.length);
        received += chunk.length;
      }
      if (received != length) {
        throw const ArchiveProtocolException('上传内容不完整');
      }
      await handle.flush();
      await handle.close();
      handle = null;

      // Re-read what actually landed on disk; the in-memory digest alone is not
      // a commit proof.
      final diskHash = await archiveFileHash(temporary.path);
      final diskLength = await temporary.length();
      if (diskHash != contentHash || diskLength != length) {
        await session.sendControl(<String, Object?>{
          't': 'upload.failed',
          'reason': 'verify',
          'message': 'Mac 校验原件失败，手机原件仍保留',
        });
        return;
      }
      final entry = await store.commitVerified(
        temporaryPath: temporary.path,
        contentHash: contentHash,
        length: length,
        extension: storedExtension,
        displayName: displayName,
        verifiedAt: DateTime.now(),
        sourceClientId: clientId,
      );
      committed = true;
      await session.sendControl(<String, Object?>{
        't': 'upload.verified',
        'contentHash': contentHash,
        'length': entry.length,
        'extension': entry.extension,
        'duplicate': false,
        'verifiedAt': entry.verifiedAt.toIso8601String(),
      });
      onVerified?.call();
    } on ArchiveRemoteException catch (error) {
      await _safeControl(session, <String, Object?>{
        't': 'upload.rejected',
        'reason': error.reason ?? 'remote',
        'message': error.message,
      });
    } on ArchiveSourceChangedException catch (error) {
      await _safeControl(session, <String, Object?>{
        't': 'upload.failed',
        'reason': 'source_changed',
        'message': error.message,
      });
    } catch (error) {
      await _safeControl(session, <String, Object?>{
        't': 'upload.failed',
        'reason': 'receive',
        'message': 'Mac 接收中断，手机原件仍保留',
      });
    } finally {
      try {
        await handle?.close();
      } catch (_) {}
      if (!committed && await temporary.exists()) {
        try {
          await temporary.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _handleVerify(
    ArchiveSecureSession session,
    Map<String, Object?> message,
  ) async {
    final hash = message['contentHash'];
    if (!archiveIsValidContentHash(hash)) {
      await session.sendControl(<String, Object?>{
        't': 'verify.result',
        'verified': false,
        'reason': 'invalid',
      });
      return;
    }
    final entry = store.entryForHash(hash as String);
    if (entry == null) {
      await session.sendControl(<String, Object?>{
        't': 'verify.result',
        'verified': false,
        'reason': 'missing',
      });
      return;
    }
    final verified = await store.verifyEntry(entry);
    await session.sendControl(<String, Object?>{
      't': 'verify.result',
      'contentHash': entry.contentHash,
      'length': entry.length,
      'extension': entry.extension,
      'verified': verified,
      'reason': verified ? null : 'corrupt',
    });
  }

  Future<void> _handleFetch(
    ArchiveSecureSession session,
    Map<String, Object?> message,
  ) async {
    final hash = message['contentHash'];
    if (!archiveIsValidContentHash(hash)) {
      await session.sendControl(<String, Object?>{
        't': 'fetch.rejected',
        'reason': 'invalid',
      });
      return;
    }
    final entry = store.entryForHash(hash as String);
    if (entry == null || !await store.verifyEntry(entry)) {
      await session.sendControl(<String, Object?>{
        't': 'fetch.rejected',
        'reason': entry == null ? 'missing' : 'corrupt',
      });
      return;
    }
    final file = await store.fileForEntry(entry);
    final handle = await file.open();
    try {
      await session.sendControl(<String, Object?>{
        't': 'fetch.begin',
        'contentHash': entry.contentHash,
        'length': entry.length,
        'extension': entry.extension,
      });
      session.resetDataOrder();
      var sent = 0;
      while (sent < entry.length) {
        final take = min(archiveChunkBytes, entry.length - sent);
        final chunk = await handle.read(take);
        if (chunk.isEmpty) {
          throw const ArchiveProtocolException('归档文件长度与记录不一致');
        }
        await session.sendData(chunk);
        sent += chunk.length;
      }
      await session.sendControl(<String, Object?>{
        't': 'fetch.finished',
        'contentHash': entry.contentHash,
        'length': entry.length,
      });
    } finally {
      await handle.close();
    }
  }

  Future<void> _safeControl(
    ArchiveSecureSession session,
    Map<String, Object?> message,
  ) async {
    try {
      await session.sendControl(message);
    } catch (_) {}
  }

  static Future<List<String>> _localAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addresses = <String>[];
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.isLoopback || address.address.isEmpty) continue;
          if (!addresses.contains(address.address)) {
            addresses.add(address.address);
          }
        }
      }
      if (addresses.isEmpty) addresses.add('127.0.0.1');
      return addresses;
    } catch (_) {
      return const <String>['127.0.0.1'];
    }
  }
}

class ArchiveUploadResult {
  const ArchiveUploadResult({
    required this.contentHash,
    required this.length,
    required this.duplicate,
    required this.verifiedAt,
  });

  final String contentHash;
  final int length;
  final bool duplicate;
  final DateTime verifiedAt;
}

class ArchiveVerifyResult {
  const ArchiveVerifyResult({
    required this.contentHash,
    required this.length,
    required this.extension,
    required this.verified,
    this.reason,
  });

  final String? contentHash;
  final int? length;
  final String? extension;
  final bool verified;
  final String? reason;
}

class ArchiveClient {
  ArchiveClient._(this.pairing, this._session);

  final ArchivePairing pairing;
  final ArchiveSecureSession _session;
  bool _closed = false;
  Future<void> _operations = Future<void>.value();

  /// The wire protocol has one command stream per authenticated connection.
  /// UI pings, restores and background uploads must never write frames
  /// concurrently, so complete operations are serialized here.
  Future<T> _serial<T>(Future<T> Function() work) {
    final completer = Completer<T>();
    _operations = _operations.then((_) async {
      try {
        completer.complete(await work());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    _operations = _operations.catchError((Object _) {});
    return completer.future;
  }

  static Future<ArchiveClient> connect(
    ArchivePairing pairing, {
    required String clientId,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    Socket? socket;
    for (final host in pairing.hosts) {
      try {
        socket = await Socket.connect(host, pairing.port, timeout: timeout);
        break;
      } on SocketException {
        continue;
      }
    }
    if (socket == null) {
      throw ArchiveException('连不上 Mac，请确认在同一局域网且接收服务已开启');
    }
    final wire = ArchiveWire.adopt(socket);
    try {
      final session = await ArchiveHandshake.client(
        wire: wire,
        pairing: pairing,
        clientId: clientId,
      );
      final client = ArchiveClient._(pairing, session);
      await client.ping();
      return client;
    } on ArchiveAuthException {
      await wire.close();
      rethrow;
    } catch (error) {
      await wire.close();
      rethrow;
    }
  }

  bool get connected => !_closed;

  Future<void> ping() => _serial(() async {
    await _session.sendControl(<String, Object?>{'t': 'ping'});
    final reply = await _session.readControl(
      timeout: const Duration(seconds: 8),
    );
    if (reply['t'] != 'pong') {
      throw const ArchiveProtocolException('Mac 响应异常');
    }
  });

  Future<ArchiveUploadResult> uploadFile({
    required String path,
    required String contentHash,
    required int length,
    required String extension,
    required String displayName,
    required String clientId,
    DateTime? recordedAt,
    void Function(int sent, int total)? onProgress,
    Future<void> Function()? onSentAll,
  }) => _serial(() async {
    if (!archiveIsValidContentHash(contentHash)) {
      throw const ArchiveProtocolException('原件内容标识不合法');
    }
    final file = File(path);
    final before = await file.stat();
    if (before.type != FileSystemEntityType.file ||
        before.size != length ||
        length <= 0) {
      throw const ArchiveSourceChangedException('原件已变化，请重试');
    }
    await _session.sendControl(<String, Object?>{
      't': 'upload.begin',
      'contentHash': contentHash,
      'length': length,
      'extension': extension,
      'displayName': archiveSanitizeDisplayName(displayName),
      'clientId': clientId,
      'recordedAt': recordedAt?.toIso8601String(),
    });
    final response = await _session.readControl();
    switch (response['t']) {
      case 'upload.verified':
        final remoteHash = response['contentHash'];
        final remoteLength = response['length'];
        if (remoteHash != contentHash || remoteLength != length) {
          throw const ArchiveProtocolException('Mac 返回的归档信息不一致');
        }
        final verifiedAt =
            DateTime.tryParse('${response['verifiedAt']}') ?? DateTime.now();
        await _verifyLocalSourceUnchanged(path, contentHash, length);
        return ArchiveUploadResult(
          contentHash: contentHash,
          length: length,
          duplicate: response['duplicate'] == true,
          verifiedAt: verifiedAt,
        );
      case 'upload.rejected':
        throw ArchiveRemoteException(
          response['message'] is String
              ? response['message'] as String
              : 'Mac 拒绝接收这份原件',
          reason: response['reason'] is String
              ? response['reason'] as String
              : null,
        );
      case 'upload.ready':
        break;
      default:
        throw const ArchiveProtocolException('Mac 没有准备好接收原件');
    }

    _session.resetDataOrder();
    final handle = await file.open();
    var sent = 0;
    try {
      final digest = SHA256Digest();
      while (sent < length) {
        final chunk = await handle.read(min(archiveChunkBytes, length - sent));
        if (chunk.isEmpty) {
          throw const ArchiveSourceChangedException('原件读取中断，请重试');
        }
        digest.update(chunk, 0, chunk.length);
        await _session.sendData(chunk);
        sent += chunk.length;
        onProgress?.call(sent, length);
      }
      final output = Uint8List(digest.digestSize);
      digest.doFinal(output, 0);
      final computed = output
          .map((value) => value.toRadixString(16).padLeft(2, '0'))
          .join();
      final after = await file.stat();
      if (computed != contentHash ||
          after.size != before.size ||
          after.modified != before.modified) {
        throw const ArchiveSourceChangedException();
      }
    } finally {
      await handle.close();
    }

    await onSentAll?.call();
    await _session.sendControl(<String, Object?>{'t': 'upload.finish'});
    final result = await _session.readControl(
      timeout: const Duration(seconds: 120),
    );
    if (result['t'] == 'upload.rejected') {
      throw ArchiveRemoteException(
        result['message'] is String
            ? result['message'] as String
            : 'Mac 拒绝接收这份原件',
        reason: result['reason'] is String ? result['reason'] as String : null,
      );
    }
    if (result['t'] != 'upload.verified') {
      throw ArchiveRemoteException(
        result['message'] is String
            ? result['message'] as String
            : 'Mac 未确认归档，手机原件仍保留',
        reason: 'not_verified',
      );
    }
    if (result['contentHash'] != contentHash || result['length'] != length) {
      throw const ArchiveProtocolException('Mac 返回的归档信息不一致');
    }
    // The sender independently re-reads its source after the receiver's
    // confirmation; a changed file is never reported as archived.
    await _verifyLocalSourceUnchanged(path, contentHash, length);
    return ArchiveUploadResult(
      contentHash: contentHash,
      length: length,
      duplicate: result['duplicate'] == true,
      verifiedAt:
          DateTime.tryParse('${result['verifiedAt']}') ?? DateTime.now(),
    );
  });

  Future<void> _verifyLocalSourceUnchanged(
    String path,
    String contentHash,
    int length,
  ) async {
    final file = File(path);
    if (!await file.exists()) {
      // The verified remote copy is still a valid archive of the queued
      // version; the phone UI presents the local copy as missing and offers
      // an explicit restore.
      return;
    }
    final actual = await archiveFileHash(path);
    if (actual != contentHash || await file.length() != length) {
      throw const ArchiveSourceChangedException();
    }
  }

  Future<ArchiveVerifyResult> verify(String contentHash) => _serial(() async {
    if (!archiveIsValidContentHash(contentHash)) {
      throw const ArchiveProtocolException('内容标识不合法');
    }
    await _session.sendControl(<String, Object?>{
      't': 'verify',
      'contentHash': contentHash,
    });
    final result = await _session.readControl(
      timeout: const Duration(seconds: 120),
    );
    if (result['t'] != 'verify.result') {
      throw const ArchiveProtocolException('Mac 未能核对归档');
    }
    return ArchiveVerifyResult(
      contentHash: result['contentHash'] is String
          ? result['contentHash'] as String
          : null,
      length: result['length'] is int ? result['length'] as int : null,
      extension: result['extension'] is String
          ? result['extension'] as String
          : null,
      verified: result['verified'] == true,
      reason: result['reason'] is String ? result['reason'] as String : null,
    );
  });

  Future<void> fetchToFile({
    required String contentHash,
    required int expectedLength,
    required String targetPath,
    void Function(int received, int total)? onProgress,
  }) => _serial(() async {
    if (!archiveIsValidContentHash(contentHash) || expectedLength <= 0) {
      throw const ArchiveProtocolException('恢复参数不合法');
    }
    await _session.sendControl(<String, Object?>{
      't': 'fetch',
      'contentHash': contentHash,
    });
    final begin = await _session.readControl();
    if (begin['t'] == 'fetch.rejected') {
      throw ArchiveRemoteException(
        begin['reason'] == 'missing' ? 'Mac 上找不到这份归档' : 'Mac 上的归档校验失败',
        reason: begin['reason'] is String ? begin['reason'] as String : null,
      );
    }
    if (begin['t'] != 'fetch.begin' ||
        begin['contentHash'] != contentHash ||
        begin['length'] != expectedLength) {
      throw const ArchiveProtocolException('Mac 返回的归档信息不一致');
    }
    final target = File(targetPath);
    await target.parent.create(recursive: true);
    final temporary = File('$targetPath.part-${archiveRandomHex(6)}');
    RandomAccessFile? handle;
    try {
      handle = await temporary.open(mode: FileMode.writeOnly);
      _session.resetDataOrder();
      final digest = SHA256Digest();
      var received = 0;
      var finished = false;
      while (true) {
        final frame = await _session.readIncoming(
          timeout: const Duration(seconds: 120),
        );
        if (frame.kind == ArchiveFrameKind.control) {
          final control = frame.control!;
          if (control['t'] != 'fetch.finished') {
            throw const ArchiveProtocolException('恢复过程中收到未知控制消息');
          }
          finished = true;
          break;
        }
        final chunk = frame.data!;
        if (received + chunk.length > expectedLength) {
          throw const ArchiveProtocolException('恢复内容超过声明长度');
        }
        await handle.writeFrom(chunk);
        digest.update(chunk, 0, chunk.length);
        received += chunk.length;
        onProgress?.call(received, expectedLength);
      }
      if (!finished || received != expectedLength) {
        throw const ArchiveProtocolException('恢复内容不完整');
      }
      await handle.flush();
      await handle.close();
      handle = null;
      final diskHash = await archiveFileHash(temporary.path);
      final diskLength = await temporary.length();
      if (diskHash != contentHash || diskLength != expectedLength) {
        throw const ArchiveRemoteException('恢复的原件校验失败，未写入资料库');
      }
      if (await target.exists()) {
        final existing = await archiveFileHash(targetPath);
        if (existing == contentHash) {
          await temporary.delete();
          return;
        }
        throw const ArchiveRemoteException(
          '本机目标位置已有不同内容的文件，未覆盖',
          reason: 'conflict',
        );
      }
      await temporary.rename(targetPath);
    } catch (_) {
      try {
        await handle?.close();
      } catch (_) {}
      if (await temporary.exists()) {
        try {
          await temporary.delete();
        } catch (_) {}
      }
      rethrow;
    }
  });

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _session.close();
  }

  void destroy() {
    if (_closed) return;
    _closed = true;
    _session.destroy();
  }
}
