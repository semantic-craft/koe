import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'doubao_stt.dart';
import 'qwen_stt.dart';
import 'stt_types.dart';

String speechRequestId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final s = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

/// Shared transport lifecycle. Provider adapters own wire messages and text
/// revision semantics; a disconnect is never treated as successful completion.
abstract class CloudSttStream implements SttStreamSession {
  CloudSttStream(this.uri, this.headers);
  final Uri uri;
  final Map<String, String> headers;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  final _events = StreamController<SttStreamEvent>.broadcast();
  final _ready = Completer<void>();
  final _done = Completer<SttStreamEvent?>();
  bool _closed = false;
  bool _finishing = false;
  bool _serverReady = false;
  String? _failure;
  String text = '';
  final _pendingAudio = BytesBuilder(copy: false);
  @override
  Stream<SttStreamEvent> get events => _events.stream;
  @override
  bool get isOpen => !_closed && _socket?.readyState == WebSocket.open;
  @override
  bool get isServerReady => isOpen && _serverReady && !_finishing;
  void send(Object data) => _socket?.add(data);
  void configure();
  void receive(dynamic data);
  void sendAudio(Uint8List pcm, {required bool last});
  void markReady() {
    _serverReady = true;
    if (!_ready.isCompleted) _ready.complete();
  }

  void emit({bool finalResult = false, bool speechFinal = false}) {
    final event = SttStreamEvent(
      type: finalResult ? 'done' : 'partial',
      text: text,
      isFinal: finalResult,
      speechFinal: speechFinal,
    );
    if (!_events.isClosed) _events.add(event);
    if (finalResult && !_done.isCompleted) _done.complete(event);
  }

  void fail(String message) {
    if (_failure != null || _closed) return;
    _failure = message;
    if (!_events.isClosed) {
      _events.add(SttStreamEvent(type: 'error', error: message));
    }
    if (!_ready.isCompleted) _ready.complete();
    if (!_done.isCompleted) _done.complete(null);
  }

  @override
  Future<void> start({Duration timeout = const Duration(seconds: 15)}) async {
    if (_closed) throw StateError('转写连接已关闭');
    try {
      final socket = await WebSocket.connect(
        uri.toString(),
        headers: headers,
      ).timeout(timeout);
      if (_closed) {
        await socket.close();
        return;
      }
      _socket = socket;
      _subscription = socket.listen(
        (data) {
          if (_closed) return;
          try {
            receive(data);
          } catch (_) {
            fail('无法解析实时识别响应');
          }
        },
        onError: (Object _) => fail('实时识别连接失败'),
        onDone: () {
          if (!_closed && !_done.isCompleted) fail('实时识别连接中断，录音仍保存在本机');
        },
      );
      configure();
      await _ready.future.timeout(timeout);
      if (_failure != null) throw StateError(_failure!);
    } catch (_) {
      await close();
      rethrow;
    }
  }

