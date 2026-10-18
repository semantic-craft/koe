import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ai/engine_config.dart';
import '../ai/speech_provider.dart';
import '../ai/stt_types.dart';
import 'speech_configuration.dart';

SttSegment? _decodeSegment(Object? value) {
  if (value is! Map) return null;
  final text = value['text'];
  final startMs = value['startMs'];
  final endMs = value['endMs'];
  final speaker = value['speaker'];
  if (text is! String || text.trim().isEmpty || startMs is! int) return null;
  if (startMs < 0 || endMs != null && (endMs is! int || endMs < startMs)) {
    return null;
  }
  return SttSegment(
    text: text.trim(),
    startMs: startMs,
    endMs: endMs as int?,
    speaker: speaker is String && speaker.trim().isNotEmpty
        ? speaker.trim()
        : null,
    speakerChanged: value['speakerChanged'] == true,
  );
}

/// No credentials are serialized. A recovered job uses the credential for its
/// saved provider; its endpoint, model and language never follow new settings.
class FileJob {
  FileJob({required this.key, required this.path, required this.config});
  String key;
  String path;
  final Map<String, dynamic> config;
  String stage = 'queued';
  String? taskId;
  String? audioHash;
  bool audioChanged = false;
  String? text;
  String? language;
  String? error;
  List<SttSegment> segments = const [];
  bool get recoverable =>
      stage == 'queued' ||
      stage == 'result' ||
      (stage == 'running' && taskId != null);
  Map<String, dynamic> toJson() => {
    'key': key,
    'path': path,
    'config': config,
    'stage': stage,
    'taskId': taskId,
    'audioHash': audioHash,
    'audioChanged': audioChanged,
    'text': text,
    'language': language,
    'error': error,
    'segments': segments
        .map(
          (s) => {
            'text': s.text,
            'startMs': s.startMs,
            'endMs': s.endMs,
            if (s.speaker != null) 'speaker': s.speaker,
            if (s.speakerChanged) 'speakerChanged': true,
          },
        )
        .toList(),
    'operation': 'transcription',
  };
  factory FileJob.fromJson(Map<String, dynamic> json) {
    final job = FileJob(
      key: json['key'] as String,
      path: json['path'] as String,
      config: Map<String, dynamic>.from(json['config'] as Map),
    );
    if (job.config['version'] != 1 ||
        SttProvider.parse(job.config['provider']) == null ||
        job.config['sourceLanguage'] is! String ||
        job.config['targetLanguage'] is! String ||
        job.config['ownerLanguage'] is! String ||
        job.config['guestLanguage'] is! String ||
        !SttDisplayMode.values.any((m) => m.name == job.config['mode'])) {
      throw const FormatException('Invalid task configuration');
    }
    job.stage = json['stage'] as String;
    if (!{
      'queued',
      'running',
      'result',
      'complete',
      'failed',
    }.contains(job.stage)) {
      throw const FormatException('Unknown task stage');
    }
    job.taskId = json['taskId'] as String?;
    job.audioHash = json['audioHash'] as String?;
    job.audioChanged = json['audioChanged'] == true;
    job.text = json['text'] as String?;
    job.language = json['language'] as String?;
    job.error = json['error'] as String?;
    final rawSegments = json['segments'];
    if (rawSegments is List) {
      job.segments = rawSegments
          .map(_decodeSegment)
          .whereType<SttSegment>()
          .toList(growable: false);
    }
    if (job.stage == 'result' && job.text == null) {
      throw const FormatException('Missing task result');
    }
    if (job.stage == 'running' && job.taskId == null) {
      job.error = '上次请求结果未确认；重试可能重复计费';
    }
    if (SttProvider.parse(job.config['provider'])?.retired == true &&
        job.stage != 'complete' &&
        job.stage != 'result') {
      job.stage = 'failed';
      job.error = '原语音服务已停用，录音已保留；请选择千问或豆包后手动重试';
    }
    return job;
  }
  static Map<String, dynamic> snapshot(SpeechConfiguration c) => {
    'version': 1,
    'provider': c.provider.name,
    'sourceLanguage': c.sourceLanguage,
    'targetLanguage': c.targetLanguage,
    'ownerLanguage': c.ownerLanguage,
    'guestLanguage': c.guestLanguage,
    'mode': c.mode.name,
    'baseUrl': c.engineConfig(c.provider).baseUrl,
    'model': c.engineConfig(c.provider).model,
  };
  SpeechConfiguration resolve(SpeechConfiguration current) {
    final provider = SttProvider.values.byName(config['provider'] as String);
    final savedUrl = config['baseUrl'] as String?;
    final credential = current.engineConfig(provider);
    // Never send an existing credential to a different historical endpoint.
    final key = credential.baseUrl == savedUrl ? credential.apiKey : null;
    return SpeechConfiguration(
      provider: provider,
      sourceLanguage: config['sourceLanguage'] as String,
      targetLanguage: config['targetLanguage'] as String,
      ownerLanguage: config['ownerLanguage'] as String,
      guestLanguage: config['guestLanguage'] as String,
      mode: SttDisplayMode.values.byName(config['mode'] as String),
      enabled: true,
      appleReady: current.appleReady,
      appleTranslationReady: current.appleTranslationReady,
      engines: {
        provider: EngineConfig(
          apiKey: key,
          baseUrl: savedUrl,
          model: config['model'] as String?,
        ),
      },
    );
  }
}

