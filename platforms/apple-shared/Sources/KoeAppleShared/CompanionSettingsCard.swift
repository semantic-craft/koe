import SwiftUI

public struct CompanionSettingsCard: View {
    let store: HostSessionStore

    public init(store: HostSessionStore) {
        self.store = store
    }

    public var body: some View {
        let device = store.device
        KoeCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("录音豆连接", systemImage: "mic")
                        .font(.system(size: AppFontSizes.md, weight: .medium))
                    Spacer()
                    KoeBadge(device.state, tint: statusTint(device))
                }
                HStack {
                    Toggle(
                        "启动时自动重连录音豆",
                        isOn: Binding(
                            get: { device.autoConnect },
                            set: { store.send(.setBleAutoConnect(enabled: $0)) }
                        )
                    )
                    .disabled(device.autoConnect && !store.canReleaseToPhone)
                    InfoTip("关闭后 Koe 启动时不再自动回连已配对的录音豆。手动点击连接录音豆时会自动重新打开。")
                }
                HStack(spacing: 10) {
                    KoeActionButton("释放蓝牙控制权", systemImage: "xmark.circle") {
                        store.send(.deviceRelease)
                    }
                    .disabled((store.today.picker?.beanControlOwner == "phone") || !store.canReleaseToPhone)
                    Text("断开当前蓝牙连接并关闭自动重连，方便手机或其他应用接管。")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                }
            }
        }
    }

    private func statusTint(_ device: DeviceSnapshot) -> Color {
        if device.connected { return AppColors.success }
        return device.phase == "disconnected" ? AppColors.textMuted : AppColors.warning
    }
}
