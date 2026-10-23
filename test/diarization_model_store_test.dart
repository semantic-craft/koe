import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:provider/provider.dart';

String _sha256Hex(List<int> bytes) {
  final digest = SHA256Digest();
  final data = Uint8List.fromList(bytes);
  digest.update(data, 0, data.length);
  final out = Uint8List(digest.digestSize);
  digest.doFinal(out, 0);
  return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('koe-diar-models-');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  for (final staleWifi in [true, false]) {
    for (final immediateResume in [false, true]) {
      test(
        'pause then resume ignores stale Wi-Fi result $staleWifi (immediate=$immediateResume)',
        () async {
          final errors = <Object>[];
          final finished = Completer<void>();
          runZonedGuarded(
            () async {
              try {
                final oldCheck = Completer<bool>();
                final checkEntered = Completer<void>();
                final resumed = Completer<void>();
                final oldResponse = StreamController<List<int>>();
                final newResponse = StreamController<List<int>>();
                var holdNextCheck = false;
                var requests = 0;
                final good = utf8.encode('new valid model');
                final spec = DiarizationModelFileSpec(
                  id: 'seg',
                  fileName: 'model.onnx',
                  expectedBytes: good.length,
                  sha256: _sha256Hex(good),
                  modelScopeUrl: 'https://modelscope.cn/model',
                  huggingFaceUrl: 'https://huggingface.co/model',
                );
                final store = DiarizationModelStore(
                  directory: tempDir,
                  customSpecs: [spec],
                  isWifiConnected: () async {
                    if (holdNextCheck) {
                      holdNextCheck = false;
                      checkEntered.complete();
                      return oldCheck.future;
                    }
                    return true;
                  },
                  client: _FakeStreamingClient((_) async {
                    requests++;
                    if (requests == 1) {
                      // onListen precedes the data event, so the blocked check belongs
                      // to the old chunk, not a request or periodic network check.
                      oldResponse.onListen = () {
                        holdNextCheck = true;
                        oldResponse.add(utf8.encode('stale bytes'));
                      };
                      return http.StreamedResponse(oldResponse.stream, 200);
                    }
                    newResponse.onListen = () => resumed.complete();
                    return http.StreamedResponse(
                      newResponse.stream,
                      200,
                      contentLength: good.length,
                    );
                  }),
                );
                try {
                  final first = store.download();
                  await checkEntered.future.timeout(const Duration(seconds: 3));
                  final pausing = store.pause();
                  final Future<bool> second;
                  if (immediateResume) {
                    second = store.download();
                  } else {
                    await pausing;
                    second = store.download();
                  }
                  await pausing;
                  expect(await first, isFalse);
                  await resumed.future.timeout(const Duration(seconds: 3));
                  expect(store.status, DiarizationModelStatus.downloading);
                  oldCheck.complete(staleWifi);
                  // Drain the old async callback before delivering the new bytes.
                  await pumpEventQueue();
                  expect(store.status, DiarizationModelStatus.downloading);
                  newResponse.add(good);
                  await newResponse.close();
                  expect(
                    await second.timeout(const Duration(seconds: 3)),
                    isTrue,
                  );
                  expect(store.status, DiarizationModelStatus.ready);
                  expect(store.errorMessage, isNull);
                  expect(requests, 2);
                  final bytes = await File(
                    '${tempDir.path}/model.onnx',
                  ).readAsBytes();
                  expect(bytes, good);
                  expect(_sha256Hex(bytes), spec.sha256);
                } finally {
                  store.dispose();
                  unawaited(oldResponse.close());
                }
              } catch (error) {
                errors.add(error);
              } finally {
                finished.complete();
              }
            },
            (error, stack) {
              errors.add(error);
            },
          );
          await finished.future.timeout(const Duration(seconds: 5));
          expect(
            errors,
            isEmpty,
            reason: 'stale callback must not escape its zone',
          );
        },
      );
    }
  }

  test(
    'default checksum rejects corrupt cache and falls back on corrupt download',
    () async {
      final spec = DiarizationModelFileSpec(
        id: 'seg',
        fileName: 'model.onnx',
        expectedBytes: 4,
        sha256: _sha256Hex(utf8.encode('good')),
        modelScopeUrl: 'https://modelscope.cn/model',
        huggingFaceUrl: 'https://huggingface.co/model',
      );
      final file = File('${tempDir.path}/model.onnx');
      await file.writeAsString('bad!');
      final requests = <String>[];
      final store = DiarizationModelStore(
        directory: tempDir,
        customSpecs: [spec],
        isWifiConnected: () async => true,
        client: _FakeStreamingClient((request) async {
          requests.add(request.url.host);
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                request.url.host == 'modelscope.cn' ? 'bad!' : 'good',
              ),
            ),
            200,
          );
        }),
      );
      addTearDown(store.dispose);
      await store.refreshStatus();
      expect(store.isReady, isFalse);
      expect(await store.download(), isTrue);
      expect(requests, ['modelscope.cn', 'huggingface.co']);
      expect(await file.readAsString(), 'good');
      await file.writeAsString('bad!');
      requests.clear();
      await store.ensureReady();
      expect(requests, ['modelscope.cn', 'huggingface.co']);
      expect(await file.readAsString(), 'good');
    },
  );

  test('Wi-Fi loss after first model prevents every later request', () async {
    var wifi = true;
    final requested = <Uri>[];
    final store = DiarizationModelStore(
      directory: tempDir,
      verifyChecksum: false,
      isWifiConnected: () async => wifi,
      client: _FakeStreamingClient((request) async {
        requested.add(request.url);
        return http.StreamedResponse(Stream.value([1, 2, 3]), 200);
      }),
    );
    addTearDown(store.dispose);
    store.addListener(() {
      if (store.progress == 0.5) wifi = false;
    });
    expect(await store.download(), isFalse);
    expect(requested, hasLength(1));
    expect(store.status, DiarizationModelStatus.wifiRequired);
  });

  test(
    'Wi-Fi loss stops an idle response and resume waits for Wi-Fi',
    () async {
      var wifi = true;
      final received = Completer<void>();
      final response = StreamController<List<int>>();
      var requests = 0;
      final store = DiarizationModelStore(
        directory: tempDir,
        verifyChecksum: false,
        isWifiConnected: () async => wifi,
        client: _FakeStreamingClient((request) async {
          requests++;
          return http.StreamedResponse(
            response.stream,
            200,
            contentLength: 100,
          );
        }),
      );
      addTearDown(store.dispose);
      store.addListener(() {
        if (store.progress > 0 && !received.isCompleted) received.complete();
      });
      final task = store.download();
      response.add([1]);
      await received.future;
      wifi = false;
      expect(await task.timeout(const Duration(seconds: 3)), isFalse);
      expect(store.status, DiarizationModelStatus.wifiRequired);
      expect(await store.download(), isFalse);
      expect(requests, 1);
      await response.close();
    },
  );

  test(
    '(1) 源顺序 ModelScope → HuggingFace：ModelScope 成功时不请求 HuggingFace；第一源失败时才回退第二源',
    () async {
      final segBytes = utf8.encode('fake-pyannote-segmentation-onnx-bytes');
      final embBytes = utf8.encode('fake-3dspeaker-campplus-embedding-bytes');
      final requestedUrls = <Uri>[];
      var failModelScopeSeg = false;

      final client = _FakeStreamingClient((request) async {
        requestedUrls.add(request.url);
        final url = request.url.toString();
        if (url == DiarizationModelStore.segmentationSpec.modelScopeUrl) {
          if (failModelScopeSeg) {
            return http.StreamedResponse(
              Stream.value(utf8.encode('bad gateway')),
              502,
            );
          }
          return http.StreamedResponse(
            Stream.value(segBytes),
            200,
            contentLength: segBytes.length,
          );
        }
        if (url == DiarizationModelStore.segmentationSpec.huggingFaceUrl) {
          return http.StreamedResponse(
            Stream.value(segBytes),
            200,
            contentLength: segBytes.length,
          );
        }
        if (url == DiarizationModelStore.embeddingSpec.modelScopeUrl) {
          return http.StreamedResponse(
            Stream.value(embBytes),
            200,
            contentLength: embBytes.length,
          );
        }
        if (url == DiarizationModelStore.embeddingSpec.huggingFaceUrl) {
          return http.StreamedResponse(
            Stream.value(embBytes),
            200,
            contentLength: embBytes.length,
          );
        }
        return http.StreamedResponse(const Stream.empty(), 404);
      });

      // 子场景 A：ModelScope 正常返回时只请求 ModelScope，不请求 HuggingFace
      final dirA = Directory('${tempDir.path}/a');
      final storeA = DiarizationModelStore(
        directory: dirA,
        client: client,
        isWifiConnected: () async => true,
        verifyChecksum: false,
      );
      addTearDown(storeA.dispose);

      final okA = await storeA.download();
      expect(okA, isTrue);
      expect(storeA.status, DiarizationModelStatus.ready);
      expect(storeA.progress, 1.0);
      expect(requestedUrls.map((u) => u.host).toList(), [
        'modelscope.cn',
        'modelscope.cn',
      ]);
      expect(
        requestedUrls.any((u) => u.host.contains('huggingface.co')),
        isFalse,
      );

      // 子场景 B：第一源（ModelScope）失败时自动回退第二源（HuggingFace）
      requestedUrls.clear();
      failModelScopeSeg = true;
      final dirB = Directory('${tempDir.path}/b');
      final storeB = DiarizationModelStore(
        directory: dirB,
        client: client,
        isWifiConnected: () async => true,
        verifyChecksum: false,
      );
      addTearDown(storeB.dispose);

      final paths = await storeB.ensureReady();
      expect(storeB.status, DiarizationModelStatus.ready);
      expect(File(paths.segmentationModelPath).readAsBytesSync(), segBytes);
      expect(File(paths.embeddingModelPath).readAsBytesSync(), embBytes);
      expect(requestedUrls.map((u) => u.toString()).toList(), [
        DiarizationModelStore.segmentationSpec.modelScopeUrl,
        DiarizationModelStore.segmentationSpec.huggingFaceUrl,
        DiarizationModelStore.embeddingSpec.modelScopeUrl,
      ]);
    },
  );

  test('(2) 非 Wi-Fi 时不发起任何下载请求；已安装模型在非 Wi-Fi 下仍可直接就绪使用', () async {
    final requestedUrls = <Uri>[];
    final segBytes = utf8.encode('seg-bytes');
    final embBytes = utf8.encode('emb-bytes');
    var wifiOn = false;

    final client = _FakeStreamingClient((request) async {
      requestedUrls.add(request.url);
      final url = request.url.toString();
      final payload = url.contains('segmentation') ? segBytes : embBytes;
      return http.StreamedResponse(
        Stream.value(payload),
        200,
        contentLength: payload.length,
      );
    });

    final store = DiarizationModelStore(
      directory: tempDir,
      client: client,
      isWifiConnected: () async => wifiOn,
      verifyChecksum: false,
    );
    addTearDown(store.dispose);

    final ok = await store.download();
    expect(ok, isFalse);
    expect(store.status, DiarizationModelStatus.wifiRequired);
    expect(store.errorMessage, contains('Wi-Fi'));
    expect(requestedUrls, isEmpty, reason: '非 Wi-Fi 下不得发出任何 HTTP 请求');

    await expectLater(
      store.ensureReady(),
      throwsA(isA<DiarizationWifiRequiredException>()),
    );
    expect(requestedUrls, isEmpty);

    // 连上 Wi-Fi 后下载完成
    wifiOn = true;
    expect(await store.download(), isTrue);
    expect(store.status, DiarizationModelStatus.ready);
    expect(requestedUrls, hasLength(2));

    // 断开 Wi-Fi 后，已落盘模型可直接离线使用，不发任何请求
    requestedUrls.clear();
    wifiOn = false;
    final paths = await store.ensureReady();
    expect(File(paths.segmentationModelPath).existsSync(), isTrue);
    expect(File(paths.embeddingModelPath).existsSync(), isTrue);
    expect(requestedUrls, isEmpty);
  });

  test('(3) 下载中途可暂停、继续与删除', () async {
    final chunk1 = utf8.encode('part-one-');
    final chunk2 = utf8.encode('part-two');
    final fullSeg = Uint8List.fromList([...chunk1, ...chunk2]);
    final fullEmb = Uint8List.fromList(utf8.encode('embedding-full-bytes'));
    final segController = StreamController<List<int>>();
    final firstChunkReceived = Completer<void>();
    var segRequestCount = 0;

    final client = _FakeStreamingClient((request) async {
      final url = request.url.toString();
      if (url == DiarizationModelStore.segmentationSpec.modelScopeUrl) {
        segRequestCount++;
        if (segRequestCount == 1) {
          return http.StreamedResponse(
            segController.stream,
            200,
            contentLength: fullSeg.length,
          );
        }
        return http.StreamedResponse(
          Stream.value(fullSeg),
          200,
          contentLength: fullSeg.length,
        );
      }
      return http.StreamedResponse(
        Stream.value(fullEmb),
        200,
        contentLength: fullEmb.length,
      );
    });

    final store = DiarizationModelStore(
      directory: tempDir,
      client: client,
      isWifiConnected: () async => true,
      verifyChecksum: false,
    );
    addTearDown(store.dispose);

    store.addListener(() {
      if (store.status == DiarizationModelStatus.downloading &&
          store.progress > 0 &&
          !firstChunkReceived.isCompleted) {
        firstChunkReceived.complete();
      }
    });

    final downloadFuture = store.download();
    segController.add(chunk1);
    await firstChunkReceived.future;
    expect(store.status, DiarizationModelStatus.downloading);
    expect(store.progress, greaterThan(0));

    // 暂停下载
    await store.pause();
    expect(await downloadFuture, isFalse);
    expect(store.status, DiarizationModelStatus.paused);
    await segController.close();

    // 继续下载完成
    expect(await store.download(), isTrue);
    expect(store.status, DiarizationModelStatus.ready);
    expect(store.progress, 1.0);

    // 删除后状态回到未安装，文件清空
    await store.delete();
    expect(store.status, DiarizationModelStatus.notInstalled);
    expect(store.progress, 0.0);
    expect(
      File(
        '${tempDir.path}/${DiarizationModelStore.segmentationSpec.fileName}',
      ).existsSync(),
      isFalse,
    );
    expect(
      File(
        '${tempDir.path}/${DiarizationModelStore.embeddingSpec.fileName}',
      ).existsSync(),
      isFalse,
    );
  });

  group('下载控制', () {
    final model = utf8.encode('12345678');
    final spec = DiarizationModelFileSpec(
      id: 'seg',
      fileName: 'model.onnx',
      expectedBytes: model.length,
      sha256: _sha256Hex(model),
      modelScopeUrl: 'https://modelscope.cn/model',
      huggingFaceUrl: 'https://huggingface.co/model',
    );

    test('用户暂停后，区分发言人不会自己重新开始下载，重开应用也一样', () async {
      final firstBody = StreamController<List<int>>();
      var requests = 0;
      DiarizationModelStore open() => DiarizationModelStore(
        directory: tempDir,
        customSpecs: [spec],
        isWifiConnected: () async => true,
        client: _FakeStreamingClient((_) async {
          requests++;
          return http.StreamedResponse(
            requests == 1 ? firstBody.stream : Stream.value(model),
            200,
            contentLength: model.length,
          );
        }),
      );
      final store = open();
      addTearDown(store.dispose);
      final download = store.download();
      firstBody.add(model.sublist(0, 4));
      for (var i = 0; i < 300 && store.progress == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await store.pause();
      expect(await download, isFalse);
      await firstBody.close();
      final pausedError = throwsA(
        isA<Exception>().having((e) => '$e', 'message', contains('暂停')),
      );

      await expectLater(store.ensureReady(), pausedError);
      expect(requests, 1);
      expect(store.status, DiarizationModelStatus.paused);

      final reopened = open();
      addTearDown(reopened.dispose);
      await reopened.refreshStatus();
      expect(reopened.status, DiarizationModelStatus.paused);
      await expectLater(reopened.ensureReady(), pausedError);
      expect(requests, 1);

      expect(await reopened.download(), isTrue);
      expect(requests, 2);
      expect(
        (await reopened.ensureReady()).segmentationModelPath,
        endsWith('model.onnx'),
      );
    });

    test('连不上或数据停住时，过一会儿就算下载失败，不会一直停在下载中', () async {
      final stalled = StreamController<List<int>>();
      addTearDown(stalled.close);
      final store = DiarizationModelStore(
        directory: tempDir,
        customSpecs: [spec],
        isWifiConnected: () async => true,
        stallTimeout: const Duration(milliseconds: 200),
        client: _FakeStreamingClient((request) {
          if (request.url.host == 'modelscope.cn') {
            return Future.value(
              http.StreamedResponse(stalled.stream, 200, contentLength: 8),
            );
          }
          return Completer<http.StreamedResponse>().future;
        }),
      );
      addTearDown(store.dispose);

      expect(await store.download(), isFalse);
      expect(store.status, DiarizationModelStatus.failed);
      expect(store.errorMessage, isNotNull);
    });
  });

  testWidgets('(4) 设置页模型管理入口：支持点击下载、暂停、继续下载与删除模型', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final segController = StreamController<List<int>>();
      final firstChunkReady = Completer<void>();
      var requestCount = 0;

      final client = _FakeStreamingClient((request) async {
        requestCount++;
        if (requestCount == 1) {
          return http.StreamedResponse(
            segController.stream,
            200,
            contentLength: 100,
          );
        }
        return http.StreamedResponse(
          Stream.value(utf8.encode('model-bytes')),
          200,
          contentLength: 11,
        );
      });

      final modelStore = DiarizationModelStore(
        directory: Directory('${tempDir.path}/ui-models'),
        client: client,
        isWifiConnected: () async => true,
        verifyChecksum: false,
      );
      modelStore.addListener(() {
        if (modelStore.isDownloading &&
            modelStore.progress > 0 &&
            !firstChunkReady.isCompleted) {
          firstChunkReady.complete();
        }
      });

      final controller = RecorderController(
        loadPersistedState: false,
        diarizationModelStore: modelStore,
        transcriptPersister: ({bool strict = false}) async {},
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('settings-diarization-model')),
        findsOneWidget,
      );
      final downloadBtn = find.byKey(
        const ValueKey('diarization-model-download'),
      );
      await tester.ensureVisible(downloadBtn);
      await tester.pump();
      await tester.tap(downloadBtn);
      segController.add(utf8.encode('half-chunk'));
      await firstChunkReady.future;
      await tester.pump();

      expect(
        find.byKey(const ValueKey('diarization-model-pause')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('diarization-model-pause')));
      for (var i = 0; i < 50 && !modelStore.isPaused; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await segController.close();
      await tester.pump();

      expect(modelStore.status, DiarizationModelStatus.paused);
      expect(
        find.byKey(const ValueKey('diarization-model-resume')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('diarization-model-resume')));
      for (var i = 0; i < 50 && !modelStore.isReady; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await tester.pump();
      expect(modelStore.status, DiarizationModelStatus.ready);
      expect(find.text('删除模型'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('diarization-model-delete')));
      for (
        var i = 0;
        i < 50 && modelStore.status != DiarizationModelStatus.notInstalled;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await tester.pump();
      expect(modelStore.status, DiarizationModelStatus.notInstalled);
      expect(
        find.byKey(const ValueKey('diarization-model-download')),
        findsOneWidget,
      );
    });
  });
}

class _FakeStreamingClient extends http.BaseClient {
  _FakeStreamingClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _handler(request);
}
