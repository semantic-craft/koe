import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

// #38: Android shows Koe in the launcher and in the background sync
// notification, the launcher icon is the approved Koe illustration (same
// source as the iOS 1024 AppIcon), and the install identity (applicationId,
// Kotlin package, method channel, notification channel) stays unchanged so
// existing data and notification settings survive an upgrade.

const applicationId = 'com.anker.anker_recorder';
const kotlinDir = 'android/app/src/main/kotlin/com/anker/anker_recorder';
const manifestPath = 'android/app/src/main/AndroidManifest.xml';
const densities = {
  'mdpi': 48,
  'hdpi': 72,
  'xhdpi': 96,
  'xxhdpi': 144,
  'xxxhdpi': 192,
};

String read(String path) => File(path).readAsStringSync();

/// Minimal decoder for 8-bit, non-interlaced RGB/RGBA PNG files, returning
/// RGB rows (alpha composited on black). Enough to compare icon artwork.
class _Png {
  _Png(this.width, this.height, this.rgb);
  final int width;
  final int height;
  final Uint8List rgb;

  static _Png decode(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    var offset = 8;
    late int width, height, colorType;
    final idat = BytesBuilder(copy: false);
    while (offset < bytes.length) {
      final length = data.getUint32(offset);
      final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
      final body = Uint8List.sublistView(bytes, offset + 8, offset + 8 + length);
      if (type == 'IHDR') {
        final header = ByteData.sublistView(body);
        width = header.getUint32(0);
        height = header.getUint32(4);
        colorType = body[9];
        if (body[8] != 8 || (colorType != 2 && colorType != 6) || body[12] != 0) {
          throw StateError('only 8-bit non-interlaced RGB/RGBA PNG supported');
        }
      } else if (type == 'IDAT') {
        idat.add(body);
      } else if (type == 'IEND') {
        break;
      }
      offset += 12 + length;
    }
    final channels = colorType == 6 ? 4 : 3;
    final raw = Uint8List.fromList(ZLibDecoder().convert(idat.takeBytes()));
    final stride = width * channels;
    final pixels = Uint8List(height * stride);
    for (var y = 0; y < height; y++) {
      final filter = raw[y * (stride + 1)];
      final src = y * (stride + 1) + 1;
      final row = y * stride;
      for (var x = 0; x < stride; x++) {
        final a = x >= channels ? pixels[row + x - channels] : 0;
        final b = y > 0 ? pixels[row - stride + x] : 0;
        final c = (x >= channels && y > 0)
            ? pixels[row - stride + x - channels]
            : 0;
        final value = raw[src + x];
        final int predicted;
        switch (filter) {
          case 0:
            predicted = 0;
          case 1:
            predicted = a;
          case 2:
            predicted = b;
          case 3:
            predicted = (a + b) >> 1;
          case 4:
            final p = a + b - c;
            final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
            predicted = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
          default:
            throw StateError('bad PNG filter $filter');
        }
        pixels[row + x] = (value + predicted) & 0xFF;
      }
    }
    final rgb = Uint8List(width * height * 3);
    for (var i = 0, j = 0; i < pixels.length; i += channels, j += 3) {
      final alpha = channels == 4 ? pixels[i + 3] : 255;
      for (var k = 0; k < 3; k++) {
        rgb[j + k] = pixels[i + k] * alpha ~/ 255;
      }
    }
    return _Png(width, height, rgb);
  }

  /// Mean colour of each cell in an n x n grid.
  List<double> grid(int n) {
    final out = <double>[];
    for (var gy = 0; gy < n; gy++) {
      for (var gx = 0; gx < n; gx++) {
        final y0 = gy * height ~/ n, y1 = (gy + 1) * height ~/ n;
        final x0 = gx * width ~/ n, x1 = (gx + 1) * width ~/ n;
        final sums = [0.0, 0.0, 0.0];
        for (var y = y0; y < y1; y++) {
          for (var x = x0; x < x1; x++) {
            for (var k = 0; k < 3; k++) {
              sums[k] += rgb[(y * width + x) * 3 + k];
            }
          }
        }
        final count = (y1 - y0) * (x1 - x0);
        out.addAll(sums.map((s) => s / count));
      }
    }
    return out;
  }
}

