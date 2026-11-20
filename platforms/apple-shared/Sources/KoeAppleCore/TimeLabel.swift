import Foundation

public enum TimeLabel {
    public static func duration(_ ms: UInt64) -> String {
        String(format: "%02d:%02d", ms / 60_000, (ms / 1000) % 60)
    }

    public static func date(_ seconds: UInt64) -> String {
        Date(timeIntervalSince1970: Double(seconds)).formatted(.dateTime.month().day().hour().minute())
    }
}
