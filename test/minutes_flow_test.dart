import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'support/minutes_flow_scenario.dart';

void main() {
  testWidgets(
    'dictation minutes persist across controller restart and reopen',
    (tester) async {
      await minutesFlowScenario(tester);
      final proof = Platform.environment['KOE_MINUTES_PROOF_DIR'];
      if (proof != null) {
        await tester.runAsync(() async {
          await File('$proof/offline-proof.json').writeAsString(
            jsonEncode({
              'minutes_flow': {
                'durable_readback': true,
                'chapters': true,
                'overflow_checked': true,
                'reopened': true,
                'input_sha256': dictationInputSha,
              },
            }),
          );
        });
      }
    },
  );
}
