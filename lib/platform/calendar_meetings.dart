import 'package:device_calendar_plus/device_calendar_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../state/recording_library.dart';
import 'device_kind.dart';

/// A calendar meeting starting soon or under way, used both to name a
/// microphone take (#407) and to schedule a phone recording reminder (#373).
class CalendarMeetingReminder {
  const CalendarMeetingReminder({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    this.participants = const [],
  });

  final String id;
  final String title;
  final DateTime start;
  final DateTime end;
  final List<String> participants;

  /// When the start-of-meeting reminder fires: at [start] (in UTC epoch time,
  /// so cross-timezone events trigger at the exact instant), or [now] if the
  /// meeting already started within the grace window.
  DateTime reminderAt(DateTime now) => start.isAfter(now) ? start : now;

  /// How long from [now] until the reminder fires; [Duration.zero] once
  /// [start] is reached.
  Duration delayFrom(DateTime now) {
    final diff = start.toUtc().difference(now.toUtc());
    return diff.isNegative ? Duration.zero : diff;
  }

  RecordingMeeting toRecordingMeeting() =>
      RecordingMeeting(title: title, participants: participants);
}

/// Reads the user's calendar for the meeting a Mac take was recorded in
/// (#407) and for upcoming meetings a phone reminds the user to record (#373).
abstract class CalendarMeetings {
  const CalendarMeetings();

  /// Asks for full calendar access when not yet decided; false when denied.
  /// The system asks only once, so later calls return at once.
  Future<bool> requestAccess();

  /// The meeting under way at [at] or about to start; null without one, or
  /// without access. Never asks for access.
  Future<RecordingMeeting?> meetingAt(DateTime at);

  /// Meetings starting in `[from, to]` (or started within [recentGrace] before
  /// [from] and still running), ordered by start time. Never asks for access.
  Future<List<CalendarMeetingReminder>> upcomingMeetings(
    DateTime from,
    DateTime to,
  ) async => const [];

  /// Schedules system local notifications for [meetings] on a phone and
  /// replaces any previously scheduled calendar reminders.
  Future<void> syncPhoneReminders(
    List<CalendarMeetingReminder> meetings, {
    required DateTime now,
  }) async {}

  /// Consumes the meeting title of a tapped reminder notification, if any.
  Future<String?> consumePendingReminderTap() async => null;

  /// Listens for reminder notification taps while the app is running.
  void setOnReminderTapped(Future<void> Function(String title)? handler) {}
}

/// EventKit through `darwin/SystemTasksBridge.swift`, the bridge that also
/// exports todos; on Android, `device_calendar_plus` for reading events and
/// `KoePlatformPlugin` for posting meeting start notifications.
class ChannelCalendarMeetings extends CalendarMeetings {
  // Keep the injection seam named while the field stays private.
  const ChannelCalendarMeetings({DeviceCalendar? androidCalendar})
  // ignore: prefer_initializing_formals
    : _androidCalendar = androidCalendar;

  final DeviceCalendar? _androidCalendar;
  DeviceCalendar get _calendar => _androidCalendar ?? DeviceCalendar.instance;

  static const _channel = MethodChannel('com.semanticcraft.koe/system_tasks');

  static bool get _onAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// A take started this long before a meeting is taken to be for it.
  static const startingSoon = Duration(minutes: 5);

  /// A meeting that started within this window before Koe checked still gets
  /// a reminder if it has not been reminded yet.
  static const recentGrace = Duration(minutes: 1);

  /// How far ahead Koe schedules local notifications for upcoming meetings.
  static const lookahead = Duration(hours: 24);

