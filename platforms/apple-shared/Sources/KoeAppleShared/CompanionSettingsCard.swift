import SwiftUI

public struct CompanionSettingsCard: View {
    let store: HostSessionStore

    public init(store: HostSessionStore) {
        self.store = store
    }

    public var body: some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("领夹麦伴侣", systemImage: "mic")
                        .font(.system(size: AppFontSizes.md, weight: .medium))
                    Spacer()
                    KoeBadge(statusLabel, tint: statusTint)
                }
                Text("领夹待命会在录音豆出仓连上后自动建立后台实时流，免按侧键即可通过正面双击或语音输入快捷键收音；空闲时自动清理机内临时文件，并预留本地桥供 Responsay 联动。")
                    .font(.system(size: AppFontSizes.sm))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineSpacing(5)
                HStack(spacing: 10) {
                    modeButton("关闭", mode: "disabled")
                    modeButton("领夹待命", mode: "collar_standby")
                    modeButton("会议兼领夹听写", mode: "meeting_and_collar")
                }
                HStack {
                    Toggle(
                        "启动时自动重连录音豆",
                        isOn: Binding(
                            get: { store.snapshot.device.autoConnect },
                            set: { store.send("set_ble_auto_connect", ["enabled": $0]) }
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

    private func modeButton(_ title: String, mode: String) -> some View {
        KoeActionButton(title, isPrimary: store.snapshot.device.companionMode == mode) {
            store.send("set_companion_mode", ["mode": mode])
            NotificationCenter.default.post(
                name: Notification.Name("KoeFlushBleOutbound"),
                object: nil
            )
        }
    }

    private var statusLabel: String {
        if store.snapshot.device.companionMode == "disabled" {
            return "未启用"
        }
        return store.snapshot.device.standbyReady ? "待命就绪" : "等待连接"
    }

    private var statusTint: Color {
        if store.snapshot.device.companionMode == "disabled" {
            return AppColors.textMuted
        }
        return store.snapshot.device.standbyReady ? AppColors.success : AppColors.warning
    }
}
