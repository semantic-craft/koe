import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../audio/ogg_opus.dart';
import 'progress_multipart.dart';
import 'stt_types.dart';

/// DashScope Paraformer file transcription.
///
/// File jobs only. Live streaming is a follow-up and is not implemented.
///
/// Confirmed from current Model Studio docs:
/// - Submit: POST `{base}/api/v1/services/audio/asr/transcription`
///   with `Authorization: Bearer`, `X-DashScope-Async: enable`, and
///   `X-DashScope-OssResourceResolve: enable` when `file_urls` is `oss://`.
/// - Poll: GET `{base}/api/v1/tasks/{task_id}` (task API and the non-realtime
///   guide). The Paraformer page's method table says POST; its own curl is GET.
/// - Result: `output.results[].transcription_url` JSON (`transcripts[].text`,
///   `sentences[].speaker_id` when diarization is on).
/// - Local files: GET `{base}/api/v1/uploads?action=getPolicy&model=...`,
///   then multipart POST to `upload_host`. The URL is `oss://` + object key
///   and expires in 48 hours. Base64 audio is not supported.
///
/// https://help.aliyun.com/zh/model-studio/paraformer-recorded-speech-recognition-restful-api
/// https://help.aliyun.com/zh/model-studio/get-temporary-file-url
/// https://help.aliyun.com/en/model-studio/manage-asynchronous-tasks
/// https://help.aliyun.com/en/model-studio/non-realtime-speech-recognition-user-guide
class QwenSttService {
  QwenSttService({
    http.Client? client,
    this.pollInterval = const Duration(seconds: 2),
    this.taskTimeout = const Duration(minutes: 15),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration pollInterval;
  final Duration taskTimeout;

  static const defaultBaseUrl = 'https://dashscope.aliyuncs.com';
  static const intlBaseUrl = 'https://dashscope-intl.aliyuncs.com';
  static const defaultModel = 'paraformer-v2';
  static const maxUploadBytes = 1024 * 1024 * 1024;

  String? apiKeyOverride;
  String? baseUrlOverride;
  String? modelOverride;

  String? get apiKey {
    final override = apiKeyOverride?.trim();
    if (override != null && override.isNotEmpty) return override;
    final env = Platform.environment['DASHSCOPE_API_KEY']?.trim();
    if (env != null && env.isNotEmpty) return env;
    return null;
  }

  /// Resolved HTTPS origin. Settings win, then `DASHSCOPE_HTTP_BASE_URL`.
  String get baseUrl => resolveDashScopeBaseUrl(
    baseUrlOverride,
    environment: Platform.environment['DASHSCOPE_HTTP_BASE_URL'],
  );

  String get model {
    final override = modelOverride?.trim();
    if (override != null && override.isNotEmpty) return override;
    return defaultModel;
  }

  bool get isConfigured => apiKey != null;

  Future<SttResult> transcribePath(
    String path, {
    String? apiKey,
    String? baseUrl,
    String? model,
    String? language,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  }) async {
    try {
      return await _transcribe(
        path,
        apiKey: apiKey,
        baseUrl: baseUrl,
        model: model,
        language: language,
        onProgress: onProgress,
        isCurrent: isCurrent,
      );
    } on QwenSttException {
      rethrow;
    } on TimeoutException {
      throw const QwenSttException('通义转写超时，请稍后重试');
    } on SocketException {
      throw const QwenSttException('无法连接通义服务，请检查网络后重试');
    } on http.ClientException {
      throw const QwenSttException('无法连接通义服务，请检查网络后重试');
    }
  }

  Future<SttResult> _transcribe(
    String path, {
    String? apiKey,
    String? baseUrl,
    String? model,
    String? language,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  }) async {
    final key = (apiKey ?? this.apiKey)?.trim();
    if (key == null || key.isEmpty) {
      throw const QwenSttException('请在设置中配置通义 Qwen');
    }
    final origin = resolveDashScopeBaseUrl(
      (baseUrl == null || baseUrl.trim().isEmpty) ? baseUrlOverride : baseUrl,
      environment: Platform.environment['DASHSCOPE_HTTP_BASE_URL'],
    );
    final resolvedModel = (model == null || model.trim().isEmpty)
        ? this.model
        : model.trim();

    onProgress?.call(const SttFileProgress(SttFileStage.preparing));
    _ensureCurrent(isCurrent);
    final audioPath = await OggOpus.ensurePlayable(path);
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
      bytes: await file.readAsBytes(),
      filename: filename,
      onProgress: onProgress,
      isCurrent: isCurrent,
    );
    _ensureCurrent(isCurrent);
    onProgress?.call(const SttFileProgress(SttFileStage.queued));
    final taskId = await _submit(
      origin: origin,
      apiKey: key,
      model: resolvedModel,
      ossUrl: ossUrl,
      language: language,
    );
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
    double? durationSec;
    for (final url in task.transcriptionUrls) {
      final document = await _fetchTranscript(url);
      _ensureCurrent(isCurrent);
      final text = renderQwenTranscript(document);
      if (text.isNotEmpty) parts.add(text);
      durationSec ??= qwenDurationSec(document);
    }
    return SttResult(
      text: normalizeSttText(parts.join('\n')),
      sourcePath: path,
      language: (language == null || language.trim().isEmpty)
          ? 'auto'
          : language.trim().toLowerCase(),
      durationSec: durationSec ?? task.durationSec,
    );
  }

  Future<String> _upload({
    required String origin,
    required String apiKey,
    required String model,
    required Uint8List bytes,
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
      if (maxMb != null && bytes.length > maxMb * 1024 * 1024) {
        throw QwenSttException('音频超过通义允许的 $maxMb MB');
      }
      return _postToOss(
        policy: policy,
        bytes: bytes,
        filename: filename,
        onProgress: onProgress,
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
    required Uint8List bytes,
    required String filename,
    SttFileProgressCallback? onProgress,
  }) async {
    final key = '${policy.uploadDir}/$filename';
    final request = http.MultipartRequest('POST', Uri.parse(policy.uploadHost))
      ..fields['OSSAccessKeyId'] = policy.accessKeyId
      ..fields['Signature'] = policy.signature
      ..fields['policy'] = policy.policy
      ..fields['x-oss-object-acl'] = policy.objectAcl
      ..fields['x-oss-forbid-overwrite'] = policy.forbidOverwrite
      ..fields['key'] = key
      ..fields['success_action_status'] = '200'
      ..files.add(
        multipartFileWithProgress(
          field: 'file',
          bytes: bytes,
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
    final body = await streamed.stream.bytesToString();
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
          throw QwenSttException(
            task.failureMessage == null || task.failureMessage!.isEmpty
                ? '通义转写失败，请重试'
                : '通义转写失败：${_clip(task.failureMessage!)}',
          );
        }
        return task;
      }
      if (status != 'PENDING' && status != 'RUNNING') {
        throw QwenSttException(
          task.failureMessage == null || task.failureMessage!.isEmpty
              ? '通义转写失败，请重试'
              : '通义转写失败：${_clip(task.failureMessage!)}',
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
    final response = await _client.get(uri).timeout(const Duration(seconds: 60));
    return _decodeObject(response);
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw QwenSttException(_httpFailure(response));
    }
    try {
      final value = jsonDecode(response.body);
      if (value is Map<String, dynamic>) return value;
    } on FormatException {
      // Fall through to the generic parse error.
    }
    throw const QwenSttException('通义返回无法解析');
  }

  String _httpFailure(http.Response response) {
    String? message;
    try {
      final value = jsonDecode(response.body);
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
      _ =>
        message == null
            ? '通义转写失败，请重试'
            : '通义转写失败：${_clip(message)}',
    };
  }

  void _ensureCurrent(bool Function()? isCurrent) {
    if (isCurrent != null && !isCurrent()) {
      throw const QwenSttException('处理已取消，可重试');
    }
  }

  void dispose() {
    _client.close();
  }
}

class QwenSttException implements Exception {
  const QwenSttException(this.message);
  final String message;
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

const qwenLanguageHintCodes = {
  'zh',
  'en',
  'ja',
  'yue',
  'ko',
  'de',
  'fr',
  'ru',
};

/// `language_hints` is documented only for `paraformer-v2`.
List<String>? qwenLanguageHints({required String model, String? language}) {
  if (model != QwenSttService.defaultModel) return null;
  final code = language?.trim().toLowerCase();
  if (code == null || code.isEmpty || code == 'auto') return null;
  if (!qwenLanguageHintCodes.contains(code)) return null;
  return [code];
}

/// Body for the shared async file API (`input.file_urls`, one URL).
///
/// `Qwen3-ASR-Flash-Filetrans` uses singular `input.file_url` and is not
/// this request shape.
Map<String, dynamic> qwenTranscriptionBody({
  required String model,
  required String fileUrl,
  String? language,
}) {
  final parameters = <String, dynamic>{
    'channel_id': [0],
  };
  if (model.startsWith('paraformer')) {
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

String resolveDashScopeBaseUrl(String? configured, {String? environment}) {
  final raw = configured?.trim();
  final candidate = (raw == null || raw.isEmpty) ? environment?.trim() : raw;
  if (candidate == null || candidate.isEmpty) {
    return QwenSttService.defaultBaseUrl;
  }
  return normalizeDashScopeBaseUrl(candidate);
}

String normalizeDashScopeBaseUrl(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return QwenSttService.defaultBaseUrl;
  if (!value.contains('://')) value = 'https://$value';
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  const apiSuffix = '/api/v1';
  if (value.endsWith(apiSuffix)) {
    value = value.substring(0, value.length - apiSuffix.length);
  }
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    throw const QwenSttException('通义服务地址需要 HTTPS');
  }
  return uri.origin;
}

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
  return QwenUploadPolicy(
    policy: field('policy'),
    signature: field('signature'),
    uploadDir: field('upload_dir').replaceAll(RegExp(r'/+$'), ''),
    uploadHost: hostUri.origin,
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
String renderQwenTranscript(Map<String, dynamic> json) {
  final transcripts = json['transcripts'];
  if (transcripts is! List || transcripts.isEmpty) {
    return normalizeSttText('${json['text'] ?? ''}');
  }
  final buffer = StringBuffer();
  String? currentSpeaker;
  for (final transcript in transcripts) {
    if (transcript is! Map) continue;
    final sentences = transcript['sentences'];
    if (sentences is List && sentences.isNotEmpty) {
      for (final sentence in sentences) {
        if (sentence is! Map) continue;
        final text = '${sentence['text'] ?? ''}'.trim();
        if (text.isEmpty) continue;
        final speaker = _speakerId(sentence['speaker_id']);
        _writeQwenSentence(
          buffer,
          text: text,
          speaker: speaker,
          currentSpeaker: currentSpeaker,
        );
        if (speaker != null) currentSpeaker = speaker;
      }
      continue;
    }
    final text = '${transcript['text'] ?? ''}'.trim();
    if (text.isEmpty) continue;
    _writeQwenSentence(
      buffer,
      text: text,
      speaker: null,
      currentSpeaker: currentSpeaker,
    );
  }
  return normalizeSttText(buffer.toString());
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

String _clip(String value) {
  final trimmed = value.trim();
  if (trimmed.length <= 180) return trimmed;
  return '${trimmed.substring(0, 180)}…';
}