/// Atomic, ordered snapshots. A corrupt journal fails closed instead of
/// becoming an empty queue and silently resubmitting previously billed work.
///
/// Device file ids whose latest retrieval was kept without the done signal /
/// every byte live in [incompleteRetrievals], saved next to the journal as
/// `incomplete_retrievals.json` (a plain list of ids, no credentials). They
/// survive a restart so a partial file that passes the 95% size check is
/// pulled again instead of counting as exported.
class FileJobJournal {
  FileJobJournal({this.file, this.inMemory = false});
  final File? file;
  final bool inMemory;
  final Map<String, FileJob> jobs = {};
  final Set<int> incompleteRetrievals = {};
  Future<void>? _loading;
  Future<void> _writing = Future.value();
  Future<File> _file() async =>
      file ??
      File(
        p.join(
          (await getApplicationDocumentsDirectory()).path,
          'AnkerRecorder',
          'file_jobs.json',
        ),
      );
  Future<File> _incompleteFile() async =>
      File(p.join((await _file()).parent.path, 'incomplete_retrievals.json'));

  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    if (inMemory) return;
    // Read before the journal so a corrupt journal cannot hide these ids.
    // An unreadable list only loses the re-pull hint, never billed work.
    try {
      final incomplete = await _incompleteFile();
      if (await incomplete.exists()) {
        incompleteRetrievals.addAll(
          (jsonDecode(await incomplete.readAsString()) as List)
              .whereType<int>(),
        );
      }
    } catch (_) {}
    final source = await _file();
    if (!await source.exists()) return;
    final parsed = (jsonDecode(await source.readAsString()) as List)
        .map((j) => FileJob.fromJson(Map<String, dynamic>.from(j as Map)))
        .toList();
    for (final job in parsed) {
      jobs[job.key] = job;
    }
  }

  Future<void> save() async {
    await load();
    final snapshot = jsonEncode(jobs.values.map((j) => j.toJson()).toList());
    final operation = _writing.then((_) async {
      if (inMemory) return;
      final destination = await _file();
      await destination.parent.create(recursive: true);
      final temporary = File('${destination.path}.tmp');
      await temporary.writeAsString(snapshot, flush: true);
      await temporary.rename(destination.path);
    });
    _writing = operation.catchError((Object _) {});
    await operation;
  }

  /// Records whether the latest retrieval of device file [fileId] was
  /// complete; persists only when the set changes.
  Future<void> markRetrieval(int fileId, {required bool complete}) async {
    try {
      await load();
    } catch (_) {
      // A corrupt journal is reported elsewhere; the id list is separate.
    }
    final changed = complete
        ? incompleteRetrievals.remove(fileId)
        : incompleteRetrievals.add(fileId);
    if (!changed || inMemory) return;
    final snapshot = jsonEncode(incompleteRetrievals.toList()..sort());
    final operation = _writing.then((_) async {
      final destination = await _incompleteFile();
      await destination.parent.create(recursive: true);
      final temporary = File('${destination.path}.tmp');
      await temporary.writeAsString(snapshot, flush: true);
      await temporary.rename(destination.path);
    });
    _writing = operation.catchError((Object _) {});
    await operation;
  }

  Future<FileJob> enqueue(
    String key,
    String path,
    SpeechConfiguration config, {
    bool retry = false,
  }) async {
    await load();
    final existing = jobs[key];
    if (existing != null && !retry) return existing;
    // A known remote task and a saved result must be resumed, not paid twice.
    if (existing != null &&
        (existing.stage == 'result' ||
            existing.stage == 'running' && existing.taskId != null)) {
      return existing;
    }
    final job = FileJob(key: key, path: path, config: FileJob.snapshot(config));
    jobs[key] = job;
    await save();
    return job;
  }

  Future<void> discard(String key) async {
    await load();
    jobs.remove(key);
    await save();
  }

  Future<void> rename(String key, String nextKey, String path) async {
    await load();
    final job = jobs.remove(key);
    if (job == null) return;
    job.key = nextKey;
    job.path = path;
    jobs[nextKey] = job;
    await save();
  }
}
