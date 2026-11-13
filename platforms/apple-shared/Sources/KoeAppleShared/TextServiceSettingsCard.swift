import SwiftUI

struct TextServiceSettingsCard: View {
    let store: HostSessionStore
    @State private var apiKey = ""
    @State private var model = ""
    @State private var chatEndpoint = ""
    @State private var asrEndpoint = ""

    var body: some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("文字整理服务", systemImage: "text.alignleft")
                        .font(.system(size: AppFontSizes.md, weight: .medium))
                    Spacer()
                    KoeBadge(store.snapshot.provider.configured ? "已配置" : "未配置")
                    InfoTip("用于纪要、文字整理与问答。支持兼容服务和本机 localhost 服务。模型名称及完整接口地址按服务填写，本机无认证服务可不填 API Key。")
                }
                TextField("文本模型名称", text: $model).textFieldStyle(.roundedBorder).onSubmit { configure() }
                TextField("对话完整接口地址，可填写 localhost 地址", text: $chatEndpoint)
                    .textFieldStyle(.roundedBorder).onSubmit { configure() }
                SecureField("API Key（本机无认证服务可留空）", text: $apiKey)
                    .textFieldStyle(.roundedBorder).onSubmit { configure() }
                DisclosureGroup("云端语音识别服务地址") {
                    TextField("转写完整接口地址，留空使用默认", text: $asrEndpoint)
                        .textFieldStyle(.roundedBorder).onSubmit { configure() }.padding(.top, 10)
                }.font(.system(size: AppFontSizes.xs))
                HStack {
                    Text(store.snapshot.provider.isolated ? "隔离运行，密钥仅在本次会话使用。" : "密钥保存在系统安全存储中，留空保留已存密钥。")
                        .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                    Spacer()
                    KoeActionButton("保存服务配置", isPrimary: true) { configure() }
                }
                HStack {
                    KoeActionButton("清除密钥") { apiKey = ""; store.send("clear_provider_credential") }
                    KoeActionButton("重试读取安全配置") { store.send("retry_provider_credentials", ["authorize": true]) }
                }
                if let message = credentialMessage {
                    Text(message).font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.warning)
                }
            }
        }
        .onAppear {
            model = store.snapshot.provider.model
            chatEndpoint = store.snapshot.provider.chatEndpoint
            asrEndpoint = store.snapshot.provider.asrEndpoint
        }
        .onDisappear { apiKey = "" }
    }

    private var credentialMessage: String? {
        switch store.snapshot.provider.credentialState {
        case "reopen_required": "工作区保存结果尚未确认，请退出并重新打开 Koe。"
        case "missing_saved": "已保存的密钥在当前安全存储中不存在，请重新输入或清除。"
        case "unavailable": "安全凭据暂不可读取，云端处理已停用。"
        default: nil
        }
    }

    private func configure() {
        var fields: [String: Any] = [
            "model": model,
            "chatEndpoint": chatEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            "asrEndpoint": asrEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields["apiKey"] = apiKey }
        store.send("configure_provider", fields)
        apiKey = ""
    }
}
