import KoeAppleCore
import SwiftUI

struct IOSActiveCaptureBar: View {
    let store: HostSessionStore

    var body: some View {
        if let capture = store.activeCapture {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    captureInfo(capture)
                    Spacer(minLength: 4)
                    IOSCaptureActionButtons(store: store, mode: capture.mode)
                }
                VStack(alignment: .leading, spacing: 6) {
                    captureInfo(capture)
                    IOSCaptureActionButtons(store: store, mode: capture.mode)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(IOSColors.bgSubtle, in: RoundedRectangle(cornerRadius: IOSRadii.card))
            .overlay(
                RoundedRectangle(cornerRadius: IOSRadii.card)
                    .stroke(IOSColors.border, lineWidth: 1)
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("active-capture-bar")
        }
    }

    private func captureInfo(_ capture: ActiveCaptureSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: capture.mode.icon)
                .font(.system(size: AppFontSizes.sm, weight: .semibold))
                .foregroundStyle(capture.phase == "recording" ? IOSColors.danger : IOSColors.textSecondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(capture.mode.title)  \(phaseLabel(capture.phase))")
                    .font(.system(size: AppFontSizes.xs, weight: .semibold))
                    .foregroundStyle(IOSColors.textPrimary)
                    .lineLimit(1)
                Text(capture.error ?? "\(capture.sourceLabel)  \(TimeLabel.duration(capture.durationMs))")
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(IOSColors.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    private func phaseLabel(_ phase: String) -> String {
        switch phase {
        case "starting": "正在启动"
        case "recording": "正在记录"
        case "pausing": "正在暂停"
        case "paused": "已暂停"
        case "cancelling": "正在取消"
        default: "正在保存"
        }
    }

}

struct IOSCaptureActionButtons: View {
    let store: HostSessionStore
    let mode: CaptureMode
    var identifierPrefix = "capture-action"

    var body: some View {
        if let capture = store.activeCapture, capture.mode == mode {
            HStack(spacing: 6) {
                ForEach(capture.actions, id: \.self) { action in
                    IOSPrimaryButton(action.iosTitle, isPrimary: action == .end) {
                        store.performCaptureAction(action)
                    }
                    .accessibilityIdentifier("\(identifierPrefix)-\(action.rawValue)")
                }
            }
        }
    }
}

private extension CaptureAction {
    var iosTitle: String {
        switch self {
        case .pause: "暂停"
        case .resume: "继续"
        case .end: "结束"
        case .retryStop: "重试停止"
        case .retrySave: "重试保存"
        case .cancel: "取消"
        }
    }
}
