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
