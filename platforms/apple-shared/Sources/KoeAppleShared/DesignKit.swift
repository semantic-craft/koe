import SwiftUI

public enum AppColors {
    public static let accent = Color(hex: 0xC4B5FD)
    public static let onAccent = Color(hex: 0x251D33)
    public static let accentSoft = Color(hex: 0x302938)
    public static let surface0 = Color(hex: 0x1A1A1D)
    public static let surface1 = Color(hex: 0x202024)
    public static let bgPanel = Color(hex: 0x141416)
    public static let bgSubtle = Color(hex: 0x252529)
    public static let border = Color(hex: 0x323237)
    public static let textPrimary = Color(hex: 0xEDECF2)
    public static let textSecondary = Color(hex: 0xBDB9C7)
    public static let textMuted = Color(hex: 0xAAA6B5)
    public static let success = Color(hex: 0x9AC9A7)
    public static let warning = Color(hex: 0xDDBC90)
    public static let danger = Color(hex: 0xEEA6A6)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

public enum AppFontSizes {
    public static let xs: CGFloat = 12
    public static let sm: CGFloat = 14
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 22
}

public enum AppRadii {
    public static let control: CGFloat = 6
    public static let cardOuter: CGFloat = 10
}

public struct KoeActionButton: View {
    private let title: String
    private let icon: String?
    private let primary: Bool
    private let action: () -> Void
    public init(_ title: String, systemImage: String? = nil, isPrimary: Bool = false, action: @escaping () -> Void) {
        self.title = title
        icon = systemImage
        primary = isPrimary
        self.action = action
    }
    public var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.system(size: AppFontSizes.xs, weight: .medium))
            .foregroundStyle(primary ? AppColors.onAccent : AppColors.textPrimary)
            .padding(.horizontal, 12).frame(minHeight: 34)
            .background(primary ? AppColors.accent : AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
            .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(primary ? AppColors.accent : AppColors.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

public struct KoeCard<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        content.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.surface1, in: RoundedRectangle(cornerRadius: AppRadii.cardOuter))
            .overlay(RoundedRectangle(cornerRadius: AppRadii.cardOuter).stroke(AppColors.border))
    }
}

struct KoeBadge: View {
    let text: String
    var tint: Color = AppColors.accent
    init(_ text: String, tint: Color = AppColors.accent) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text).font(.system(size: AppFontSizes.xs))
            .foregroundStyle(tint).padding(.horizontal, 7).padding(.vertical, 4)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: icon).font(.system(size: AppFontSizes.lg)).foregroundStyle(AppColors.accent)
            Text(title).font(.system(size: AppFontSizes.md, weight: .medium))
            Text(detail).font(.system(size: AppFontSizes.sm)).foregroundStyle(AppColors.textMuted)
                .multilineTextAlignment(.center).frame(maxWidth: 370)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 42)
    }
}

struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: AppFontSizes.lg, weight: .semibold))
            Text(subtitle).font(.system(size: AppFontSizes.sm)).foregroundStyle(AppColors.textMuted)
        }
    }
}

struct SourceLink: View {
    let source: SourceSnapshot
    let store: HostSessionStore
    var body: some View {
        Button {
            store.send("open_source", ["recordId": source.recordId, "segmentId": source.segmentId])
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.right")
                Text(source.title).lineLimit(1)
                Text(TimeLabel.duration(source.startMs)).monospacedDigit()
            }
            .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.accent)
            .frame(minHeight: 30, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(source.quote)
    }
}

public enum TimeLabel {
    public static func duration(_ ms: UInt64) -> String {
        String(format: "%02d:%02d", ms / 60_000, (ms / 1000) % 60)
    }
    static func date(_ seconds: UInt64) -> String {
        Date(timeIntervalSince1970: Double(seconds)).formatted(.dateTime.month().day().hour().minute())
    }
}
