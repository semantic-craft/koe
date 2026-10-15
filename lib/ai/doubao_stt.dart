import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../audio/ogg_opus.dart';
import 'cloud_stt_service.dart';
import 'stt_types.dart';

/// Doubao (Volcano Engine) recorded-file transcription via the
/// "big model flash" one-shot recognize API.
///
/// File jobs only. Live streaming is a follow-up and is not implemented.
///
/// Confirmed from current Volcano docs (2026-10-15, see
/// koe-notes/doubao-volcano-api.md):
/// - Standard edition (`volc.seedasr.auc` / `volc.bigasr.auc`,
///   submit + query) accepts only a publicly downloadable `audio.url`
///   and has no hosted upload, so local recordings cannot reach it without
///   the user's own object storage. Those resource ids are rejected here.
/// - Flash edition is the only recorded-file API that accepts inline audio
///   (`audio.data`, base64) and returns the transcript in a single
///   synchronous request: `POST {base}/api/v3/auc/bigmodel/recognize/flash`,
///   <= 2 h audio, <= 100 MB hard cap, <= 20 MB recommended for direct
///   base64 upload.
/// - Auth is the v3 header scheme: `X-Api-Key` plus `X-Api-Resource-Id`
///   (the configurable "model") and a client-generated `X-Api-Request-Id`.
///   The body's `request.model_name` is always the literal `bigmodel`.
/// - Status and error codes arrive in the response header
///   `X-Api-Status-Code` (`20000000` success) with `X-Api-Message`;
///   they are mapped to readable Chinese below.
/// - Language codes are BCP-47 style (`zh-CN`); app ISO short codes are
///   mapped (`zh` -> `zh-CN`), `auto` omits the field.
///
/// https://docs.volcengine.com/docs/DoubaoVoice/LargemodelrecordingfileLiterecognitionAPI
/// https://docs.volcengine.com/docs/DoubaoVoice/error-code-query
class DoubaoSttService extends CloudFileSttService {
  DoubaoSttService({
    http.Client? client,
    this.requestTimeout = const Duration(minutes: 10),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration requestTimeout;

  static const defaultBaseUrl = 'https://openspeech.bytedance.com';
  static const defaultModel = 'volc.bigasr.auc_turbo';

  /// Flash direct base64 upload is recommended up to 20 MB (the API hard
  /// cap is 100 MB). Keep the conservative limit as the pre-flight check.
  static const maxDirectUploadBytes = 20 * 1024 * 1024;

  @override
  String get engineLabel => '豆包';

  @override
  String get apiKeyEnvVar => 'DOUBAO_API_KEY';

  @override
  String get baseUrlEnvVar => 'DOUBAO_HTTP_BASE_URL';

  @override
  String get fallbackBaseUrl => defaultBaseUrl;

  @override
  String get fallbackModel => defaultModel;

  @override
  String get apiSuffix => '/api/v3';

  @override
  CloudSttException fail(String message) => DoubaoSttException(message);

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
    final key = (apiKey ?? this.apiKey)?.trim();
    if (key == null || key.isEmpty) {
      throw const DoubaoSttException('请在设置中配置豆包');
    }
    final origin = resolvedBaseUrl(baseUrl);
    final resolvedModel = (model == null || model.trim().isEmpty)
        ? this.model
        : model.trim();
    final rejection = doubaoModelRejection(resolvedModel);
    if (rejection != null) {
      throw DoubaoSttException(rejection);
    }

    onProgress?.call(const SttFileProgress(SttFileStage.preparing));
    _ensureCurrent(isCurrent);
    final audioPath = await OggOpus.ensurePlayable(path);
    final file = File(audioPath);
    final length = await file.length();
    if (!await file.exists() || length < 64) {
      throw const DoubaoSttException('音频太短或无效，无法转写');
    }
    if (length > maxDirectUploadBytes) {
      throw const DoubaoSttException(
        '音频超过 20 MB，无法直传豆包极速版；请压缩音频或改用标准版',
      );
    }

    final bytes = await file.readAsBytes();
    final requestId = _requestId();
    debugPrint(
      '[Doubao] flash ${file.uri.pathSegments.last} ${bytes.length}B '
      'model=$resolvedModel host=${Uri.parse(origin).host}',
    );
    onProgress?.call(const SttFileProgress(SttFileStage.uploading));
    _ensureCurrent(isCurrent);
    final response = await _client
        .post(
          Uri.parse('$origin/api/v3/auc/bigmodel/recognize/flash'),
          headers: {
            'X-Api-Key': key,
            'X-Api-Resource-Id': resolvedModel,
            'X-Api-Request-Id': requestId,
            'Content-Type': 'application/json',
          },
          body: jsonEncode(
            doubaoTranscriptionBody(
              data: base64Encode(bytes),
              language: language,
            ),
          ),
        )
        .timeout(requestTimeout);

    final status = _statusCode(response);
    if (status != '20000000') {
      // Prefer the status header's message; fall back to a body `message`
      // so credential hints surface wherever the provider puts them.
      final hint = _statusMessage(response) ?? _bodyMessage(response);
      final readable = doubaoStatusMessage(status, hint);
      throw DoubaoSttException(
        readable ?? _httpFailure(response) ?? '豆包返回无法解析',
      );
    }

    onProgress?.call(const SttFileProgress(SttFileStage.fetching));
    _ensureCurrent(isCurrent);
    final document = _decodeObject(response);
    final recognized = parseDoubaoRecognize(document);
    return SttResult(
      text: renderDoubaoTranscript(document),
      sourcePath: path,
      language: (language == null || language.trim().isEmpty)
          ? 'auto'
          : language.trim().toLowerCase(),
      durationSec: recognized.durationSec,
    );
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    try {
      final value = jsonDecode(utf8.decode(response.bodyBytes));
      if (value is Map<String, dynamic>) return value;
    } on FormatException {
      // Fall through to the generic parse error.
    }
    throw const DoubaoSttException('豆包返回无法解析');
  }

  String? _statusCode(http.Response response) =>
      response.headers['x-api-status-code']?.trim();

  String? _statusMessage(http.Response response) =>
      response.headers['x-api-message']?.trim();

  /// HTTP transport failures (non-2xx without a usable status header).
  String? _httpFailure(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return null;
    final message = _bodyMessage(response);
    return switch (response.statusCode) {
      401 || 403 => '豆包 API Key 无效，请在设置中更新',
      429 => '豆包请求过多，请稍后重试',
      _ => message == null ? '豆包转写失败，请重试' : '豆包转写失败：${clipSttMessage(message)}',
    };
  }

  /// Best-effort `message` field from an error body.
  String? _bodyMessage(http.Response response) {
    try {
      final value = jsonDecode(utf8.decode(response.bodyBytes));
      if (value is Map) {
        final text = '${value['message'] ?? ''}'.trim();
        if (text.isNotEmpty) return text;
      }
    } on FormatException {
      // The transport status decides.
    }
    return null;
  }

  void _ensureCurrent(bool Function()? isCurrent) {
    if (isCurrent != null && !isCurrent()) {
      throw const DoubaoSttException('处理已取消，可重试');
    }
  }

  @override
  void dispose() {
    _client.close();
  }
}

class DoubaoSttException extends CloudSttException {
  const DoubaoSttException(super.message);

