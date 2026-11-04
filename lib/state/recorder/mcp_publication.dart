part of '../recorder_controller.dart';

class _McpGrant {
  const _McpGrant(this.reference, this.contentHash);
  final RecordingReference reference;
  final String contentHash;
}

mixin _RecorderMcpPublication on ChangeNotifier {
  // Provided by RecorderController and the recording stores.
  RecordingAnalysis get analysis;
  RecordingLibraryStore get library;
  Future<void> get _transcriptsLoaded;
  Future<void> get _libraryLoaded;
  Map<String, TranscriptMetadata> get _transcriptMetadata;
  String _referenceKey(RecordingReference ref);
  RecordingViewData recordingView(RecordingReference ref);
  Map<String, String> speakerAliasesForPath(String path);
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
