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

  test(
    '(2) 非 Wi-Fi 时不发起任何下载请求；已安装模型在非 Wi-Fi 下仍可直接就绪使用',
    () async {
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
    },
  );

  test(
    '(3) 下载中途可暂停、继续与删除，且哈希校验不匹配时拒绝落盘并回退第二源',
    () async {
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
        File('${tempDir.path}/${DiarizationModelStore.segmentationSpec.fileName}')
            .existsSync(),
        isFalse,
      );
      expect(
        File('${tempDir.path}/${DiarizationModelStore.embeddingSpec.fileName}')
            .existsSync(),
        isFalse,
      );

      // 开启哈希校验时：第一源返回损坏字节（SHA-256 不匹配），自动回退第二源通过校验
      final validSeg = utf8.encode('valid-seg-content');
      final validEmb = utf8.encode('valid-emb-content');
      final customSpecs = [
        DiarizationModelFileSpec(
          id: 'segmentation',
          fileName: 'segmentation-model.onnx',
          expectedBytes: validSeg.length,
          sha256: _sha256Hex(validSeg),
          modelScopeUrl: 'https://modelscope.cn/seg.onnx',
          huggingFaceUrl: 'https://huggingface.co/seg.onnx',
        ),
        DiarizationModelFileSpec(
          id: 'embedding',
          fileName: 'embedding-model.onnx',
          expectedBytes: validEmb.length,
          sha256: _sha256Hex(validEmb),
          modelScopeUrl: 'https://modelscope.cn/emb.onnx',
          huggingFaceUrl: 'https://huggingface.co/emb.onnx',
        ),
      ];
      final verifyClient = _FakeStreamingClient((request) async {
        final url = request.url.toString();
        if (url == 'https://modelscope.cn/seg.onnx') {
          return http.StreamedResponse(
            Stream.value(utf8.encode('corrupted-bytes!!')),
            200,
          );
        }
        if (url == 'https://huggingface.co/seg.onnx') {
          return http.StreamedResponse(Stream.value(validSeg), 200);
        }
        return http.StreamedResponse(Stream.value(validEmb), 200);
      });
      final verifiedStore = DiarizationModelStore(
        directory: Directory('${tempDir.path}/verified'),
        client: verifyClient,
        isWifiConnected: () async => true,
        verifyChecksum: true,
        customSpecs: customSpecs,
      );
      addTearDown(verifiedStore.dispose);
      expect(await verifiedStore.download(), isTrue);
      expect(verifiedStore.status, DiarizationModelStatus.ready);
    },
  );

  testWidgets(
    '(4) 设置页模型管理入口：支持点击下载、暂停、继续下载与删除模型',
    (tester) async {
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

        await tester.tap(
          find.byKey(const ValueKey('diarization-model-resume')),
        );
        for (var i = 0; i < 50 && !modelStore.isReady; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await tester.pump();
        expect(modelStore.status, DiarizationModelStatus.ready);
        expect(find.text('删除模型'), findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey('diarization-model-delete')),
        );
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
    },
  );
}

class _FakeStreamingClient extends http.BaseClient {
  _FakeStreamingClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _handler(request);
}
