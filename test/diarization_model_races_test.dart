import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/diarization_model_store.dart';

const _spec = DiarizationModelFileSpec(
  id: 'one',
  fileName: 'model.onnx',
  expectedBytes: 4,
  sha256: '770e607624d689265ca6c44884d0807d9b054d23c473c106c72be9de08b7376c',
  modelScopeUrl: 'https://example.com/model',
  huggingFaceUrl: 'https://example.com/model',
);

class _HeldLengthFile implements File {
  _HeldLengthFile(this.file, this.entered, this.release);
  final File file;
  final Completer<void> entered;
  final Completer<void> release;

  @override
  Future<bool> exists() => file.exists();
  @override
  Future<int> length() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return file.length();
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HeldRenameFile implements File {
  _HeldRenameFile(this.file, this.entered, this.release);
  final File file;
  final Completer<void> entered;
  final Completer<void> release;

  @override
  Future<bool> exists() => file.exists();
  @override
  Future<File> rename(String path) async {
    // Only the first move waits. A duplicate resolver can move its source
    // first, exposing the race as a real filesystem failure.
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return file.rename(path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(
    () async => dir = await Directory.systemTemp.createTemp('koe-model-races-'),
  );
  tearDown(() => dir.delete(recursive: true));

  test(
    'deleting between model existence and length does not fail stale refresh',
    () async {
      final file = File('${dir.path}/model.onnx')..writeAsStringSync('good');
      final entered = Completer<void>();
      final release = Completer<void>();
      final store = DiarizationModelStore(directory: dir, customSpecs: [_spec]);
      addTearDown(store.dispose);
      final files = {
        file.path: _HeldLengthFile(file, entered, release),
        '${dir.path}/download.paused': File('${dir.path}/download.paused'),
        '${dir.path}/model.onnx.part': File('${dir.path}/model.onnx.part'),
      };
      await IOOverrides.runZoned(() async {
        final refresh = store.refreshStatus();
        final checked = expectLater(refresh, completes);
        await entered.future;
        await store.delete();
        release.complete();
        await checked;
        expect(store.status, DiarizationModelStatus.notInstalled);
        expect(await file.exists(), isFalse);
      }, createFile: (path) => files[path]!);
    },
  );

  test(
    'concurrent iOS model checks share migration and later deletion stays deleted',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final support = Directory('${dir.path}/support');
      final documents = Directory('${dir.path}/documents');
      final legacy = Directory(
        '${documents.path}/AnkerRecorder/diarization_models',
      );
      await legacy.create(recursive: true);
      final old = File('${legacy.path}/model.onnx')..writeAsStringSync('good');
      final target = '${support.path}/AnkerRecorder/diarization_models';
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => call.method == 'getApplicationSupportDirectory'
            ? support.path
            : documents.path,
      );
      const storage = MethodChannel('com.semanticcraft.koe/model_storage');
      messenger.setMockMethodCallHandler(storage, (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(storage, null));
      final entered = Completer<void>();
      final release = Completer<void>();
      final store = DiarizationModelStore(customSpecs: [_spec]);
      addTearDown(store.dispose);
      final files = <String, File>{
        for (final base in [legacy.path, target])
          for (final name in [
            'model.onnx',
            'model.onnx.part',
            'download.paused',
          ])
            '$base/$name': File('$base/$name'),
        old.path: _HeldRenameFile(old, entered, release),
      };
      await IOOverrides.runZoned(() async {
        final refresh = store.refreshStatus();
        final checkedRefresh = expectLater(refresh, completes);
        await entered.future;
        final secondRefresh = store.refreshStatus();
        final checkedSecond = expectLater(secondRefresh, completes);
        final timer = Timer(
          const Duration(milliseconds: 100),
          release.complete,
        );
        addTearDown(timer.cancel);
        await Future.wait([checkedRefresh, checkedSecond]);
        expect(store.status, DiarizationModelStatus.ready);
        await store.delete();
        await store.refreshStatus();
        expect(store.status, DiarizationModelStatus.notInstalled);
        expect(await files['$target/model.onnx']!.exists(), isFalse);
        expect(await old.exists(), isFalse);
      }, createFile: (path) => files[path]!);
    },
  );
}
