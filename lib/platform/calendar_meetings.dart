import 'package:flutter/services.dart';

import '../state/recording_library.dart';

/// Reads the user's calendar for the meeting a Mac take was recorded in
/// (#407), so the take is named after it and its minutes know who was
/// invited.
abstract class CalendarMeetings {
  /// Asks for full calendar access when not yet decided; false when denied.
  /// The system asks only once, so later calls return at once.
  Future<bool> requestAccess();

  /// The meeting under way at [at] or about to start; null without one, or
  /// without access. Never asks for access.
  Future<RecordingMeeting?> meetingAt(DateTime at);
}

/// EventKit through `darwin/SystemTasksBridge.swift`, the bridge that also
/// exports todos.
class ChannelCalendarMeetings implements CalendarMeetings {
  const ChannelCalendarMeetings();

  static const _channel = MethodChannel('com.semanticcraft.koe/system_tasks');

  /// A take started this long before a meeting is taken to be for it.
  static const startingSoon = Duration(minutes: 5);

  @override
  Future<bool> requestAccess() async {
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
      final events = await _channel.invokeListMethod<Object?>('events', {
        'target': 'event',
        'start': at.millisecondsSinceEpoch,
        'end': at.add(startingSoon).millisecondsSinceEpoch,
      });
      return _meetingAmong(events ?? const [], at);
    } catch (_) {
      return null;
    }
  }
}

/// Of the events the bridge found, the one a take started at [at] was
/// recorded in: under way or starting within
/// [ChannelCalendarMeetings.startingSoon], the one whose start is nearest.
/// All-day, canceled and declined events are not meetings the user is in.
RecordingMeeting? _meetingAmong(List<Object?> events, DateTime at) {
  final soon = at.add(ChannelCalendarMeetings.startingSoon);
  Map<Object?, Object?>? best;
  Duration? bestGap;
  for (final event in events) {
    if (event is! Map) continue;
    final title = event['title'];
    final start = event['start'];
    final end = event['end'];
    if (title is! String || title.trim().isEmpty) continue;
    if (start is! int || end is! int) continue;
    if (event['allDay'] == true ||
        event['canceled'] == true ||
        event['declined'] == true) {
      continue;
    }
    final from = DateTime.fromMillisecondsSinceEpoch(start);
    final to = DateTime.fromMillisecondsSinceEpoch(end);
    if (!from.isBefore(soon) || !to.isAfter(at)) continue;
    final gap = from.difference(at).abs();
    if (bestGap == null || gap < bestGap) {
      best = event;
      bestGap = gap;
    }
  }
  if (best == null) return null;
  final people = best['people'];
  final names = <String>[];
  for (final person in people is List ? people : const []) {
    if (person is! Map || person['declined'] == true) continue;
    // Rooms, equipment and mailing lists are not people.
    if (const {'room', 'resource', 'group'}.contains(person['kind'])) continue;
    final name = _personName(person);
    if (name != null && !names.contains(name)) names.add(name);
  }
  return RecordingMeeting(
    title: (best['title'] as String).trim(),
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
