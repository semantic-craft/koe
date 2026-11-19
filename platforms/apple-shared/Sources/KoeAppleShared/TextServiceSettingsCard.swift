import SwiftUI

struct TextServiceSettingsCard: View {
    let store: HostSessionStore
    @Binding var draft: ModelSettingsDraft
    let onSave: () -> Void

    var body: some View {
        let provider = store.settings.provider
        KoeCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Label("文本整理与问答（LLM）", systemImage: "text.alignleft")
                        .font(.system(size: AppFontSizes.md, weight: .medium))
                    KoeBadge(provider.configured ? "已就绪" : "未配置", tint: provider.configured ? AppColors.success : AppColors.textMuted)
                    Spacer()
                    Picker("LLM 服务商", selection: Binding(
                        get: { draft.llmProvider },
                        set: { draft.selectLlmProvider($0) }
                    )) {
                        Text("DeepSeek（官方）").tag("deepseek")
                        Text("自定义兼容").tag("custom")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }

                if draft.llmProvider != "custom" {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(ModelSettingsCatalog.deepseekLlmModels) { option in
                            llmOptionCard(option, selected: draft.deepseekLlmModel == option.id) {
                                draft.deepseekLlmModel = option.id
                            }
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("自定义模型名称（Model ID）")
                                .font(.system(size: AppFontSizes.xs))
                                .foregroundStyle(AppColors.textSecondary)
                            TextField("例如：deepseek-flash 或本机 Ollama 模型名", text: $draft.customLlmModel)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: AppFontSizes.xs, design: .monospaced))
                                .onSubmit { onSave() }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("对话接口地址（支持 http://127.0.0.1）")
                                .font(.system(size: AppFontSizes.xs))
                                .foregroundStyle(AppColors.textSecondary)
                            TextField("https://your-host/v1/chat/completions", text: $draft.customChatEndpoint)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: AppFontSizes.xs, design: .monospaced))
                                .onSubmit { onSave() }
                        }
                    }
                }

                HStack(spacing: 8) {
                    Text("当前 LLM 接口（OpenAI 兼容）")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                    Spacer()
                    Text(endpointPreview)
                        .font(.system(size: AppFontSizes.xs, design: .monospaced))
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("纪要与问答启用深度思考")
                                .font(.system(size: AppFontSizes.sm, weight: .medium))
                            InfoTip("DeepSeek V4.1 / V4 支持深度思考切换。关闭（thinking: disabled）可显著缩短实时纪要首字耗时与生成延迟。")
                        }
                        Text("关闭可缩短实时纪要生成耗时；开启适合复杂会议分析与长文推理。")
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.textMuted)
                    }
                    Spacer()
                    Toggle("", isOn: $draft.enableThinking)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("纪要与问答启用深度思考")
                }
            }
        }
    }

    private var endpointPreview: String {
        let ep = draft.effectiveChatEndpoint()
        return ep.isEmpty ? "自定义地址（见服务商凭证高级展开项）" : ep
    }

    private func llmOptionCard(_ option: LlmModelOption, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(option.id)
                        .font(.system(size: AppFontSizes.xs, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AppColors.accent : AppColors.textMuted)
                }
                HStack(spacing: 4) {
                    KoeBadge(option.primaryBadge, tint: option.primaryBadgeRecommended ? AppColors.success : AppColors.accent)
                    ForEach(option.metaBadges, id: \.self) { badge in
                        KoeBadge(badge, tint: AppColors.textMuted)
                    }
                }
                Text(option.description)
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? AppColors.accentSoft : AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
            .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(selected ? AppColors.accent : AppColors.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
