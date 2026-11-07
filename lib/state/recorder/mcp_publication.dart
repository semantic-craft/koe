part of '../recorder_controller.dart';

enum McpSyncMode {
  vps,
  lan;

  String get label => switch (this) {
    McpSyncMode.vps => 'VPS 云端',
    McpSyncMode.lan => 'Mac 局域网',
  };

  static McpSyncMode parse(Object? raw) =>
      raw == 'lan' ? McpSyncMode.lan : McpSyncMode.vps;
}

class McpSyncConfig {
  const McpSyncConfig({
    required this.baseUrl,
    required this.token,
    required this.mode,
    this.email,
  });

  static const prefix = 'KOEMCP1.';
  static final _ticketPattern = RegExp(r'KOEMCP1\.([A-Za-z0-9_-]{20,2048})');

  final String baseUrl;
  final String token;
  final McpSyncMode mode;
  final String? email;

  Uri get mcpEndpoint => Uri.parse('$baseUrl/mcp');
  Uri get packsIndexUri => Uri.parse('$baseUrl/sync/packs');
  Uri packUri(String id) => Uri.parse('$baseUrl/sync/packs/$id');
  static Uri pairRequestUri(String baseUrl) =>
      Uri.parse('${_normalizeBaseUrl(baseUrl)}/pair/request');
  static Uri pairVerifyUri(String baseUrl) =>
      Uri.parse('${_normalizeBaseUrl(baseUrl)}/pair/verify');

  String get redactedLabel => '${mode.label}已连接';

  String encodePairingCode() {
    final payload = jsonEncode({
      'v': 1,
      'u': _normalizeBaseUrl(baseUrl),
      't': token,
      'm': mode.name,
      if (email != null && email!.isNotEmpty) 'e': email,
    });
    final encoded = base64UrlEncode(utf8.encode(payload)).replaceAll('=', '');
    return '$prefix$encoded';
  }

  static String _normalizeBaseUrl(String raw) {
    var cleaned = raw.trim();
    while (cleaned.endsWith('/')) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    if (cleaned.endsWith('/mcp')) {
      cleaned = cleaned.substring(0, cleaned.length - 4);
      while (cleaned.endsWith('/')) {
        cleaned = cleaned.substring(0, cleaned.length - 1);
      }
    }
    return cleaned;
  }

  static McpSyncConfig parseFromText(String rawText) {
    final match = _ticketPattern.firstMatch(rawText);
    if (match == null) {
      throw const FormatException('未在文本或剪贴板中找到 KOEMCP1. 连接码');
    }
    final body = match.group(1)!;
    final padded = body + '=' * ((4 - body.length % 4) % 4);
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(base64Url.decode(padded)));
    } catch (_) {
      throw const FormatException('KOEMCP1. 连接码格式损坏，请让 Agent 重新生成');
    }
    if (decoded is! Map || decoded['v'] != 1) {
      throw const FormatException('不支持的 KOEMCP1. 连接码版本');
    }
    final rawUrl = decoded['u'];
    final rawToken = decoded['t'];
    final rawEmail = decoded['e'];
    if (rawUrl is! String || rawUrl.trim().isEmpty) {
      throw const FormatException('连接码缺少服务地址');
    }
    if (rawToken is! String || rawToken.trim().length < 24) {
      throw const FormatException('连接码令牌无效');
    }
    final normalizedUrl = _normalizeBaseUrl(rawUrl);
    final uri = Uri.tryParse(normalizedUrl);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      throw const FormatException('连接码服务地址无效');
    }
    return McpSyncConfig(
      baseUrl: normalizedUrl,
      token: rawToken.trim(),
      mode: McpSyncMode.parse(decoded['m']),
      email: rawEmail is String && rawEmail.trim().isNotEmpty ? rawEmail.trim() : null,
    );
  }
}

enum McpSyncPhase { unconfigured, idle, syncing, error }

class McpSyncState {
  const McpSyncState({
    this.phase = McpSyncPhase.unconfigured,
    this.lastSyncedAt,
    this.syncedCount = 0,
    this.errorMessage,
  });

  final McpSyncPhase phase;
  final DateTime? lastSyncedAt;
  final int syncedCount;
  final String? errorMessage;
}

class _McpGrant {
  const _McpGrant(this.reference, this.contentHash);
  final RecordingReference reference;
  final String contentHash;
}

