import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../audio/ogg_opus.dart';
import '../audio/audio_duration.dart';
import '../audio/upload_source.dart';
import 'cloud_stt_service.dart';
import 'oss_upload_request.dart';
import 'stt_types.dart';

/// DashScope Qwen-Audio 3.1 file transcription.
///
/// File adapter; realtime recognition is implemented in cloud_stt_stream.dart.
///
/// Confirmed from current Model Studio docs (Beijing and Singapore legacy
/// hosts still work; workspace domains are optional via [baseUrl]):
/// - Model: `qwen-audio-3.1-asr-flash-filetrans` (recommended long-audio
///   file model). `qwen3-asr-flash-filetrans` is a different body
///   (`input.file_url`) and is rejected here.
/// - Submit: POST `{base}/api/v1/services/audio/asr/transcription`
///   with `Authorization: Bearer`, `Content-Type: application/json`,
///   `X-DashScope-Async: enable`, and `X-DashScope-OssResourceResolve: enable`
///   when `file_urls` is `oss://`. `parameters` is required for this model
///   (an empty object is enough; this client always sends options).
/// - Poll: GET `{base}/api/v1/tasks/{task_id}` with `Authorization: Bearer`.
/// - Result: `output.results[].transcription_url` (24h JSON;
///   `transcripts[].text`, `sentences[].speaker_id` when diarization is on).
///   Task `usage.duration` is seconds.
/// - Local files: GET `{base}/api/v1/uploads?action=getPolicy&model=...`,
///   then multipart POST to `upload_host`. The URL is `oss://` + object key
///   and expires in 48 hours. Base64 audio is not supported. Temporary
///   upload is capped at 1 GB; the model itself allows 2 GB via a public URL.
///
/// https://help.aliyun.com/zh/model-studio/fun-asr-recorded-speech-recognition-http-api
/// https://help.aliyun.com/zh/model-studio/qwen-audio-3-1-asr-flash-filetrans
/// https://help.aliyun.com/zh/model-studio/non-realtime-speech-recognition-user-guide
/// https://help.aliyun.com/zh/model-studio/asr-model
/// https://help.aliyun.com/zh/model-studio/get-temporary-file-url
/// https://help.aliyun.com/zh/model-studio/manage-asynchronous-tasks
class QwenSttService extends CloudFileSttService {
  QwenSttService({
    http.Client? client,
    this.pollInterval = const Duration(seconds: 2),
    this.taskTimeout = const Duration(minutes: 15),
  }) : _client = client ?? http.Client();

