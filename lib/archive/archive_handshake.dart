import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'archive_pairing.dart';
import 'archive_wire.dart';

/// Mutual pairing handshake. Successful AEAD decryption of the first encrypted
/// frame is the proof that both ends hold the same pairing secret.
class ArchiveHandshake {
  static Future<ArchiveSecureSession> client({
    required ArchiveWire wire,
    required ArchivePairing pairing,
    required String clientId,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final clientNonce = archiveRandomBytes(32);
    await wire.writeFrame(
      archivePlainFrame(ArchiveFrameKind.hello, <String, Object?>{
        'v': archiveProtocolVersion,
        'desk': pairing.deskId,
        'client': clientId,
        'nonce': base64Url.encode(clientNonce).replaceAll('=', ''),
      }),
    );
    final challenge = archiveDecodePlain(
      await wire.readFrame(timeout: timeout),
      ArchiveFrameKind.challenge,
    );
    if (challenge['v'] != archiveProtocolVersion) {
      throw const ArchiveProtocolException('Mac 归档协议版本不受支持');
    }
    final serverNonce = _decodeNonce(challenge['nonce']);
    final keys = archiveDeriveSessionKeys(
      pairingKey: pairing.keyBytes,
      deskId: pairing.deskId,
      clientNonce: clientNonce,
      serverNonce: serverNonce,
    );
    final session = ArchiveSecureSession(
      wire: wire,
      sendKey: keys.clientToServer,
      receiveKey: keys.serverToClient,
      isClient: true,
      sessionId: keys.sessionId,
    );
    await session.sendControl(<String, Object?>{
      't': 'pair',
      'client': clientId,
    }, timeout: timeout);
    final Map<String, Object?> ready;
    try {
      ready = await session.readControl(timeout: timeout);
    } on ArchiveProtocolException {
      // The receiver only closes at this point when it could not authenticate
      // the first encrypted frame. Do not leave the phone waiting 30 seconds.
      await wire.close();
      throw const ArchiveAuthException();
    } on ArchiveTimeoutException {
      await wire.close();
      throw const ArchiveAuthException('配对验证超时，请确认配对信息');
    }
    if (ready['t'] != 'ready' ||
        ready['desk'] != pairing.deskId ||
        ready['session'] != keys.sessionId) {
      throw const ArchiveAuthException();
    }
    return session;
  }

  static Future<ArchiveSecureSession> server({
    required ArchiveWire wire,
    required String deskId,
    required Uint8List pairingKey,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final hello = archiveDecodePlain(
      await wire.readFrame(timeout: timeout),
      ArchiveFrameKind.hello,
    );
    if (hello['v'] != archiveProtocolVersion || hello['desk'] != deskId) {
      throw const ArchiveAuthException('配对目标不是这台 Mac');
    }
    final clientId = hello['client'];
    if (clientId is! String ||
        !RegExp(r'^[a-f0-9]{16,64}$').hasMatch(clientId)) {
      throw const ArchiveProtocolException('客户端标识不合法');
    }
    final clientNonce = _decodeNonce(hello['nonce']);
    final serverNonce = archiveRandomBytes(32);
    await wire.writeFrame(
      archivePlainFrame(ArchiveFrameKind.challenge, <String, Object?>{
        'v': archiveProtocolVersion,
        'nonce': base64Url.encode(serverNonce).replaceAll('=', ''),
      }),
    );
    final keys = archiveDeriveSessionKeys(
      pairingKey: pairingKey,
      deskId: deskId,
      clientNonce: clientNonce,
      serverNonce: serverNonce,
    );
    final session = ArchiveSecureSession(
      wire: wire,
      sendKey: keys.serverToClient,
      receiveKey: keys.clientToServer,
      isClient: false,
      sessionId: keys.sessionId,
    );
    final pair = await session.readControl(timeout: timeout);
    if (pair['t'] != 'pair' || pair['client'] != clientId) {
      throw const ArchiveAuthException();
    }
    await session.sendControl(<String, Object?>{
      't': 'ready',
      'desk': deskId,
      'session': keys.sessionId,
    }, timeout: timeout);
    return session;
  }

  static Uint8List _decodeNonce(Object? value) {
    if (value is! String || value.length > 64) {
      throw const ArchiveProtocolException('随机数格式不正确');
    }
    final Uint8List decoded;
    try {
      decoded = base64Url.decode(base64Url.normalize(value));
    } catch (_) {
      throw const ArchiveProtocolException('随机数格式不正确');
    }
    if (decoded.length != 32) {
      throw const ArchiveProtocolException('随机数长度不正确');
    }
    return decoded;
  }
}
