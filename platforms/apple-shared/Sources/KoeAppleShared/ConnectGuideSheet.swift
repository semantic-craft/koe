import AppKit
import SwiftUI

public struct ProductAssetImage: View {
    public let name: String
    public let size: CGFloat

    public init(name: String, size: CGFloat = 220) {
        self.name = name
        self.size = size
    }

    public static func resolveImageURL(named name: String) -> URL? {
        for ext in ["webp", "png"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "product") {
                return url
            }
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            for ext in ["webp", "png"] {
                let candidate = dir.appendingPathComponent("assets/product/\(name).\(ext)")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for ext in ["webp", "png"] {
            let candidate = cwd.appendingPathComponent("assets/product/\(name).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public var body: some View {
        Group {
            if let url = Self.resolveImageURL(named: name), let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: AppFontSizes.lg))
                    .foregroundStyle(AppColors.accent)
            }
        }
        .frame(width: size, height: size)
    }
}

struct PulsingRingIndicator: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let progress = (context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4)) / 1.4
            let ringSize = 18.0 + 32.0 * progress
            ZStack {
                Circle()
                    .stroke(AppColors.accent.opacity(0.9 * (1.0 - progress)), lineWidth: 2.5)
                    .frame(width: ringSize, height: ringSize)
                Circle()
                    .fill(AppColors.accent.opacity(0.28))
                    .frame(width: 24, height: 24)
                Circle()
                    .fill(AppColors.accent)
                    .frame(width: 10, height: 10)
            }
            .frame(width: 52, height: 52)
        }
    }
}

public struct ConnectGuideSheet: View {
    public let store: HostSessionStore

    public init(store: HostSessionStore) {
        self.store = store
    }

