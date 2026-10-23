import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/digests/sha256.dart';

import '../platform/wifi_connectivity.dart';

enum DiarizationModelStatus {
  notInstalled,
  downloading,
  paused,
  ready,
  wifiRequired,
  failed,
}

enum ModelDownloadSource { modelScope, huggingFace }

class DiarizationModelFileSpec {
  const DiarizationModelFileSpec({
    required this.id,
    required this.fileName,
    required this.expectedBytes,
    required this.sha256,
    required this.modelScopeUrl,
    required this.huggingFaceUrl,
  });

  final String id;
  final String fileName;
  final int expectedBytes;
  final String sha256;
  final String modelScopeUrl;
  final String huggingFaceUrl;
}

class DiarizationModelPaths {
  const DiarizationModelPaths({
    required this.segmentationModelPath,
    required this.embeddingModelPath,
  });

  final String segmentationModelPath;
  final String embeddingModelPath;
}

class DiarizationWifiRequiredException implements Exception {
  const DiarizationWifiRequiredException([
    this.message = '仅在 Wi-Fi 下下载本机发言人模型（不用手机流量和个人热点），请连接 Wi-Fi 后重试',
  ]);
  final String message;

  @override
  String toString() => message;
}

/// The user paused the model download; nothing downloads it again until
/// they resume it.
class DiarizationModelPausedException implements Exception {
  const DiarizationModelPausedException([
    this.message = '本机发言人模型下载已暂停，请在设置里继续下载',
  ]);
  final String message;

  @override
  String toString() => message;
}

enum _CancelReason { none, pause, delete, wifi }

/// Manages on-demand download, pause, resume, verification, and deletion of
/// the offline speaker diarization ONNX models (ADR 0002 #7):
///
/// 1. `pyannote/segmentation-3.0` (`segmentation-model.onnx`, MIT)
/// 2. `3D-Speaker CAM++` (`3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx`, Apache-2.0)
///
/// Source priority: ModelScope first, falling back to HuggingFace only when
/// ModelScope fails. Downloads only over Wi-Fi.
class DiarizationModelStore extends ChangeNotifier {
  DiarizationModelStore({
    Directory? directory,
    http.Client? client,
    WifiCheck? isWifiConnected,
    this.verifyChecksum = true,
    List<DiarizationModelFileSpec>? customSpecs,
    this.stallTimeout = const Duration(seconds: 30),
  }) : _directoryOverride = directory,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _isWifiConnected = isWifiConnected ?? defaultIsWifiConnected,
       _specs = customSpecs ?? specs;

  static const segmentationSpec = DiarizationModelFileSpec(
    id: 'segmentation',
    fileName: 'segmentation-model.onnx',
    expectedBytes: 5992913,
    sha256: '220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079',
    modelScopeUrl:
        'https://modelscope.cn/models/pengzhendong/sherpa-onnx-pyannote-segmentation-3-0/resolve/master/model.onnx',
    huggingFaceUrl:
        'https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.onnx',
  );

  static const embeddingSpec = DiarizationModelFileSpec(
    id: 'embedding',
    fileName: '3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx',
    expectedBytes: 28281164,
    sha256: 'aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2',
    modelScopeUrl:
        'https://modelscope.cn/models/lijiu09/speaker-embedding-models/resolve/master/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx',
    huggingFaceUrl:
        'https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/main/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx',
  );

  static const List<DiarizationModelFileSpec> specs = [
    segmentationSpec,
    embeddingSpec,
  ];

  final Directory? _directoryOverride;
  final http.Client _client;
  final bool _ownsClient;
  final WifiCheck _isWifiConnected;
  final bool verifyChecksum;
  final List<DiarizationModelFileSpec> _specs;

  /// How long a source may send nothing, before or during its reply, before
  /// it counts as failed.
  final Duration stallTimeout;

  /// Kept in the model directory while the user has the download paused.
  static const _pausedMarker = 'download.paused';

  DiarizationModelStatus status = DiarizationModelStatus.notInstalled;
  double progress = 0.0;
  String? errorMessage;
  ModelDownloadSource? activeSource;

