import EventKit
#if os(iOS)
import Flutter
import UserNotifications
#else
import FlutterMacOS
#endif

/// Writes the one Reminders item or Calendar event Koe made for a todo, and
/// reads it back. Called only after the user confirms an export in Koe. On
/// the Mac it also reads the events around a microphone take, which Koe
/// names the take after (#407).
enum SystemTasksBridge {
  private static let store = EKEventStore()
  #if os(iOS)
  private static let reminderPrefix = "koe.calendar.meeting."
  private static let pendingReminderKey = "calendarMeeting.pendingTitle"
  private static var channel: FlutterMethodChannel?
  private static let notificationDelegate = CalendarReminderNotificationDelegate()
  #endif

  static func configure(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.semanticcraft.koe/system_tasks", binaryMessenger: binaryMessenger)
    #if os(iOS)
    self.channel = channel
    let center = UNUserNotificationCenter.current()
    if center.delegate == nil {
      center.delegate = notificationDelegate
    }
    #endif
    channel.setMethodCallHandler { call, result in
      guard let args = call.arguments as? [String: Any],
        let target = args["target"] as? String
      else {
        result(FlutterError(code: "invalid_argument", message: nil, details: nil))
        return
      }
      let type: EKEntityType = target == "reminder" ? .reminder : .event
      switch call.method {
      case "access":
        requestAccess(type) { granted in DispatchQueue.main.async { result(granted) } }
      case "save":
        guard authorized(type) else {
          result(FlutterError(code: "denied", message: nil, details: nil))
          return
        }
        do {
          result(try save(type, args))
        } catch {
          result(FlutterError(code: "failed", message: nil, details: nil))
        }
      case "fetch":
        guard authorized(type) else {
          result(FlutterError(code: "denied", message: nil, details: nil))
          return
        }
        result(fetch(args["id"] as? String ?? ""))
      case "events":
        guard authorized(.event) else {
          result(FlutterError(code: "denied", message: nil, details: nil))
          return
        }
        result(events(from: date(args["start"]), to: date(args["end"])))
      #if os(iOS)
      case "scheduleMeetingReminders":
        scheduleMeetingReminders(args, result: result)
      case "consumePendingMeetingReminder":
        let title = UserDefaults.standard.string(forKey: pendingReminderKey)
        if title != nil {
          UserDefaults.standard.removeObject(forKey: pendingReminderKey)
        }
        result(title)
      #endif
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  #if os(iOS)
  fileprivate static func enqueueReminderTap(_ title: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    UserDefaults.standard.set(trimmed, forKey: pendingReminderKey)
    DispatchQueue.main.async {
      channel?.invokeMethod("onMeetingReminderTapped", arguments: trimmed)
    }
  }

  private static func scheduleMeetingReminders(
    _ args: [String: Any], result: @escaping FlutterResult
  ) {
    let meetings = args["meetings"] as? [[String: Any]] ?? []
    let nowMs = (args["now"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
    let center = UNUserNotificationCenter.current()
    center.getPendingNotificationRequests { existing in
      let previous = existing.map(\.identifier).filter { $0.hasPrefix(reminderPrefix) }
      if !previous.isEmpty {
        center.removePendingNotificationRequests(withIdentifiers: previous)
      }
      guard !meetings.isEmpty else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else {
          DispatchQueue.main.async { result(nil) }
          return
        }
        for item in meetings.prefix(24) {
          guard let id = item["id"] as? String,
            let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty,
            let startMs = (item["start"] as? NSNumber)?.doubleValue
          else { continue }
          let delaySeconds = max(1.0, (startMs - nowMs) / 1000.0)
          let content = UNMutableNotificationContent()
          content.title = "「\(title)」开始了"
          content.body = "点开进入 Koe 准备会议录音"
          content.sound = .default
          content.userInfo = ["koeMeetingTitle": title]
          let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: delaySeconds, repeats: false)
          let request = UNNotificationRequest(
            identifier: "\(reminderPrefix)\(id)", content: content, trigger: trigger)
          center.add(request, withCompletionHandler: nil)
        }
        DispatchQueue.main.async { result(nil) }
      }
    }
  }
  #endif

  private static func authorized(_ type: EKEntityType) -> Bool {
    let status = EKEventStore.authorizationStatus(for: type)
    if #available(iOS 17.0, macOS 14.0, *) { return status == .fullAccess }
    return status == .authorized
  }

  private static func requestAccess(_ type: EKEntityType, _ done: @escaping (Bool) -> Void) {
    if authorized(type) {
      done(true)
      return
    }
    if #available(iOS 17.0, macOS 14.0, *) {
      if type == .reminder {
        store.requestFullAccessToReminders { granted, _ in done(granted) }
      } else {
        store.requestFullAccessToEvents { granted, _ in done(granted) }
      }
    } else {
      store.requestAccess(to: type) { granted, _ in done(granted) }
    }
  }

  private struct Missing: Error {}

  private static func date(_ value: Any?) -> Date? {
    guard let ms = value as? NSNumber else { return nil }
    return Date(timeIntervalSince1970: ms.doubleValue / 1000)
  }

  private static func ms(_ date: Date) -> Int { Int(date.timeIntervalSince1970 * 1000) }

  private static func save(_ type: EKEntityType, _ args: [String: Any]) throws -> String {
    let title = args["title"] as? String ?? ""
    let notes = args["notes"] as? String
    let start = date(args["start"])
    var existing: EKCalendarItem?
    if let id = args["id"] as? String {
      // A deleted item must not be silently recreated as a duplicate.
      guard let found = store.calendarItem(withIdentifier: id) else { throw Missing() }
      existing = found
    }
    if type == .reminder {
      let reminder: EKReminder
      if let found = existing as? EKReminder {
        reminder = found
      } else {
        guard let calendar = store.defaultCalendarForNewReminders() else { throw Missing() }
        reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.notes = notes
      }
      reminder.title = title
      if let start {
        var units: Set<Calendar.Component> = [.year, .month, .day]
        if args["hasTime"] as? Bool ?? true { units.formUnion([.hour, .minute]) }
        reminder.dueDateComponents = Calendar.current.dateComponents(units, from: start)
      } else {
        reminder.dueDateComponents = nil
      }
      reminder.isCompleted = args["done"] as? Bool ?? false
      try store.save(reminder, commit: true)
      return reminder.calendarItemIdentifier
    }
    guard let start else { throw Missing() }
    let event: EKEvent
    if let found = existing as? EKEvent {
      event = found
    } else {
      guard let calendar = store.defaultCalendarForNewEvents else { throw Missing() }
      event = EKEvent(eventStore: store)
      event.calendar = calendar
      event.notes = notes
    }
    event.title = title
    event.startDate = start
    event.endDate = date(args["end"]) ?? start.addingTimeInterval(3600)
    try store.save(event, span: .thisEvent, commit: true)
    return event.calendarItemIdentifier
  }

  /// The events in the user's own calendars overlapping the range. Koe picks
  /// the meeting among them; subscribed and birthday calendars are not
  /// meetings the user attends.
  private static func events(from start: Date?, to end: Date?) -> [[String: Any]] {
    guard let start, let end else { return [] }
    let calendars = store.calendars(for: .event).filter {
      $0.type != .subscription && $0.type != .birthday
    }
    if calendars.isEmpty { return [] }
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
    return store.events(matching: predicate).map { event in
      let attendees = event.attendees ?? []
      var people = attendees.map(person)
      if let organizer = event.organizer, !attendees.contains(where: { $0.url == organizer.url }) {
        people.insert(person(organizer), at: 0)
      }
      return [
        "id": event.calendarItemIdentifier,
        "title": event.title ?? "",
        "start": ms(event.startDate),
        "end": ms(event.endDate),
        "allDay": event.isAllDay,
        "canceled": event.status == .canceled,
        "declined": attendees.contains { $0.isCurrentUser && $0.participantStatus == .declined },
        "people": people,
      ]
    }
  }

  private static func person(_ participant: EKParticipant) -> [String: Any] {
    let kind: String
    switch participant.participantType {
    case .person: kind = "person"
    case .room: kind = "room"
    case .resource: kind = "resource"
    case .group: kind = "group"
    default: kind = "unknown"
    }
    var out: [String: Any] = [
      "kind": kind,
      "url": participant.url.absoluteString,
      "declined": participant.participantStatus == .declined,
    ]
    if let name = participant.name { out["name"] = name }
    return out
  }

  private static func fetch(_ id: String) -> [String: Any]? {
    guard !id.isEmpty, let item = store.calendarItem(withIdentifier: id) else { return nil }
    if let reminder = item as? EKReminder {
      var out: [String: Any] = ["title": reminder.title ?? "", "done": reminder.isCompleted]
      if let components = reminder.dueDateComponents,
        let due = Calendar.current.date(from: components)
      {
        out["start"] = ms(due)
      }
      return out
    }
    if let event = item as? EKEvent {
      return ["title": event.title ?? "", "start": ms(event.startDate), "end": ms(event.endDate)]
    }
    return nil
  }
}

#if os(iOS)
private final class CalendarReminderNotificationDelegate: NSObject,
  UNUserNotificationCenterDelegate
{
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if notification.request.identifier.hasPrefix("koe.calendar.meeting.") {
      if #available(iOS 14.0, *) {
        completionHandler([.banner, .list, .sound])
      } else {
        completionHandler([.alert, .sound])
      }
    } else {
      completionHandler([])
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let title = response.notification.request.content.userInfo["koeMeetingTitle"] as? String {
      SystemTasksBridge.enqueueReminderTap(title)
    }
    completionHandler()
  }
}
#endif
