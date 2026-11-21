import KoeAppleCore
import SwiftUI

struct IOSDeviceSheetView: View {
    let store: HostSessionStore
    @Environment(\.dismiss) private var dismiss

    private var isReleased: Bool { store.today.beanControlState == "released" }

    var body: some View {
        let device = store.device

        IOSContentHuggingSheet(minHeight: 340, maxHeight: 680) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: AppFontSizes.md))
                        .foregroundStyle(IOSColors.accent)
                    Text(device.deviceName)
                        .font(.system(size: AppFontSizes.md, weight: .semibold))
                        .foregroundStyle(IOSColors.textPrimary)
                        .lineLimit(1)
                    IOSBadge(
                        isReleased ? "已让出" : device.state,
                        tint: isReleased ? IOSColors.textMuted : (device.connected ? IOSColors.success : IOSColors.warning)
                    )
                    Spacer()
                    IOSPrimaryButton("完成", isPrimary: false) {
                        dismiss()
                    }
                    .accessibilityIdentifier("device-sheet-close")
                }

                Text(device.statusDetail)
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(IOSColors.textSecondary)

                IOSHostErrorBar(store: store)
                disconnectedScanButton

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                    ],
                    spacing: 10
                ) {
                    telemetryTile(
                        label: "录音豆电量",
                        value: device.batteryPercent.map { device.charging ? "\($0)% 充电中" : "\($0)%" } ?? "—"
                    )
                    telemetryTile(
                        label: "充电仓电量",
                        value: device.boxBatteryPercent.map { device.boxCharging ? "\($0)% 充电中" : "\($0)%" } ?? "—"
                    )
                    telemetryTile(
                        label: "固件版本",
                        value: device.firmwareVersion.isEmpty ? "—" : device.firmwareVersion
                    )
                    telemetryTile(
                        label: "设备存储",
                        value: device.storageLabel
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("蓝牙控制权")
                        .font(.system(size: AppFontSizes.xs, weight: .semibold))
                        .foregroundStyle(IOSColors.textPrimary)
                    HStack(spacing: 6) {
                        controlButton(
                            title: "当前 iPhone 连接",
                            active: !isReleased
                        ) {
                            if isReleased {
                                store.send(.deviceOpenGuide)
                                store.bridgeActions.requestBleScan()
                            }
                        }
                        .disabled(device.busy)

                        controlButton(
                            title: "让出控制权",
                            active: isReleased
                        ) {
                            if !isReleased {
                                store.send(.deviceRelease)
                            }
                        }
                        .disabled(isReleased || !store.canReleaseToPhone)
                    }
                    .padding(4)
                    .background(IOSColors.bgSubtle, in: RoundedRectangle(cornerRadius: IOSRadii.control))
                    .overlay(
                        RoundedRectangle(cornerRadius: IOSRadii.control)
                            .stroke(IOSColors.border, lineWidth: 1)
                    )
                }

                Toggle(
                    "启动时自动连接录音豆",
                    isOn: Binding(
                        get: { device.autoConnect },
                        set: { store.send(.setBleAutoConnect(enabled: $0)) }
                    )
                )
                .font(.system(size: AppFontSizes.xs, weight: .medium))
                .foregroundStyle(IOSColors.textPrimary)

                if let guide = device.guide {
                    IOSCard {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(guide.mode == "onboarding"
                                    ? "连接引导  \(guide.step + 1) / \(max(guide.totalSteps, 1))"
                                    : "连接引导")
                                    .font(.system(size: AppFontSizes.xs, weight: .semibold))
                                    .foregroundStyle(IOSColors.textMuted)
                                Spacer()
                                IOSPrimaryButton("关闭引导", isPrimary: false) {
                                    store.send(.deviceCloseGuide)
                                }
                            }
                            Text(guide.title)
                                .font(.system(size: AppFontSizes.sm, weight: .semibold))
                                .foregroundStyle(IOSColors.textPrimary)
                            Text(guide.subtitle)
                                .font(.system(size: AppFontSizes.xs))
                                .foregroundStyle(IOSColors.textSecondary)
                            guidePrimaryButton(guide)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("离线录音文件 (\(device.files.count))")
                            .font(.system(size: AppFontSizes.xs, weight: .semibold))
                            .foregroundStyle(IOSColors.textPrimary)
                        Spacer()
                        if !device.files.isEmpty {
                            IOSPrimaryButton("全部取回", isPrimary: false) {
                                store.send(.deviceDownloadAll)
                            }
                            .disabled(device.busy)
                        }
                    }

                    if device.files.isEmpty {
                        Text("设备内暂无待取回的离线文件。")
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(IOSColors.textMuted)
                    } else {
                        ForEach(device.files) { file in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.title)
                                        .font(.system(size: AppFontSizes.xs, weight: .medium))
                                        .foregroundStyle(IOSColors.textPrimary)
                                        .lineLimit(1)
                                    Text(TimeLabel.duration(file.durationMs))
                                        .font(.system(size: AppFontSizes.xs))
                                        .foregroundStyle(IOSColors.textMuted)
                                        .monospacedDigit()
                                }
                                Spacer()
                                if file.synced {
                                    IOSBadge("已取回", tint: IOSColors.success)
                                } else {
                                    IOSPrimaryButton(file.downloading ? "取回中" : "取回", isPrimary: false) {
                                        store.send(.deviceDownload(fileId: file.fileId))
                                    }
                                    .disabled(file.downloading || device.busy)
                                }
                            }
                            .padding(10)
                            .background(IOSColors.bgSubtle, in: RoundedRectangle(cornerRadius: IOSRadii.control))
                        }
                    }
                }

                HStack(spacing: 8) {
                    IOSPrimaryButton("刷新状态", systemImage: "arrow.clockwise", isPrimary: false) {
                        store.send(.deviceRefresh)
                        store.bridgeActions.flushBleOutbound()
                    }
                    .disabled(device.busy)

                    IOSPrimaryButton("连接引导", systemImage: "questionmark.circle", isPrimary: false) {
                        store.send(.deviceOpenGuide)
                    }
                }
            }
            .padding(20)
        }
    }

    var disconnectedScanButton: IOSPrimaryButton? {
        guard !store.device.connected, !isReleased else { return nil }
        return IOSPrimaryButton("扫描录音豆", systemImage: "antenna.radiowaves.left.and.right") {
            store.bridgeActions.requestBleScan()
        }
    }

    func guidePrimaryButton(_ guide: DeviceGuideSnapshot) -> IOSPrimaryButton? {
        switch guide.mode {
        case "connect_guide":
            return IOSPrimaryButton(guide.primaryLabel) { store.bridgeActions.requestBleScan() }
        case "onboarding":
            return IOSPrimaryButton(guide.primaryLabel) { store.send(.deviceOnboardingNext) }
        default:
            return nil
        }
    }

    private func telemetryTile(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(IOSColors.textMuted)
            Text(value)
                .font(.system(size: AppFontSizes.sm, weight: .semibold))
                .foregroundStyle(IOSColors.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IOSColors.bgSubtle, in: RoundedRectangle(cornerRadius: IOSRadii.control))
    }

    private func controlButton(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: AppFontSizes.xs, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? IOSColors.onAccent : IOSColors.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 34)
                .background(
                    active ? IOSColors.accent : Color.clear,
                    in: RoundedRectangle(cornerRadius: IOSRadii.control - 2)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
