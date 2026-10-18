// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Wire format for the direct phone-to-Mac original-audio archive.
///
/// The only unauthenticated frames are the version/desk hello and the random
/// challenge. Everything after that (metadata and audio bytes) is wrapped in
/// ChaCha20-Poly1305 with keys derived from the pairing secret and both random
/// nonces. Each frame carries a strictly increasing sequence number and its
/// direction/kind in the associated data, so replayed, reflected, reordered or
/// cross-direction frames are rejected.
const int archiveProtocolVersion = 1;
const int archiveDefaultPort = 47831;
const int archiveMaxControlBytes = 64 * 1024;
const int archiveMaxDataBytes = 128 * 1024;
const int archiveChunkBytes = 48 * 1024;
const int archiveMaxAudioBytes = 512 * 1024 * 1024;
const int archiveMaxDisplayNameLength = 200;

enum ArchiveFrameKind {
  hello(1),
  challenge(2),
  control(4),
  data(5);

  const ArchiveFrameKind(this.wireValue);
  final int wireValue;

  static ArchiveFrameKind? fromWire(int value) {
    for (final kind in values) {
      if (kind.wireValue == value) return kind;
    }
    return null;
  }
}

class ArchiveException implements Exception {
  const ArchiveException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ArchiveProtocolException extends ArchiveException {
  const ArchiveProtocolException(super.message);
}

class ArchiveAuthException extends ArchiveException {
  const ArchiveAuthException([super.message = '配对密钥无效，请重新配对']);
}

class ArchiveTimeoutException extends ArchiveException {
  const ArchiveTimeoutException([super.message = '连接超时，请稍后重试']);
}

class ArchiveSourceChangedException extends ArchiveException {
  const ArchiveSourceChangedException([super.message = '原件在归档过程中发生变化，请重试']);
}

class ArchiveRemoteException extends ArchiveException {
  const ArchiveRemoteException(super.message, {this.reason});
  final String? reason;
}

/// One framed TCP connection. A frame is a 4-byte big-endian length followed
/// by one kind byte and its payload.
class ArchiveWire {
  ArchiveWire._(this._socket) : _iterator = StreamIterator<Uint8List>(_socket);

  final Socket _socket;
  final StreamIterator<Uint8List> _iterator;
  final List<Uint8List> _chunks = <Uint8List>[];
  int _buffered = 0;
  bool _closed = false;

  static ArchiveWire adopt(Socket socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    return ArchiveWire._(socket);
  }

  Future<Uint8List> readFrame({required Duration timeout}) async {
    final deadline = DateTime.now().add(timeout);
    final header = await _take(4, deadline);
    final length = ByteData.sublistView(header).getUint32(0, Endian.big);
    if (length < 1 || length > archiveMaxDataBytes + 64) {
      throw const ArchiveProtocolException('收到超长的数据帧，连接已关闭');
    }
    return _take(length, deadline);
  }

  Future<void> writeFrame(Uint8List payload) async {
    if (_closed) throw const ArchiveProtocolException('连接已关闭');
    if (payload.length > archiveMaxDataBytes + 64) {
      throw const ArchiveProtocolException('待发送的数据帧过大');
    }
    final output = Uint8List(4 + payload.length);
    ByteData.sublistView(output).setUint32(0, payload.length, Endian.big);
    output.setRange(4, output.length, payload);
    _socket.add(output);
    await _socket.flush();
  }

  Future<Uint8List> _take(int count, DateTime deadline) async {
    while (_buffered < count) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw const ArchiveTimeoutException('等待对端响应超时');
      }
      final bool hasNext;
      try {
        hasNext = await _iterator.moveNext().timeout(remaining);
      } on TimeoutException {
        throw const ArchiveTimeoutException('等待对端响应超时');
      } on SocketException {
        throw const ArchiveProtocolException('连接已断开');
      }
      if (!hasNext) throw const ArchiveProtocolException('对端已断开连接');
      final chunk = _iterator.current;
      if (chunk.isNotEmpty) {
        _chunks.add(chunk);
        _buffered += chunk.length;
      }
    }
    final output = Uint8List(count);
    var written = 0;
    while (written < count) {
      final head = _chunks.first;
      final need = count - written;
      if (head.length <= need) {
        output.setRange(written, written + head.length, head);
        written += head.length;
        _buffered -= head.length;
        _chunks.removeAt(0);
      } else {
        output.setRange(written, written + need, head);
        _chunks[0] = Uint8List.sublistView(head, need);
        _buffered -= need;
        written += need;
      }
    }
    return output;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _iterator.cancel();
    } catch (_) {}
    try {
      await _socket.close();
    } catch (_) {}
    _socket.destroy();
  }

  void destroy() {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
  }
}

