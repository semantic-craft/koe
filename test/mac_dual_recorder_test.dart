import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/platform/mac_dual_recorder.dart';
import 'package:koe/platform/phone_recorder.dart';

class Mic extends PhoneRecorder {
  @override
  Future<bool> requestPermission() async => true;
  @override
  Stream<PhoneMicState> get states => const Stream.empty();
  @override
  Future<void> start(String path) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> cancel() async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dual-test');
  test(
    'partial and old-session speech never become confirmed minutes sources',
    () async {
      final dir = await Directory.systemTemp.createTemp('dual-final-');
      final events = StreamController<dynamic>.broadcast(sync: true);
      String? session;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'supported') return true;
            if (call.method == 'start') {
              session = (call.arguments as Map)['session'] as String?;
            }
            return null;
          });
      final recorder = MacDualRecorder(
        microphone: Mic(),
        channel: channel,
        events: events.stream,
      )..enabled = true;
      await recorder.start('${dir.path}/a.wav');
      events.add({
        'session': session,
        'lane': 'microphone',
        'requestId': 'one',
        'offset': 0,
        'text': '半句',
        'final': false,
      });
      expect(recorder.view.value.segments, isEmpty);
      events.add({
        'session': session,
        'lane': 'microphone',
        'requestId': 'one',
        'offset': 0,
        'text': '确定一句',
        'final': true,
      });
      events.add({
        'session': 'old',
        'lane': 'microphone',
        'requestId': 'two',
        'offset': 1,
        'text': '旧会话',
        'final': true,
      });
      expect(recorder.view.value.segments.single.text, '确定一句');
      await recorder.dispose();
      await events.close();
      await dir.delete(recursive: true);
    },
  );
  test('discard deletes both lanes even when native stop fails', () async {
    final directory = await Directory.systemTemp.createTemp('koe-dual-test-');
    final path = '${directory.path}/phone_123.wav';
    final events = StreamController<dynamic>.broadcast();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'supported') return true;
          if (call.method == 'stop') throw PlatformException(code: 'disk');
          return null;
        });
    final recorder = MacDualRecorder(
      microphone: Mic(),
      channel: channel,
      events: events.stream,
    )..enabled = true;
    await recorder.start(path);
    for (final item in [
      path,
      MacDualRecorder.systemPath(path),
      MacDualRecorder.textPath(path),
    ]) {
      await File(item).writeAsString('recording');
    }
    await expectLater(recorder.cancel(), throwsA(isA<PlatformException>()));
    expect(await directory.list().toList(), isEmpty);
    await recorder.dispose();
    await events.close();
    await directory.delete();
  });
}
