import SwiftUI

public struct SettingsDoctorView: View {
    let store: HostSessionStore
    @State private var draft = ModelSettingsDraft()
    @State private var didInitialize = false

    public init(store: HostSessionStore) { self.store = store }

    public var body: some View {
        let provider = store.settings.provider
        let speech = store.settings.speech
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    PageHeading(
                        title: "模型设置",
                        subtitle: "阿里云百炼（Qwen）主打语音识别（ASR），DeepSeek 官方负责文本整理（LLM）并可选语音识别。"
                    )
                    Spacer(minLength: 12)
                    KoeActionButton("保存设置", isPrimary: true) { saveConfiguration() }
                }

                presetBar(speechEngine: speech.engine)
                ModelSettingsCredentialsCard(store: store, draft: $draft, onSave: saveConfiguration)
                SpeechSettingsCard(store: store, draft: $draft)
                TextServiceSettingsCard(store: store, draft: $draft, onSave: saveConfiguration)
                footerSaveBar(speech: speech)
            }
            .padding(30)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            if !didInitialize {
                draft.sync(from: provider)
                didInitialize = true
            }
        }
        .onChange(of: store.settings.provider.persistedModelFingerprint) { _, _ in
            draft.sync(from: store.settings.provider)
        }
        .onDisappear {
            draft.qwenApiKey = ""
            draft.deepseekApiKey = ""
        }
    }

    private func presetBar(speechEngine: String) -> some View {
        let catalog = store.settings.provider.effectiveCatalog
        let matched = draft.matchedPreset(speechEngine: speechEngine, catalog: catalog)
        return HStack(spacing: 8) {
            Text("快捷组合")
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textMuted)
            presetChip("Qwen 语音 + DeepSeek 文本（推荐）", id: "hybrid", active: matched == "hybrid")
            presetChip("DeepSeek 官方全套", id: "deepseek-full", active: matched == "deepseek-full")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColors.bgPanel, in: RoundedRectangle(cornerRadius: AppRadii.control))
        .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(AppColors.border))
    }

    private func presetChip(_ title: String, id: String, active: Bool) -> some View {
        Button {
            if store.settings.speech.engine != "cloud" {
                store.send(.configureSpeech(engine: "cloud"))
            }
            draft.applyPreset(id, catalog: store.settings.provider.effectiveCatalog)
        } label: {
            Text(title)
                .font(.system(size: AppFontSizes.xs, weight: .medium))
                .foregroundStyle(active ? AppColors.onAccent : AppColors.textSecondary)
                .padding(.horizontal, 11)
                .frame(minHeight: 28)
                .background(active ? AppColors.accent : AppColors.surface0, in: Capsule())
                .overlay(Capsule().stroke(active ? AppColors.accent : AppColors.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func footerSaveBar(speech: SpeechSnapshot) -> some View {
        HStack(spacing: 12) {
            Text(summaryLine(speech: speech))
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            KoeActionButton("恢复官方默认") {
                draft.applyPreset("hybrid", catalog: store.settings.provider.effectiveCatalog)
                draft.qwenWorkspaceId = ""
                draft.enableThinking = false
                if speech.engine != "cloud" {
                    store.send(.configureSpeech(engine: "cloud"))
                }
                saveConfiguration()
            }
            KoeActionButton("保存模型设置", isPrimary: true) {
                saveConfiguration()
            }
        }
        .padding(.top, 4)
    }

    private func summaryLine(speech: SpeechSnapshot) -> String {
        let asrText: String = switch speech.engine {
        case "cloud":
            draft.asrProvider == "deepseek"
                ? "DeepSeek ASR（/v1/tools/asr）"
                : "Qwen ASR（\(draft.qwenAsrModel)）"
        case "downloaded":
            "离线模型（\(speech.modelId ?? "未选择")）"
        default:
            "Apple 本机识别"
        }
        let llmText: String = switch draft.llmProvider {
        case "custom":
            "自定义 LLM（\(draft.activeLlmModel.isEmpty ? "未填写" : draft.activeLlmModel)）"
        default:
            "DeepSeek LLM（\(draft.deepseekLlmModel)）"
        }
        return "当前组合：\(asrText) + \(llmText)"
    }

    private func saveConfiguration() {
        store.send(draft.configureProviderCommand)
        if store.navigation.effectiveError == nil {
            draft.qwenApiKey = ""
            draft.deepseekApiKey = ""
        }
    }
}
