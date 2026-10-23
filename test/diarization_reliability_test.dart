import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/audio/audio_transcoder.dart';
import 'package:koe/state/recorder_controller.dart';
import 'support/wav_fixture.dart';

class _ConversionProbe implements AudioTranscoder {
  @override
  Future<void> toWav(String input, String output) async {
    throw const AudioTranscodeException('normalization reached');
  }
}

class _HeldFile implements File {
  _HeldFile(this.file, this.entered, this.release);
  final File file;
  final Completer<void> entered;
  final Completer<void> release;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<int> length() => file.length();
  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    final bytes = await file.readAsBytes();
    if (!entered.isCompleted) entered.complete();
    await release.future;
    yield bytes;
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('koe-434-'));
  tearDown(() => dir.delete(recursive: true));

  test(
    'WAV is normalized before model loading, including device 48 kHz (#434)',
    () async {
      final bytes = wavBytes(List.filled(960, 0));
      final data = ByteData.sublistView(bytes);
      data.setUint32(24, 48000, Endian.little);
      data.setUint32(28, 96000, Endian.little);
      final file = File('${dir.path}/device.wav')..writeAsBytesSync(bytes);
      final store = DiarizationModelStore(
        directory: dir,
        isWifiConnected: () async => false,
      );
      addTearDown(store.dispose);
      await expectLater(
        SherpaSpeakerDiarizer(
          modelStore: store,
          transcoder: _ConversionProbe(),
        ).diarize(file.path),
        throwsA(
          isA<AudioTranscodeException>().having(
            (e) => e.message,
            'reason',
            'normalization reached',
          ),
        ),
      );
    },
  );

  test(
    'pause after delete leaves the model absent, including restart (#434)',
    () async {
      final store = DiarizationModelStore(directory: dir);
      addTearDown(store.dispose);
      await store.delete();
      await store.pause();
      expect(store.status, DiarizationModelStatus.notInstalled);
      final restarted = DiarizationModelStore(directory: dir);
      addTearDown(restarted.dispose);
      await restarted.refreshStatus();
      expect(restarted.status, DiarizationModelStatus.notInstalled);
    },
  );

  test('deletion wins over an older checksum finishing later (#434)', () async {
    final file = File('${dir.path}/model.onnx')..writeAsStringSync('good');
    final entered = Completer<void>();
    final release = Completer<void>();
    const spec = DiarizationModelFileSpec(
      id: 'one',
      fileName: 'model.onnx',
      expectedBytes: 4,
      sha256:
          '770e607624d689265ca6c44884d0807d9b054d23c473c106c72be9de08b7376c',
      modelScopeUrl: 'https://example.com/model',
      huggingFaceUrl: 'https://example.com/model',
    );
    final store = DiarizationModelStore(directory: dir, customSpecs: [spec]);
    addTearDown(store.dispose);
    final files = <String, File>{
      file.path: file,
      '${dir.path}/download.paused': File('${dir.path}/download.paused'),
      '${dir.path}/model.onnx.part': File('${dir.path}/model.onnx.part'),
    };
    await IOOverrides.runZoned(
      () async {
        final refreshing = store.refreshStatus();
        await entered.future;
        await store.delete();
        release.complete();
        await refreshing;
        expect(store.status, DiarizationModelStatus.notInstalled);
        expect(await file.exists(), isFalse);
      },
      createFile: (path) =>
          path == file.path ? _HeldFile(file, entered, release) : files[path]!,
    );
  });

  test(
    'a cleared single speaker can be assigned again without stale provider text (#434)',
    () async {
      final c = RecorderController(loadPersistedState: false);
      addTearDown(c.dispose);
      const path = '/tmp/1783917052.wav';
      c.rememberTranscript(
        path,
        '说话人 1：第一句',
        segments: [
          TranscriptSegment(
            text: '第一句',
            start: Duration.zero,
            end: const Duration(seconds: 1),
            speaker: '1',
            speakerChanged: true,
          ),
        ],
      );
      await c.setSegmentSpeaker(path, 0, '');
      expect(c.transcriptsByPath[path], '第一句');
      await c.setSegmentSpeaker(path, 0, '2');
      expect(c.transcriptsByPath[path], '说话人 2：第一句');
      expect(c.transcriptSegmentsForPath(path).single.speaker, '2');
    },
  );

  test(
    'manual segment correction updates provider text and rolls back on save failure (#434)',
    () async {
      var fail = false;
      final c = RecorderController(
        loadPersistedState: false,
        transcriptPersister: ({bool strict = false}) async {
          if (fail) throw StateError('disk');
        },
      );
      addTearDown(c.dispose);
      const path = '/tmp/1783917051.wav';
      c.rememberTranscript(
        path,
        '说话人 1：第一句\n说话人 2：第二句',
        segments: [
          TranscriptSegment(
            text: '第一句',
            start: Duration.zero,
            end: const Duration(seconds: 1),
            speaker: '1',
            speakerChanged: true,
          ),
          TranscriptSegment(
            text: '第二句',
            start: const Duration(seconds: 1),
            end: const Duration(seconds: 2),
            speaker: '2',
            speakerChanged: true,
          ),
        ],
      );
      await c.setSegmentSpeaker(path, 1, '1');
      expect(c.transcriptsByPath[path], '说话人 1：第一句\n第二句');
      fail = true;
      await expectLater(c.setSegmentSpeaker(path, 1, '3'), throwsStateError);
      expect(c.transcriptsByPath[path], '说话人 1：第一句\n第二句');
      expect(c.transcriptSegmentsForPath(path)[1].speaker, '1');
    },
  );
}
