import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'iOS declares background audio alongside Bluetooth restoration',
    () async {
      final plist = await File('ios/Runner/Info.plist').readAsString();

      expect(plist, contains('<key>UIBackgroundModes</key>'));
      expect(plist, contains('<string>bluetooth-central</string>'));
      expect(plist, contains('<string>audio</string>'));
    },
  );

  test('Android registers the media playback service and activity', () async {
    final manifest = await File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsString();
    final activity = await File(
      'android/app/src/main/kotlin/com/anker/anker_recorder/MainActivity.kt',
    ).readAsString();

    expect(
      manifest,
      contains('android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK'),
    );
    expect(manifest, contains('com.ryanheise.audioservice.AudioService'));
    expect(
      manifest,
      contains('com.ryanheise.audioservice.MediaButtonReceiver'),
    );
    expect(manifest, contains('android:foregroundServiceType="mediaPlayback"'));
    expect(activity, contains('AudioServiceActivity'));
  });
}