  /// Scoped to the single file execution owned by RecorderController.
  QwenTaskRecovery? recovery;
  final http.Client _client;
  final Duration pollInterval;
  final Duration taskTimeout;
  Completer<void>? _abort;
  bool _cancelled = false;
  void cancelCurrent() {
    _cancelled = true;
    final abort = _abort;
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  static const defaultBaseUrl = 'https://dashscope.aliyuncs.com';
  static const intlBaseUrl = 'https://dashscope-intl.aliyuncs.com';
  static const defaultModel = 'qwen-audio-3.1-asr-flash-filetrans';
  static const incompatibleFileUrlModel = 'qwen3-asr-flash-filetrans';

  /// Temporary upload credential limit. The filetrans model allows 2 GB
  /// when the caller already has a public URL.
  static const maxUploadBytes = 1024 * 1024 * 1024;

  @override
  String get engineLabel => '通义';

  @override
  String get apiKeyEnvVar => 'DASHSCOPE_API_KEY';

  @override
  String get baseUrlEnvVar => 'DASHSCOPE_HTTP_BASE_URL';

  @override
  String get fallbackBaseUrl => defaultBaseUrl;

  @override
  String get fallbackModel => defaultModel;

  @override
  String get apiSuffix => '/api/v1';

  @override
  CloudSttException fail(String message) => QwenSttException(message);

  @override
  Future<SttResult> run(
    String path, {
    String? apiKey,
    String? baseUrl,
    String? model,
    String? language,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  }) async {
    _cancelled = false;
    _abort = Completer<void>();
    final ownerIsCurrent = isCurrent;
    isCurrent = () => !_cancelled && (ownerIsCurrent?.call() ?? true);
    final key = (apiKey ?? this.apiKey)?.trim();
    if (key == null || key.isEmpty) {
      throw const QwenSttException('请在设置中配置通义 Qwen');
    }
    final origin = resolvedBaseUrl(baseUrl);
    final resolvedModel = (model == null || model.trim().isEmpty)
        ? this.model
        : model.trim();
    if (resolvedModel == QwenSttService.incompatibleFileUrlModel) {
      throw const QwenSttException(
        'qwen3-asr-flash-filetrans 使用 input.file_url，请改用 qwen-audio-3.1-asr-flash-filetrans',
      );
    }

    final checkpoint = recovery;
    var taskId = checkpoint?.taskId;
    if (taskId == null) {
      onProgress?.call(const SttFileProgress(SttFileStage.preparing));
      _ensureCurrent(isCurrent);
      final uploadSource = await qwenUploadSource(path);
      final duration = await AudioDuration.read(uploadSource);
      validateQwenAudio(
        length: await File(uploadSource).length(),
        duration: duration,
      );
      final audioPath = await OggOpus.prepareUpload(
        uploadSource,
        isCurrent: isCurrent,
      );
      final file = File(audioPath);
      final length = await file.length();
      if (!await file.exists() || length < 64) {
        throw const QwenSttException('音频太短或无效，无法转写');
      }
      if (length > maxUploadBytes) {
        throw const QwenSttException('音频超过 1 GB，无法上传');
      }

      final filename = _uploadFilename(audioPath);
      debugPrint(
        '[Qwen] upload ${p.basename(audioPath)} ${length}B '
        'model=$resolvedModel host=${Uri.parse(origin).host}',
      );
      final ossUrl = await _upload(
        origin: origin,
        apiKey: key,
        model: resolvedModel,
        file: file,
        filename: filename,
        onProgress: onProgress,
        isCurrent: isCurrent,
      );
      _ensureCurrent(isCurrent);
      onProgress?.call(const SttFileProgress(SttFileStage.queued));
      taskId = await _submit(
        origin: origin,
        apiKey: key,
        model: resolvedModel,
        ossUrl: ossUrl,
        language: language,
      );
      await checkpoint?.onSubmitted(taskId);
    }
    final task = await _wait(
      origin: origin,
      apiKey: key,
      taskId: taskId,
      onProgress: onProgress,
      isCurrent: isCurrent,
    );
    _ensureCurrent(isCurrent);
    onProgress?.call(const SttFileProgress(SttFileStage.fetching));
    final parts = <String>[];
    final segments = <SttSegment>[];
    var timingComplete = true;
    double? durationSec;
    for (final url in task.transcriptionUrls) {
      final document = await _fetchTranscript(url);
      _ensureCurrent(isCurrent);
      final parsed = parseQwenTranscript(document);
      final text = parsed.text;
      if (text.isNotEmpty) parts.add(text);
      if (parsed.segments.isEmpty) {
        timingComplete = false;
      } else {
        segments.addAll(parsed.segments);
      }
      durationSec ??= qwenDurationSec(document);
    }
    return SttResult(
      text: normalizeSttText(parts.join('\n')),
      sourcePath: path,
      language: (language == null || language.trim().isEmpty)
          ? 'auto'
          : language.trim().toLowerCase(),
      durationSec: durationSec ?? task.durationSec,
      segments: timingComplete ? segments : const [],
    );
  }

  Future<String> _upload({
    required String origin,
    required String apiKey,
    required String model,
    required File file,
    required String filename,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  }) async {
    Future<String> once() async {
      final policy = await _policy(
        origin: origin,
        apiKey: apiKey,
        model: model,
      );
      _ensureCurrent(isCurrent);
      final maxMb = policy.maxFileSizeMb;
      if (maxMb != null && await file.length() > maxMb * 1024 * 1024) {
        throw QwenSttException('音频超过通义允许的 $maxMb MB');
      }
      return _postToOss(
        policy: policy,
        file: file,
        filename: filename,
        onProgress: onProgress,
        isCurrent: isCurrent,
      );
    }

    try {
      return await once();
    } on QwenPolicyExpired {
      _ensureCurrent(isCurrent);
      return once();
    }
  }

  Future<QwenUploadPolicy> _policy({
    required String origin,
    required String apiKey,
    required String model,
  }) async {
    final uri = Uri.parse(
      '$origin/api/v1/uploads',
    ).replace(queryParameters: {'action': 'getPolicy', 'model': model});
    final response = await _client
        .get(
          uri,
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 30));
    return parseQwenUploadPolicy(_decodeObject(response));
  }

