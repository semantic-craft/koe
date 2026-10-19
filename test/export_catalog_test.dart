import 'package:koe/protocol/models.dart';
import 'package:koe/state/export_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('local exports are deduplicated and sorted newest first', () {
    final paths = ExportCatalog.newestPathsFirst([
      '/exports/1710000000.opus.bin',
      '/exports/1730000000.opus',
      '/exports/1710000000.opus',
      '/exports/1720000000.opus',
    ]);

    expect(paths, [
      '/exports/1730000000.opus',
      '/exports/1720000000.opus',
      '/exports/1710000000.opus',
    ]);
  });

  // #232: 录音豆录音（秒）、导入（微秒）、Mac 恢复（毫秒）、手机录音
  // （phone_ 微秒）混在一起时，资料列表按真实先后排，不按数字位数排。
  test('mixed timestamp units sort by actual time, newest first', () {
    const device = '/exports/1792377669.wav'; // 10:41
    const imported = '/imports/1792371609000000_abcdef123456_会议.m4a'; // 09:00
    const restored =
        '/imports/1792374069000_abcdef123456_restored.wav'; // 09:41
    const phone = '/phone/phone_1792380789000000.wav'; // 11:33

    expect(
      ExportCatalog.newestPathsFirst([imported, device, restored, phone]),
      [phone, device, restored, imported],
    );
  });

  test('standard WAV is preferred over raw Opus for the same recording', () {
    final result = ExportCatalog.newestPathsFirst([
      '/exports/1730000000.opus',
      '/exports/1730000000.wav',
    ]);

    expect(result, ['/exports/1730000000.wav']);
  });

  test('renamed exports retain their device file id and extension', () {
    final renamed = ExportCatalog.renamedFileName(
      '/exports/1730000000.opus.bin',
      'Customer interview',
    );

    expect(renamed, '1730000000_Customer interview.opus.bin');
    expect(ExportCatalog.isSupportedExportPath('/exports/$renamed'), isTrue);
    expect(ExportCatalog.fileIdFromPath(renamed), 1730000000);
    expect(
      ExportCatalog.editableLabelFromPath('/exports/$renamed'),
      'Customer interview',
    );
  });

  test('renamed exports reject unsafe filenames', () {
    expect(
      () => ExportCatalog.renamedFileName('/exports/173.wav', '../meeting'),
      throwsArgumentError,
    );
  });

  test('unexported device recordings are newest first', () {
    final missing = ExportCatalog.unexportedNewestFirst(
      [
        OfflineFileEntry(fileId: 100, sizeBytes: 160),
        OfflineFileEntry(fileId: 300, sizeBytes: 160),
        OfflineFileEntry(fileId: 200, sizeBytes: 160),
      ],
      {200},
    );

    expect(missing.map((file) => file.fileId), [300, 100]);
  });
}
