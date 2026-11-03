import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/platform/mac_captions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('one window receives captions, minutes and final hide', () async {
    const channel = MethodChannel('captions-test');
    final snapshots = <Map>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          snapshots.add(call.arguments as Map);
          return null;
        });
    final c = MacCaptions(channel: channel, enabled: true);
    await c.show(
      mode: 'captions',
      original: '你好',
      translation: 'Hello',
      minutes: '概要',
    );
    await c.show(
      mode: 'minutes',
      original: '你好',
      translation: 'Hello',
      minutes: '概要',
    );
    await c.hide();
    expect(snapshots.map((s) => s['mode']), ['captions', 'minutes', 'hidden']);
  });
}