  @override
  String toString() => 'DoubaoSttException($message)';
}

/// One diarized utterance from a completed flash result.
class DoubaoUtterance {
  const DoubaoUtterance({
    required this.text,
    this.speaker,
    this.startTimeMs,
    this.endTimeMs,
  });

  final String text;
  /// Provider-assigned speaker number (`additions.speaker`, `0`..`9`).
  final String? speaker;
  final int? startTimeMs;
  final int? endTimeMs;
}

/// Parsed body of a successful flash recognize response.
class DoubaoRecognize {
  const DoubaoRecognize({
    required this.text,
    this.utterances = const [],
    this.durationSec,
  });

  final String text;
  final List<DoubaoUtterance> utterances;
  /// `audio_info.duration` is milliseconds.
  final double? durationSec;
}

/// App ISO short codes -> Volcano BCP-47 language codes.
const doubaoLanguageCodes = {
  'zh': 'zh-CN',
  'en': 'en-US',
  'ja': 'ja-JP',
  'ko': 'ko-KR',
  'yue': 'yue-CN',
};

/// Map an app language selection to a flash `audio.language` value.
///
/// `auto`, unknown codes, and BCP-47-looking codes that are not known map to
/// null, which omits the field and lets the model auto-detect. A value that
/// already looks like BCP-47 (`zh-CN`) passes through.
String? doubaoLanguageCode(String? language) {
  final code = language?.trim();
  if (code == null || code.isEmpty || code == 'auto') return null;
  final lower = code.toLowerCase();
  if (lower.contains('-')) {
    return _normalizeKnown(lower) ?? code;
  }
  return _normalizeKnown(lower);
}

String? _normalizeKnown(String lower) => doubaoLanguageCodes[lower];

/// Flash-family check: `_turbo` resource ids (any version suffix) and
/// anything the provider names `flash`. Standard and streaming ids are
/// rejected by [doubaoModelRejection].
bool isDoubaoFlashModel(String model) {
  final lower = model.toLowerCase();
  return lower.contains('_turbo') || lower.contains('flash');
}

/// Readable rejection for models the one-shot service cannot call, or null
/// when the model is flash-family and may proceed.
String? doubaoModelRejection(String model) {
  const flash = DoubaoSttService.defaultModel;
  if (model == 'volc.seedasr.auc' || model == 'volc.bigasr.auc') {
    return '标准版 $model 只支持公网 audio.url，暂不支持直传；'
        '请改用极速版 $flash';
  }
  if (model.contains('sauc') || model.toLowerCase().contains('stream')) {
    return '流式模型 $model 不支持录音文件转写；请改用极速版 $flash';
  }
  if (isDoubaoFlashModel(model)) return null;
  return '不支持的豆包模型 $model；请使用极速版 $flash';
}

/// Body for the one-shot flash recognize API (`audio.data` base64).
///
/// `request.model_name` is always the literal `bigmodel`; the configurable
/// model travels in the `X-Api-Resource-Id` header, not the body.
Map<String, dynamic> doubaoTranscriptionBody({
  required String data,
  String? language,
}) {
  final audio = <String, dynamic>{
    'data': data,
    'format': 'ogg',
    'codec': 'opus',
    'rate': 48000,
    'bits': 16,
    'channel': 1,
  };
  final code = doubaoLanguageCode(language);
  if (code != null) audio['language'] = code;
  return {
    'user': {'uid': 'anker-recorder'},
    'audio': audio,
    'request': {
      'model_name': 'bigmodel',
      'enable_itn': true,
      'enable_punc': true,
      'enable_speaker_info': true,
      'show_utterances': true,
    },
  };
}

String resolveDoubaoBaseUrl(String? configured, {String? environment}) =>
    resolveCloudBaseUrl(
      configured,
      environment: environment,
      fallback: DoubaoSttService.defaultBaseUrl,
      normalize: normalizeDoubaoBaseUrl,
    );

String normalizeDoubaoBaseUrl(String raw) => normalizeCloudHttpsOrigin(
  raw,
  fallback: DoubaoSttService.defaultBaseUrl,
  apiSuffix: '/api/v3',
  fail: (message) => DoubaoSttException('豆包$message'),
);

/// Map an `X-Api-Status-Code` / `X-Api-Message` pair to readable Chinese.
///
/// Returns null for `20000000` (success). Processing (`20000001`) and
/// queued (`20000002`) cannot appear on the synchronous flash call and are
/// treated as failures. Credential problems surface as parameter errors
/// whose message mentions keys or tokens.
String? doubaoStatusMessage(String? code, String? message) {
  final status = code?.trim();
  if (status == null || status.isEmpty || status == '20000000') return null;
  final text = message?.trim() ?? '';
  final lower = text.toLowerCase();
  final credential = lower.contains('key') || lower.contains('token');
  return switch (status) {
    '20000001' || '20000002' => '豆包转写未同步完成，请重试',
    '20000003' => '未识别到语音，可重试',
    '45000001' when credential => '豆包 API Key 无效，请在设置中更新',
    '45000001' => text.isEmpty ? '豆包请求参数无效，请重试' : '豆包请求参数无效：${clipSttMessage(text)}',
    '45000002' => '音频太短或无效，无法转写',
    '45000131' => '豆包请求过多，请稍后重试',
    '45000132' => '音频超过大小限制，无法转写',
    '45000151' => '音频格式不支持，请更换格式',
    '55000031' => '豆包服务繁忙，请稍后重试',
    _ when status.startsWith('550') => '豆包转写失败，请重试',
    _ => text.isEmpty ? '豆包转写失败，请重试' : '豆包转写失败：${clipSttMessage(text)}',
  };
}

/// Parse a successful flash recognize body.
///
/// Throws [DoubaoSttException] when `result` is missing or has no text and
/// no utterances.
DoubaoRecognize parseDoubaoRecognize(Map<String, dynamic> json) {
  final result = json['result'];
  if (result is! Map) {
    throw const DoubaoSttException('豆包未返回转写结果');
  }
  final text = '${result['text'] ?? ''}'.trim();
  final utterances = <DoubaoUtterance>[];
  final rawUtterances = result['utterances'];
  if (rawUtterances is List) {
    for (final item in rawUtterances) {
      if (item is! Map) continue;
      final utterance = '${item['text'] ?? ''}'.trim();
      if (utterance.isEmpty) continue;
      final additions = item['additions'];
      final speaker = additions is Map
          ? '${additions['speaker'] ?? ''}'.trim()
          : '';
      utterances.add(
        DoubaoUtterance(
          text: utterance,
          speaker: speaker.isEmpty ? null : speaker,
          startTimeMs: _intOrNone(item['start_time']),
          endTimeMs: _intOrNone(item['end_time']),
        ),
      );
    }
  }
  if (text.isEmpty && utterances.isEmpty) {
    throw const DoubaoSttException('豆包未返回转写结果');
  }
  double? durationSec;
  final audioInfo = json['audio_info'];
  if (audioInfo is Map && audioInfo['duration'] is num) {
    durationSec = (audioInfo['duration'] as num).toDouble() / 1000;
  }
  return DoubaoRecognize(
    text: text,
    utterances: utterances,
    durationSec: durationSec,
  );
}

/// Paragraph text from a flash recognize body.
///
/// Utterances are rendered as `说话人 N：` prefixed lines (the same shape
/// Qwen transcripts use, so downstream parsing is provider-agnostic);
/// without utterances the plain `result.text` is returned.
String renderDoubaoTranscript(Map<String, dynamic> json) {
  final result = json['result'];
  if (result is! Map) {
    return normalizeSttText('${json['text'] ?? ''}');
  }
  final utterances = result['utterances'];
  if (utterances is! List || utterances.isEmpty) {
    return normalizeSttText('${result['text'] ?? ''}');
  }
  final buffer = StringBuffer();
  String? currentSpeaker;
  for (final item in utterances) {
    if (item is! Map) continue;
    final text = '${item['text'] ?? ''}'.trim();
    if (text.isEmpty) continue;
    final additions = item['additions'];
    final rawSpeaker = additions is Map
        ? '${additions['speaker'] ?? ''}'.trim()
        : '';
    final speaker = rawSpeaker.isEmpty ? null : rawSpeaker;
    final labeled = speaker != null && speaker != currentSpeaker;
    if (buffer.isNotEmpty) buffer.write('\n');
    buffer.write(labeled ? '说话人 $speaker：$text' : text);
    if (speaker != null) currentSpeaker = speaker;
  }
  if (buffer.isEmpty) {
    return normalizeSttText('${result['text'] ?? ''}');
  }
  return normalizeSttText(buffer.toString());
}

/// `audio_info.duration` milliseconds -> seconds.
double? doubaoDurationSec(Map<String, dynamic> json) {
  final audioInfo = json['audio_info'];
  if (audioInfo is! Map) return null;
  final ms = audioInfo['duration'];
  if (ms is! num || ms < 0) return null;
  return ms.toDouble() / 1000;
}

int? _intOrNone(Object? raw) {
  if (raw is! num) return null;
  return raw.toInt();
}

int _requestCounter = 0;

String _requestId() =>
    'ank-${DateTime.now().microsecondsSinceEpoch}-${_requestCounter++}';
