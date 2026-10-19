import 'dart:io';

import 'package:flutter/foundation.dart';

import 'context_file.dart';
import 'source_pack.dart';

enum AskRole { user, koe }

/// [pending]: the request is out. Found after a restart it means the result
/// is unknown (and may have been billed), so a retry is the user's choice.
enum AskStatus { done, pending, failed }

class AskMessage {
  const AskMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.at,
    this.sources = const [],
    this.status = AskStatus.done,
    this.grounded = true,
    this.viaVoice = false,
    this.notice = false,
  });

  final String id;
  final AskRole role;
  final String text;
  final DateTime at;
  final List<SourceLine> sources;
  final AskStatus status;

  /// False when Koe found nothing to answer from and said so without asking
  /// the model.
  final bool grounded;

  /// The question came from hold-to-talk; [text] is what was recognized.
  final bool viaVoice;

  /// Koe's own status reply (such as delegation not being open yet); nothing
  /// was asked of the model and nothing was carried out.
  final bool notice;

  AskMessage copyWith({
    String? text,
    List<SourceLine>? sources,
    AskStatus? status,
    bool? grounded,
  }) => AskMessage(
    id: id,
    role: role,
    text: text ?? this.text,
    at: at,
    sources: sources ?? this.sources,
    status: status ?? this.status,
    grounded: grounded ?? this.grounded,
    viaVoice: viaVoice,
    notice: notice,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'role': role.name,
    'text': text,
    'at': at.toIso8601String(),
    if (sources.isNotEmpty) 'sources': [for (final s in sources) s.toJson()],
    'status': status.name,
    if (!grounded) 'grounded': false,
    if (viaVoice) 'viaVoice': true,
    if (notice) 'notice': true,
  };

  static AskMessage? decode(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final text = value['text'];
    final at = decodeTime(value['at']);
    final role = AskRole.values
        .where((item) => item.name == value['role'])
        .firstOrNull;
    if (id is! String || text is! String || at == null || role == null) {
      return null;
    }
    return AskMessage(
      id: id,
      role: role,
      text: text,
      at: at,
      sources: SourceLine.decodeAll(value['sources']),
      status:
          AskStatus.values
              .where((item) => item.name == value['status'])
              .firstOrNull ??
          AskStatus.done,
      grounded: value['grounded'] != false,
      viaVoice: value['viaVoice'] == true,
      notice: value['notice'] == true,
    );
  }
}

/// A spoken question that has been recorded but not yet sent: recognition is
/// running, failed, or was cut off by a restart. The audio stays on the phone
/// until its text is in the conversation, so nothing said is lost.
class AskVoiceClip {
  const AskVoiceClip({required this.path, required this.at, this.error});

  final String path;
  final DateTime at;

  /// Why the last recognition did not finish; null while it runs, or when
  /// the app stopped before it finished.
  final String? error;

  AskVoiceClip withError(String? error) =>
      AskVoiceClip(path: path, at: at, error: error);

  Map<String, Object?> toJson() => {
    'path': path,
    'at': at.toIso8601String(),
    if (error != null) 'error': error,
  };

  static AskVoiceClip? decode(Object? value) {
    if (value is! Map) return null;
    final path = value['path'];
    final at = decodeTime(value['at']);
    if (path is! String || at == null) return null;
    final error = value['error'];
    return AskVoiceClip(
      path: path,
      at: at,
      error: error is String ? error : null,
    );
  }
}

class AskSession {
  const AskSession({
    required this.id,
    required this.createdAt,
    this.messages = const [],
    this.draft = '',
    this.voice,
  });

  final String id;
  final DateTime createdAt;
  final List<AskMessage> messages;

  /// The unsent question, kept while the user reads a source.
  final String draft;

  /// The spoken question waiting to become text, if any.
  final AskVoiceClip? voice;

  String get title {
    final first = messages.where((m) => m.role == AskRole.user).firstOrNull;
    return first?.text ?? '新会话';
  }

  AskSession copyWith({
    List<AskMessage>? messages,
    String? draft,
    AskVoiceClip? voice,
    bool clearVoice = false,
  }) => AskSession(
    id: id,
    createdAt: createdAt,
    messages: messages ?? this.messages,
    draft: draft ?? this.draft,
    voice: clearVoice ? null : voice ?? this.voice,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'messages': [for (final m in messages) m.toJson()],
    if (draft.isNotEmpty) 'draft': draft,
    if (voice != null) 'voice': voice!.toJson(),
  };

  static AskSession? decode(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final createdAt = decodeTime(value['createdAt']);
    if (id is! String || createdAt == null) return null;
    final draft = value['draft'];
    return AskSession(
      id: id,
      createdAt: createdAt,
      messages: [
        for (final entry in value['messages'] as List? ?? const [])
          ?AskMessage.decode(entry),
      ],
      draft: draft is String ? draft : '',
      voice: AskVoiceClip.decode(value['voice']),
    );
  }
}

/// Ask Koe conversations in `ask.json`, newest first.
class AskStore extends ChangeNotifier {
  AskStore({File? file, bool inMemory = false})
    : _file = ContextFile(fileName, file: file, inMemory: inMemory);

  static const fileName = 'ask.json';

  final ContextFile _file;
  List<AskSession> _sessions = [];
  Future<void>? _loading;
  bool _disposed = false;
  String? recoveryNotice;

  /// Read answers aloud with a synthetic voice. Off unless the user turns it
  /// on.
  bool readAloud = false;

  Future<void> get idle => _file.idle;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final json = await _file.read();
      _sessions = [
        for (final entry in json?['sessions'] as List? ?? const [])
          ?AskSession.decode(entry),
      ];
      readAloud = json?['readAloud'] == true;
    } on FormatException {
      recoveryNotice = '问答记录无法读取，已另存旧文件';
    } catch (error) {
      recoveryNotice = '问答记录无法读取';
      debugPrint('[AskStore] load failed: $error');
    }
    notifyListeners();
  }

  List<AskSession> get sessions => List.unmodifiable(_sessions);

  AskSession? sessionById(String? id) =>
      id == null ? null : _sessions.where((s) => s.id == id).firstOrNull;

  Future<void> put(AskSession session) async {
    final previous = _sessions;
    _sessions = [
      session,
      for (final item in previous)
        if (item.id != session.id) item,
    ];
    try {
      await _file.write(_json());
    } catch (error) {
      _sessions = previous;
      debugPrint('[AskStore] save failed: $error');
      notifyListeners();
      throw StateError('问答保存失败，请检查存储空间');
    }
    notifyListeners();
  }

  /// Keeps the draft without reordering or failing loudly; it is a
  /// convenience, not a record.
  void saveDraft(String sessionId, String draft) {
    final index = _sessions.indexWhere((s) => s.id == sessionId);
    if (index < 0 || _sessions[index].draft == draft) return;
    _sessions = [..._sessions]
      ..[index] = _sessions[index].copyWith(draft: draft);
    _file.write(_json()).catchError((Object _) {});
  }

  Future<void> setReadAloud(bool value) async {
    if (readAloud == value) return;
    readAloud = value;
    notifyListeners();
    try {
      await _file.write(_json());
    } catch (error) {
      debugPrint('[AskStore] save failed: $error');
    }
  }

  Map<String, Object?> _json() => {
    'version': 1,
    if (readAloud) 'readAloud': true,
    'sessions': [for (final item in _sessions) item.toJson()],
  };

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
