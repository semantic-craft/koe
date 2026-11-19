import SwiftUI

public struct CaptureView: View {
    let store: HostSessionStore
    public init(store: HostSessionStore) { self.store = store }

    private var device: DeviceSnapshot { store.device }
    private var capture: CaptureStudioSnapshot { store.captureStudio.studio }
    private var isRecordingLocked: Bool { store.captureStudio.isRecordingLocked }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(
                    title: "录音管理",
                    subtitle: "选择当前录音音源、控制系统音频双路采集，并取回录音豆上的离线录音文件。"
                )
                sourceSelectionDeck
                offlineFilesCard
                localAudioStorageCard
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
                            Text("当前生效音源").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                            Button { store.send(.selectCaptureSource(source: "auto")) } label: {
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
                            KoeBadge(isAuto ? "\(capture.selectedBadge) / 自动优先" : "\(capture.selectedBadge) / 手动指定")
                        }
                    }
                    Spacer()
                    Text("连接录音豆时优先使用硬件录音，断开后自动切回 Mac 麦克风。")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 260, alignment: .trailing)
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
                VStack(alignment: .leading, spacing: 10) {
                    Text("系统音频采集").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                    systemAudioToggle
                }
            }
        }
    }

    private var systemAudioToggle: some View {
        let on = capture.includeSystemAudio
        let available = capture.canIncludeSystemAudio
        return HStack(spacing: 8) {
            Button { store.send(.setCaptureSystemAudio(enabled: !on)) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2")
                        .foregroundStyle(on && available ? AppColors.accent : AppColors.textSecondary)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("同时采集系统音频").font(.system(size: AppFontSizes.sm, weight: .medium))
                            if !available {
                                KoeBadge("录音豆模式仅录麦克风", tint: AppColors.textMuted)
                            }
                        }
                        Text("使用 Mac 麦克风进行随心闪记或实时纪要时，同步录制远端会议声音（不含 Koe 自身播放）。")
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.textMuted)
                    }
                    Spacer()
                    Image(systemName: on && available ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(on && available ? AppColors.accent : AppColors.textMuted)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(on && available ? AppColors.accentSoft : AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
                .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(on && available ? AppColors.accent : AppColors.border))
                .opacity(available ? 1.0 : 0.72)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            .disabled(isRecordingLocked || !available)
            .accessibilityLabel("同时采集系统音频")
            .accessibilityValue(on ? "已开启" : "已关闭")
            InfoTip("全天听记和录音豆只录麦克风。首次使用需在系统设置中允许 Koe 录制系统音频；任一路失败会标记采集不完整并保留另一路。")
        }
    }

    private var beanSourceCard: some View {
        let selected = capture.selectedSource == "bean"
        return Button { store.send(.selectCaptureSource(source: "bean")) } label: {
            HStack(spacing: 12) {
                Image(systemName: "waveform.badge.mic").foregroundStyle(selected ? AppColors.accent : AppColors.textSecondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(device.deviceName).font(.system(size: AppFontSizes.sm, weight: .medium))
                        KoeBadge("录音豆")
                        KoeBadge(device.state, tint: device.connected ? AppColors.success : AppColors.textMuted)
                    }
                    Text("按侧键默认记入随心闪记；设备电量、蓝牙连接与手机切换请点击左下角录音豆状态卡。")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                }
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

    private func macInputCard(_ input: AudioInputSnapshot) -> some View {
        let selected = capture.selectedSource == input.sourceKey
            || (capture.selectedSource == "system_default" && input.isDefault)
        let iconName = switch input.transport {
        case "bluetooth": "headphones"
        case "usb": "cable.connector"
        case "built_in": "laptopcomputer"
        default: "mic"
        }
        return Button { store.send(.selectCaptureSource(source: input.sourceKey)) } label: {
            HStack(spacing: 10) {
                Image(systemName: iconName).foregroundStyle(selected ? AppColors.accent : AppColors.textSecondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(input.name).font(.system(size: AppFontSizes.sm, weight: .medium))
                        KoeBadge(input.badge, tint: input.transport == "bluetooth" ? AppColors.accent : AppColors.textSecondary)
                        if input.isDefault { KoeBadge("系统默认", tint: AppColors.textMuted) }
                    }
                    Text("支持同时采集系统音频，用于双路录制线上会议")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                }
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
        return Button { store.send(.selectCaptureSource(source: "system_default")) } label: {
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

    private var offlineFilesCard: some View {
        let pendingCount = device.files.filter { !$0.synced }.count
        return KoeCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Label("录音豆离线文件", systemImage: "folder")
                        .font(.system(size: AppFontSizes.md, weight: .medium))
                    KoeBadge("\(device.files.count) 条文件", tint: AppColors.textMuted)
                    Spacer()
                    if device.connected {
                        KoeActionButton("刷新列表", systemImage: "arrow.clockwise") {
                            store.send(.deviceRefresh)
                            store.bridgeActions.flushBleOutbound()
                        }.disabled(device.busy)
                        KoeActionButton("全部取回", isPrimary: true) {
                            store.send(.deviceDownloadAll)
                            store.bridgeActions.flushBleOutbound()
                        }.disabled(device.busy || pendingCount == 0)
                    }
                }

                if device.connected {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("设备内部存储（\(device.deviceName)）")
                                .font(.system(size: AppFontSizes.xs))
                                .foregroundStyle(AppColors.textSecondary)
                            Spacer()
                            Text(device.storageLabel)
                                .font(.system(size: AppFontSizes.xs, design: .monospaced))
                                .foregroundStyle(AppColors.textSecondary)
                        }
                        if let ratio = device.storageUsedRatio {
                            ProgressView(value: ratio)
                                .accessibilityLabel("设备内部存储已用比例")
                        }
                    }
                    if device.busy && device.transferPhase == "pulling_offline" {
                        ProgressView(value: device.progress)
                            .accessibilityLabel("录音豆文件取回进度")
                    }
                    if device.files.isEmpty {
                        Text("设备上暂无离线录音文件。离线录音会在连接后显示并支持自动或手动取回。")
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.textMuted)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(device.files) { file in
                                offlineFileRow(file)
                            }
                        }
                    }
                } else {
                    HStack {
                        Text("未连接录音豆。请点击左下角录音豆状态卡完成蓝牙连接，以浏览和取回离线录音。")
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.textMuted)
                        Spacer()
                        KoeActionButton("连接录音豆", systemImage: "antenna.radiowaves.left.and.right") {
                            store.send(.deviceOpenGuide)
                            store.bridgeActions.requestBleScan()
                        }.disabled(device.busy)
                    }
                }
            }
        }
    }

    private func offlineFileRow(_ file: DeviceFileSnapshot) -> some View {
        HStack(spacing: 12) {
            Text(file.title)
                .font(.system(size: AppFontSizes.sm, weight: .medium))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
            Spacer()
            Text(TimeLabel.duration(file.durationMs))
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
            KoeBadge("Opus", tint: AppColors.textMuted)
            if file.downloading {
                HStack(spacing: 6) {
                    ProgressView(value: device.progress).frame(width: 72)
                    Text("\(Int((device.progress * 100).rounded()))%")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textSecondary)
                        .monospacedDigit()
                }
                KoeActionButton("传输中") {}.disabled(true)
            } else if file.synced {
                KoeBadge("已入库", tint: AppColors.success)
                if let recordId = file.recordId {
                    KoeActionButton("查看记录") {
                        store.send(.selectRecord(recordId: recordId))
                    }
                }
            } else {
                KoeBadge("待取回", tint: AppColors.textMuted)
                KoeActionButton("取回", isPrimary: true) {
                    store.send(.deviceDownload(fileId: file.id))
                    store.bridgeActions.flushBleOutbound()
                }.disabled(device.busy)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
    }

    private var localAudioStorageCard: some View {
        let storage = capture.audioStorage
        let sizeText = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: storage?.totalBytes ?? 0),
            countStyle: .file
        )
        let countText = "\(storage?.fileCount ?? 0) 个音频文件"
        return KoeCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Label("本机音频保存", systemImage: "internaldrive")
                        .font(.system(size: AppFontSizes.md, weight: .medium))
                    KoeBadge("已占 \(sizeText) / \(countText)", tint: AppColors.textMuted)
                    Spacer()
                    if let path = storage?.path, !path.isEmpty {
                        KoeActionButton("在访达中显示", systemImage: "folder") {
                            store.bridgeActions.revealPathInFinder(path)
                        }
                    }
                }
                if let path = storage?.path, !path.isEmpty {
                    HStack(spacing: 8) {
                        Text("保存位置")
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.textMuted)
                        Text(path)
                            .font(.system(size: AppFontSizes.xs, design: .monospaced))
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
                }
                Text("所有录音原文件默认保存在本机，音频与工作区数据分离保管，支持随时重新转写或回听核对。")
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textMuted)
            }
        }
    }
}
