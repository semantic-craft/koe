import 'package:file_selector_ios/file_selector_ios.dart';
// The host API is the plugin's own test seam (`@visibleForTesting`).
// ignore: implementation_imports
import 'package:file_selector_ios/src/messages.g.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ui/file_types.dart';

class _PickerHost extends FileSelectorApi {
  List<String>? utis;

  @override
  Future<List<String>> openFile(FileSelectorConfig config) async {
    utis = config.utis;
    return [];
  }
}

void main() {
  // On iPhone, a filter with extensions alone threw before the picker opened,
  // so 导入音频, 导入文字 and 补配原音频 silently did nothing.
  for (final (name, group, uti) in [
    ('audio', audioFileTypes, 'public.audio'),
    ('minutes text', minutesTextFileTypes, 'public.plain-text'),
  ]) {
    test('the iOS picker opens with the $name filter', () async {
      final host = _PickerHost();
      final picked = await FileSelectorIOS(
        api: host,
      ).openFile(acceptedTypeGroups: [group]);

      expect(picked, isNull);
      expect(host.utis, contains(uti));
    });
  }
}