mixin _RecorderMcpPublication on ChangeNotifier {
  // Provided by RecorderController and the recording stores.
  Directory? get _libraryDirectoryOverride;
  RecordingAnalysis get analysis;
  RecordingLibraryStore get library;
  MinutesDocumentStore get minutes;
  Future<void> get _transcriptsLoaded;
  Future<void> get _libraryLoaded;
  Future<void> get _minutesLoaded;
  Map<String, TranscriptMetadata> get _transcriptMetadata;
  String _referenceKey(RecordingReference ref);
  int? fileIdFromPath(String path);
  RecordingViewData recordingView(RecordingReference ref);
  Map<String, String> speakerAliasesForPath(String path);
  Future<Directory> _packWorkDirectory(String name);
  Future<MaterialPackImportOutcome> importMaterialPack(String packPath);
  Future<void> _persistSettings();
  // END DEPS

  Directory? _mcpDirectory;
  Future<Directory>? _mcpDirectoryPending;
  final Map<String, _McpGrant> _mcpGrants = {};
  Map<String, dynamic> _mcpRecords = {};
  String _mcpContent = '{}';
  int _mcpGeneration = DateTime.now().microsecondsSinceEpoch;
  bool _mcpOwnDirectory = false;
  bool _mcpClosed = false;
  bool _mcpNotifying = false;
  Future<void> _mcpPending = Future.value();
  Timer? _mcpHeartbeat;
  String? _mcpContentError;
  String? _mcpWriteError;
  String? get mcpPublicationError => _mcpContentError ?? _mcpWriteError;

  McpSyncConfig? _mcpSyncConfig;
  String? _mcpSyncUrl;
  String? _mcpSyncEmail;
  McpSyncState _mcpSyncState = const McpSyncState();
  Future<void>? _mcpSyncInFlight;
  Timer? _mcpSyncDebounce;
  bool _mcpSyncQueued = false;
  final Map<String, String> _mcpKnownRemoteShas = {};

  McpSyncConfig? get mcpSyncConfig => _mcpSyncConfig;
  String? get mcpSyncUrl => _mcpSyncConfig?.baseUrl ?? _mcpSyncUrl;
  String? get mcpSyncEmail => _mcpSyncConfig?.email ?? _mcpSyncEmail;
  McpSyncState get mcpSyncState => _mcpSyncState;

  void applySavedMcpSyncConfig(McpSyncConfig? config) {
    _mcpSyncConfig = config;
    if (config != null) {
      _mcpSyncUrl = config.baseUrl;
      if (config.email != null && config.email!.isNotEmpty) {
        _mcpSyncEmail = config.email;
      }
    }
    _mcpSyncState = config == null
        ? const McpSyncState()
        : McpSyncState(
            phase: McpSyncPhase.idle,
            lastSyncedAt: _mcpSyncState.lastSyncedAt,
            syncedCount: _mcpSyncState.syncedCount,
          );
    if (config != null && !_mcpClosed) {
      unawaited(syncMcpNow());
    } else if (config == null && !_mcpClosed) {
      unawaited(tryBindMcpFromDropFile());
    }
  }

  Future<Map<String, dynamic>> requestMcpOtpPairing({
    required String baseUrl,
    required String email,
  }) async {
    final normalizedUrl = McpSyncConfig._normalizeBaseUrl(baseUrl);
    final uri = McpSyncConfig.pairRequestUri(normalizedUrl);
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw const FormatException('服务地址必须以 http:// 或 https:// 开头');
    }
    if (uri.host.isEmpty) {
      throw const FormatException('服务地址域名或 IP 无效');
    }
    final cleanEmail = email.trim().toLowerCase();
    if (cleanEmail.isEmpty || !cleanEmail.contains('@')) {
      throw const FormatException('请输入有效的邮箱地址');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'email': cleanEmail}));
      final resp = await req.close().timeout(const Duration(seconds: 12));
      final respBody = await utf8.decoder.bind(resp).join();
      final Map<String, dynamic> json;
      try {
        json = jsonDecode(respBody) as Map<String, dynamic>;
      } catch (_) {
        throw HttpException('服务器返回无效响应 (HTTP ${resp.statusCode})');
      }
      if (resp.statusCode == 403) {
        throw const HttpException('该邮箱未被授权接入此 VPS 服务');
      }
      if (resp.statusCode != 200 || json['ok'] != true) {
        final err =
            json['error'] as String? ?? '发送验证码失败 (HTTP ${resp.statusCode})';
        throw HttpException(err);
      }
      _mcpSyncUrl = normalizedUrl;
      _mcpSyncEmail = cleanEmail;
      unawaited(_persistSettings());
      return json;
    } finally {
      client.close(force: true);
    }
  }

  Future<McpSyncConfig> verifyMcpOtpPairing({
    required String baseUrl,
    required String email,
    required String code,
  }) async {
    final normalizedUrl = McpSyncConfig._normalizeBaseUrl(baseUrl);
    final uri = McpSyncConfig.pairVerifyUri(normalizedUrl);
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw const FormatException('服务地址必须以 http:// 或 https:// 开头');
    }
    if (uri.host.isEmpty) {
      throw const FormatException('服务地址域名或 IP 无效');
    }
    final cleanEmail = email.trim().toLowerCase();
    if (cleanEmail.isEmpty || !cleanEmail.contains('@')) {
      throw const FormatException('请输入有效的邮箱地址');
    }
    final cleanCode = code.trim();
    if (cleanCode.length != 6 || !RegExp(r'^\d{6}$').hasMatch(cleanCode)) {
      throw const FormatException('请输入 6 位数字验证码');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'email': cleanEmail,
        'code': cleanCode,
      }));
      final resp = await req.close().timeout(const Duration(seconds: 12));
      final respBody = await utf8.decoder.bind(resp).join();
      final Map<String, dynamic> json;
      try {
        json = jsonDecode(respBody) as Map<String, dynamic>;
      } catch (_) {
        throw HttpException('服务器返回无效响应 (HTTP ${resp.statusCode})');
      }
      if (resp.statusCode == 401) {
        throw const HttpException('验证码错误或已失效');
      }
      if (resp.statusCode == 429) {
        throw const HttpException('重试次数过多，请重新获取验证码');
      }
      if (resp.statusCode != 200 || json['ok'] != true) {
        final err =
            json['error'] as String? ?? '验证码校验失败 (HTTP ${resp.statusCode})';
        throw HttpException(err);
      }
      final token = json['token'] as String?;
      if (token == null || token.trim().length < 24) {
        throw const FormatException('服务端颁发的令牌格式无效');
      }
      final isLocal = uri.host == 'localhost' ||
          uri.host == '127.0.0.1' ||
          uri.host.startsWith('192.168.') ||
          uri.host.startsWith('10.');
      final config = McpSyncConfig(
        baseUrl: normalizedUrl,
        token: token.trim(),
        mode: isLocal ? McpSyncMode.lan : McpSyncMode.vps,
        email: cleanEmail,
      );
      _mcpSyncConfig = config;
      _mcpSyncUrl = normalizedUrl;
      _mcpSyncEmail = cleanEmail;
      _mcpKnownRemoteShas.clear();
      _mcpSyncState = const McpSyncState(phase: McpSyncPhase.idle);
      _notifyMcpStatus();
      unawaited(_persistSettings());
      await syncMcpNow();
      return config;
    } finally {
      client.close(force: true);
    }
  }

  String buildAgentMcpSetupPrompt({bool? hasVps, String? ownerEmail}) {
    if (hasVps == true) {
      return '''
请直接阅读当前 Koe 仓库中的 `tools/koe-mcp/README.md` 与 `tools/koe-mcp/server.py`，从我电脑的 SSH 配置与环境信息中自动定位我的 VPS，完成 Koe 远程 HTTP MCP 与双端同步部署：

1. 将仓库下的 `tools/koe-mcp/server.py` 部署到我的 VPS（例如 `/opt/koe-mcp/server.py`），创建数据目录 `~/.koe/mcp-sync`，并以常驻服务启动 HTTP MCP 与同步接口（`--directory ~/.koe/mcp-sync --http-listen 127.0.0.1:8787 --token-file ~/.koe/mcp-token`，经反代暴露 HTTPS `/mcp` 与 `/sync/packs`）。
2. 将该 HTTP MCP 地址与 Bearer 令牌自动写入我电脑上的 MCP 客户端（Magpie / Claude Code / Codex / Antigravity）。
3. 执行 `python3 /opt/koe-mcp/server.py --directory ~/.koe/mcp-sync --token-file ~/.koe/mcp-token --public-url https://<自动发现的VPS域名>/mcp --mode vps --print-pairing` 生成 `KOEMCP1.` 连接码，写入系统剪贴板（`pbcopy`）并回复给我。
'''.trim();
    }
    if (hasVps == false) {
      return '''
请直接阅读当前 Koe 仓库中的 `tools/koe-mcp/README.md` 与 `tools/koe-mcp/server.py`，直接在这台 Mac 上完成 Koe 本地读取或局域网同步配置：

1. 若只需在本机让 AI 直接读取 Koe 纪要与转写：直接按 `tools/koe-mcp/README.md` 挂载本机 `tools/koe-mcp/server.py`。
2. 若需开启手机与 Mac 局域网同步：创建 `~/.koe/mcp-sync`，自动获取这台 Mac 的局域网/Tailscale IP，后台常驻启动 `python3 tools/koe-mcp/server.py --directory ~/.koe/mcp-sync --http-listen 0.0.0.0:8787 --token-file ~/.koe/mcp-token`，并配置好本机 MCP 客户端。
3. 运行 `python3 tools/koe-mcp/server.py --directory ~/.koe/mcp-sync --token-file ~/.koe/mcp-token --public-url http://<Mac局域网IP>:8787/mcp --mode lan --print-pairing` 生成 `KOEMCP1.` 连接码，写入系统剪贴板（`pbcopy`）并回复给我。
'''.trim();
    }
    return '''
请阅读当前 Koe 仓库中的 `tools/koe-mcp/README.md` 与 `tools/koe-mcp/server.py`，帮我完成 Koe 的外部 AI（MCP）与多端同步配置：

1. 请先询问我是否有自己的 VPS：
   - 如果我有 VPS：请向我询问或从我的 `~/.ssh/config` 中与我确认 VPS 的连接细节（SSH 主机、公网域名等），然后将 `tools/koe-mcp/server.py` 部署到该 VPS（`--directory ~/.koe/mcp-sync --http-listen 127.0.0.1:8787 --token-file ~/.koe/mcp-token`，经 HTTPS 反代暴露 `/mcp` 与 `/sync/packs`），配置好我电脑上的 MCP 客户端，并运行 `--mode vps --print-pairing` 生成连接码。
   - 如果我没有 VPS：请直接在这台 Mac 上按 `tools/koe-mcp/README.md` 配置本机 MCP 读取与局域网同步（常驻启动 `tools/koe-mcp/server.py --directory ~/.koe/mcp-sync --http-listen 0.0.0.0:8787 --token-file ~/.koe/mcp-token`），配置好本机 MCP 客户端，并运行 `--mode lan --print-pairing` 生成连接码。
2. 生成 `KOEMCP1.` 连接码后，请直接写入系统剪贴板（`pbcopy`）并在回复中发给我（若我的 iPhone 正插在电脑上，也可通过 `xcrun devicectl` 写入 iPhone Koe 容器的 `Documents/AnkerRecorder/mcp_pairing.txt`），我回 Koe 点一下「粘贴 AI 返回的连接码」即可完成绑定。
'''.trim();
  }

  Future<File?> _mcpPairingDropFile() async {
    final override = _libraryDirectoryOverride;
    if (override != null) {
      return File(p.join(override.path, 'mcp_pairing.txt'));
    }
    if (library.inMemory) return null;
    try {
      final base = await getApplicationDocumentsDirectory();
      return File(p.join(base.path, 'AnkerRecorder', 'mcp_pairing.txt'));
    } catch (_) {
      return null;
    }
  }

  Future<McpSyncConfig?> tryBindMcpFromDropFile() async {
    try {
      final dropFile = await _mcpPairingDropFile();
      if (dropFile == null || !dropFile.existsSync()) return null;
      final raw = dropFile.readAsStringSync();
      try {
        dropFile.deleteSync();
      } catch (_) {}
      return await bindMcpSyncFromText(raw);
    } catch (_) {
      return null;
    }
  }

  Future<McpSyncConfig> bindMcpSyncFromText(String rawText) async {
    final config = McpSyncConfig.parseFromText(rawText);
    _mcpSyncConfig = config;
    _mcpKnownRemoteShas.clear();
    _mcpSyncState = const McpSyncState(phase: McpSyncPhase.idle);
    _notifyMcpStatus();
    unawaited(_persistSettings());
    await syncMcpNow();
    return config;
  }

  Future<McpSyncConfig> bindMcpSyncFromClipboard() async {
    final fromDrop = await tryBindMcpFromDropFile();
    if (fromDrop != null) return fromDrop;
    final data = await Clipboard.getData('text/plain');
    final raw = data?.text ?? '';
    return bindMcpSyncFromText(raw);
  }

  Future<void> disconnectMcpSync() async {
    _mcpSyncConfig = null;
    _mcpKnownRemoteShas.clear();
    _mcpSyncState = const McpSyncState(phase: McpSyncPhase.unconfigured);
    _notifyMcpStatus();
    await _persistSettings();
  }

  MaterialPack? _mcpPackForDocument(MinutesDocument doc) {
    if (doc.restore != null) {
      try {
        return MaterialPack.fromJson(doc.restore);
      } catch (_) {}
    }
    if (doc.bodyText.trim().isEmpty) return null;
    final contentHash =
        doc.audioHash != null &&
            RegExp(r'^[a-f0-9]{64}$').hasMatch(doc.audioHash!)
        ? doc.audioHash!
        : analysisFingerprint('minutes-doc:${doc.id}');
    final currentMinutes =
        analysis.results['minutes:${doc.id}/minutes'] ??
        analysis.results['${doc.id}/minutes'];
    return MaterialPack(
      exportedAt: (doc.capturedAt ?? doc.importedAt).toUtc(),
      material: PackMaterial(
        contentHash: contentHash,
        title: doc.title,
        source: RecordingSource.phone,
        recordedAt: doc.capturedAt ?? doc.importedAt,
      ),
      transcript: PackTranscript(
        text: doc.bodyText,
        segments: [
          for (final seg in doc.segments)
            TranscriptSegment(
              text: seg.text,
              start: seg.start,
              end: seg.end,
              speaker: seg.speaker,
            ),
        ],
      ),
      minutes: currentMinutes == null
          ? null
          : PackMinutes(current: currentMinutes),
      bookmarks: const [],
    );
  }

  Map<String, MaterialPack> _collectMcpSyncPacks() {
    final packs = <String, MaterialPack>{};
    for (final asset in library.assets) {
      if (asset.trashed) continue;
      final ref = RecordingReference(
        fileId: fileIdFromPath(asset.path),
        path: asset.path,
      );
      final pack = _mcpPack(ref);
      if (pack != null) {
        packs[pack.material.contentHash] = MaterialPack.fromJson(pack.toJson());
      }
    }
    for (final doc in minutes.documents) {
      final pack = _mcpPackForDocument(doc);
      if (pack != null && !packs.containsKey(pack.material.contentHash)) {
        packs[pack.material.contentHash] = MaterialPack.fromJson(pack.toJson());
      }
    }
    return packs;
  }

  Uint8List _encodeKoepackBytes(MaterialPack pack) {
    final jsonBytes = utf8.encode(jsonEncode(pack.toJson()));
    final header = utf8.encode('KOEPACK1\n${jsonBytes.length}\n');
    final builder = BytesBuilder(copy: false)
      ..add(header)
      ..add(jsonBytes);
    return builder.toBytes();
  }

  String _manifestSha256(MaterialPack pack) =>
      analysisFingerprint(jsonEncode(pack.toJson()));

  Future<void> syncMcpNow() {
    if (_mcpSyncConfig == null || _mcpClosed) return Future.value();
    if (_mcpSyncInFlight != null) {
      _mcpSyncQueued = true;
      return _mcpSyncInFlight!;
    }
    final future = _runMcpSyncLoop();
    _mcpSyncInFlight = future;
    return future;
  }

  Future<void> _runMcpSyncLoop() async {
    try {
      do {
        _mcpSyncQueued = false;
        final config = _mcpSyncConfig;
        if (config == null || _mcpClosed) return;
        await _syncMcpOnce(config);
      } while (_mcpSyncQueued && !_mcpClosed && _mcpSyncConfig != null);
    } finally {
      _mcpSyncInFlight = null;
    }
  }

  Future<void> _syncMcpOnce(McpSyncConfig config) async {
    await Future.wait([
      _transcriptsLoaded,
      _libraryLoaded,
      _minutesLoaded,
      analysis.load(),
    ]);
    if (_mcpClosed || _mcpSyncConfig != config) return;
    _mcpSyncState = McpSyncState(
      phase: McpSyncPhase.syncing,
      lastSyncedAt: _mcpSyncState.lastSyncedAt,
      syncedCount: _mcpSyncState.syncedCount,
    );
    _notifyMcpStatus();

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      // 1. Fetch remote index: GET /sync/packs
      final listReq = await client.getUrl(config.packsIndexUri);
      listReq.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${config.token}',
      );
      final listResp = await listReq.close().timeout(
        const Duration(seconds: 6),
      );
      final listBody = await utf8.decoder.bind(listResp).join();
      if (listResp.statusCode != 200) {
        throw HttpException('HTTP ${listResp.statusCode}: $listBody');
      }
      final decodedList = jsonDecode(listBody) as Map<String, dynamic>;
      final remotePacks = (decodedList['packs'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final remoteShas = <String, String>{
        for (final entry in remotePacks)
          if (entry['id'] is String && entry['sha256'] is String)
            entry['id'] as String: entry['sha256'] as String,
      };

      // 2. Push dirty/missing local packs: PUT /sync/packs/<id>
      final localPacks = _collectMcpSyncPacks();
      for (final entry in localPacks.entries) {
        final materialId = entry.key;
        final pack = entry.value;
        final localSha = _manifestSha256(pack);
        if (remoteShas[materialId] == localSha) {
          _mcpKnownRemoteShas[materialId] = localSha;
          continue;
        }
        final rawBytes = _encodeKoepackBytes(pack);
        final putReq = await client.putUrl(config.packUri(materialId));
        putReq.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${config.token}',
        );
        putReq.headers.contentType = ContentType('application', 'x-koepack');
        putReq.contentLength = rawBytes.length;
        putReq.add(rawBytes);
        final putResp = await putReq.close().timeout(
          const Duration(seconds: 8),
        );
        final putBody = await utf8.decoder.bind(putResp).join();
        if (putResp.statusCode == 200) {
          final putJson = jsonDecode(putBody) as Map<String, dynamic>;
          final savedSha = putJson['sha256'] as String? ?? localSha;
          remoteShas[materialId] = savedSha;
          _mcpKnownRemoteShas[materialId] = savedSha;
        }
      }

      // 3. Pull missing/newer remote packs: GET /sync/packs/<id>
      Directory? workDir;
      try {
        for (final entry in remoteShas.entries) {
          final materialId = entry.key;
          final remoteSha = entry.value;
          if (_mcpKnownRemoteShas[materialId] == remoteSha) continue;
          final getReq = await client.getUrl(config.packUri(materialId));
          getReq.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer ${config.token}',
          );
          final getResp = await getReq.close().timeout(
            const Duration(seconds: 8),
          );
          final rawBytes = await consolidateHttpClientResponseBytes(getResp);
          if (getResp.statusCode != 200) continue;
          workDir ??= await _packWorkDirectory('koe-mcp-pull');
          final tempFile = File(p.join(workDir.path, '$materialId.koepack'));
          await tempFile.writeAsBytes(rawBytes, flush: true);
          await importMaterialPack(tempFile.path);
          _mcpKnownRemoteShas[materialId] = remoteSha;
        }
      } finally {
        if (workDir != null) {
          try {
            await workDir.delete(recursive: true);
          } catch (_) {}
        }
      }

      _mcpSyncState = McpSyncState(
        phase: McpSyncPhase.idle,
        lastSyncedAt: DateTime.now(),
        syncedCount: remoteShas.length,
      );
      _notifyMcpStatus();
    } catch (error) {
      _mcpSyncState = McpSyncState(
        phase: McpSyncPhase.error,
        lastSyncedAt: _mcpSyncState.lastSyncedAt,
        syncedCount: _mcpSyncState.syncedCount,
        errorMessage: '$error',
      );
      _notifyMcpStatus();
    } finally {
      client.close(force: true);
    }
  }

  void _initMcpPublication(Directory? directory) {
    _mcpDirectory = directory;
    addListener(_scheduleMcpPublication);
    analysis.addListener(_scheduleMcpPublication);
  }

  Future<Directory> get mcpPublicationDirectory =>
      _mcpDirectoryPending ??= () async {
        Directory directory;
        if (_mcpDirectory != null) {
          directory = _mcpDirectory!;
          await directory.create(recursive: true);
        } else {
          final root = Directory(
            p.join((await getApplicationSupportDirectory()).path, 'mcp-live'),
          );
          await root.create(recursive: true);
          await _removeExpiredMcpSessions(root);
          directory = await root.createTemp('session-');
          _mcpOwnDirectory = true;
        }
        _mcpDirectory = directory;
        return directory;
      }();

  Future<void> _removeExpiredMcpSessions(Directory root) async {
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory ||
          !p.basename(entry.path).startsWith('session-')) {
        continue;
      }
      try {
        final files = await entry.list(followLinks: false).toList();
        if (files.length != 1 ||
            files.single is! File ||
            p.basename(files.single.path) != 'live.json') {
          continue;
        }
        final manifest = files.single as File;
        if (await manifest.length() > MaterialPack.maxManifestBytes) continue;
        final value = jsonDecode(await manifest.readAsString());
        if (value is! Map ||
            value['version'] != 1 ||
            value['expiresAt'] is! String) {
          continue;
        }
        final expiry = DateTime.tryParse(value['expiresAt'] as String);
        if (expiry != null && expiry.isBefore(DateTime.now())) {
          await entry.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  String _mcpId(RecordingReference ref) =>
      analysisFingerprint(_referenceKey(ref));
  bool mcpAccessGranted(RecordingReference ref) =>
      _mcpGrants.containsKey(_mcpId(ref));

  Future<void> grantMcpAccess(RecordingReference ref) async {
    if (_mcpClosed) throw StateError('MCP publication is closed');
    await Future.wait([_transcriptsLoaded, _libraryLoaded, analysis.load()]);
    if (_mcpClosed) throw StateError('MCP publication is closed');
    final recording = recordingView(ref);
    if (recording.path == null ||
        library.assetForPath(recording.path!)?.trashed == true) {
      throw StateError('这条录音不可用');
    }
    final identity = library.assetForPath(recording.path!)?.contentHash;
    if (identity == null || identity.isEmpty) {
      throw StateError('这条录音尚未登记音频身份，暂不能开放 MCP 读取');
    }
    await mcpPublicationDirectory;
    if (_mcpClosed) throw StateError('MCP publication is closed');
    _mcpGrants[_mcpId(ref)] = _McpGrant(ref, identity);
    _mcpGeneration++;
    _mcpHeartbeat ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_mcpClosed && _mcpGrants.isNotEmpty) _queueMcpWrite();
    });
    _scheduleMcpPublication();
    _queueMcpWrite();
    await flushMcpPublication();
    if (_mcpClosed) throw StateError('MCP publication is closed');
    if (mcpPublicationError != null) throw StateError(mcpPublicationError!);
    notifyListeners();
  }

  Future<void> revokeMcpAccess(RecordingReference ref) async {
    if (_mcpClosed) throw StateError('MCP publication is closed');
    _mcpGrants.remove(_mcpId(ref));
    _mcpGeneration++;
    _scheduleMcpPublication();
    _queueMcpWrite();
    await flushMcpPublication();
    if (_mcpClosed) throw StateError('MCP publication is closed');
    if (mcpPublicationError != null) throw StateError(mcpPublicationError!);
    notifyListeners();
  }

  MaterialPack? _mcpPack(RecordingReference ref) {
    final recording = recordingView(ref);
    final path = recording.path;
    if (path == null || library.assetForPath(path)?.trashed == true) {
      return null;
    }
    final identity = library.assetForPath(path)?.contentHash;
    if (identity == null || identity.isEmpty) return null;
    final current = analysis.results['${_referenceKey(ref)}/minutes'];
    if (recording.text.trim().isEmpty && current == null) return null;
    final metadata = _transcriptMetadata[_referenceKey(ref)];
    return MaterialPack(
      exportedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      material: PackMaterial(
        contentHash: identity,
        title: recording.title,
        source: recording.source,
        recordedAt: recording.recordedAt,
      ),
      transcript: recording.text.trim().isEmpty
          ? null
          : PackTranscript(
              text: recording.text,
              manual: recording.manuallyEdited ? recording.text : null,
              segments: recording.manuallyEdited
                  ? const []
                  : recording.segments,
              speakerAliases: speakerAliasesForPath(path),
              revision: metadata?.revision ?? 0,
              provider: metadata?.provider,
              sourceLanguage: metadata?.sourceLanguage,
            ),
      minutes: current == null ? null : PackMinutes(current: current),
      bookmarks: const [],
    );
  }

  bool _refreshMcpRecords() {
    final next = <String, dynamic>{};
    for (final entry in Map.of(_mcpGrants).entries) {
      final recording = recordingView(entry.value.reference);
      if (recording.path == null ||
          library.assetForPath(recording.path!)?.trashed == true ||
          library.assetForPath(recording.path!)?.contentHash !=
              entry.value.contentHash) {
        _mcpGrants.remove(entry.key);
        continue;
      }
      final pack = _mcpPack(entry.value.reference);
      if (pack != null) {
        next[entry.key] = MaterialPack.fromJson(pack.toJson()).toJson();
      }
    }
    final content = jsonEncode(next);
    _mcpContentError = null;
    if (content == _mcpContent) return false;
    _mcpContent = content;
    final publishedAt = DateTime.now().toUtc().toIso8601String();
    _mcpRecords = {
      for (final entry in next.entries)
        entry.key: {
          ...entry.value as Map<String, dynamic>,
          'exportedAt': publishedAt,
        },
    };
    _mcpGeneration++;
    return true;
  }

  void _scheduleMcpPublication() {
    if (_mcpNotifying) return;
    if (_mcpClosed) return;
    if (_mcpSyncConfig != null) {
      _mcpSyncDebounce?.cancel();
      _mcpSyncDebounce = Timer(const Duration(milliseconds: 400), () {
        _mcpSyncDebounce = null;
        if (_mcpClosed || _mcpSyncConfig == null || _mcpSyncInFlight != null) {
          return;
        }
        try {
          final localPacks = _collectMcpSyncPacks();
          final hasDirty = localPacks.entries.any(
            (e) => _mcpKnownRemoteShas[e.key] != _manifestSha256(e.value),
          );
          if (hasDirty) {
            unawaited(syncMcpNow());
          }
        } catch (_) {}
      });
    }
    if (_mcpGrants.isEmpty && _mcpRecords.isEmpty && _mcpContentError == null) {
      return;
    }
    try {
      final previous = mcpPublicationError;
      if (_refreshMcpRecords()) _queueMcpWrite();
      if (previous != mcpPublicationError) _notifyMcpStatus();
    } catch (_) {
      _mcpRecords = {};
      _mcpContent = '{}';
      _mcpGeneration++;
      _queueMcpWrite();
      final previous = mcpPublicationError;
      _mcpContentError = 'MCP 内容无法发布，请检查文字或纪要';
      if (previous != mcpPublicationError) _notifyMcpStatus();
    }
  }

  void _notifyMcpStatus() {
    if (_mcpClosed) return;
    _mcpNotifying = true;
    try {
      notifyListeners();
    } finally {
      _mcpNotifying = false;
    }
  }

  void _queueMcpWrite() {
    _mcpPending = _mcpPending
        .then((_) async {
          final directory = await mcpPublicationDirectory;
          final content = jsonEncode({
            'version': 1,
            'generation': _mcpGeneration,
            'expiresAt': DateTime.now()
                .toUtc()
                .add(const Duration(seconds: 15))
                .toIso8601String(),
            'records': _mcpClosed ? <String, dynamic>{} : _mcpRecords,
          });
          if (utf8.encode(content).length > MaterialPack.maxManifestBytes) {
            await writeFileAtomically(
              File(p.join(directory.path, 'live.json')),
              jsonEncode({
                'version': 1,
                'generation': _mcpGeneration,
                'expiresAt': DateTime.now().toUtc().toIso8601String(),
                'records': {},
              }),
            );
            throw StateError('MCP publication exceeds 32 MiB');
          }
          await writeFileAtomically(
            File(p.join(directory.path, 'live.json')),
            content,
          );
          final hadError = _mcpWriteError != null;
          _mcpWriteError = null;
          if (hadError) _notifyMcpStatus();
        })
        .catchError((Object _) {
          final previous = mcpPublicationError;
          _mcpWriteError = 'MCP 内容未能保存，访问将在15秒内失效';
          if (previous != mcpPublicationError) _notifyMcpStatus();
        });
  }

  Future<void> flushMcpPublication() async {
    var pending = _mcpPending;
    await pending;
    while (!identical(pending, _mcpPending)) {
      pending = _mcpPending;
      await pending;
    }
  }

  void _disposeMcpPublication() {
    _mcpClosed = true;
    _mcpHeartbeat?.cancel();
    _mcpSyncDebounce?.cancel();
    _mcpSyncDebounce = null;
    removeListener(_scheduleMcpPublication);
    analysis.removeListener(_scheduleMcpPublication);
    if (_mcpDirectoryPending != null) {
      _mcpGrants.clear();
      _mcpRecords = {};
      _mcpGeneration++;
      _queueMcpWrite();
      unawaited(
        _mcpPending.then((_) async {
          if (!_mcpOwnDirectory) return;
          try {
            await _mcpDirectory?.delete(recursive: true);
          } catch (_) {}
        }),
      );
    }
  }
}
