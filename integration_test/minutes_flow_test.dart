import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../test/support/minutes_flow_scenario.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('iOS saves and reopens complete dictation chapters', (
    tester,
  ) async {
    await minutesFlowScenario(
      tester,
      screenshot: (name) async {
        await binding.takeScreenshot(name);
      },
    );
    binding.reportData = {
      ...?binding.reportData,
      'minutes_flow': {
        'durable_readback': true,
        'chapters': true,
        'overflow_checked': true,
        'reopened': true,
        'live_draft_recovered': true,
        'input_sha256': dictationInputSha,
      },
    };
  });
}