enum ArchiveDirection {
  clientToServer(1),
  serverToClient(2);

  const ArchiveDirection(this.wireValue);
  final int wireValue;
}

class ArchiveSessionKeys {
  const ArchiveSessionKeys({
    required this.clientToServer,
    required this.serverToClient,
    required this.sessionId,
  });

  final Uint8List clientToServer;
  final Uint8List serverToClient;
  final String sessionId;
}

Uint8List archiveRandomBytes(int length) {
  final random = Random.secure();
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

String archiveRandomHex(int bytes) => archiveRandomBytes(
  bytes,
).map((value) => value.toRadixString(16).padLeft(2, '0')).join();

Uint8List archiveHmacSha256(List<int> key, List<int> data) {
  final mac = HMac(SHA256Digest(), 64)
    ..init(KeyParameter(Uint8List.fromList(key)));
  mac.update(Uint8List.fromList(data), 0, data.length);
  final output = Uint8List(mac.macSize);
  mac.doFinal(output, 0);
  return output;
}

/// HKDF-SHA256 (RFC 5869) for the single 32-byte output block used here.
Uint8List archiveHkdfSha256({
  required List<int> inputKey,
  required List<int> salt,
  required List<int> info,
  int length = 32,
}) {
  if (length <= 0 || length > 32) {
    throw ArgumentError.value(length, 'length', '只支持一个 SHA-256 摘要块');
  }
  final prk = archiveHmacSha256(salt, inputKey);
  final block = archiveHmacSha256(prk, <int>[...info, 1]);
  return Uint8List.sublistView(block, 0, length);
}

ArchiveSessionKeys archiveDeriveSessionKeys({
  required Uint8List pairingKey,
  required String deskId,
  required Uint8List clientNonce,
  required Uint8List serverNonce,
}) {
  final transcript = <int>[
    ...utf8.encode('koe-archive-handshake-v1'),
    ...utf8.encode(deskId),
    ...clientNonce,
    ...serverNonce,
  ];
  final handshake = archiveHmacSha256(pairingKey, transcript);
  return ArchiveSessionKeys(
    clientToServer: archiveHkdfSha256(
      inputKey: pairingKey,
      salt: handshake,
      info: utf8.encode('koe-archive-c2s-v1'),
    ),
    serverToClient: archiveHkdfSha256(
      inputKey: pairingKey,
      salt: handshake,
      info: utf8.encode('koe-archive-s2c-v1'),
    ),
    sessionId: archiveHkdfSha256(
      inputKey: pairingKey,
      salt: handshake,
      info: utf8.encode('koe-archive-session-v1'),
      length: 16,
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join(),
  );
}

Uint8List _uint64(int value) {
  final data = ByteData(8)..setUint64(0, value, Endian.big);
  return data.buffer.asUint8List();
}

Uint8List _nonceFor(int sequence) {
  final nonce = Uint8List(12);
  final data = ByteData.sublistView(nonce);
  data.setUint32(0, 0, Endian.big);
  data.setUint64(4, sequence, Endian.big);
  return nonce;
}

Uint8List _associatedData(
  ArchiveDirection direction,
  ArchiveFrameKind kind,
  int sequence,
) {
  return <int>[
    ...utf8.encode('koe-archive-frame-v1'),
    direction.wireValue,
    kind.wireValue,
    ..._uint64(sequence),
  ].toUint8List();
}

class ArchiveIncoming {
  const ArchiveIncoming.control(this.control)
    : kind = ArchiveFrameKind.control,
      data = null,
      dataIndex = null;

  const ArchiveIncoming.data(this.dataIndex, this.data)
    : kind = ArchiveFrameKind.data,
      control = null;

  final ArchiveFrameKind kind;
  final Map<String, Object?>? control;
  final int? dataIndex;
  final Uint8List? data;
}

/// Authenticated, ordered frame channel after the pairing handshake.
class ArchiveSecureSession {
  ArchiveSecureSession({
    required ArchiveWire wire,
    required Uint8List sendKey,
    required Uint8List receiveKey,
    required bool isClient,
    this.sessionId = '',
  }) : _wire = wire,
       _sendKey = sendKey,
       _receiveKey = receiveKey,
       _sendDirection = isClient
           ? ArchiveDirection.clientToServer
           : ArchiveDirection.serverToClient,
       _receiveDirection = isClient
           ? ArchiveDirection.serverToClient
           : ArchiveDirection.clientToServer;

  final ArchiveWire _wire;
  final Uint8List _sendKey;
  final Uint8List _receiveKey;
  final ArchiveDirection _sendDirection;
  final ArchiveDirection _receiveDirection;
  final String sessionId;

  int _sendSequence = 0;
  int _receiveSequence = 0;
  int _sendDataIndex = 0;
  int _receiveDataIndex = 0;

  void resetDataOrder() {
    _sendDataIndex = 0;
    _receiveDataIndex = 0;
  }

  Future<void> sendControl(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(message)));
    if (plain.length > archiveMaxControlBytes) {
      throw const ArchiveProtocolException('控制消息过大');
    }
    await _sendFrame(ArchiveFrameKind.control, plain);
  }

  Future<void> sendData(Uint8List data) async {
    if (data.isEmpty || data.length > archiveMaxDataBytes) {
      throw const ArchiveProtocolException('音频分块大小不合法');
    }
    final plain = Uint8List(8 + data.length);
    ByteData.sublistView(plain).setUint64(0, _sendDataIndex, Endian.big);
    plain.setRange(8, plain.length, data);
    _sendDataIndex++;
    await _sendFrame(ArchiveFrameKind.data, plain);
  }

  Future<ArchiveIncoming> readIncoming({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final frame = await _wire.readFrame(timeout: timeout);
    if (frame.isEmpty) throw const ArchiveProtocolException('空数据帧');
    final kind = ArchiveFrameKind.fromWire(frame.first);
    if (kind == null ||
        (kind != ArchiveFrameKind.control && kind != ArchiveFrameKind.data)) {
      throw const ArchiveProtocolException('未加密阶段不允许该帧');
    }
    final body = Uint8List.sublistView(frame, 1);
    final plain = _open(kind, body);
    if (kind == ArchiveFrameKind.control) {
      if (plain.length > archiveMaxControlBytes) {
        throw const ArchiveProtocolException('控制消息过大');
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(plain));
      } catch (_) {
        throw const ArchiveProtocolException('控制消息无法解析');
      }
      if (decoded is! Map) throw const ArchiveProtocolException('控制消息格式错误');
      return ArchiveIncoming.control(
        decoded.map((key, value) => MapEntry('$key', value)),
      );
    }
    if (plain.length < 9) throw const ArchiveProtocolException('音频分块过短');
    final index = ByteData.sublistView(plain).getUint64(0, Endian.big);
    if (index != _receiveDataIndex) {
      throw const ArchiveProtocolException('音频分块顺序不正确');
    }
    _receiveDataIndex++;
    return ArchiveIncoming.data(index, Uint8List.sublistView(plain, 8));
  }

  Future<Map<String, Object?>> readControl({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final incoming = await readIncoming(timeout: timeout);
    if (incoming.kind != ArchiveFrameKind.control) {
      throw const ArchiveProtocolException('期望控制消息，收到音频分块');
    }
    return incoming.control!;
  }

  Future<ArchiveIncoming> readData({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final incoming = await readIncoming(timeout: timeout);
    if (incoming.kind != ArchiveFrameKind.data) {
      throw const ArchiveProtocolException('期望音频分块，收到控制消息');
    }
    return incoming;
  }

  Future<void> _sendFrame(ArchiveFrameKind kind, Uint8List plain) async {
    final sequence = _sendSequence++;
    final sealed = _seal(kind, plain, sequence);
    final payload = Uint8List(1 + sealed.length);
    payload[0] = kind.wireValue;
    payload.setRange(1, payload.length, sealed);
    await _wire.writeFrame(payload);
  }

  Uint8List _seal(ArchiveFrameKind kind, Uint8List plain, int sequence) {
    final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305());
    cipher.init(
      true,
      AEADParameters(
        KeyParameter(_sendKey),
        128,
        _nonceFor(sequence),
        _associatedData(_sendDirection, kind, sequence),
      ),
    );
    final output = Uint8List(cipher.getOutputSize(plain.length));
    final written = cipher.processBytes(plain, 0, plain.length, output, 0);
    final finished = cipher.doFinal(output, written);
    return Uint8List.sublistView(output, 0, written + finished);
  }

  Uint8List _open(ArchiveFrameKind kind, Uint8List sealed) {
    if (sealed.length < 16) {
      throw const ArchiveAuthException('加密封装不完整');
    }
    final sequence = _receiveSequence;
    final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305());
    cipher.init(
      false,
      AEADParameters(
        KeyParameter(_receiveKey),
        128,
        _nonceFor(sequence),
        _associatedData(_receiveDirection, kind, sequence),
      ),
    );
    final Uint8List plain;
    try {
      final output = Uint8List(cipher.getOutputSize(sealed.length));
      final written = cipher.processBytes(sealed, 0, sealed.length, output, 0);
      final finished = cipher.doFinal(output, written);
      plain = Uint8List.sublistView(output, 0, written + finished);
    } catch (_) {
      throw const ArchiveAuthException();
    }
    _receiveSequence++;
    return plain;
  }

  Future<void> close() => _wire.close();
  void destroy() => _wire.destroy();
}