  Future<String> _postToOss({
    required QwenUploadPolicy policy,
    required File file,
    required String filename,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  }) async {
    final key = '${policy.uploadDir}/$filename';
    final request = OssUploadRequest(
      Uri.parse(policy.uploadHost),
      abortTrigger: _abort?.future,
      fields: {
        'OSSAccessKeyId': policy.accessKeyId,
        'Signature': policy.signature,
        'policy': policy.policy,
        'x-oss-object-acl': policy.objectAcl,
        'x-oss-forbid-overwrite': policy.forbidOverwrite,
        'key': key,
        'success_action_status': '200',
      },
      file: multipartFileFromDisk(
        field: 'file',
        file: file,
        isCurrent: isCurrent,
        filename: filename,
        onProgress: (sent, total) => onProgress?.call(
          SttFileProgress(
            SttFileStage.uploading,
            uploadedBytes: sent,
            totalBytes: total,
          ),
        ),
      ),
    );
    final streamed = await _client
        .send(request)
        .timeout(const Duration(minutes: 10));
    final body = await streamed.stream.bytesToString().timeout(
      const Duration(seconds: 30),
    );
    if (streamed.statusCode == 403 && body.contains('Policy expired')) {
      throw const QwenPolicyExpired();
    }
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      debugPrint('[Qwen] OSS upload HTTP ${streamed.statusCode}');
      throw const QwenSttException('通义音频上传失败，请重试');
    }
    return 'oss://$key';
  }

  Future<String> _submit({
    required String origin,
    required String apiKey,
    required String model,
    required String ossUrl,
    String? language,
  }) async {
    final response = await _client
        .post(
          Uri.parse('$origin/api/v1/services/audio/asr/transcription'),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
            'X-DashScope-Async': 'enable',
            'X-DashScope-OssResourceResolve': 'enable',
          },
          body: jsonEncode(
            qwenTranscriptionBody(
              model: model,
              fileUrl: ossUrl,
              language: language,
            ),
          ),
        )
        .timeout(const Duration(seconds: 60));
    final json = _decodeObject(response);
    final output = json['output'];
    final taskId = output is Map ? '${output['task_id'] ?? ''}'.trim() : '';
    if (taskId.isEmpty) {
      throw const QwenSttException('通义未返回转写任务');
    }
    debugPrint('[Qwen] task $taskId');
    return taskId;
  }

  Future<QwenTaskStatus> _wait({
    required String origin,
    required String apiKey,
    required String taskId,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  }) async {
    final deadline = DateTime.now().add(taskTimeout);
    while (true) {
      _ensureCurrent(isCurrent);
      final response = await _client
          .get(
            Uri.parse('$origin/api/v1/tasks/${Uri.encodeComponent(taskId)}'),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 30));
      final task = parseQwenTask(_decodeObject(response));
      final status = task.status.toUpperCase();
      if (status == 'SUCCEEDED') {
        if (task.transcriptionUrls.isEmpty) {
          throw QwenTaskFailedException(
            task.failureMessage == null || task.failureMessage!.isEmpty
                ? '通义转写失败，请重试'
                : '通义转写失败：${clipSttMessage(task.failureMessage!)}',
          );
        }
        return task;
      }
      if (status != 'PENDING' && status != 'RUNNING') {
        throw QwenTaskFailedException(
          task.failureMessage == null || task.failureMessage!.isEmpty
              ? '通义转写失败，请重试'
              : '通义转写失败：${clipSttMessage(task.failureMessage!)}',
        );
      }
      onProgress?.call(
        SttFileProgress(
          status == 'PENDING' ? SttFileStage.queued : SttFileStage.processing,
        ),
      );
      if (!DateTime.now().isBefore(deadline)) {
        throw const QwenSttException('通义转写超时，请稍后重试');
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<Map<String, dynamic>> _fetchTranscript(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const QwenSttException('通义转写结果地址无效');
    }
    final response = await _client
        .get(uri)
        .timeout(const Duration(seconds: 60));
    return _decodeObject(response);
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw QwenSttException(_httpFailure(response));
    }
    try {
      final value = jsonDecode(_utf8Body(response));
      if (value is Map<String, dynamic>) return value;
    } on FormatException {
      // Fall through to the generic parse error.
    }
    throw const QwenSttException('通义返回无法解析');
  }

  String _httpFailure(http.Response response) {
    String? message;
    try {
      final value = jsonDecode(_utf8Body(response));
      if (value is Map) {
        final text = '${value['message'] ?? ''}'.trim();
        if (text.isNotEmpty) message = text;
      }
    } on FormatException {
      message = null;
    }
    return switch (response.statusCode) {
      401 || 403 => '通义 API Key 无效，请在设置中更新',
      429 => '通义请求过多，请稍后重试',
      _ => message == null ? '通义转写失败，请重试' : '通义转写失败：${clipSttMessage(message)}',
    };
  }

  void _ensureCurrent(bool Function()? isCurrent) {
    if (isCurrent != null && !isCurrent()) {
      throw const QwenSttException('处理已取消，可重试');
    }
  }

  @override
  void dispose() {
    cancelCurrent();
    _client.close();
  }
}

