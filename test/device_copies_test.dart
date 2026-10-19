import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ble/ble_file_pull.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/state/device_copies.dart';

class _Context implements DeviceCopyContext {
  final Map<int, String> paths = {};
  final Set<int> dismissed = {};
  final Set<int> locked = {};
  @override
  int recorderStatus = 0;
  @override
  int? currentRecordingFileId;

  @override
  String? localPathFor(int fileId) => paths[fileId];
  @override
  bool isDismissed(int fileId) => dismissed.contains(fileId);
  @override
  bool isAudioLocked(int? fileId, String? path) => locked.contains(fileId);
}

void main() {
  late Directory dir;
  late _Context context;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('device-copies-');
    context = _Context();
  });
  tearDown(() => dir.delete(recursive: true));

  DeviceCopies open() => DeviceCopies(directory: dir)..bind(context);
  OfflineFileEntry listed(int id, int size) =>
      OfflineFileEntry(fileId: id, sizeBytes: size);

  test('a partial retrieval stays partial after a restart until a complete '
      'one replaces it', () async {
    context.paths[7] = '${dir.path}/7.wav';
    final first = open();
    await first.recordRetrieval(7, complete: false);
    await first.flush();

    final restarted = open();
    await restarted.load();
    expect(restarted.statusOf(listed(7, 100)), DeviceCopyStatus.partial);
    expect(restarted.usableForProcessing(fileId: 7), isFalse);

    await restarted.recordRetrieval(7, complete: true, listedBytes: 100);
    expect(restarted.statusOf(listed(7, 100)), DeviceCopyStatus.downloaded);
    expect(restarted.usableForProcessing(fileId: 7), isTrue);
  });

  test('a device file that grew after retrieval must be retrieved again, '
      'also after a restart (#92)', () async {
    context.paths[8] = '${dir.path}/8.wav';
    final first = open();
    await first.recordRetrieval(8, complete: true, listedBytes: 2000);
    await first.flush();

    final restarted = open();
    await restarted.load();
    expect(restarted.statusOf(listed(8, 3500)), DeviceCopyStatus.outgrown);
    expect(restarted.statusOf(listed(8, 2000)), DeviceCopyStatus.downloaded);
  });

  test('a file the recorder answered as unfinished is unfinished until the '
      'recorder stops (#253)', () async {
    final copies = open()..noteUnfinished(9);
    context.recorderStatus = 2;
    expect(copies.statusOf(listed(9, 160)), DeviceCopyStatus.unfinished);
    expect(
      copies.statusOf(listed(10, BleFilePull.unfinishedFileSize)),
      DeviceCopyStatus.unfinished,
    );

    copies.recorderStopped();
    context.recorderStatus = 0;
    expect(copies.statusOf(listed(9, 160)), DeviceCopyStatus.none);
  });

  test('copies from before sizes were recorded get a baseline once: a short '
      'one becomes partial, a full one downloaded', () async {
    final short = File('${dir.path}/11.wav')
      ..writeAsBytesSync(List.filled(90, 0));
    final full = File('${dir.path}/12.wav')
      ..writeAsBytesSync(List.filled(96, 0));
    context.paths[11] = short.path;
    context.paths[12] = full.path;
    final copies = open();

    expect(await copies.reconcile([listed(11, 100), listed(12, 100)]), isTrue);
    expect(copies.statusOf(listed(11, 100)), DeviceCopyStatus.partial);
    expect(copies.statusOf(listed(12, 100)), DeviceCopyStatus.downloaded);
    // The baseline now decides; a later listing that grew is outgrown.
    expect(copies.statusOf(listed(12, 150)), DeviceCopyStatus.outgrown);
  });

  test('a trashed copy is dismissed, not retrieved again', () {
    context.dismissed.add(13);
    expect(open().statusOf(listed(13, 100)), DeviceCopyStatus.dismissed);
  });

  test(
    'a copy being retrieved is not usable until the transfer ends',
    () async {
      final copies = open();
      final transfer = Completer<void>();
      final running = copies.retrieving(14, () => transfer.future);
      expect(copies.usableForProcessing(fileId: 14), isFalse);
      transfer.complete();
      await running;
      expect(copies.usableForProcessing(fileId: 14), isTrue);
    },
  );
}
