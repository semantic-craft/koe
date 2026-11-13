import SwiftUI

extension CaptureMode {
    var title: String {
        switch self {
        case .quickNote: "随手记"
        case .allDay: "全天听记"
        case .meeting: "实时纪要"
        case .dictation: "语音输入"
        }
    }

    var purpose: String {
        switch self {
        case .quickNote: "快速留下一段想法"
        case .allDay: "持续记录，随时回看"
        case .meeting: "记录讨论并整理纪要"
        case .dictation: "将语音输入到光标位置"
        }
    }

    var icon: String {
        switch self {
        case .quickNote: "waveform"
        case .allDay: "sun.max"
        case .meeting: "person.2"
        case .dictation: "character.cursor.ibeam"
        }
    }
}

extension HostSessionStore {
    func startCapture(_ mode: CaptureMode) {
        send("start_capture_mode", ["mode": mode.rawValue])
        NotificationCenter.default.post(name: Notification.Name("KoeFlushBleOutbound"), object: nil)
    }
}

struct ActiveCaptureBar: View {
    let capture: ActiveCaptureSnapshot
    let store: HostSessionStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: capture.mode.icon)
                .foregroundStyle(capture.phase == "recording" ? AppColors.danger : AppColors.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("\(capture.mode.title)  \(phaseLabel)")
                    .font(.system(size: AppFontSizes.sm, weight: .semibold))
                Text(capture.error ?? "\(capture.sourceLabel)  \(TimeLabel.duration(capture.durationMs))")
                    .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textSecondary)
            }
            if let level = capture.level {
                ProgressView(value: level).frame(width: 68)
                    .accessibilityLabel("麦克风电平")
            }
            Spacer(minLength: 4)
            if store.snapshot.section != "live_minutes" {
                KoeActionButton("查看实时纪要", systemImage: "doc.text") {
                    store.send("navigate", ["section": "live_minutes"])
                }
            }
            ForEach(capture.actions, id: \.self) { action in
                KoeActionButton(actionTitle(action)) { perform(action) }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
        .background(AppColors.bgSubtle)
        .overlay(alignment: .top) { Rectangle().fill(AppColors.border).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("active-capture-bar")
    }

    private var phaseLabel: String {
        switch capture.phase {
        case "starting": "正在启动"
        case "recording": capture.dictating && capture.mode == .allDay ? "正在记录  语音输入中" : "正在记录"
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
        case .endDictation: "结束语音输入"
        case .retrySave: "重试保存"
        case .cancel: "取消录音"
        }
    }

    private func perform(_ action: CaptureAction) {
        if action == .resume {
            NotificationCenter.default.post(name: Notification.Name("KoeResumeMicrophone"), object: nil)
        } else {
            store.send("capture_action", ["action": action.rawValue])
            NotificationCenter.default.post(name: Notification.Name("KoeFlushBleOutbound"), object: nil)
        }
    }
}
