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
  });

  static const prefix = 'KOEMCP1.';
  static final _ticketPattern = RegExp(r'KOEMCP1\.([A-Za-z0-9_-]{20,2048})');

  final String baseUrl;
  final String token;
  final McpSyncMode mode;

  Uri get mcpEndpoint => Uri.parse('$baseUrl/mcp');
  Uri get packsIndexUri => Uri.parse('$baseUrl/sync/packs');
  Uri packUri(String id) => Uri.parse('$baseUrl/sync/packs/$id');

  String get redactedLabel {
    final uri = Uri.tryParse(baseUrl);
    final hostPort = uri == null || uri.host.isEmpty
        ? baseUrl
        : (uri.hasPort ? '${uri.host}:${uri.port}' : uri.host);
    return '${mode.label} · $hostPort';
  }

  String encodePairingCode() {
    final payload = jsonEncode({
      'v': 1,
      'u': _normalizeBaseUrl(baseUrl),
      't': token,
      'm': mode.name,
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
  McpSyncState _mcpSyncState = const McpSyncState();
  Future<void>? _mcpSyncInFlight;
  Timer? _mcpSyncDebounce;
  bool _mcpSyncQueued = false;
  final Map<String, String> _mcpKnownRemoteShas = {};

  McpSyncConfig? get mcpSyncConfig => _mcpSyncConfig;
  McpSyncState get mcpSyncState => _mcpSyncState;

  void applySavedMcpSyncConfig(McpSyncConfig? config) {
    _mcpSyncConfig = config;
    _mcpSyncState = config == null
        ? const McpSyncState()
        : McpSyncState(
            phase: McpSyncPhase.idle,
            lastSyncedAt: _mcpSyncState.lastSyncedAt,
            syncedCount: _mcpSyncState.syncedCount,
          );
    if (config != null && !_mcpClosed) {
      unawaited(syncMcpNow());
    }
  }

  String buildAgentMcpSetupPrompt({required bool hasVps}) {
    if (hasVps) {
      return '''
请帮我在我的 VPS 上部署 Koe 的轻量同步与远程 HTTP MCP 服务（零第三方依赖，仅用 Python 3.10+ 标准库），并把它配置进我的 MCP 客户端（如 Magpie / Codex / Claude Code / Antigravity）：

1. 将当前仓库下的 `tools/koe-mcp/server.py` 上传到我的 VPS（例如 `/opt/koe-mcp/server.py`），并创建数据目录 `~/.koe/mcp-sync`。
2. 在 VPS 上执行以下命令生成 32 字节安全令牌与 Koe App 一键配对码（请把 `<你的域名或公网地址>` 换成实际 HTTPS 地址）：
   python3 /opt/koe-mcp/server.py --directory ~/.koe/mcp-sync --token-file ~/.koe/mcp-token --public-url https://<你的域名或公网地址>/mcp --mode vps --print-pairing
3. 用 systemd 或后台常驻方式启动 HTTP 服务（并通过 Caddy / Nginx 反代到该端口）：
   python3 /opt/koe-mcp/server.py --directory ~/.koe/mcp-sync --http-listen 127.0.0.1:8787 --token-file ~/.koe/mcp-token
4. 在本机的 Magpie 或 MCP 配置中添加 HTTP MCP 服务器：
   - 名称：`koe-minutes`
   - 运行方式：`HTTP`
   - URL：`https://<你的域名或公网地址>/mcp`
   - 请求头：`Authorization: Bearer <~/.koe/mcp-token 中的令牌>`
5. 最后，请把第 2 步输出的 `KOEMCP1.` 开头的一整串连接码直接发给我。我复制后回到 Koe App 点击「从剪贴板一键接入」即可自动完成手机与 Mac 同步配置。
'''.trim();
    }
    return '''
我没有单独的 VPS，请帮我在当前这台 Mac 上启动 Koe 的本地/局域网 HTTP MCP 与同步服务，并配置好我的 MCP 客户端（如 Magpie / Codex / Claude Code / Antigravity）：

1. 创建数据目录 `~/.koe/mcp-sync`，并查看这台 Mac 的局域网或 Tailscale IP（例如 `192.168.x.x`）。
2. 在 Koe 仓库根目录运行以下命令，生成安全令牌与 Koe App 一键配对码：
   python3 tools/koe-mcp/server.py --directory ~/.koe/mcp-sync --token-file ~/.koe/mcp-token --public-url http://<Mac局域网IP>:8787/mcp --mode lan --print-pairing
3. 将以下命令配置为 macOS 后台常驻服务（LaunchAgent 或后台进程）：
   python3 tools/koe-mcp/server.py --directory ~/.koe/mcp-sync --http-listen 0.0.0.0:8787 --token-file ~/.koe/mcp-token
4. 在本机的 Magpie 或 MCP 配置中添加 HTTP MCP 服务器：
   - 名称：`koe-minutes`
   - 运行方式：`HTTP`
   - URL：`http://127.0.0.1:8787/mcp`
   - 请求头：`Authorization: Bearer <~/.koe/mcp-token 中的令牌>`
5. 最后，请把第 2 步输出的 `KOEMCP1.` 开头的一整串连接码直接发给我。我复制后在手机或 Mac 的 Koe App 点击「从剪贴板一键接入」即可自动完成配置。
'''.trim();
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
