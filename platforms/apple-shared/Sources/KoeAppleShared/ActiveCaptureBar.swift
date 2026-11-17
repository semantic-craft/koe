import SwiftUI

extension HostSessionStore {
    public func startCapture(_ mode: CaptureMode, stayOnPage: Bool = false) {
        send(.startCaptureMode(mode: mode, stayOnPage: stayOnPage))
        bridgeActions.flushBleOutbound()
    }

    public func performCaptureAction(_ action: CaptureAction) {
        if action == .resume {
            bridgeActions.resumeMicrophone()
        } else {
            send(.captureAction(action: action))
            bridgeActions.flushBleOutbound()
        }
    }
}

struct ActiveCaptureBar: View {
    let store: HostSessionStore
    var isLiveMinutesSection: Bool = false

    var body: some View {
        if let capture = store.activeCapture {
            HStack(spacing: 12) {
                Image(systemName: capture.mode.icon)
                    .foregroundStyle(capture.phase == "recording" ? AppColors.danger : AppColors.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(capture.mode.title)  \(phaseLabel(capture))")
                        .font(.system(size: AppFontSizes.sm, weight: .semibold))
                    Text(capture.error ?? "\(capture.sourceLabel)  \(TimeLabel.duration(capture.durationMs))")
                        .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textSecondary)
                }
                if let level = capture.level {
                    ProgressView(value: level).frame(width: 68)
                        .accessibilityLabel("麦克风电平")
                }
                Spacer(minLength: 4)
                if (capture.mode == .meeting || capture.mode == .allDay) && !isLiveMinutesSection {
                    KoeActionButton("查看实时纪要", systemImage: "doc.text") {
                        store.send(.navigate(section: "live_minutes"))
                    }
                }
                ForEach(capture.actions, id: \.self) { action in
                    KoeActionButton(actionTitle(action)) { store.performCaptureAction(action) }
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(AppColors.bgSubtle)
            .overlay(alignment: .top) { Rectangle().fill(AppColors.border).frame(height: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("active-capture-bar")
        }
    }

    private func phaseLabel(_ capture: ActiveCaptureSnapshot) -> String {
        switch capture.phase {
        case "starting": "正在启动"
        case "recording": "正在记录"
        case "pausing": "正在暂停"
        case "paused": "已暂停"
        case "cancelling": "正在取消"
        default: "正在保存"
        }
    }

    private func actionTitle(_ action: CaptureAction) -> String {
        switch action {
        case .pause: "暂停"
        case .resume: "继续"
        case .end: "结束"
        case .retryStop: "重试停止"
        case .retrySave: "重试保存"
        case .cancel: "取消录音"
        }
    }
}
