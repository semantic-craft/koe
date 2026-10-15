import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:anker_recorder/ai/cloud_stt_stream.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Qwen waits for task-started, replaces partials, flushes tail and finishes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var receivedBytes = 0;
    server.listen((request) async {
      expect(request.headers.value('authorization'), 'Bearer test-key');
      final ws = await WebSocketTransformer.upgrade(request);
      String? task;
      void reply(String event, [Map<String,dynamic>? output]) => ws.add(jsonEncode({
        'header': {'event':event,'task_id':task},
        'payload': {'output': output}
      }));
      ws.listen((data) {
        if (data is List<int>) { receivedBytes += data.length; return; }
        final msg = jsonDecode(data as String) as Map;
        if (msg['header']['action'] == 'run-task') {
          task = msg['header']['task_id'] as String;
          expect(msg['payload']['model'], QwenSttStreamSession.model);
          reply('task-started');
          reply('result-generated', {'sentence':{'sentence_id':1,'text':'重复的草稿草稿'}});
          reply('result-generated', {'sentence':{'sentence_id':1,'text':'修正。','sentence_end':true}});
          reply('result-generated', {'sentence':{'sentence_id':2,'text':'第二句。','sentence_end':true}});
        } else { reply('task-finished'); }
      });
    });
    final session = QwenSttStreamSession(apiKey:'test-key', endpoint:Uri.parse('ws://127.0.0.1:${server.port}'));
    addTearDown(session.dispose);
    session.sendPcm(Uint8List(320)); // no audio before ready
    await session.start();
    for(var i=0;i<21;i++) { session.sendPcm(Uint8List(640)); }
    final result = await session.finish();
    expect(receivedBytes, 13440);
    expect(result?.text, '修正。\n第二句。');
    expect(result?.isFinal, isTrue);
    expect(session.isOpen, isFalse);
  });

  test('Doubao uses second pass, decodes gzip sequence packets and replaces drafts', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force:true));
    var audioBytes = 0;
    server.listen((request) async {
      expect(request.headers.value('x-api-resource-id'), 'volc.seedasr.sauc.duration');
      final ws = await WebSocketTransformer.upgrade(request);
      void reply(String text, {bool last=false}) {
        final payload = gzip.encode(utf8.encode(jsonEncode({'result':{'text':text}})));
        final frame = Uint8List(12 + payload.length);
        frame.setAll(0,[0x11,last ? 0x93 : 0x91,0x11,0]);
        final view = ByteData.sublistView(frame);
        view.setInt32(4,last ? -2 : 1);view.setUint32(8,payload.length);frame.setAll(12,payload);
        ws.add(frame);
      }
      ws.listen((data) {
        final bytes = data as List<int>;
        if (bytes[1] >> 4 == 1) {
          final body = jsonDecode(utf8.decode(bytes.sublist(8)));
          expect(body['request']['enable_nonstream'], isTrue);
          expect(body['request']['ssd_version'], '200');
          expect(body['audio']['rate'],16000);
          reply('较长的错误草稿');
        } else {
          audioBytes += bytes.length - 8;
          if ((bytes[1]&2)!=0) reply('准确。',last:true);
        }
      });
    });
    final session=DoubaoSttStreamSession(apiKey:'test-key',language:'zh',endpoint:Uri.parse('ws://127.0.0.1:${server.port}'));
    addTearDown(session.dispose);
    await session.start();session.sendPcm(Uint8List(7000));
    final result=await session.finish();
    expect(audioBytes,7000);expect(result?.text,'准确。');expect(result?.isFinal,isTrue);
  });

  test('abrupt socket close is an error, never a completed transcript', () async {
    final server=await HttpServer.bind(InternetAddress.loopbackIPv4,0);
    addTearDown(()=>server.close(force:true));
    server.listen((request) async {
      final ws=await WebSocketTransformer.upgrade(request);
      ws.listen((_) {ws.close();});
    });
    final session=DoubaoSttStreamSession(apiKey:'test-key',endpoint:Uri.parse('ws://127.0.0.1:${server.port}'));
    addTearDown(session.dispose);
    final events=<String>[];
    final sub=session.events.listen((e)=>events.add(e.type));
    addTearDown(sub.cancel);
    await expectLater(session.start(),throwsStateError);
    expect(events,contains('error'));expect(events, isNot(contains('done')));
  });
}
