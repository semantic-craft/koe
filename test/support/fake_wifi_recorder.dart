import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:koe/protocol/frame.dart';
import 'package:koe/wifi/softap_link.dart';

/// One slice unit as the recorder sends and counts it: sequence, flags, 160
/// bytes of audio and a pad byte (PROTOCOL.md §6.5). File heads announce
/// sizes in these units.
const recorderUnitBytes = 166;

/// Audio of [units] slice units, different for every [fileId].
List<int> recorderAudio(int fileId, {required int units}) =>
    List<int>.generate(units * 160, (i) => (fileId + i * 7) & 0xFF);

/// Android's link: reaches the recorder only after joining its hotspot.
/// A hotspot it could not join is gone afterwards, as the recorder turns it
/// off when nobody joins.
class FakeSoftApLink implements SoftApLink {
  FakeSoftApLink({required this.recorderPort, this.joinError});

  final int recorderPort;

  /// Thrown by the first join, as when the user cancels the system dialog.
  final SoftApJoinException? joinError;
  final events = <String>[];
  final _gone = <String>{};
  var _joins = 0;
  var _joined = false;

  /// Hotspots joined, by SSID, including failed attempts.
  List<String> get joins => [
    for (final e in events)
      if (e.startsWith('join ')) e.split(' ')[1],
  ];

  @override
  bool get joinsItself => true;

  @override
  Future<void> join({required String ssid, required String password}) async {
    events.add('join $ssid $password');
    if (_gone.contains(ssid)) {
      throw SoftApJoinException('找不到录音豆的 Wi‑Fi「$ssid」');
    }
    if (_joins++ == 0 && joinError != null) {
      _gone.add(ssid);
      throw joinError!;
    }
    _joined = true;
  }

  @override
  SoftApDial get dial => (host, port) async {
    events.add('dial $host:$port');
    if (!_joined) throw const SocketException('not on the hotspot');
    return Socket.connect(InternetAddress.loopbackIPv4, recorderPort);
  };

  @override
  Future<void> startKeepalive(String host) async =>
      events.add('keepalive $host');

  @override
  Future<void> release() async {
    events.add('release');
    _joined = false;
  }
}

/// Answers one file request on the recorder's end of the WebSocket.
typedef RecorderFileServer =
    FutureOr<void> Function(WebSocket socket, int fileId);

/// The recorder's WebSocket listener: hands each file request (hex text
/// `1A07`) to a [RecorderFileServer].
class FakeWifiRecorder {
  FakeWifiRecorder._(this._server, this._serveFile);

  static Future<FakeWifiRecorder> start(RecorderFileServer serveFile) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final recorder = FakeWifiRecorder._(server, serveFile);
    server.listen(recorder._serve);
    return recorder;
  }

  /// Sends each requested file whole: head, every unit and the done marker.
  static Future<FakeWifiRecorder> serving(Map<int, List<int>> audioById) =>
      start((socket, fileId) {
        final audio = audioById[fileId]!;
        socket.add([
          ...head(fileId, units: audio.length ~/ 160),
          ...slices(audio),
          ...done(),
        ]);
      });

  final HttpServer _server;
  final RecorderFileServer _serveFile;
  final _sockets = <WebSocket>[];

  /// File ids in the order Koe requested them.
  final requests = <int>[];
  String? host;

  int get port => _server.port;

  Future<void> _serve(HttpRequest request) async {
    host = request.headers.value(HttpHeaders.hostHeader);
    final socket = await WebSocketTransformer.upgrade(request);
    _sockets.add(socket);
    socket.listen((message) {
      if (message is! String || !message.startsWith('08ee0000001a07')) return;
      // 1A07 request: 9 header bytes, transferred u32, then the file id.
      final idHex = message.substring(26, 34);
      var fileId = 0;
      for (var i = 3; i >= 0; i--) {
        fileId =
            fileId << 8 |
            int.parse(idHex.substring(i * 2, i * 2 + 2), radix: 16);
      }
      requests.add(fileId);
      _serveFile(socket, fileId);
    });
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      await socket.close();
    }
    await _server.close(force: true);
  }

  /// File head announcing [units] slice units.
  static Uint8List head(int fileId, {required int units}) =>
      frame(0x07, [...u32(fileId), ...u32(units * recorderUnitBytes)]);

  /// [audio] as slice units numbered from [sequence], in as many frames as
  /// the 16-bit frame length needs.
  static Uint8List slices(List<int> audio, {int sequence = 0}) {
    const unitsPerFrame = 390;
    final out = BytesBuilder(copy: false);
    final units = audio.length ~/ 160;
    for (var first = 0; first < units; first += unitsPerFrame) {
      final last = first + unitsPerFrame < units
          ? first + unitsPerFrame
          : units;
      final payload = Uint8List((last - first) * recorderUnitBytes);
      for (var u = first; u < last; u++) {
        final at = (u - first) * recorderUnitBytes;
        payload.setAll(at, u32(sequence + u));
        payload.setRange(at + 5, at + 165, audio, u * 160);
      }
      out.add(frame(0x08, payload));
    }
    return out.takeBytes();
  }

  static Uint8List done() => frame(0x0A, [1]);

  static Uint8List frame(int id, List<int> payload) {
    final length = 9 + payload.length + 1;
    final out = Uint8List(length)
      ..setAll(0, [
        0x09,
        0xFF,
        0x00,
        0x00,
        0x01,
        0x1A,
        id,
        length & 0xFF,
        length >> 8,
      ])
      ..setAll(9, payload);
    out[length - 1] = ProtocolFrame.checksum(
      Uint8List.sublistView(out, 0, length - 1),
    );
    return out;
  }

  static List<int> u32(int value) => [
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ];
}
