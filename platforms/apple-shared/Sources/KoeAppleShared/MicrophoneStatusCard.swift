import SwiftUI

struct MicrophoneStatusCard: View {
    let store: HostSessionStore
    let microphone: MicrophoneSnapshot

    var body: some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle().fill(microphone.error != nil || microphone.phase == "paused" ? AppColors.warning : AppColors.danger)
                        .frame(width: 8, height: 8)
                    Text("\(microphone.phaseSummaryLabel)  \(microphone.inputLabel)")
                        .font(.system(size: AppFontSizes.sm, weight: .medium))
                    KoeBadge(microphone.inputBadge)
                    Spacer()
                    Text(TimeLabel.duration(microphone.durationMs))
                        .font(.system(size: AppFontSizes.md, weight: .semibold, design: .monospaced))
                }
                CaptureLevelMeter(level: microphone.level)
                if let error = microphone.error ?? microphone.interruption {
                    Text(error).font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.danger)
                }
                HStack(spacing: 10) {
                    if microphone.error != nil {
                        KoeActionButton("重试保存", systemImage: "arrow.clockwise", isPrimary: true) {
                            store.send("retry_microphone_save")
                        }
                        if microphone.phase != "saving" {
                            KoeActionButton("取消录音", systemImage: "xmark.circle") { store.send("cancel_microphone") }
                        }
                    } else if store.snapshot.allDay.state == "idle" {
                        if microphone.phase == "recording" {
                            KoeActionButton("暂停", systemImage: "pause.circle") { store.send("pause_microphone") }
                        } else if microphone.phase == "paused" {
                            KoeActionButton("继续", systemImage: "play.circle") {
                                NotificationCenter.default.post(name: Notification.Name("KoeResumeMicrophone"), object: nil)
                            }
                        }
                        if ["recording", "starting", "pausing", "paused"].contains(microphone.phase) {
                            KoeActionButton("停止并保存", systemImage: "stop.circle", isPrimary: true) {
                                store.send("stop_microphone")
                            }
                            KoeActionButton("取消录音", systemImage: "xmark.circle") { store.send("cancel_microphone") }
                        }
                    }
                    Spacer()
                }
            }
        }
    }
}

private struct CaptureLevelMeter: View {
    let level: Double
    private let barCount = 12
    var body: some View {
        let clamped = min(max(level, 0.0), 1.0)
        HStack(spacing: 5) {
            ForEach(0..<barCount, id: \.self) { index in
                let threshold = Double(index + 1) / Double(barCount)
                RoundedRectangle(cornerRadius: 2)
                    .fill(clamped >= threshold - 0.04 ? AppColors.accent : AppColors.bgSubtle)
                    .frame(maxWidth: .infinity).frame(height: 8)
            }
        }
    }
}
