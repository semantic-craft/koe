import SwiftUI

struct MicrophoneCard: View {
    let store: HostSessionStore
    var body: some View {
        KoeCard {
            HStack(spacing: 12) {
                Label("Mac 麦克风", systemImage: "mic.fill")
                    .font(.system(size: AppFontSizes.sm, weight: .medium))
                if let microphone = store.snapshot.microphone {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label(microphone.phase))
                        Text("\(microphone.durationMs / 1000) 秒")
                    }.font(.system(size: AppFontSizes.xs))
                    Spacer()
                    if microphone.error != nil {
                        Button("重试保存") { store.send("retry_microphone_save") }
                        if microphone.phase != "saving" {
                            Button("取消录音", role: .destructive) { store.send("cancel_microphone") }
                        }
                    } else if ["recording", "starting", "pausing", "paused"].contains(microphone.phase) {
                        if microphone.phase == "recording" {
                            Button("暂停") { store.send("pause_microphone") }
                        } else if microphone.phase == "paused" {
                            Button("继续") {
                                NotificationCenter.default.post(name: Notification.Name("KoeResumeMicrophone"), object: nil)
                            }
                        }
                        Button("停止并保存") { store.send("stop_microphone") }
                        Button("取消录音", role: .destructive) { store.send("cancel_microphone") }
                    }
                    if let error = microphone.error {
                        InfoTip(error)
                    }
                } else {
                    Spacer()
                    Button("选择输入并录音") {
                        NotificationCenter.default.post(name: Notification.Name("KoeStartMicrophone"), object: nil)
                    }
                    .disabled(store.snapshot.lifecycle?.quitPhase != nil && store.snapshot.lifecycle?.quitPhase != "running")
                }
            }
        }
    }
    private func label(_ phase: String) -> String {
        switch phase {
        case "starting": return "等待麦克风权限"
        case "recording": return "正在录音"
        case "pausing": return "正在暂停并保存尾音"
        case "paused": return "已暂停"
        case "cancelling": return "正在取消录音"
        case "saving": return "正在保存"
        default: return "正在停止并保存"
        }
    }
}
