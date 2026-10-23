import 'dart:io';
import 'dart:typed_data';
import 'package:koe/audio/audio_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'audio identity follows content, including same size and modification time',
    () async {
      final dir = await Directory.systemTemp.createTemp('version-test-');
      addTearDown(() => dir.delete(recursive: true));
      final f = File('${dir.path}/1.wav');
      await f.writeAsBytes([1, 2, 3]);
      final original = await audioVersion(f.path);
      expect(original, hasLength(64));
      final date = (await f.stat()).modified;
      final renamed = await f.rename('${dir.path}/renamed.wav');
      expect(await audioVersion(renamed.path), original);
      await renamed.writeAsBytes([3, 2, 1]);
      await renamed.setLastModified(date);
      expect(await audioVersion(renamed.path), isNot(original));
      expect(await audioVersion('${dir.path}/missing.wav'), isNull);
    },
  );

  test(
    'audio identity is the SHA-256 of the whole file, so saved identities still match',
    () async {
      final dir = await Directory.systemTemp.createTemp('version-test-');
      addTearDown(() => dir.delete(recursive: true));
      // Several read chunks, each different, and a short last one.
      final bytes = Uint8List(3 * 65536 + 1234);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = (i ^ (i >> 8) ^ (i >> 16)) & 0xFF;
      }
      final take = File('${dir.path}/take.wav');
      await take.writeAsBytes(bytes);
      final empty = File('${dir.path}/empty.wav');
      await empty.writeAsBytes(const []);
      // As `shasum -a 256` prints them.
      expect(
        await audioVersion(take.path),
        '6e8f36cb5314f42c6def49ac6e0232d5c66f889fae0f13a97f7c2a5045c1a2b6',
      );
      expect(
        await audioVersion(empty.path),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    },
  );
}