class QwenSttException extends CloudSttException {
  const QwenSttException(super.message);

  @override
  String toString() => 'QwenSttException($message)';
}

class QwenPolicyExpired implements Exception {
  const QwenPolicyExpired();
}

class QwenUploadPolicy {
  const QwenUploadPolicy({
    required this.policy,
    required this.signature,
    required this.uploadDir,
    required this.uploadHost,
    required this.accessKeyId,
    required this.objectAcl,
    required this.forbidOverwrite,
    this.maxFileSizeMb,
  });

  final String policy;
  final String signature;
  final String uploadDir;
  final String uploadHost;
  final String accessKeyId;
  final String objectAcl;
  final String forbidOverwrite;
  final int? maxFileSizeMb;
}

class QwenTaskStatus {
  const QwenTaskStatus({
    required this.status,
    this.taskId,
    this.transcriptionUrls = const [],
    this.failureMessage,
    this.durationSec,
  });

  final String status;
  final String? taskId;
  final List<String> transcriptionUrls;
  final String? failureMessage;
  final double? durationSec;
}

/// `language_hints` codes for Qwen-Audio-3.x filetrans and `fun-asr`.
const qwenAudio3LanguageCodes = {
  'zh',
  'en',
  'ja',
  'ko',
  'vi',
  'th',
  'id',
  'ms',
  'tl',
  'hi',
  'ar',
  'fr',
  'de',
  'es',
  'pt',
  'ru',
  'it',
  'nl',
  'sv',
  'da',
  'fi',
  'no',
  'el',
  'pl',
  'cs',
  'hu',
  'ro',
  'bg',
  'hr',
  'sk',
};

/// `language_hints` codes documented only for `paraformer-v2`.
const paraformerV2LanguageCodes = {
  'zh',
  'en',
  'ja',
  'yue',
  'ko',
  'de',
  'fr',
  'ru',
};

const _diarizationModels = {
  'qwen-audio-3.1-asr-flash-filetrans',
  'qwen-audio-3.0-asr-flash-filetrans',
  'fun-asr',
  'paraformer-v2',
};

bool qwenDiarizationEnabled(String model) => _diarizationModels.contains(model);

/// One hint, or null when the model should auto-detect.
List<String>? qwenLanguageHints({required String model, String? language}) {
  final code = language?.trim().toLowerCase();
  if (code == null || code.isEmpty || code == 'auto') return null;
  final allowed = switch (model) {
    'qwen-audio-3.1-asr-flash-filetrans' ||
    'qwen-audio-3.0-asr-flash-filetrans' ||
    'fun-asr' => qwenAudio3LanguageCodes,
    'paraformer-v2' => paraformerV2LanguageCodes,
    _ => null,
  };
  if (allowed == null || !allowed.contains(code)) return null;
  return [code];
}

/// Body for the async file API (`input.file_urls`, one URL).
///
/// `parameters` is always present. Qwen-Audio-3.1/3.0 filetrans fails when
/// that object is omitted. `qwen3-asr-flash-filetrans` uses singular
/// `input.file_url` and is rejected before this body is sent.
Map<String, dynamic> qwenTranscriptionBody({
  required String model,
  required String fileUrl,
  String? language,
}) {
  final parameters = <String, dynamic>{
    'channel_id': [0],
  };
  if (qwenDiarizationEnabled(model)) {
    parameters['diarization_enabled'] = true;
  }
  final hints = qwenLanguageHints(model: model, language: language);
  if (hints != null) parameters['language_hints'] = hints;
  return {
    'model': model,
    'input': {
      'file_urls': [fileUrl],
    },
    'parameters': parameters,
  };
}

String resolveDashScopeBaseUrl(String? configured, {String? environment}) =>
    resolveCloudBaseUrl(
      configured,
      environment: environment,
      fallback: QwenSttService.defaultBaseUrl,
      normalize: normalizeDashScopeBaseUrl,
    );