    private var device: DeviceSnapshot {
        store.snapshot.device
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let guide = device.guide {
                if guide.mode == "onboarding" {
                    onboardingContent(guide)
                } else {
                    connectGuideContent(guide)
                }
            }
        }
        .padding(28)
        .frame(width: 520)
        .background(AppColors.surface0, in: RoundedRectangle(cornerRadius: AppRadii.cardOuter))
        .overlay(RoundedRectangle(cornerRadius: AppRadii.cardOuter).stroke(AppColors.border))
        .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
        .foregroundStyle(AppColors.textPrimary)
        .preferredColorScheme(.light)
    }

    private func connectGuideContent(_ guide: DeviceGuideSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(guide.title)
                        .font(.system(size: AppFontSizes.lg, weight: .semibold))
                    Text(guide.subtitle)
                        .font(.system(size: AppFontSizes.sm))
                        .foregroundStyle(AppColors.textSecondary)
                }
                Spacer()
                KoeBadge(device.state, tint: statusTint)
            }

            HStack {
                Spacer()
                visualStage(imageName: guide.imageName, highlightTarget: guide.highlightTarget)
                Spacer()
            }
            .padding(.vertical, 6)
            .background(AppColors.surface1, in: RoundedRectangle(cornerRadius: AppRadii.cardOuter))
            .overlay(RoundedRectangle(cornerRadius: AppRadii.cardOuter).stroke(AppColors.border))

            VStack(alignment: .leading, spacing: 10) {
                instructionRow(step: "1", text: "将麦克风放入充电仓，确认触点贴合")
                instructionRow(step: "2", text: "短按充电仓下方按钮开启蓝牙广播完成连接")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.surface1, in: RoundedRectangle(cornerRadius: AppRadii.control))
            .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(AppColors.border))

            HStack(spacing: 10) {
                Circle()
                    .fill(statusTint)
                    .frame(width: 8, height: 8)
                Text(device.statusDetail)
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textSecondary)
                Spacer()
            }

            HStack(spacing: 10) {
                KoeActionButton("稍后连接") {
                    store.send(.deviceCloseGuide)
                }
                Spacer()
                KoeActionButton(
                    guide.primaryLabel,
                    systemImage: "antenna.radiowaves.left.and.right",
                    isPrimary: true
                ) {
                    NotificationCenter.default.post(name: Notification.Name("KoeRequestBleScan"), object: nil)
                }
            }
        }
    }

    private func onboardingContent(_ guide: DeviceGuideSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(guide.title)
                        .font(.system(size: AppFontSizes.lg, weight: .semibold))
                    Text(guide.subtitle)
                        .font(.system(size: AppFontSizes.sm))
                        .foregroundStyle(AppColors.textSecondary)
                }
                Spacer()
                KoeBadge("\(guide.step + 1) / \(max(guide.totalSteps, 1))", tint: AppColors.accent)
            }

            if guide.step == 0 {
                HStack(spacing: 14) {
                    batteryCard(
                        title: "麦克风",
                        imageName: "guide_connect_device",
                        percent: device.batteryPercent ?? 100,
                        charging: device.charging
                    )
                    batteryCard(
                        title: "充电仓",
                        imageName: "guide_connect_case",
                        percent: device.boxBatteryPercent ?? 100,
                        charging: device.boxCharging
                    )
                }
            } else {
                HStack {
                    Spacer()
                    visualStage(imageName: guide.imageName, highlightTarget: guide.highlightTarget)
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(AppColors.surface1, in: RoundedRectangle(cornerRadius: AppRadii.cardOuter))
                .overlay(RoundedRectangle(cornerRadius: AppRadii.cardOuter).stroke(AppColors.border))
            }

            HStack(spacing: 8) {
                ForEach(0..<max(guide.totalSteps, 1), id: \.self) { index in
                    Capsule()
                        .fill(index == guide.step ? AppColors.accent : AppColors.border)
                        .frame(width: index == guide.step ? 22 : 8, height: 6)
                }
                Spacer()
                KoeActionButton("跳过引导") {
                    store.send(.deviceCloseGuide)
                }
                KoeActionButton(guide.primaryLabel, isPrimary: true) {
                    store.send(.deviceOnboardingNext)
                }
            }
        }
    }

    private func visualStage(imageName: String, highlightTarget: String) -> some View {
        let stageSize: CGFloat = 220
        return ZStack(alignment: .topLeading) {
            ProductAssetImage(name: imageName, size: stageSize)
            if let point = highlightPoint(for: highlightTarget, size: stageSize) {
                PulsingRingIndicator()
                    .position(x: point.x, y: point.y)
            }
        }
        .frame(width: stageSize, height: stageSize)
    }

    private func highlightPoint(for target: String, size: CGFloat) -> CGPoint? {
        switch target {
        case "case_button":
            return CGPoint(x: size * 0.25, y: size * 0.80)
        case "record_button":
            return CGPoint(x: size * 0.765, y: size * 0.59)
        case "center":
            return CGPoint(x: size * 0.50, y: size * 0.50)
        default:
            return nil
        }
    }

    private func instructionRow(step: String, text: String) -> some View {
        HStack(spacing: 10) {
            Text(step)
                .font(.system(size: AppFontSizes.xs, weight: .semibold))
                .foregroundStyle(AppColors.onAccent)
                .frame(width: 20, height: 20)
                .background(AppColors.accent, in: Circle())
            Text(text)
                .font(.system(size: AppFontSizes.sm))
                .foregroundStyle(AppColors.textPrimary)
        }
    }

    private func batteryCard(title: String, imageName: String, percent: Int, charging: Bool) -> some View {
        let clamped = max(0, min(percent, 100))
        return VStack(spacing: 12) {
            ProductAssetImage(name: imageName, size: 104)
            HStack {
                Text(title)
                    .font(.system(size: AppFontSizes.sm, weight: .medium))
                Spacer()
                Text(charging ? "\(clamped)% 充电中" : "\(clamped)%")
                    .font(.system(size: AppFontSizes.xs, weight: .medium))
                    .foregroundStyle(clamped <= 20 ? AppColors.warning : AppColors.success)
            }
            ProgressView(value: Double(clamped), total: 100.0)
                .tint(clamped <= 20 ? AppColors.warning : AppColors.success)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(AppColors.surface1, in: RoundedRectangle(cornerRadius: AppRadii.cardOuter))
        .overlay(RoundedRectangle(cornerRadius: AppRadii.cardOuter).stroke(AppColors.border))
    }

    private var statusTint: Color {
        if device.connected { return AppColors.success }
        switch device.phase {
        case "scanning", "connecting", "handshaking":
            return AppColors.warning
        default:
            return AppColors.textMuted
        }
    }
}
