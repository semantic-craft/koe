// Android calendar scenario: Koe's system tasks write one test event into the
// Pixel's default calendar, read it back, update it in place, and see it as
// gone once deleted. Only the event created here is touched. Run with
// `scripts/android-check`, which grants READ/WRITE_CALENDAR first.
import 'package:device_calendar_plus/device_calendar_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:koe/platform/system_tasks.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('writes, reads back and loses a test calendar event', (
    tester,
  ) async {
    const tasks = ChannelSystemTasks();
    const event = SystemTaskTarget.event;
    expect(tasks.supports(event), isTrue);
    expect(tasks.supports(SystemTaskTarget.reminder), isFalse);
    expect(await tasks.requestAccess(event), isTrue);

    // A minute-aligned slot a year out, so it never sits among real plans.
    final now = DateTime.now();
    final start = DateTime(now.year + 1, now.month, now.day, 9, now.minute);
    final title = 'Koe 测试事件 ${now.millisecondsSinceEpoch}';
    final id = await tasks.save(
      event,
      title: title,
      start: start,
      end: start.add(const Duration(minutes: 30)),
      notes: '来自 Koe 真机验收，会自动删除',
    );
    var deleted = false;
    addTearDown(() async {
      if (!deleted) await DeviceCalendar.instance.deleteEvent(instanceId: id);
    });

    final read = await tasks.fetch(event, id);
    expect(read?.title, title);
    expect(read?.start, start);
    expect(read?.end, start.add(const Duration(minutes: 30)));

    final later = start.add(const Duration(hours: 2));
    expect(
      await tasks.save(
        event,
        existingId: id,
        title: '$title 改',
        start: later,
        end: read?.end,
      ),
      id,
    );
    final moved = await tasks.fetch(event, id);
    expect(moved?.title, '$title 改');
    expect(moved?.start, later);
    expect(moved?.end, later.add(const Duration(minutes: 30)));

    await DeviceCalendar.instance.deleteEvent(instanceId: id);
    deleted = true;
    expect(await tasks.fetch(event, id), isNull);
    await expectLater(
      tasks.save(event, existingId: id, title: title, start: start),
      throwsA(isA<SystemTasksUnavailable>()),
    );
  });
}
