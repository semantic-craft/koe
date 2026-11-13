import SwiftUI

public struct CaptureView: View {
    let store: HostSessionStore
    public init(store: HostSessionStore) { self.store = store }

    private var device: DeviceSnapshot { store.snapshot.device }
    private var capture: CaptureStudioSnapshot { store.snapshot.capture }
    private var isRecordingLocked: Bool { store.snapshot.activeCapture != nil }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeading(title: "录音管理", subtitle: "选择录音豆、Mac 蓝牙耳机或本机麦克风。")
                sourceSelectionDeck
                if device.busy && device.transferPhase == "pulling_offline" {
                    ProgressView(value: device.progress)
                        .accessibilityLabel("录音豆文件取回进度")
                }
                if device.connected && !device.files.isEmpty {
                    deviceFiles
                }
            }
            .padding(30).frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    Text(device.connected ? "可从今天页或录音豆侧边按键开始录音。" : "连接录音豆后即可无线录音或取回离线文件。")
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
    private var deviceFiles: some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("录音豆文件").font(.system(size: AppFontSizes.md, weight: .medium))
                ForEach(device.files) { file in
                    HStack(spacing: 10) {
                        Text(file.title).font(.system(size: AppFontSizes.sm))
                        Text(TimeLabel.duration(file.durationMs)).font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.textMuted)
                        Spacer()
                        KoeActionButton("取回") {
                            store.send("device_download", ["fileId": file.id])
                            NotificationCenter.default.post(name: Notification.Name("KoeFlushBleOutbound"), object: nil)
                        }.disabled(device.busy)
                    }
                }
            }
        }
    }
}