  @override
  Future<bool> requestAccess() async {
    if (_onAndroid) {
      try {
        final status = await _calendar.requestPermissions();
        return status == CalendarPermissionStatus.granted;
      } catch (_) {
        return false;
      }
    }
    try {
      return await _channel.invokeMethod<bool>('access', {'target': 'event'}) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<RecordingMeeting?> meetingAt(DateTime at) async {
    // Only names the take: nothing here may stop it from being saved.
    try {
      final events = await _rawEvents(at, at.add(startingSoon));
      return meetingAmongEvents(events, at);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<CalendarMeetingReminder>> upcomingMeetings(
    DateTime from,
    DateTime to,
  ) async {
    try {
      final events = await _rawEvents(from.subtract(recentGrace), to);
      return upcomingRemindersAmongEvents(events, from: from, to: to);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> syncPhoneReminders(
    List<CalendarMeetingReminder> meetings, {
    required DateTime now,
  }) async {
    if (!runsOnPhone) return;
    try {
      await _channel.invokeMethod<void>('scheduleMeetingReminders', {
        'target': 'event',
        'now': now.millisecondsSinceEpoch,
        'meetings': [
          for (final m in meetings)
            {
              'id': m.id,
              'title': m.title,
              'start': m.start.millisecondsSinceEpoch,
              'end': m.end.millisecondsSinceEpoch,
            },
        ],
      });
    } catch (_) {}
  }

  @override
  Future<String?> consumePendingReminderTap() async {
    if (!runsOnPhone) return null;
    try {
      final title = await _channel.invokeMethod<String>(
        'consumePendingMeetingReminder',
        {'target': 'event'},
      );
      final trimmed = title?.trim();
      return trimmed == null || trimmed.isEmpty ? null : trimmed;
    } catch (_) {
      return null;
    }
  }

  @override
  void setOnReminderTapped(Future<void> Function(String title)? handler) {
    if (!runsOnPhone) return;
    if (handler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onMeetingReminderTapped') {
        final title = (call.arguments as String?)?.trim();
        if (title != null && title.isNotEmpty) {
          await handler(title);
        }
      }
      return null;
    });
  }

  Future<List<Object?>> _rawEvents(DateTime start, DateTime end) async {
    if (_onAndroid) {
      final status = await _calendar.hasPermissions();
      if (status != CalendarPermissionStatus.granted) return const [];
      final calendars = await _calendar.listCalendars();
      final ownIds = [
        for (final cal in calendars)
          if (!cal.hidden && !cal.readOnly) cal.id,
      ];
      if (ownIds.isEmpty && calendars.isNotEmpty) return const [];
      final list = await _calendar.listEvents(
        start,
        end,
        calendarIds: ownIds.isEmpty ? null : ownIds,
      );
      return [for (final event in list) androidEventToMap(event)];
    }
    final events = await _channel.invokeListMethod<Object?>('events', {
      'target': 'event',
      'start': start.millisecondsSinceEpoch,
      'end': end.millisecondsSinceEpoch,
    });
    return events ?? const [];
  }
}

/// Maps an Android `device_calendar_plus` [Event] into the bridge map format
/// shared with `darwin/SystemTasksBridge.swift`.
@visibleForTesting
Map<String, Object?> androidEventToMap(Event event) {
  final people = <Map<String, Object?>>[];
  if (event.organizer case final organizer?) {
    people.add({
      'kind': 'person',
      'name': ?organizer.name,
      if (organizer.emailAddress != null)
        'url': 'mailto:${organizer.emailAddress}',
      'declined': false,
    });
  }
  for (final attendee in event.attendees ?? const <Attendee>[]) {
    people.add({
      'kind': attendee.role == AttendeeRole.nonParticipant ? 'room' : 'person',
      'name': ?attendee.name,
      if (attendee.emailAddress != null)
        'url': 'mailto:${attendee.emailAddress}',
      'declined': attendee.status == AttendeeStatus.declined,
    });
  }
  return {
    'id': event.instanceId,
    'title': event.title,
    'start': event.startDate.millisecondsSinceEpoch,
    'end': event.endDate.millisecondsSinceEpoch,
    'allDay': event.isAllDay,
    'canceled': event.status == EventStatus.canceled,
    'declined': false,
    'people': people,
  };
}

/// Of the events the bridge found, the one a take started at [at] was
/// recorded in: under way or starting within
/// [ChannelCalendarMeetings.startingSoon], the one whose start is nearest.
/// All-day, canceled and declined events are not meetings the user is in.
@visibleForTesting
RecordingMeeting? meetingAmongEvents(List<Object?> events, DateTime at) {
  final soon = at.add(ChannelCalendarMeetings.startingSoon);
  Map<Object?, Object?>? best;
  Duration? bestGap;
  for (final event in events) {
    final parsed = _parseMeetingEvent(event);
    if (parsed == null) continue;
    final from = parsed.start;
    final to = parsed.end;
    if (!from.isBefore(soon) || !to.isAfter(at)) continue;
    final gap = from.difference(at).abs();
    if (bestGap == null || gap < bestGap) {
      best = event as Map<Object?, Object?>;
      bestGap = gap;
    }
  }
  if (best == null) return null;
  final parsed = _parseMeetingEvent(best)!;
  return RecordingMeeting(title: parsed.title, participants: parsed.participants);
}

/// Filters and orders upcoming calendar events in `[from, to]` for phone
/// start-of-meeting reminders (#373).
///
/// - Skips all-day, canceled, and declined events, and events with blank titles.
/// - Compares instants in UTC epoch milliseconds so events created in another
///   timezone trigger at the exact moment they start.
/// - Includes meetings starting in `[from - recentGrace, to]` that have not
///   ended by [from].
@visibleForTesting
List<CalendarMeetingReminder> upcomingRemindersAmongEvents(
  List<Object?> events, {
  required DateTime from,
  required DateTime to,
  Duration recentGrace = ChannelCalendarMeetings.recentGrace,
}) {
  final earliestMs = from.subtract(recentGrace).millisecondsSinceEpoch;
  final fromMs = from.millisecondsSinceEpoch;
  final toMs = to.millisecondsSinceEpoch;
  final out = <CalendarMeetingReminder>[];
  final seenIds = <String>{};
  for (final event in events) {
    final parsed = _parseMeetingEvent(event);
    if (parsed == null) continue;
    final startMs = parsed.start.millisecondsSinceEpoch;
    final endMs = parsed.end.millisecondsSinceEpoch;
    if (startMs < earliestMs || startMs > toMs || endMs <= fromMs) continue;
    if (!seenIds.add(parsed.id)) continue;
    out.add(parsed);
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

CalendarMeetingReminder? _parseMeetingEvent(Object? event) {
  if (event is! Map) return null;
  final rawTitle = event['title'];
  final start = event['start'];
  final end = event['end'];
  if (rawTitle is! String || rawTitle.trim().isEmpty) return null;
  if (start is! int || end is! int || end <= start) return null;
  if (event['allDay'] == true ||
      event['canceled'] == true ||
      event['declined'] == true) {
    return null;
  }
  final title = rawTitle.trim();
  final rawId = event['id'];
  final id = rawId is String && rawId.trim().isNotEmpty
      ? '${rawId.trim()}@$start'
      : '$title@$start';
  final people = event['people'];
  final names = <String>[];
  for (final person in people is List ? people : const []) {
    if (person is! Map || person['declined'] == true) continue;
    // Rooms, equipment and mailing lists are not people.
    if (const {'room', 'resource', 'group'}.contains(person['kind'])) continue;
    final name = _personName(person);
    if (name != null && !names.contains(name)) names.add(name);
  }
  return CalendarMeetingReminder(
    id: id,
    title: title,
    start: DateTime.fromMillisecondsSinceEpoch(start),
    end: DateTime.fromMillisecondsSinceEpoch(end),
    participants: names,
  );
}

/// The name the calendar shows, else the part of the address before the @
/// (as omi does, `app/lib/pages/conversation_detail/widgets/calendar_event_sheets.dart:17`).
String? _personName(Map<Object?, Object?> person) {
  String? local(String address) {
    final value = address.split('@').first.trim();
    return value.isEmpty ? null : value;
  }

  final name = person['name'];
  if (name is String && name.trim().isNotEmpty) {
    return name.contains('@') ? local(name.trim()) : name.trim();
  }
  final url = person['url'];
  if (url is String && url.startsWith('mailto:')) {
    return local(url.substring('mailto:'.length));
  }
  return null;
}
