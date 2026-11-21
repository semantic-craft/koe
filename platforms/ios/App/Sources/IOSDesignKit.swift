import KoeAppleCore
import SwiftUI

struct IOSCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IOSColors.surface1, in: RoundedRectangle(cornerRadius: IOSRadii.card))
            .overlay(
                RoundedRectangle(cornerRadius: IOSRadii.card)
                    .stroke(IOSColors.border, lineWidth: 1)
            )
    }
}

struct IOSBadge: View {
    let text: String
    var tint: Color = IOSColors.accent

    init(_ text: String, tint: Color = IOSColors.accent) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: AppFontSizes.xs, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

struct IOSPrimaryButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    var systemImage: String?
    var isPrimary: Bool = true
    let action: () -> Void
    let minimumHeight: CGFloat

    init(
        _ title: String,
        systemImage: String? = nil,
        isPrimary: Bool = true,
        minimumHeight: CGFloat = 38,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isPrimary = isPrimary
        self.minimumHeight = minimumHeight
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: AppFontSizes.xs, weight: .semibold))
            .foregroundStyle(isPrimary ? IOSColors.onAccent : IOSColors.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: minimumHeight)
            .background(
                isPrimary ? IOSColors.accent : IOSColors.bgSubtle,
                in: RoundedRectangle(cornerRadius: IOSRadii.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: IOSRadii.control)
                    .stroke(isPrimary ? IOSColors.accent : IOSColors.border, lineWidth: 1)
            )
            .opacity(isEnabled ? 1.0 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct IOSInfoTip: View {
    let title: String
    let message: String
    @State private var isPresented = false

    init(_ message: String, title: String = "说明") {
        self.title = title
        self.message = message
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: AppFontSizes.sm))
                .foregroundStyle(IOSColors.textMuted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: AppFontSizes.sm, weight: .semibold))
                    .foregroundStyle(IOSColors.textPrimary)
                Text(message)
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(IOSColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: 280, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }
}

private struct IOSViewportHeight: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var iosViewportHeight: CGFloat {
        get { self[IOSViewportHeight.self] }
        set { self[IOSViewportHeight.self] = newValue }
    }
}

struct IOSContentHuggingSheet<Content: View>: View {
    private let minHeight: CGFloat
    private let maxHeight: CGFloat
    private let content: Content
    @Environment(\.iosViewportHeight) private var viewportHeight
    @State private var measuredHeight: CGFloat = 320

    init(
        minHeight: CGFloat = 220,
        maxHeight: CGFloat = 640,
        @ViewBuilder content: () -> Content
    ) {
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newHeight in
                    let clamped = min(max(newHeight + 24, minHeight), maxHeight)
                    if abs(clamped - measuredHeight) > 1 {
                        measuredHeight = clamped
                    }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(IOSColors.surface0)
        .presentationDetents(viewportHeight > 0 ? [.height(min(measuredHeight, viewportHeight * 0.9)), .large] : [.large])
        .presentationCornerRadius(20)
        .presentationDragIndicator(.visible)
    }
}

struct IOSChromeSurfaceModifier: ViewModifier {
    let fallbackColor: Color

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.background(.regularMaterial)
        } else {
            content.background(fallbackColor)
        }
    }
}

extension View {
    func iosChromeSurface(_ fallbackColor: Color = IOSColors.surface0) -> some View {
        modifier(IOSChromeSurfaceModifier(fallbackColor: fallbackColor))
    }
}

struct IOSSourceLink: View {
    let source: SourceSnapshot
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right")
                Text(source.title)
                    .lineLimit(1)
                Text(TimeLabel.duration(source.startMs))
                    .monospacedDigit()
            }
            .font(.system(size: AppFontSizes.xs, weight: .medium))
            .foregroundStyle(IOSColors.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(IOSColors.accentSoft, in: RoundedRectangle(cornerRadius: IOSRadii.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("跳转来源 \(source.title)")
    }
}

struct IOSEmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: AppFontSizes.lg))
                .foregroundStyle(IOSColors.accent)
            Text(title)
                .font(.system(size: AppFontSizes.md, weight: .semibold))
                .foregroundStyle(IOSColors.textPrimary)
            Text(detail)
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(IOSColors.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
    }
}