  @override
  void sendPcm(Uint8List pcm16le) {
    if (!isServerReady || pcm16le.isEmpty) return;
    _pendingAudio.add(pcm16le);
    final bytes = _pendingAudio.takeBytes();
    var offset = 0;
    for (; offset + 6400 <= bytes.length; offset += 6400) {
      sendAudio(Uint8List.sublistView(bytes, offset, offset + 6400), last: false);
    }
    if (offset < bytes.length) _pendingAudio.add(Uint8List.sublistView(bytes, offset));
  }
  @override
  void finalizeUtterance() {} // Provider VAD performs sentence finalization.
  @override
  Future<SttStreamEvent?> finish({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (_closed) return null;
    if (!_finishing && !_done.isCompleted) {
      _finishing = true;
      if (_pendingAudio.isNotEmpty) sendAudio(_pendingAudio.takeBytes(), last: false);
      sendAudio(Uint8List(0), last: true);
    }
    try {
      final result = await _done.future.timeout(timeout);
      if (_failure != null) throw StateError(_failure!);
      return result;
    } finally {
      await close();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _serverReady = false;
    if (!_ready.isCompleted) _ready.complete();
    if (!_done.isCompleted) _done.complete(null);
    await _subscription?.cancel();
    await _socket?.close();
  }

  @override
  Future<void> dispose() async {
    await close();
    await _events.close();
  }
}

class QwenSttStreamSession extends CloudSttStream {
  QwenSttStreamSession({
    required String apiKey,
    String? baseUrl,
    this.language,
    Uri? endpoint,
  }) : super(
         endpoint ??
             Uri.parse(
               '${normalizeDashScopeBaseUrl(baseUrl ?? QwenSttService.defaultBaseUrl).replaceFirst('https:', 'wss:')}/api-ws/v1/inference',
             ),
         {'Authorization': 'Bearer $apiKey'},
       );
  static const model = 'qwen-audio-3.1-asr-flash-streaming';
  final String? language;
  final taskId = speechRequestId();
  final _sentences = <int, String>{};
  Map<String, dynamic> _header(String action) => {
    'action': action,
    'task_id': taskId,
    'streaming': 'duplex',
  };
  @override
  void configure() => send(
    jsonEncode({
      'header': _header('run-task'),
      'payload': {
        'task_group': 'audio',
        'task': 'asr',
        'function': 'recognition',
        'model': model,
        'parameters': {
          'format': 'pcm',
          'sample_rate': 16000,
          if (language != null && language != 'auto')
            'language_hints': [language],
        },
        'input': <String, dynamic>{},
      },
    }),
  );
  @override
  void sendAudio(Uint8List pcm, {required bool last}) {
    if (last) {
      send(
        jsonEncode({
          'header': _header('finish-task'),
          'payload': {'input': <String, dynamic>{}},
        }),
      );
    } else {
      send(pcm);
    }
  }

  @override
  void receive(dynamic data) {
    final message = jsonDecode(data as String) as Map;
    final header = message['header'] as Map;
    if (header['task_id'] != taskId) return;
    switch (header['event']) {
      case 'task-started':
        markReady();
      case 'task-failed':
        fail('千问实时识别失败，请检查模型权限和配额');
      case 'task-finished':
        emit(finalResult: true);
      case 'result-generated':
        final sentence = message['payload']?['output']?['sentence'];
        if (sentence is! Map || sentence['heartbeat'] == true) return;
        final id = sentence['sentence_id'];
        if (id is! num) return;
        _sentences[id.toInt()] = '${sentence['text'] ?? ''}';
        final ids = _sentences.keys.toList()..sort();
        text = normalizeSttText(ids.map((id) => _sentences[id]).join('\n'));
        emit(speechFinal: sentence['sentence_end'] == true);
    }
  }
}

/// Volcano optimized bidirectional protocol, 2.0 with server second pass.
class DoubaoSttStreamSession extends CloudSttStream {
  DoubaoSttStreamSession({
    required String apiKey,
    String? baseUrl,
    this.language,
    Uri? endpoint,
  }) : super(
         endpoint ??
             Uri.parse(
               '${normalizeDoubaoBaseUrl(baseUrl ?? DoubaoSttService.defaultBaseUrl).replaceFirst('https:', 'wss:')}/api/v3/sauc/bigmodel_async',
             ),
         {
           'X-Api-Key': apiKey,
           'X-Api-Resource-Id': resource,
           'X-Api-Connect-Id': speechRequestId(),
         },
       );
  static const resource = 'volc.seedasr.sauc.duration';
  final String? language;
  @override
  void configure() {
    final code = doubaoLanguageCode(language);
    send(
      volcanoFrame(
        1,
        0,
        utf8.encode(
          jsonEncode({
            'user': {'uid': 'soundcore-manager'},
            'audio': {
              'format': 'pcm',
              'codec': 'raw',
              'rate': 16000,
              'bits': 16,
              'channel': 1,
              'language': ?code,
            },
            'request': {
              'model_name': 'bigmodel',
              'enable_nonstream': true,
              'enable_itn': true,
              'enable_punc': true,
              'show_utterances': true,
              'enable_speaker_info': true,
              if (code == null || code == 'zh-CN') 'ssd_version': '200',
            },
          }),
        ),
        json: true,
      ),
    );
  }

  @override
  void sendAudio(Uint8List pcm, {required bool last}) =>
      send(volcanoFrame(2, last ? 2 : 0, pcm));
  @override
  void receive(dynamic data) {
    final bytes = Uint8List.fromList(data as List<int>);
    if (bytes.length < 8 || bytes[0] >> 4 != 1) throw const FormatException();
    final type = bytes[1] >> 4, flags = bytes[1] & 15;
    var offset = (bytes[0] & 15) * 4;
    final view = ByteData.sublistView(bytes);
    if ((flags & 1) != 0) offset += 4;
    if (type == 15) {
      fail('豆包实时识别失败，请检查模型权限、配额和音频格式');
      return;
    }
    if (type != 9) return;
    final length = view.getUint32(offset);
    offset += 4;
    if (offset + length != bytes.length) throw const FormatException();
    List<int> payload = bytes.sublist(offset);
    if ((bytes[2] & 15) == 1) payload = gzip.decode(payload);
    final doc = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
    if (doc['code'] != null &&
        doc['code'] != 0 &&
        doc['code'] != 1000 &&
        doc['code'] != 20000000) {
      fail('豆包实时识别请求失败');
      return;
    }
    markReady();
    if (doc['result'] is Map) text = renderDoubaoTranscript(doc);
    emit(finalResult: (flags & 2) != 0);
  }
}

Uint8List volcanoFrame(
  int type,
  int flags,
  List<int> payload, {
  bool json = false,
}) {
  final bytes = Uint8List(8 + payload.length);
  bytes.setAll(0, [0x11, (type << 4) | flags, json ? 0x10 : 0, 0]);
  ByteData.sublistView(bytes).setUint32(4, payload.length);
  bytes.setAll(8, payload);
  return bytes;
}