Uint8List archivePlainFrame(
  ArchiveFrameKind kind,
  Map<String, Object?> message,
) {
  final json = Uint8List.fromList(utf8.encode(jsonEncode(message)));
  if (json.length > archiveMaxControlBytes) {
    throw const ArchiveProtocolException('握手消息过大');
  }
  final output = Uint8List(1 + json.length);
  output[0] = kind.wireValue;
  output.setRange(1, output.length, json);
  return output;
}

Map<String, Object?> archiveDecodePlain(
  Uint8List frame,
  ArchiveFrameKind expected,
) {
  if (frame.isEmpty || frame.first != expected.wireValue) {
    throw const ArchiveProtocolException('握手消息类型不正确');
  }
  if (frame.length - 1 > archiveMaxControlBytes) {
    throw const ArchiveProtocolException('握手消息过大');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(Uint8List.sublistView(frame, 1)));
  } catch (_) {
    throw const ArchiveProtocolException('握手消息无法解析');
  }
  if (decoded is! Map) throw const ArchiveProtocolException('握手消息格式错误');
  return decoded.map((key, value) => MapEntry('$key', value));
}

Future<String?> archiveFileHash(String path) async {
  final file = File(path);
  if (!await file.exists()) return null;
  final before = await file.stat();
  if (before.type != FileSystemEntityType.file) return null;
  final digest = SHA256Digest();
  await for (final chunk in file.openRead()) {
    final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    digest.update(bytes, 0, bytes.length);
  }
  final after = await file.stat();
  if (after.type != FileSystemEntityType.file ||
      after.size != before.size ||
      after.modified != before.modified) {
    throw const ArchiveSourceChangedException();
  }
  final output = Uint8List(digest.digestSize);
  digest.doFinal(output, 0);
  return output.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}

