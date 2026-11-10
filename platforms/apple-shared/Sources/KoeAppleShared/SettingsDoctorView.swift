import SwiftUI

public struct SettingsDoctorView: View {
    let store: HostSessionStore
    @State private var apiKey = ""
    @State private var model = "qwen-plus"
    @State private var chatEndpoint = ""
    @State private var asrEndpoint = ""
    public init(store: HostSessionStore) { self.store = store }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeading(title: "设置", subtitle: "连接录音豆，管理当前使用的 AI 服务。")
                KoeCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label("Soundcore Work D3200", systemImage: "waveform.badge.mic")
                                .font(.system(size: AppFontSizes.md, weight: .medium))
                            Spacer()
                            KoeBadge(store.snapshot.device.state,
                                     tint: store.snapshot.device.connected ? AppColors.success : AppColors.textMuted)
                        }
                        Text("连接后可以查看设备中的录音，并将它们取回到这台 Mac。")
                            .font(.system(size: AppFontSizes.sm)).foregroundStyle(AppColors.textSecondary)
                        HStack {
                            KoeActionButton("查找录音豆", systemImage: "antenna.radiowaves.left.and.right", isPrimary: true) {
                                NotificationCenter.default.post(name: Notification.Name("KoeRequestBleScan"), object: nil)
                            }.disabled(store.snapshot.device.busy)
                            if store.snapshot.device.connected {
                                KoeActionButton("开始录音", systemImage: "record.circle") { store.send("device_start") }
                                KoeActionButton("结束录音", systemImage: "stop.circle") { store.send("device_stop") }
                            }
                        }
                        if store.snapshot.device.busy { ProgressView(value: store.snapshot.device.progress) }
                        ForEach(store.snapshot.device.files) { file in
                            HStack {
                                Text(file.title).font(.system(size: AppFontSizes.sm))
                                Text(TimeLabel.duration(file.durationMs)).font(.system(size: AppFontSizes.xs))
                                    .foregroundStyle(AppColors.textMuted)
                                Spacer()
                                KoeActionButton("取回") { store.send("device_download", ["fileId": file.id]) }
                                    .disabled(store.snapshot.device.busy)
                            }.padding(.vertical, 5)
                        }
                    }
                }
                KoeCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label("AI 服务", systemImage: "sparkles").font(.system(size: AppFontSizes.md, weight: .medium))
                            Spacer()
                            KoeBadge(store.snapshot.provider.configured ? "当前会话已配置" : "未配置",
                                     tint: store.snapshot.provider.configured ? AppColors.success : AppColors.textMuted)
                        }
                        Text("使用阿里云百炼完成转写、整理与问答。未配置时，原文、待办、记忆和本地检索仍可使用。")
                            .font(.system(size: AppFontSizes.sm)).foregroundStyle(AppColors.textSecondary).lineSpacing(5)
                        SecureField("API Key", text: $apiKey).textFieldStyle(.roundedBorder).onSubmit { configure() }
                        TextField("文本模型", text: $model).textFieldStyle(.roundedBorder).onSubmit { configure() }
                        DisclosureGroup("自定义服务地址（可选）") {
                            VStack(spacing: 10) {
                                TextField("对话服务完整地址，留空使用默认", text: $chatEndpoint)
                                    .textFieldStyle(.roundedBorder).onSubmit { configure() }
                                TextField("转写服务完整地址，留空使用默认", text: $asrEndpoint)
                                    .textFieldStyle(.roundedBorder).onSubmit { configure() }
                            }.padding(.top, 10)
                        }.font(.system(size: AppFontSizes.xs))
                        HStack {
                            Text("密钥只在本次运行期间使用，退出后清除。")
                                .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                            Spacer()
                            KoeActionButton("用于当前会话", isPrimary: true) { configure() }
                                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                Text("记录与确认结果保存在本机工作区。导出时可选择保存位置。")
                    .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
            }.padding(30).frame(maxWidth: 850, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if !store.snapshot.provider.model.isEmpty { model = store.snapshot.provider.model } }
        .onDisappear { apiKey = "" }
    }
    private func configure() {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var fields: [String: Any] = ["apiKey": apiKey, "model": model]
        let chat = chatEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let asr = asrEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chat.isEmpty { fields["chatEndpoint"] = chat }
        if !asr.isEmpty { fields["asrEndpoint"] = asr }
        store.send("configure_provider", fields)
        apiKey = ""
    }
}
