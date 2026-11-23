import SwiftUI

public struct BeanDevicePopoverView: View {
    let store: HostSessionStore
    @Environment(\.dismiss) private var dismiss

    public init(store: HostSessionStore) {
        self.store = store
    }

    public var body: some View {
        let device = store.device
        let isPhoneOwner = store.today.picker?.beanControlOwner == "phone"
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.mic")
                    .foregroundStyle(AppColors.accent)
                Text(device.deviceName)
                    .font(.system(size: AppFontSizes.sm, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                Spacer()
                KoeBadge(statusLabel(device: device, isPhoneOwner: isPhoneOwner), tint: statusTint(device: device, isPhoneOwner: isPhoneOwner))
            }

            Text(statusSubtitle(device: device, isPhoneOwner: isPhoneOwner))
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if device.connected && !isPhoneOwner {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    telemetryTile(
                        label: "麦克风电量",
                        value: device.batteryPercent.map { device.charging ? "\($0)% 充电中" : "\($0)%" } ?? "—"
                    )
                    telemetryTile(
                        label: "充电仓电量",
                        value: device.boxBatteryPercent.map { device.boxCharging ? "\($0)% 充电中" : "\($0)%" } ?? "—"
                    )
                    telemetryTile(label: "设备存储", value: device.storageLabel)
                    telemetryTile(label: "固件版本", value: device.firmwareVersion.isEmpty ? "—" : device.firmwareVersion)
                }
            }

            HStack {
                Text("蓝牙控制权")
                    .font(.system(size: AppFontSizes.xs, weight: .medium))
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                HStack(spacing: 4) {
                    ownerSegment("Mac 使用", active: !isPhoneOwner) {
                        if isPhoneOwner {
                            store.send(.deviceOpenGuide)
                            store.bridgeActions.requestBleScan()
                        }
                    }
                    .disabled(device.busy)
                    ownerSegment("手机接管", active: isPhoneOwner) {
                        if !isPhoneOwner {
                            store.send(.deviceRelease)
                        }
                    }
                    .disabled(isPhoneOwner || !store.canReleaseToPhone)
                }
                .padding(3)
                .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
                .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(AppColors.border))
            }

            Divider().overlay(AppColors.border)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("启动时自动重连")
                        .font(.system(size: AppFontSizes.xs, weight: .medium))
                        .foregroundStyle(AppColors.textPrimary)
                    Text("关闭后仅手动点击连接")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { device.autoConnect },
                    set: { store.send(.setBleAutoConnect(enabled: $0)) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(device.autoConnect && !store.canReleaseToPhone)
                .accessibilityLabel("启动时自动重连录音豆")
            }

            HStack(spacing: 8) {
                if device.connected {
                    KoeActionButton("刷新状态", systemImage: "arrow.clockwise") {
                        store.send(.deviceRefresh)
                        store.bridgeActions.flushBleOutbound()
                    }
                    .disabled(device.busy)
                    KoeActionButton("使用引导", systemImage: "questionmark.circle") {
                        dismiss()
                        store.send(.deviceOpenGuide)
                    }
                    Spacer(minLength: 4)
                    KoeActionButton("离线文件（\(device.files.count)）", isPrimary: true) {
                        dismiss()
                        store.send(.navigate(section: "capture"))
                    }
                } else {
                    KoeActionButton("连接录音豆", systemImage: "antenna.radiowaves.left.and.right", isPrimary: true) {
                        dismiss()
                        store.send(.deviceOpenGuide)
                        store.bridgeActions.requestBleScan()
                    }
                    .disabled(device.busy)
                    KoeActionButton("重新扫描", systemImage: "arrow.clockwise") {
                        store.bridgeActions.requestBleScan()
                    }
                    .disabled(device.busy)
                    if device.autoConnect && !isPhoneOwner {
                        KoeActionButton("切回手机") {
                            store.send(.deviceRelease)
                        }
                        .disabled(!store.canReleaseToPhone)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 344)
        .background(AppColors.surface0)
        .preferredColorScheme(.light)
    }

    private func ownerSegment(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: AppFontSizes.xs, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? AppColors.textPrimary : AppColors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(active ? AppColors.surface0 : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func telemetryTile(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textMuted)
            Text(value)
                .font(.system(size: AppFontSizes.xs, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
    }

    private func statusLabel(device: DeviceSnapshot, isPhoneOwner: Bool) -> String {
        if isPhoneOwner { return "手机接管" }
        return device.state
    }

    private func statusTint(device: DeviceSnapshot, isPhoneOwner: Bool) -> Color {
        if isPhoneOwner { return AppColors.textMuted }
        if device.connected { return AppColors.success }
        return device.phase == "disconnected" ? AppColors.textMuted : AppColors.warning
    }

    private func statusSubtitle(device: DeviceSnapshot, isPhoneOwner: Bool) -> String {
        if isPhoneOwner {
            return "已断开蓝牙并关闭自动重连，可直接在手机端使用 soundcore App。"
        }
        if device.connected {
            return "蓝牙链路稳定，可直接开始无线录音或取回离线文件。"
        }
        return "将麦克风放入充电仓，短按充电仓下方按钮开启蓝牙广播后点击连接。"
    }
}
