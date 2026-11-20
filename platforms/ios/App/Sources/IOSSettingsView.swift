import KoeAppleCore
import SwiftUI

struct IOSSettingsView: View {
    let store: HostSessionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let platform = store.platform
        let provider = store.settings.provider
        let speech = store.settings.speech

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    IOSCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("宿主设备配置")
                                    .font(.system(size: AppFontSizes.md, weight: .semibold))
                                    .foregroundStyle(IOSColors.textPrimary)
                                Spacer()
                                IOSBadge(platform.hostDisplayName, tint: IOSColors.accent)
                            }
                            settingsRow("平台标识", value: platform.id)
                            settingsRow("本机语音引擎", value: platform.nativeSpeechLabel)
                            HStack {
                                Text("系统音频录制")
                                    .font(.system(size: AppFontSizes.xs))
                                    .foregroundStyle(IOSColors.textSecondary)
                                IOSInfoTip(
                                    "iOS 端不支持系统音频内录，请使用 iPhone 麦克风或 Soundcore Work 录音豆采集声音。",
                                    title: "iOS 音频限制"
                                )
                                Spacer()
                                Text(platform.supportsSystemAudio ? "可用" : "iOS 端不可用")
                                    .font(.system(size: AppFontSizes.xs, weight: .medium))
                                    .foregroundStyle(IOSColors.textMuted)
                            }
                            settingsRow("应用更新通道", value: platform.supportsSelfUpdate ? "应用内更新" : "App Store 分发")
                        }
                    }

                    IOSCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("模型与转写服务")
                                    .font(.system(size: AppFontSizes.md, weight: .semibold))
                                    .foregroundStyle(IOSColors.textPrimary)
                                Spacer()
                                IOSBadge(
                                    provider.configured ? "已配置" : "未配置",
                                    tint: provider.configured ? IOSColors.success : IOSColors.textMuted
                                )
                            }
                            settingsRow("语音识别提供方", value: "\(provider.asrProvider)  |  \(provider.asrModel)")
                            settingsRow("摘要对话提供方", value: "\(provider.llmProvider)  |  \(provider.model)")
                            settingsRow("Qwen 凭据状态", value: credentialLabel(provider.credentialState))
                            settingsRow("DeepSeek 凭据状态", value: credentialLabel(provider.deepseekCredentialState))
                            settingsRow("凭据隔离模式", value: provider.isolated ? "调试隔离存储" : "系统钥匙串")
                        }
                    }

                    IOSCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("本机语音识别")
                                .font(.system(size: AppFontSizes.md, weight: .semibold))
                                .foregroundStyle(IOSColors.textPrimary)
                            settingsRow("当前模式", value: speech.engine)
                            settingsRow("Apple 本机状态", value: speech.appleState)
                            if let message = speech.appleMessage, !message.isEmpty {
                                Text(message)
                                    .font(.system(size: AppFontSizes.xs))
                                    .foregroundStyle(IOSColors.textMuted)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(IOSColors.bgPanel)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    IOSPrimaryButton("完成", isPrimary: false) {
                        dismiss()
                    }
                    .accessibilityIdentifier("settings-close")
                }
            }
        }
    }

    private func settingsRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(IOSColors.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: AppFontSizes.xs, weight: .medium))
                .foregroundStyle(IOSColors.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func credentialLabel(_ raw: String) -> String {
        switch raw {
        case "ready": "已就绪"
        case "reopen_required": "需要重新授权"
        case "unavailable": "暂不可用"
        default: "未设置"
        }
    }
}