String normalizeDashScopeBaseUrl(String raw) => normalizeCloudHttpsOrigin(
  raw,
  fallback: QwenSttService.defaultBaseUrl,
  apiSuffix: '/api/v1',
  fail: (message) => QwenSttException('通义$message'),
);

QwenUploadPolicy parseQwenUploadPolicy(Map<String, dynamic> json) {
  final data = json['data'];
  if (data is! Map) {
    throw const QwenSttException('通义上传凭证无效');
  }
  String field(String name) {
    final value = '${data[name] ?? ''}'.trim();
    if (value.isEmpty) throw const QwenSttException('通义上传凭证无效');
    return value;
  }

  final host = field('upload_host');
  final hostUri = Uri.tryParse(host);
  if (hostUri == null || hostUri.scheme != 'https' || hostUri.host.isEmpty) {
    throw const QwenSttException('通义上传凭证无效');
  }
  final maxRaw = data['max_file_size_mb'];
  int? maxMb;
  if (maxRaw is num && maxRaw > 0) {
    maxMb = maxRaw.toInt();
  } else if (maxRaw is String) {
    final parsed = int.tryParse(maxRaw.trim());
    if (parsed != null && parsed > 0) maxMb = parsed;
  }
  final rawHost = hostUri.toString();
  final fragment = rawHost.indexOf('#');
  return QwenUploadPolicy(
    policy: field('policy'),
    signature: field('signature'),
    uploadDir: field('upload_dir').replaceAll(RegExp(r'/+$'), ''),
    uploadHost: fragment == -1 ? rawHost : rawHost.substring(0, fragment),
    accessKeyId: field('oss_access_key_id'),
    objectAcl: field('x_oss_object_acl'),
    forbidOverwrite: field('x_oss_forbid_overwrite'),
    maxFileSizeMb: maxMb,
  );
}

QwenTaskStatus parseQwenTask(Map<String, dynamic> json) {
  final output = json['output'] is Map ? json['output'] as Map : json;
  final status = '${output['task_status'] ?? ''}'.trim();
  if (status.isEmpty) {
    throw const QwenSttException('通义转写状态无效');
  }
  final urls = <String>[];
  final failures = <String>[];
  final results = output['results'];
  if (results is List) {
    for (final item in results) {
      if (item is! Map) continue;
      final subtask = '${item['subtask_status'] ?? ''}'.trim().toUpperCase();
      final url = '${item['transcription_url'] ?? ''}'.trim();
      if (subtask == 'SUCCEEDED' && url.isNotEmpty) {
        urls.add(url);
      } else if (subtask == 'FAILED') {
        final code = '${item['code'] ?? ''}'.trim();
        final message = '${item['message'] ?? ''}'.trim();
        final detail = [
          code,
          message,
        ].where((part) => part.isNotEmpty).join(': ');
        if (detail.isNotEmpty) failures.add(detail);
      }
    }
  }
  final outputMessage = '${output['message'] ?? ''}'.trim();
  if (outputMessage.isNotEmpty) failures.add(outputMessage);
  double? durationSec;
  final usage = json['usage'];
  if (usage is Map && usage['duration'] is num) {
    durationSec = (usage['duration'] as num).toDouble();
  }
  final taskId = '${output['task_id'] ?? ''}'.trim();
  return QwenTaskStatus(
    status: status,
    taskId: taskId.isEmpty ? null : taskId,
    transcriptionUrls: urls,
    failureMessage: failures.isEmpty ? null : failures.join('\n'),
    durationSec: durationSec,
  );
}

/// Paragraph text from a `transcription_url` document.
///
/// Speaker labels use `sentences[].speaker_id` when diarization is enabled.
String renderQwenTranscript(Map<String, dynamic> json) =>
    parseQwenTranscript(json).text;

