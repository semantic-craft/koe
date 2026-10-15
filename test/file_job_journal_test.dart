import 'dart:io';
import 'package:anker_recorder/ai/engine_config.dart';
import 'package:anker_recorder/ai/speech_provider.dart';
import 'package:anker_recorder/ai/stt_types.dart';
import 'package:anker_recorder/state/file_job_journal.dart';
import 'package:anker_recorder/state/speech_configuration.dart';
import 'package:flutter_test/flutter_test.dart';

SpeechConfiguration config({
  String key = 'secret-not-on-disk',
  String url = 'https://example.com',
  String model = 'saved-model',
}) => SpeechConfiguration(
  provider: SttProvider.qwen,
  sourceLanguage: 'zh',
  targetLanguage: 'en',
  ownerLanguage: 'zh',
  guestLanguage: 'en',
  mode: SttDisplayMode.transcription,
  enabled: true,
  appleReady: false,
  appleTranslationReady: false,
  engines: {
    SttProvider.qwen: EngineConfig(apiKey: key, baseUrl: url, model: model),
  },
);
void main() {
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('file-journal-test-');
    file = File('${directory.path}/jobs.json');
  });
  tearDown(() => directory.delete(recursive: true));
  test(
    'queued task survives restart without credentials and pins model',
    () async {
      await FileJobJournal(
        file: file,
      ).enqueue('recording', '/audio.wav', config());
      expect(await file.readAsString(), isNot(contains('secret-not-on-disk')));
      final recovered = FileJobJournal(file: file);
      await recovered.load();
      final job = recovered.jobs['recording']!;
      expect(job.recoverable, isTrue);
      final resolved = job.resolve(
        config(key: 'rotated-key', model: 'new-model'),
      );
      expect(resolved.engineConfig(SttProvider.qwen).model, 'saved-model');
      expect(resolved.engineKey(SttProvider.qwen), 'rotated-key');
      expect(
        job
            .resolve(config(url: 'https://new.example'))
            .engineKey(SttProvider.qwen),
        isNull,
      );
    },
  );
  test(
    'uncertain request blocks automatic retry; known task resumes',
    () async {
      final journal = FileJobJournal(file: file);
      final job = await journal.enqueue('a', '/a.wav', config());
      job.stage = 'running';
      await journal.save();
      final unknown = FileJobJournal(file: file);
      await unknown.load();
      expect(unknown.jobs['a']!.recoverable, isFalse);
      expect(unknown.jobs['a']!.error, contains('重复计费'));
      job.taskId = 'remote-task';
      await journal.save();
      final known = FileJobJournal(file: file);
      await known.load();
      expect(known.jobs['a']!.recoverable, isTrue);
      final retry = await known.enqueue(
        'a',
        '/a.wav',
        config(model: 'different'),
        retry: true,
      );
      expect(retry.taskId, 'remote-task');
      expect(retry.config['model'], 'saved-model');
    },
  );
  test(
    'saved result survives; completed task deduplicates; rename and delete persist',
    () async {
      final journal = FileJobJournal(file: file);
      final job = await journal.enqueue('a', '/a.wav', config());
      job.stage = 'result';
      job.text = 'saved text';
      await journal.save();
      final recovered = FileJobJournal(file: file);
      await recovered.load();
      expect(recovered.jobs['a']!.text, 'saved text');
      expect(recovered.jobs['a']!.recoverable, isTrue);
      recovered.jobs['a']!.stage = 'complete';
      await recovered.save();
      expect(
        (await recovered.enqueue('a', '/a.wav', config())).recoverable,
        isFalse,
      );
      await recovered.rename('a', 'b', '/b.wav');
      final renamed = FileJobJournal(file: file);
      await renamed.load();
      expect(renamed.jobs['b']!.path, '/b.wav');
      await renamed.discard('b');
      final empty = FileJobJournal(file: file);
      await empty.load();
      expect(empty.jobs, isEmpty);
    },
  );
  test('corruption blocks both recovery and new requests', () async {
    await file.writeAsString('{broken');
    final journal = FileJobJournal(file: file);
    await expectLater(journal.load(), throwsFormatException);
    await expectLater(
      journal.enqueue('a', '/a.wav', config()),
      throwsFormatException,
    );
    expect(await file.readAsString(), '{broken');
  });
}
