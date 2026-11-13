import SwiftUI

public struct CaptureView: View {
    let store: HostSessionStore
    public init(store: HostSessionStore) { self.store = store }

    private var device: DeviceSnapshot { store.snapshot.device }
    private var capture: CaptureStudioSnapshot { store.snapshot.capture }
    private var isBeanLive: Bool {
        device.recording || device.stopping || device.transferPhase == "streaming_realtime"
    }
    private var isRecordingLocked: Bool { isBeanLive || store.snapshot.microphone != nil }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeading(title: "录音", subtitle: "选择录音豆、Mac 蓝牙耳机或本机麦克风，录音先保存在本机。")
                AllDayCard(store: store)
                if isBeanLive && store.snapshot.allDay.state == "idle" {
                    beanLiveCard
                }
                if let mic = store.snapshot.microphone, store.snapshot.allDay.state == "idle" {
                    microphoneLiveCard(mic)
                }
                sourceSelectionDeck
                if device.busy && device.transferPhase == "pulling_offline" {
                    offlineProgressCard
                } else if device.connected && !device.recording && !device.files.isEmpty {
                    offlineFilesCard
                }
            }
            .padding(30).frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var beanLiveCard: some View {
        let liveRecord = store.snapshot.activeLiveRecord
        return KoeCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle().fill(AppColors.danger).frame(width: 8, height: 8)
                    Text(device.stopping ? "正在等待录音豆停止" : "正在通过 \(device.deviceName) 录音")
                        .font(.system(size: AppFontSizes.sm, weight: .medium))
                    KoeBadge("录音豆")
                    Spacer()
                    Text(TimeLabel.duration(device.liveDurationMs))
                        .font(.system(size: AppFontSizes.md, weight: .semibold, design: .monospaced))
                    KoeActionButton(device.stopping ? "重试停止" : "停止录音", systemImage: "stop.circle") {
                        store.send("device_stop")
                        NotificationCenter.default.post(name: Notification.Name("KoeFlushBleOutbound"), object: nil)
                    }
                }
                if let caption = store.snapshot.liveCaption, !caption.text.isEmpty {
                    Text(caption.text).font(.system(size: AppFontSizes.sm)).lineLimit(3)
                } else {
                    Text(device.liveBytes > 0 ? "正在接收实时语音流 (\(device.liveBytes) B)" : "正在等待录音豆语音帧")
                        .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textSecondary)
                }
                if store.snapshot.speech.engine == "apple_speech" && store.snapshot.speech.appleState != "ready" {
                    HStack(spacing: 12) {
                        Text(store.snapshot.speech.appleMessage ?? "Apple 本机识别尚未就绪，原始录音会保留。")
                            .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                        Spacer()
                        KoeActionButton("打开设置", systemImage: "gearshape") {
                            store.send("navigate", ["section": "settings"])
                        }
                    }
                }
                if let liveRecord {
                    Button { store.send("select_record", ["recordId": liveRecord.id]) } label: {
                        HStack(spacing: 5) { Text("查看完整实时字幕"); Image(systemName: "chevron.right") }
                            .font(.system(size: AppFontSizes.xs, weight: .medium))
                            .foregroundStyle(AppColors.accent).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func microphoneLiveCard(_ mic: MicrophoneSnapshot) -> some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle().fill(mic.phase == "paused" ? AppColors.warning : AppColors.danger).frame(width: 8, height: 8)
                    Text("\(micPhaseLabel(mic.phase))  \(mic.inputLabel)")
                        .font(.system(size: AppFontSizes.sm, weight: .medium))
                    KoeBadge(mic.inputBadge)
                    Spacer()
                    Text(TimeLabel.duration(mic.durationMs))
                        .font(.system(size: AppFontSizes.md, weight: .semibold, design: .monospaced))
                }
                CaptureLevelMeter(level: mic.level)
                if let error = mic.error ?? mic.interruption {
                    Text(error).font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.danger)
                }
                HStack(spacing: 10) {
                    if mic.error != nil {
                        KoeActionButton("重试保存", systemImage: "arrow.clockwise", isPrimary: true) {
                            store.send("retry_microphone_save")
                        }
                        if mic.phase != "saving" {
                            KoeActionButton("取消录音", systemImage: "xmark.circle") { store.send("cancel_microphone") }
                        }
                    } else if ["recording", "starting", "pausing", "paused"].contains(mic.phase) {
                        if mic.phase == "recording" {
                            KoeActionButton("暂停", systemImage: "pause.circle") { store.send("pause_microphone") }
                        } else if mic.phase == "paused" {
                            KoeActionButton("继续", systemImage: "play.circle") {
                                NotificationCenter.default.post(name: Notification.Name("KoeResumeMicrophone"), object: nil)
                            }
                        }
                        KoeActionButton("停止并保存", systemImage: "stop.circle", isPrimary: true) {
                            store.send("stop_microphone")
                        }
                        KoeActionButton("取消录音", systemImage: "xmark.circle") { store.send("cancel_microphone") }
                    }
                    Spacer()
                }
            }
        }
    }

    private var sourceSelectionDeck: some View {
        let isAuto = capture.selectionMode == "auto"
        return KoeCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text("当前录音音源").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                            Button { store.send("select_capture_source", ["source": "auto"]) } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: isAuto ? "checkmark.circle.fill" : "sparkles")
                                    Text("自动优先")
                                }
                                .font(.system(size: AppFontSizes.xs, weight: .medium))
                                .foregroundStyle(isAuto ? AppColors.accent : AppColors.textSecondary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(isAuto ? AppColors.accentSoft : AppColors.bgSubtle, in: Capsule())
                                .overlay(Capsule().stroke(isAuto ? AppColors.accent : AppColors.border))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .disabled(isRecordingLocked)
                        }
                        HStack(spacing: 8) {
                            Text(capture.selectedLabel).font(.system(size: AppFontSizes.md, weight: .semibold))
                            KoeBadge(capture.selectedBadge)
                        }
                    }
                    Spacer()
                    primaryCaptureButton
                }
                Divider().overlay(AppColors.border)
                VStack(alignment: .leading, spacing: 10) {
                    Text("专属录音豆硬件").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                    beanSourceCard
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Mac 蓝牙与本机麦克风").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                    if capture.inputs.isEmpty {
                        fallbackSystemDefaultCard
                    } else {
                        ForEach(capture.inputs) { input in macInputCard(input) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var primaryCaptureButton: some View {
        if capture.selectedSource == "bean" && !device.connected {
            KoeActionButton("连接录音豆", systemImage: "antenna.radiowaves.left.and.right", isPrimary: true) {
                store.send("device_open_guide")
                NotificationCenter.default.post(name: Notification.Name("KoeRequestBleScan"), object: nil)
            }.disabled(device.busy || isRecordingLocked)
        } else if capture.selectedSource == "bean" && device.companionMode == "collar_standby" {
            KoeActionButton("打开设置调整模式", systemImage: "slider.horizontal.3", isPrimary: true) {
                store.send("navigate", ["section": "settings"])
            }
        } else if capture.selectedSource == "bean" {
            KoeActionButton("使用录音豆开始录音", systemImage: "record.circle", isPrimary: true) {
                store.send("device_start")
                NotificationCenter.default.post(name: Notification.Name("KoeFlushBleOutbound"), object: nil)
            }.disabled(!capture.canStart)
        } else {
            KoeActionButton("开始录音", systemImage: "mic.fill", isPrimary: true) {
                store.send("start_microphone", ["inputId": capture.selectedInputId])
            }.disabled(!capture.canStart)
        }
    }

    private var beanSourceCard: some View {
        let selected = capture.selectedSource == "bean"
        return HStack(spacing: 12) {
            Button { store.send("select_capture_source", ["source": "bean"]) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform.badge.mic").foregroundStyle(selected ? AppColors.accent : AppColors.textSecondary)
                        Text(device.deviceName).font(.system(size: AppFontSizes.sm, weight: .medium))
                        KoeBadge("录音豆")
                        KoeBadge(device.state, tint: device.connected ? AppColors.success : AppColors.textMuted)
                        Spacer()
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? AppColors.accent : AppColors.textMuted)
                    }
                    if device.connected {
                        HStack(spacing: 16) {
                            Text(device.batteryPercent.map { "电量 \($0)%" } ?? "电量 —")
                            Text("存储 \(device.storageLabel)")
                        }.font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textSecondary)
                    } else {
                        Text(device.statusDetail).font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                    }
                    Text(device.connected ? "点击上方按钮或短按录音豆侧边按键均可开始录音。" : "连接录音豆后即可无线录音或取回离线文件。")
                        .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            .disabled(isRecordingLocked)
            if !device.connected {
                KoeActionButton("连接", systemImage: "antenna.radiowaves.left.and.right") {
                    store.send("device_open_guide")
                    NotificationCenter.default.post(name: Notification.Name("KoeRequestBleScan"), object: nil)
                }.disabled(device.busy || isRecordingLocked)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? AppColors.accentSoft : AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
        .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(selected ? AppColors.accent : AppColors.border))
    }

    private func macInputCard(_ input: AudioInputSnapshot) -> some View {
        let selected = capture.selectedSource == input.sourceKey
            || (capture.selectedSource == "system_default" && input.isDefault)
        let iconName = switch input.transport {
        case "bluetooth": "headphones"
        case "usb": "cable.connector"
        case "built_in": "laptopcomputer"
        default: "mic"
        }
        return Button { store.send("select_capture_source", ["source": input.sourceKey]) } label: {
            HStack(spacing: 10) {
                Image(systemName: iconName).foregroundStyle(selected ? AppColors.accent : AppColors.textSecondary)
                Text(input.name).font(.system(size: AppFontSizes.sm, weight: .medium))
                KoeBadge(input.badge, tint: input.transport == "bluetooth" ? AppColors.accent : AppColors.textSecondary)
                if input.isDefault { KoeBadge("系统默认", tint: AppColors.textMuted) }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AppColors.accent : AppColors.textMuted)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AppColors.accentSoft : AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
            .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(selected ? AppColors.accent : AppColors.border))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .disabled(isRecordingLocked)
    }

    private var fallbackSystemDefaultCard: some View {
        let selected = capture.selectedSource == "system_default"
        return Button { store.send("select_capture_source", ["source": "system_default"]) } label: {
            HStack(spacing: 10) {
                Image(systemName: "mic").foregroundStyle(selected ? AppColors.accent : AppColors.textSecondary)
                Text("系统默认麦克风").font(.system(size: AppFontSizes.sm, weight: .medium))
                KoeBadge("系统默认", tint: AppColors.textSecondary)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AppColors.accent : AppColors.textMuted)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AppColors.accentSoft : AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
            .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(selected ? AppColors.accent : AppColors.border))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .disabled(isRecordingLocked)
    }

    private var offlineProgressCard: some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("正在取回录音", systemImage: "arrow.down.circle")
                        .font(.system(size: AppFontSizes.sm, weight: .medium))
                    Spacer()
                    Text("\(Int((device.progress * 100).rounded()))%")
                        .font(.system(size: AppFontSizes.xs, design: .monospaced)).foregroundStyle(AppColors.textSecondary)
                }
                ProgressView(value: device.progress)
            }
        }
    }

    private var offlineFilesCard: some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("录音豆待取回文件 (\(device.files.count))")
                    .font(.system(size: AppFontSizes.sm, weight: .medium))
                ForEach(device.files) { file in
                    HStack(spacing: 10) {
                        Text("#\(file.fileId)").font(.system(size: AppFontSizes.xs, design: .monospaced))
                        Text(TimeLabel.duration(file.durationMs))
                            .font(.system(size: AppFontSizes.xs, design: .monospaced)).foregroundStyle(AppColors.textSecondary)
                        Spacer()
                        KoeActionButton("取回") {
                            store.send("device_download", ["fileId": file.fileId])
                            NotificationCenter.default.post(name: Notification.Name("KoeFlushBleOutbound"), object: nil)
                        }.disabled(device.busy)
                    }
                }
            }
        }
    }

    private func micPhaseLabel(_ phase: String) -> String {
        switch phase {
        case "starting": "等待麦克风权限"
        case "recording": "正在录音"
        case "pausing": "正在暂停并保存尾音"
        case "paused": "已暂停"
        case "cancelling": "正在取消录音"
        case "saving": "正在保存"
        default: "正在停止并保存"
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
