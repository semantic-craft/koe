// #371: exercises the shipped Android decoder and sherpa native libraries.
// Supply the pinned production models and sherpa's 0-four-speakers-zh.wav
// through KOE_DIARIZATION_FIXTURES when running scripts/android-check.
// This is native/offline acceptance, not an independent Chinese DER benchmark.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:koe/ai/diarization_model_store.dart';
import 'package:koe/ai/speaker_diarization.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cached models distinguish speakers without network access', (
    tester,
  ) async {
    final support = await getApplicationSupportDirectory();
    final fixtures = Directory('${support.path}/diarization-fixtures');
    final client = MockClient((_) async {
      throw StateError('Offline inference attempted a network request');
    });
    final store = DiarizationModelStore(
      directory: fixtures,
      client: client,
      isWifiConnected: () async => false,
    );
    try {
      final watch = Stopwatch()..start();
      final result = await SherpaSpeakerDiarizer(
        modelStore: store,
      ).diarize('${fixtures.path}/0-four-speakers-zh.wav', expectedSpeakers: 4);
      expect(result.turns, isNotEmpty);
      expect(result.turns.map((turn) => turn.speaker).toSet(), hasLength(4));
      for (final turn in result.turns) {
        expect(turn.start, greaterThanOrEqualTo(Duration.zero));
        expect(turn.end, greaterThan(turn.start));
      }
      // ignore: avoid_print
      print(
        'KOE_DIARIZATION: ${result.turns.length} turns, '
        '4 speakers, ${watch.elapsedMilliseconds} ms, cached/offline',
      );
    } finally {
      store.dispose();
      client.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
