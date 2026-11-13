import SwiftUI

struct AllDayCard: View {
    let store: HostSessionStore
    @State private var showDemo = false
    private var session: AllDaySnapshot { store.snapshot.allDay }
    private var active: Bool { session.state != "idle" }

    var body: some View {
        VStack(spacing: 14) {
            KoeCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("全天听记", systemImage: "sun.max")
                            .font(.system(size: AppFontSizes.md, weight: .medium))
                        Spacer()
                        KoeBadge(statusLabel, tint: statusTint)
                    }
                    Text(active ? "开始和结束语音输入，只圈定一段听写，不会关闭麦克风。" : "持续记录一天的对话，需要听写时再单独圈定一句。使用当前选中的录音音源。")
                        .font(.system(size: AppFontSizes.sm)).foregroundStyle(AppColors.textSecondary).lineSpacing(5)
                    HStack(spacing: 12) {
                        if active {
                            Text("已记录 \(session.segmentCount) 段")
                                .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                            Spacer()
                            KoeActionButton(store.snapshot.dictation.active ? "结束语音输入" : "开始语音输入",
                                            systemImage: store.snapshot.dictation.active ? "checkmark.circle" : "text.cursor",
                                            isPrimary: true) {
                                store.send("set_dictation_active", ["active": !store.snapshot.dictation.active])
                            }.disabled(session.state != "recording")
                            KoeActionButton("结束全天听记", systemImage: "stop.circle") {
                                store.send("stop_all_day")
                                flushBluetooth()
                            }.disabled(session.state == "finishing")
                        } else {
                            Text("音源：\(store.snapshot.capture.selectedLabel)")
                                .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                            Spacer()
                            KoeActionButton("开始全天听记", systemImage: "record.circle", isPrimary: true) {
                                let capture = store.snapshot.capture
                                var fields: [String: Any] = ["source": capture.selectedSource == "bean" ? "bean" : "microphone"]
                                if capture.selectedSource != "bean" { fields["inputId"] = capture.selectedInputId }
                                store.send("start_all_day", fields)
                                flushBluetooth()
                            }.disabled(!store.snapshot.capture.canStart)
                        }
                    }
                    if let message = session.message {
                        Text(message).font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.warning)
                    }
                    HStack {
                        KoeActionButton("查看演示", systemImage: "play.rectangle") { showDemo = true }
                        if !active {
                            KoeActionButton("选择录音音源", systemImage: "mic") { store.send("navigate", ["section": "capture"]) }
                        }
                    }
                }
            }
            if active, let microphone = store.snapshot.microphone {
                MicrophoneStatusCard(store: store, microphone: microphone)
            }
        }
        .sheet(isPresented: $showDemo) { AllDayDemoView() }
    }

    private var statusLabel: String {
        if !active { return "未开始" }
        if let microphone = store.snapshot.microphone {
            if microphone.error != nil { return "录音待处理" }
            if microphone.interruption != nil { return "录音中断" }
            return microphone.phaseSummaryLabel
        }
        return session.state == "finishing" ? "正在保存" : "持续录音中"
    }

    private var statusTint: Color {
        if !active { return AppColors.textMuted }
        if let microphone = store.snapshot.microphone, microphone.error != nil || microphone.interruption != nil {
            return AppColors.warning
        }
        return AppColors.success
    }

    private func flushBluetooth() {
        NotificationCenter.default.post(name: Notification.Name("KoeFlushBleOutbound"), object: nil)
    }
}