String archiveHashBytes(List<int> bytes) {
  final digest = SHA256Digest()
    ..update(Uint8List.fromList(bytes), 0, bytes.length);
  final output = Uint8List(digest.digestSize);
  digest.doFinal(output, 0);
  return output.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}

bool archiveConstantTimeEquals(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var i = 0; i < left.length; i++) {
    difference |= left[i] ^ right[i];
  }
  return difference == 0;
}

final RegExp _contentHashPattern = RegExp(r'^[a-f0-9]{64}$');
bool archiveIsValidContentHash(Object? value) =>
    value is String && _contentHashPattern.hasMatch(value);

const Set<String> archiveAllowedSourceExtensions = <String>{
  '.wav',
  '.m4a',
  '.mp3',
  '.aac',
  '.flac',
  '.ogg',
  '.opus',
  '.opus.bin',
};

const Set<String> archiveAllowedStoredExtensions = <String>{
  '.wav',
  '.m4a',
  '.mp3',
  '.aac',
  '.flac',
  '.ogg',
  '.opus',
  '.opus.bin',
};

/// Server-side path components never come from the remote peer: the stored
/// name is the verified content hash plus a whitelisted audio extension.
String archiveStoredExtension(String extension) {
  final lower = extension.toLowerCase();
  // `.opus.bin` is a raw/encrypted original byte stream. Renaming it `.opus`
  // would claim it is directly decodable, so the suffix is preserved.
  if (archiveAllowedStoredExtensions.contains(lower)) return lower;
  throw const ArchiveProtocolException('不支持的音频扩展名');
}

bool archiveIsAllowedSourceExtension(String path) {
  final lower = path.toLowerCase();
  return archiveAllowedSourceExtensions.any(lower.endsWith);
}

String archiveSanitizeDisplayName(String value) {
  final sanitized = value
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (sanitized.isEmpty) return '录音';
  return sanitized.length <= archiveMaxDisplayNameLength
      ? sanitized
      : sanitized.substring(0, archiveMaxDisplayNameLength);
}

extension _IntListBytes on List<int> {
  Uint8List toUint8List() => Uint8List.fromList(this);
}