  Future<bool>? _activeDownload;
  StreamSubscription<List<int>>? _activeSubscription;
  Completer<bool>? _activeStreamCompleter;
  Completer<void>? _activeRequestAbort;
  _CancelReason _cancelReason = _CancelReason.none;
  bool _disposed = false;
  int _requestGeneration = 0;
  Future<void>? _stopping;

  bool get isReady => status == DiarizationModelStatus.ready;
  bool get isDownloading => status == DiarizationModelStatus.downloading;
  bool get isPaused => status == DiarizationModelStatus.paused;

  Future<Directory> _resolveDirectory() async {
    final override = _directoryOverride;
    if (override != null) {
      if (!await override.exists()) await override.create(recursive: true);
      return override;
    }
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    final dir = Directory(
      p.join(base.path, 'AnkerRecorder', 'diarization_models'),
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<bool> _isSpecInstalled(
    Directory dir,
    DiarizationModelFileSpec spec,
  ) async {
    final file = File(p.join(dir.path, spec.fileName));
    if (!await file.exists()) return false;
    final length = await file.length();
    if (length <= 0) return false;
    if (verifyChecksum) {
      final actual = await _fileSha256(file);
      if (actual != spec.sha256.toLowerCase()) return false;
    }
    return true;
  }

  Future<String> _fileSha256(File file) async {
    final digest = SHA256Digest();
    await for (final chunk in file.openRead()) {
      final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      digest.update(bytes, 0, bytes.length);
    }
    final out = Uint8List(digest.digestSize);
    digest.doFinal(out, 0);
    return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> refreshStatus() async {
    if (_activeDownload != null) return;
    final dir = await _resolveDirectory();
    var installedCount = 0;
    var hasPart = false;
    for (final spec in _specs) {
      if (await _isSpecInstalled(dir, spec)) {
        installedCount++;
      } else if (await File(
        p.join(dir.path, '${spec.fileName}.part'),
      ).exists()) {
        hasPart = true;
      }
    }
    if (installedCount == _specs.length) {
      status = DiarizationModelStatus.ready;
      progress = 1.0;
      errorMessage = null;
    } else if (hasPart ||
        status == DiarizationModelStatus.paused ||
        await _pausedFile(dir).exists()) {
      status = DiarizationModelStatus.paused;
    } else {
      status = DiarizationModelStatus.notInstalled;
      progress = 0.0;
    }
    _notify();
  }

  Future<DiarizationModelPaths> ensureReady() async {
    final dir = await _resolveDirectory();
    var allInstalled = true;
    for (final spec in _specs) {
      if (!await _isSpecInstalled(dir, spec)) {
        allInstalled = false;
        break;
      }
    }
    if (allInstalled) {
      status = DiarizationModelStatus.ready;
      progress = 1.0;
      errorMessage = null;
      _notify();
      return DiarizationModelPaths(
        segmentationModelPath: p.join(dir.path, _specs.first.fileName),
        embeddingModelPath: p.join(dir.path, _specs.last.fileName),
      );
    }
    if (await _pausedFile(dir).exists()) {
      throw const DiarizationModelPausedException();
    }

    final ok = await download();
    if (!ok) {
      if (status == DiarizationModelStatus.wifiRequired) {
        throw const DiarizationWifiRequiredException();
      }
      throw StateError(errorMessage ?? '本机发言人模型下载未完成');
    }
    return DiarizationModelPaths(
      segmentationModelPath: p.join(dir.path, _specs.first.fileName),
      embeddingModelPath: p.join(dir.path, _specs.last.fileName),
    );
  }

  Future<bool> download() {
    if (_disposed) return Future.value(false);
    final stopping = _stopping;
    if (stopping != null) return stopping.then((_) => download());
    final running = _activeDownload;
    if (running != null) return running;
    final task = _runDownload();
    _activeDownload = task;
    return task.whenComplete(() {
      if (identical(_activeDownload, task)) {
        _activeDownload = null;
      }
    });
  }

  Future<bool> _runDownload() async {
    _cancelReason = _CancelReason.none;
    final dir = await _resolveDirectory();
    await _setPaused(dir, false);
    var allInstalled = true;
    for (final spec in _specs) {
      if (!await _isSpecInstalled(dir, spec)) {
        allInstalled = false;
        break;
      }
    }
    if (_cancelReason != _CancelReason.none || _disposed) return false;
    if (allInstalled) {
      status = DiarizationModelStatus.ready;
      progress = 1.0;
      errorMessage = null;
      _notify();
      return true;
    }

    final wifi = await _wifiAvailable();
    if (_cancelReason != _CancelReason.none || _disposed) return false;
    if (!wifi) {
      status = DiarizationModelStatus.wifiRequired;
      errorMessage = const DiarizationWifiRequiredException().message;
      _notify();
      return false;
    }

    status = DiarizationModelStatus.downloading;
    errorMessage = null;
    _notify();

    for (var i = 0; i < _specs.length; i++) {
      final spec = _specs[i];
      if (_cancelReason != _CancelReason.none || _disposed) break;
      final installed = await _isSpecInstalled(dir, spec);
      if (_cancelReason != _CancelReason.none || _disposed) break;
      if (installed) {
        progress = (i + 1) / _specs.length;
        _notify();
        continue;
      }
      final baseProgress = i / _specs.length;
      final weight = 1.0 / _specs.length;
      final downloaded = await _downloadSpecWithFallback(
        dir,
        spec,
        onSpecProgress: (specFraction) {
          progress = (baseProgress + specFraction * weight).clamp(0.0, 0.999);
          _notify();
        },
      );
      if (!downloaded) {
        activeSource = null;
        if (_cancelReason == _CancelReason.pause) {
          status = DiarizationModelStatus.paused;
          errorMessage = null;
        } else if (_cancelReason == _CancelReason.delete) {
          status = DiarizationModelStatus.notInstalled;
          progress = 0.0;
          errorMessage = null;
        } else if (_cancelReason == _CancelReason.wifi) {
          status = DiarizationModelStatus.wifiRequired;
          errorMessage = const DiarizationWifiRequiredException().message;
        } else {
          status = DiarizationModelStatus.failed;
          errorMessage ??= '本机发言人模型下载失败，请检查网络后重试';
        }
        _notify();
        return false;
      }
      progress = (i + 1) / _specs.length;
      _notify();
    }

    if (_cancelReason == _CancelReason.wifi) {
      activeSource = null;
      status = DiarizationModelStatus.wifiRequired;
      errorMessage = const DiarizationWifiRequiredException().message;
      _notify();
      return false;
    }
    if (_cancelReason == _CancelReason.pause) {
      activeSource = null;
      status = DiarizationModelStatus.paused;
      _notify();
      return false;
    }
    if (_cancelReason == _CancelReason.delete) {
      activeSource = null;
      status = DiarizationModelStatus.notInstalled;
      progress = 0.0;
      _notify();
      return false;
    }

    if (_disposed) return false;
    activeSource = null;
    status = DiarizationModelStatus.ready;
    progress = 1.0;
    errorMessage = null;
    _notify();
    return true;
  }

  Future<bool> _downloadSpecWithFallback(
    Directory dir,
    DiarizationModelFileSpec spec, {
    required void Function(double fraction) onSpecProgress,
  }) async {
    final sources = <(ModelDownloadSource, String)>[
      (ModelDownloadSource.modelScope, spec.modelScopeUrl),
      (ModelDownloadSource.huggingFace, spec.huggingFaceUrl),
    ];
    for (final (source, url) in sources) {
      if (_cancelReason != _CancelReason.none || _disposed) return false;
      activeSource = source;
      _notify();
      final ok = await _downloadFromUrl(
        dir: dir,
        spec: spec,
        url: url,
        onSpecProgress: onSpecProgress,
      );
      if (ok) return true;
      if (_cancelReason != _CancelReason.none || _disposed) return false;
    }
    return false;
  }

  Future<bool> _downloadFromUrl({
    required Directory dir,
    required DiarizationModelFileSpec spec,
    required String url,
    required void Function(double fraction) onSpecProgress,
  }) async {
    final generation = ++_requestGeneration;
    bool isCurrent() => generation == _requestGeneration && !_disposed;
    final partFile = File(p.join(dir.path, '${spec.fileName}.part'));
    final targetFile = File(p.join(dir.path, spec.fileName));
    IOSink? sink;
    Timer? networkMonitor;
    StreamSubscription<List<int>>? requestSubscription;
    final abort = Completer<void>();
    _activeRequestAbort = abort;
    var monitoring = true;
    try {
      var checking = false;
      networkMonitor = Timer.periodic(const Duration(milliseconds: 250), (
        _,
      ) async {
        if (checking) return;
        checking = true;
        try {
          final wifi = await _wifiAvailable();
          if (monitoring && isCurrent() && !wifi) {
            if (_cancelReason == _CancelReason.none) {
              _cancelReason = _CancelReason.wifi;
            }
            if (!abort.isCompleted) abort.complete();
            final pending = _activeStreamCompleter;
            if (pending != null && !pending.isCompleted) {
              pending.complete(false);
            }
          }
        } finally {
          checking = false;
        }
      });
      var uri = Uri.parse(url);
      http.StreamedResponse? response;
      for (var redirects = 0; redirects <= 10; redirects++) {
        if (!await _checkWifi(generation)) return false;
        if (_cancelReason != _CancelReason.none || _disposed) return false;
        final request = http.AbortableRequest(
          'GET',
          uri,
          abortTrigger: abort.future,
        )..followRedirects = false;
        response = await _client
            .send(request)
            .timeout(
              stallTimeout,
              onTimeout: () {
                if (!abort.isCompleted) abort.complete();
                throw TimeoutException('模型下载源没有回应', stallTimeout);
              },
            );
        if (!isCurrent() || _cancelReason != _CancelReason.none) {
          await response.stream.listen(null).cancel();
          return false;
        }
        if (![301, 302, 303, 307, 308].contains(response.statusCode)) break;
        final location = response.headers['location'];
        await response.stream.listen(null).cancel();
        if (!isCurrent() || location == null || redirects == 10) return false;
        uri = uri.resolve(location);
        if (uri.scheme != 'https') return false;
      }
      if (response == null) return false;
      if (_cancelReason != _CancelReason.none || _disposed) {
        await response.stream.listen(null).cancel();
        return false;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.listen(null).cancel();
        return false;
      }
      final total = response.contentLength ?? spec.expectedBytes;
      var received = 0;
      sink = partFile.openWrite(mode: FileMode.writeOnly);
      final completer = Completer<bool>();
      _activeStreamCompleter = completer;
      late StreamSubscription<List<int>> sub;
      // A reply that stops sending fails, so another source can be tried.
      sub = response.stream
          .timeout(stallTimeout)
          .listen(
            (chunk) async {
              sub.pause();
              try {
                final wifi = await _checkWifi(generation);
                // listen does not await this callback. Cancellation can close the
                // sink while the platform Wi-Fi check is still outstanding.
                if (!isCurrent()) return;
                if (!wifi || _cancelReason != _CancelReason.none) {
                  if (!completer.isCompleted) completer.complete(false);
                  return;
                }
                sink!.add(chunk);
                received += chunk.length;
                onSpecProgress(
                  total > 0 ? (received / total).clamp(0.0, 1.0) : 0.5,
                );
                sub.resume();
              } catch (_) {
                if (isCurrent() && !completer.isCompleted) {
                  completer.complete(false);
                }
              }
            },
            onDone: () {
              if (!completer.isCompleted) {
                completer.complete(
                  _cancelReason == _CancelReason.none && !_disposed,
                );
              }
            },
            onError: (Object _) {
              if (!completer.isCompleted) completer.complete(false);
            },
            cancelOnError: true,
          );
      requestSubscription = sub;
      _activeSubscription = sub;
      final finished = await completer.future;
      // Invalidate callbacks BEFORE cancelling the subscription / closing its
      // sink, including when an async callback is waiting on a platform call.
      if (isCurrent()) _requestGeneration++;
      if (identical(_activeSubscription, sub)) {
        _activeSubscription = null;
      }
      if (identical(_activeStreamCompleter, completer)) {
        _activeStreamCompleter = null;
      }
      await sub.cancel();
      await sink.flush();
      await sink.close();
      sink = null;

      if (!finished || _cancelReason != _CancelReason.none || _disposed) {
        return false;
      }
      if (received <= 0) {
        if (await partFile.exists()) await partFile.delete();
        return false;
      }
      if (verifyChecksum) {
        final sha = await _fileSha256(partFile);
        if (sha != spec.sha256.toLowerCase()) {
          if (await partFile.exists()) await partFile.delete();
          return false;
        }
      }
      if (_cancelReason != _CancelReason.none || _disposed) return false;
      await partFile.rename(targetFile.path);
      return true;
    } catch (_) {
      if (isCurrent()) _requestGeneration++;
      await requestSubscription?.cancel();
      try {
        await sink?.close();
      } catch (_) {}
      if (_cancelReason == _CancelReason.none && await partFile.exists()) {
        try {
          await partFile.delete();
        } catch (_) {}
      }
      return false;
    } finally {
      monitoring = false;
      if (isCurrent()) _requestGeneration++;
      networkMonitor?.cancel();
      _activeSubscription = null;
      _activeStreamCompleter = null;
      await requestSubscription?.cancel();
      try {
        await sink?.close();
      } catch (_) {}
      if (identical(_activeRequestAbort, abort)) _activeRequestAbort = null;
    }
  }

  Future<bool> _wifiAvailable() async {
    try {
      return await _isWifiConnected();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _checkWifi(int generation) async {
    if (generation != _requestGeneration || _disposed) return false;
    final wifi = await _wifiAvailable();
    if (generation != _requestGeneration || _disposed) return false;
    if (!wifi && _cancelReason == _CancelReason.none) {
      _cancelReason = _CancelReason.wifi;
    }
    return wifi;
  }

  // A resume requested before pause/delete finishes must wait for cancellation
  // and sink closure, not join the cancelled download or reopen its .part file.
  Future<void> _stop(Future<void> Function() action) {
    final previous = _stopping;
    final task = previous == null ? action() : previous.then((_) => action());
    late final Future<void> completion;
    completion = task.whenComplete(() {
      if (identical(_stopping, completion)) _stopping = null;
    });
    _stopping = completion;
    return completion;
  }

  Future<void> pause() => _stop(_pause);

  Future<void> _pause() async {
    _requestGeneration++;
    _cancelReason = _CancelReason.pause;
    _abortRequest();
    final completer = _activeStreamCompleter;
    _activeStreamCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(false);
    }
    final sub = _activeSubscription;
    _activeSubscription = null;
    await sub?.cancel();
    final running = _activeDownload;
    if (running != null) {
      try {
        await running;
      } catch (_) {}
    }
    status = DiarizationModelStatus.paused;
    activeSource = null;
    _notify();
    await _setPaused(await _resolveDirectory(), true);
  }

  Future<void> delete() => _stop(_delete);

  Future<void> _delete() async {
    _requestGeneration++;
    _cancelReason = _CancelReason.delete;
    _abortRequest();
    final completer = _activeStreamCompleter;
    _activeStreamCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(false);
    }
    final sub = _activeSubscription;
    _activeSubscription = null;
    await sub?.cancel();
    final running = _activeDownload;
    if (running != null) {
      try {
        await running;
      } catch (_) {}
    }
    final dir = await _resolveDirectory();
    await _setPaused(dir, false);
    for (final spec in _specs) {
      final f = File(p.join(dir.path, spec.fileName));
      final part = File(p.join(dir.path, '${spec.fileName}.part'));
      if (await f.exists()) await f.delete();
      if (await part.exists()) await part.delete();
    }
    status = DiarizationModelStatus.notInstalled;
    progress = 0.0;
    errorMessage = null;
    activeSource = null;
    _notify();
  }

  File _pausedFile(Directory dir) => File(p.join(dir.path, _pausedMarker));

  /// Remembers across launches that the user paused the download.
  Future<void> _setPaused(Directory dir, bool paused) async {
    final marker = _pausedFile(dir);
    try {
      if (paused) {
        await marker.writeAsString('');
      } else if (await marker.exists()) {
        await marker.delete();
      }
    } on FileSystemException catch (error) {
      debugPrint('[Diarization] pause not remembered: $error');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _abortRequest() {
    final abort = _activeRequestAbort;
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  @override
  void dispose() {
    _disposed = true;
    _requestGeneration++;
    _cancelReason = _CancelReason.pause;
    _abortRequest();
    final completer = _activeStreamCompleter;
    if (completer != null && !completer.isCompleted) completer.complete(false);
    _activeSubscription?.cancel();
    if (_ownsClient) _client.close();
    super.dispose();
  }
}