/// Paragraph text plus provider times from a `transcription_url` document.
///
/// Times are only returned when every emitted sentence has a valid
/// `begin_time`/`end_time`. Partial timing would make a sentence jump to the
/// wrong place, so it is discarded rather than guessed from text length.
({String text, List<SttSegment> segments}) parseQwenTranscript(
  Map<String, dynamic> json,
) {
  final transcripts = json['transcripts'];
  if (transcripts is! List || transcripts.isEmpty) {
    return (
      text: normalizeSttText('${json['text'] ?? ''}'),
      segments: const [],
    );
  }
  final buffer = StringBuffer();
  final segments = <SttSegment>[];
  String? currentSpeaker;
  var timingComplete = true;
  for (final transcript in transcripts) {
    if (transcript is! Map) continue;
    final sentences = transcript['sentences'];
    if (sentences is List && sentences.isNotEmpty) {
      for (final sentence in sentences) {
        if (sentence is! Map) continue;
        final text = '${sentence['text'] ?? ''}'.trim();
        if (text.isEmpty) continue;
        final speaker = _speakerId(sentence['speaker_id']);
        final labeled = speaker != null && speaker != currentSpeaker;
        _writeQwenSentence(
          buffer,
          text: text,
          speaker: speaker,
          currentSpeaker: currentSpeaker,
        );
        final startMs = _intOrNone(sentence['begin_time']);
        final endMs = _intOrNone(sentence['end_time']);
        if (startMs == null ||
            endMs == null ||
            startMs < 0 ||
            endMs < startMs) {
          timingComplete = false;
        } else {
          segments.add(
            SttSegment(
              text: text,
              startMs: startMs,
              endMs: endMs,
              speaker: speaker,
              speakerChanged: labeled,
            ),
          );
        }
        if (speaker != null) currentSpeaker = speaker;
      }
      continue;
    }
    final text = '${transcript['text'] ?? ''}'.trim();
    if (text.isEmpty) continue;
    timingComplete = false;
    _writeQwenSentence(
      buffer,
      text: text,
      speaker: null,
      currentSpeaker: currentSpeaker,
    );
  }
  return (
    text: normalizeSttText(buffer.toString()),
    segments: timingComplete ? segments : const <SttSegment>[],
  );
}

double? qwenDurationSec(Map<String, dynamic> json) {
  final properties = json['properties'];
  if (properties is! Map) return null;
  final ms = properties['original_duration_in_milliseconds'];
  if (ms is! num || ms < 0) return null;
  return ms.toDouble() / 1000;
}

String? _speakerId(Object? raw) {
  if (raw == null) return null;
  final id = '$raw'.trim();
  return id.isEmpty ? null : id;
}

int? _intOrNone(Object? raw) => raw is num ? raw.toInt() : null;

void _writeQwenSentence(
  StringBuffer buffer, {
  required String text,
  required String? speaker,
  required String? currentSpeaker,
}) {
  final labeled = speaker != null && speaker != currentSpeaker;
  if (buffer.isNotEmpty) buffer.write('\n');
  buffer.write(labeled ? '说话人 $speaker：$text' : text);
}

String _uploadFilename(String path) {
  final ext = p.extension(path).toLowerCase();
  const allowed = {
    '.aac',
    '.amr',
    '.flac',
    '.m4a',
    '.mp3',
    '.ogg',
    '.opus',
    '.wav',
    '.webm',
  };
  return 'audio${allowed.contains(ext) ? ext : '.ogg'}';
}

String _utf8Body(http.Response response) => utf8.decode(response.bodyBytes);

/// The checkpoint callback must be durable before polling starts.
class QwenTaskRecovery {
  const QwenTaskRecovery({this.taskId, required this.onSubmitted});
  final String? taskId;
  final Future<void> Function(String taskId) onSubmitted;
}

class QwenTaskFailedException extends QwenSttException {
  const QwenTaskFailedException(super.message);
}

/// Prefer the original compressed recording only when its measured duration
/// matches the generated playback file. Never substitute unrelated audio.
Future<String> qwenUploadSource(String path) => compressedUploadSource(path);

void validateQwenAudio({required int length, Duration? duration}) {
  if (length > QwenSttService.maxUploadBytes) {
    throw const QwenSttException('音频超过当前上传方式的 1 GiB 限制');
  }
  if (duration != null && duration > const Duration(hours: 12)) {
    throw const QwenSttException('音频超过千问支持的 12 小时');
  }
}

http.MultipartFile multipartFileFromDisk({
  required String field,
  required File file,
  required String filename,
  required void Function(int, int) onProgress,
  bool Function()? isCurrent,
}) {
  final length = file.lengthSync();
  Stream<List<int>> chunks() async* {
    var sent = 0;
    onProgress(0, length);
    await for (final chunk in file.openRead()) {
      if (isCurrent != null && !isCurrent()) {
        throw const QwenSttException('已取消');
      }
      yield chunk;
      sent += chunk.length;
      onProgress(sent, length);
    }
  }

  return http.MultipartFile(field, chunks(), length, filename: filename);
}
