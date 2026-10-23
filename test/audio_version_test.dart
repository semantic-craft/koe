import 'dart:io';
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
}