void main() {
  group('Android identity', () {
    test('launcher label is Koe', () {
      final manifest = read(manifestPath);
      expect(manifest, contains('android:label="Koe"'));
      expect(manifest, isNot(contains('安克录音豆')));
      expect(manifest, contains('android:icon="@mipmap/ic_launcher"'));
    });

    test('applicationId, namespace and Kotlin package are unchanged', () {
      final gradle = File('android/app/build.gradle.kts').existsSync()
          ? read('android/app/build.gradle.kts')
          : read('android/app/build.gradle');
      expect(gradle, contains('applicationId = "$applicationId"'));
      expect(gradle, contains('namespace = "$applicationId"'));
      for (final file in ['MainActivity.kt', 'RecordingSyncService.kt']) {
        expect(read('$kotlinDir/$file'),
            startsWith('package $applicationId\n'), reason: file);
      }
    });

    test('legacy URL entry, activity and sync service are unchanged', () {
      final manifest = read(manifestPath);
      expect(manifest, contains('android:scheme="soundcore"'));
      expect(manifest, contains('android:name=".MainActivity"'));
      expect(manifest, contains('android:launchMode="singleTop"'));
      expect(manifest, contains('android:name=".RecordingSyncService"'));
      expect(manifest,
          contains('android:foregroundServiceType="connectedDevice"'));
    });

    test('background sync method channel is unchanged on both sides', () {
      const channel = '$applicationId/background_sync';
      expect(read('$kotlinDir/MainActivity.kt'), contains('"$channel"'));
      final dart = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .any((f) => f.readAsStringSync().contains("'$channel'"));
      expect(dart, isTrue, reason: 'Dart side of $channel');
    });
  });

  group('Android background sync notification', () {
    final service = read('$kotlinDir/RecordingSyncService.kt');

    test('title is Koe and keeps the sync status text', () {
      expect(service, contains('.setContentTitle("Koe")'));
      expect(service, contains('.setContentText("正在后台同步录音")'));
      expect(service, isNot(contains('安克录音豆')));
    });

    test('notification channel and id are unchanged', () {
      expect(service, contains('CHANNEL_ID = "recording_sync"'));
      expect(service, contains('NOTIFICATION_ID = 3200'));
    });

    test('tapping the notification returns to MainActivity', () {
      expect(service, contains('Intent(this, MainActivity::class.java)'));
      expect(service, contains('PendingIntent.getActivity('));
      expect(service, contains('.setContentIntent(contentIntent)'));
      expect(service, contains('PendingIntent.FLAG_IMMUTABLE'));
    });
  });

  group('Android launcher icon', () {
    List<double>? iosGrid;
    List<double> ios() => iosGrid ??= _Png.decode(File(
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png',
    ).readAsBytesSync()).grid(8);

    for (final entry in densities.entries) {
      test('mipmap-${entry.key} is the Koe illustration at ${entry.value} px',
          () {
        final png = _Png.decode(File(
          'android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png',
        ).readAsBytesSync());
        expect(png.width, entry.value);
        expect(png.height, entry.value);
        // Same artwork as the iOS AppIcon: the mean colour of every grid
        // cell matches closely. The previous device photo differs by ~85.
        final cells = png.grid(8);
        final reference = ios();
        var total = 0.0;
        for (var i = 0; i < cells.length; i++) {
          total += (cells[i] - reference[i]).abs();
        }
        expect(total / cells.length, lessThan(8));
      });
    }

    test('generator script writes every Android density', () {
      final script = read('scripts/generate-app-icons.swift');
      expect(script, contains('assets/artwork/koe-schoolgirl-b-cheerful.png'));
      for (final entry in densities.entries) {
        expect(script, contains('("${entry.key}", ${entry.value})'));
      }
      expect(script, contains(r'mipmap-\(density)/ic_launcher.png'));
    });
  });
}
