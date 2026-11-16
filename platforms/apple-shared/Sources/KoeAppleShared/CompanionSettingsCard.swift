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
                DisclosureGroup("高级录音豆音频模式") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("音频模式", selection: Binding(
                            get: { device.companionMode },
                            set: {
                                store.send(.setCompanionMode(mode: $0))
                                NotificationCenter.default.post(name: Notification.Name("KoeFlushBleOutbound"), object: nil)
                            }
                        )) {
                            Text("普通录音，按侧键开始和结束").tag("disabled")
                            Text("领夹待命，出仓后持续接收声音").tag("collar_standby")
                            Text("实时纪要，同时圈定听写").tag("meeting_and_collar")
                        }
                        InfoTip("领夹待命会在录音豆出仓连接后建立后台音频流，并清理空闲临时文件。实时纪要兼听写保留原始音频，同时允许双击圈定听写。日常使用可在今天或录音页直接开始全天听记。")
                    }.padding(.top, 12)
                }
                HStack {
                    Toggle(
                        "启动时自动重连录音豆",
                        isOn: Binding(
                            get: { device.autoConnect },
                            set: { store.send(.setBleAutoConnect(enabled: $0)) }
                        )
                    )
                    InfoTip("关闭后 Koe 启动时不再自动回连已配对的录音豆。手动点击连接录音豆时会自动重新打开。")
                }
                HStack(spacing: 10) {
                    KoeActionButton("释放蓝牙控制权", systemImage: "xmark.circle") {
                        NotificationCenter.default.post(
                            name: Notification.Name("KoeReleaseBleControl"),
                            object: nil
                        )
                    }
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
