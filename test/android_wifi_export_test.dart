import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/protocol/frame.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/wifi/softap_link.dart';
import 'package:koe/wifi/wifi_export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding answers every HttpClient request with 400; the export
  // needs a real WebSocket handshake with the fake recorder.
  HttpOverrides.global = null;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory documents;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('android-wifi-export-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => documents.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await documents.delete(recursive: true);
  });

  // TEST-NET-1: nothing answers there, so on Android only the hotspot the
  // link joined reaches the recorder — the phone's default network does not.
  WifiEndpoint endpoint(int port) => WifiEndpoint(
    ssid: 'WiFi-1761100000000',
    password: '1761100000000',
    ip: '192.0.2.1',
    port: port,
  );

  test('Android export joins the hotspot and pulls the file through it', () async {
    final audio = List<int>.generate(160, (i) => i);
    final recorder = await _FakeRecorder.start(fileId: 1761100000, audio: audio);
    final link = _FakeLink(recorderPort: recorder.port);
    final service = WifiExportService(
      blePackets: const Stream<DecodedPacket>.empty(),
      bleWrite: (_) async {},
      link: link,
    );

    final saved = await service
        .transferFiles(
          endpoint: endpoint(recorder.port),
          files: [OfflineFileEntry(fileId: 1761100000, sizeBytes: 160)],
          useSsl: false,
        )
        .timeout(const Duration(seconds: 10));

    expect(saved, hasLength(1));
    expect(await File(saved.single).readAsBytes(), audio);
    expect(link.events, [
      'join WiFi-1761100000000 1761100000000',
      'dial 192.0.2.1:${recorder.port}',
      'keepalive 192.0.2.1',
      'release',
    ]);
    // The recorder still sees its own address, as with a direct connection.
    expect(recorder.host, '192.0.2.1:${recorder.port}');
    await recorder.close();
    await service.dispose();
  });

  test('a failed hotspot join ends the export with its reason', () async {
    const reason = '没有连上录音豆的 Wi‑Fi「WiFi-1761100000000」';
    final link = _FakeLink(
      recorderPort: 9,
      joinError: const SoftApJoinException(reason),
    );
    final service = WifiExportService(
      blePackets: const Stream<DecodedPacket>.empty(),
      bleWrite: (_) async {},
      link: link,
    );

    await expectLater(
      service.transferFiles(
        endpoint: endpoint(9),
        files: [OfflineFileEntry(fileId: 1761100000, sizeBytes: 160)],
        useSsl: false,
      ),
      throwsA(isA<SoftApJoinException>()),
    );

    expect(service.current.phase, ExportPhase.error);
    expect(service.current.error, reason);
    // Withdraws the system's network request instead of leaving it pending.
    expect(link.events, ['join WiFi-1761100000000 1761100000000', 'release']);
    await service.dispose();
  });
}

/// Android's link: reaches the recorder only after joining its hotspot.
class _FakeLink implements SoftApLink {
  _FakeLink({required this.recorderPort, this.joinError});

  final int recorderPort;
  final SoftApJoinException? joinError;
  final events = <String>[];
  var _joined = false;

  @override
  bool get joinsItself => true;

  @override
  Future<void> join({required String ssid, required String password}) async {
    events.add('join $ssid $password');
    if (joinError case final error?) throw error;
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

/// The recorder's WebSocket listener: answers a file request (hex text
/// `1A07`) with the file head, one slice of [audio] and the done marker.
class _FakeRecorder {
  _FakeRecorder._(this._server, this.fileId, this.audio);

  static Future<_FakeRecorder> start({
    required int fileId,
    required List<int> audio,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final recorder = _FakeRecorder._(server, fileId, audio);
    server.listen(recorder._serve);
    return recorder;
  }

  final HttpServer _server;
  final int fileId;
  final List<int> audio;
  final _sockets = <WebSocket>[];
  String? host;

  int get port => _server.port;

  Future<void> _serve(HttpRequest request) async {
    host = request.headers.value(HttpHeaders.hostHeader);
    final socket = await WebSocketTransformer.upgrade(request);
    _sockets.add(socket);
    socket.listen((message) {
      if (message is! String || !message.startsWith('08ee0000001a07')) return;
      socket.add([
        ..._frame(0x07, [..._u32(fileId), ..._u32(audio.length)]),
        // One slice unit: sequence, flags, 160 bytes of audio, pad.
        ..._frame(0x08, [..._u32(0), 0, ...audio, 0]),
        ..._frame(0x0A, [1]),
      ]);
    });
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      await socket.close();
    }
    await _server.close(force: true);
  }

  static List<int> _frame(int id, List<int> payload) {
    final length = 9 + payload.length + 1;
    final body = [
      0x09,
      0xFF,
      0x00,
      0x00,
      0x01,
      0x1A,
      id,
      length & 0xFF,
      length >> 8,
      ...payload,
    ];
    return [...body, ProtocolFrame.checksum(body)];
  }

  static List<int> _u32(int value) => [
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ];
}
