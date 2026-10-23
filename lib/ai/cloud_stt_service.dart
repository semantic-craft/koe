import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'stt_types.dart';

/// Readable failure shared by the cloud file-transcription services.
///
/// Each service keeps its own exception class as a subclass so callers can
/// still distinguish engines while shared plumbing treats them uniformly.
abstract class CloudSttException implements Exception {
  const CloudSttException(this.message);

  final String message;
}

/// Shared plumbing for cloud file-transcription engines whose credentials
/// are a saved (API key, base URL, model) trio with environment fallbacks.
///
/// The base owns credential resolution and HTTPS-origin normalization; the
/// engine-specific request flow lives in [run], which [transcribePath]
/// wraps with the shared timeout / connectivity error mapping. Adding a
/// cloud engine means subclassing this and filling in the constants — no
/// new resolution or error-mapping code.
abstract class CloudFileSttService {
  /// Saved overrides shown in the Settings form; null falls back to the
  /// environment variables and then the engine defaults.
  String? apiKeyOverride;
  String? baseUrlOverride;
  String? modelOverride;

  /// Engine name as it appears in user-facing messages ('通义', '豆包').
  String get engineLabel;

  /// Environment variable supplying the API key when no override is saved.
  String get apiKeyEnvVar;

  /// Environment variable supplying the base URL when no override is saved.
  String get baseUrlEnvVar;

  /// Service origin used when neither settings nor environment name one.
  /// Subclasses return their `defaultBaseUrl` constant.
  String get fallbackBaseUrl;

  /// Model sent when no override is saved. Subclasses return their
  /// `defaultModel` constant.
  String get fallbackModel;

  /// Path prefix stripped when the user pastes a full endpoint.
  String get apiSuffix;

  /// The engine's readable failure carrying [message].
  CloudSttException fail(String message);

  /// Saved-or-environment API key.
  String? get apiKey {
    final override = apiKeyOverride?.trim();
    if (override != null && override.isNotEmpty) return override;
    final env = Platform.environment[apiKeyEnvVar]?.trim();
    if (env != null && env.isNotEmpty) return env;
    return null;
  }

  /// Resolved HTTPS origin for the saved settings: override, environment,
  /// then [fallbackBaseUrl].
  String get baseUrl => resolveCloudBaseUrl(
    baseUrlOverride,
    environment: Platform.environment[baseUrlEnvVar],
    fallback: fallbackBaseUrl,
    normalize: normalizeBaseUrl,
  );

  /// Saved-or-default model.
  String get model {
    final override = modelOverride?.trim();
    if (override != null && override.isNotEmpty) return override;
    return fallbackModel;
  }

  bool get isConfigured => apiKey != null;

  /// Shared HTTPS-origin normalization: add the scheme, trim trailing
  /// slashes and [apiSuffix], then require an https origin. An invalid
  /// value throws the engine's exception and leaves nothing saved.
  String normalizeBaseUrl(String raw) => normalizeCloudHttpsOrigin(
    raw,
    fallback: fallbackBaseUrl,
    apiSuffix: apiSuffix,
    fail: (message) => fail('$engineLabel$message'),
  );

  /// Origin for one call: [baseUrl] (a take's snapshot) wins, then the
  /// saved override, then the environment, then [fallbackBaseUrl].
  String resolvedBaseUrl(String? baseUrl) => resolveCloudBaseUrl(
    (baseUrl == null || baseUrl.trim().isEmpty) ? baseUrlOverride : baseUrl,
    environment: Platform.environment[baseUrlEnvVar],
    fallback: fallbackBaseUrl,
    normalize: normalizeBaseUrl,
  );

  /// The engine-specific request flow, with credentials already resolved.
  /// [expectedSpeakers] is about how many people speak, when the user said
  /// so; an engine without such a hint ignores it.
  Future<SttResult> run(
    String path, {
    String? apiKey,
    String? baseUrl,
    String? model,
    String? language,
    int? expectedSpeakers,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  });

  /// One file transcription with the shared error mapping: engine failures
  /// pass through; timeouts and connectivity loss become readable messages.
  Future<SttResult> transcribePath(
    String path, {
    String? apiKey,
    String? baseUrl,
    String? model,
    String? language,
    int? expectedSpeakers,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  }) async {
    try {
      return await run(
        path,
        apiKey: apiKey,
        baseUrl: baseUrl,
        model: model,
        language: language,
        expectedSpeakers: expectedSpeakers,
        onProgress: onProgress,
        isCurrent: isCurrent,
      );
    } on CloudSttException {
      rethrow;
    } on TimeoutException {
      throw fail('$engineLabel转写超时，请稍后重试');
    } on SocketException {
      throw fail('无法连接$engineLabel服务，请检查网络后重试');
    } on http.ClientException {
      throw fail('无法连接$engineLabel服务，请检查网络后重试');
    }
  }

  void dispose();
}

/// Resolves a cloud engine's origin: [configured] (saved settings) wins,
/// then [environment], then [fallback]; non-empty values are normalized.
String resolveCloudBaseUrl(
  String? configured, {
  String? environment,
  required String fallback,
  required String Function(String) normalize,
}) {
  final raw = configured?.trim();
  final candidate = (raw == null || raw.isEmpty) ? environment?.trim() : raw;
  if (candidate == null || candidate.isEmpty) {
    return fallback;
  }
  return normalize(candidate);
}

/// HTTPS-origin normalization shared by the cloud trio engines: add the
/// scheme, trim trailing slashes and [apiSuffix], then require an https
/// origin; blank input returns [fallback] and anything else throws [fail].
String normalizeCloudHttpsOrigin(
  String raw, {
  required String fallback,
  required String apiSuffix,
  required CloudSttException Function(String) fail,
}) {
  var value = raw.trim();
  if (value.isEmpty) return fallback;
  if (!value.contains('://')) value = 'https://$value';
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  if (value.endsWith(apiSuffix)) {
    value = value.substring(0, value.length - apiSuffix.length);
  }
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    throw fail('服务地址需要 HTTPS');
  }
  return uri.origin;
}

/// Clips a provider error message for display.
String clipSttMessage(String value) {
  final trimmed = value.trim();
  if (trimmed.length <= 180) return trimmed;
  return '${trimmed.substring(0, 180)}…';
}
