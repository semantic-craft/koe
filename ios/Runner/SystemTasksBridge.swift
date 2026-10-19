import EventKit
import Flutter

/// Writes the one Reminders item or Calendar event Koe made for a todo, and
/// reads it back. Called only after the user confirms an export in Koe.
enum SystemTasksBridge {
  private static let store = EKEventStore()

  static func configure(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.semanticcraft.koe/system_tasks", binaryMessenger: binaryMessenger)
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
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func authorized(_ type: EKEntityType) -> Bool {
    let status = EKEventStore.authorizationStatus(for: type)
    if #available(iOS 17.0, *) { return status == .fullAccess }
    return status == .authorized
  }

  private static func requestAccess(_ type: EKEntityType, _ done: @escaping (Bool) -> Void) {
    if authorized(type) {
      done(true)
      return
    }
    if #available(iOS 17.0, *) {
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
