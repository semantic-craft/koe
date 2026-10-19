import 'dart:io';

/// Deletes a test's temporary folder even if a write the test started but did
/// not await (a store save after dispose) lands while it is being removed.
Future<void> deleteTemporaryDirectory(Directory directory) async {
  for (var attempt = 0; ; attempt++) {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt >= 20) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
