import SwiftUI

struct SpeechSettingsCard: View {
    let store: HostSessionStore
    @Binding var draft: ModelSettingsDraft

    private var speech: SpeechSnapshot { store.settings.speech }
    private var provider: ProviderSnapshot { store.settings.provider }

    var body: some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Label("语音识别（ASR）", systemImage: "waveform")
                        .font(.system(size: AppFontSizes.md, weight: .medium))
                    Spacer()
                    Picker("识别引擎", selection: Binding(
                        get: { speech.engine },
                        set: { store.send(.configureSpeech(engine: $0)) }
                    )) {
                        Text("云端识别").tag("cloud")
                        Text("Apple 本机").tag("apple_speech")
                        Text("本机离线模型").tag("downloaded")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300)
                }

                if speech.engine == "cloud" {
                    cloudAsrPanel
                } else if speech.engine == "apple_speech" {
                    HStack(spacing: 8) {
                        Label(
                            speech.appleMessage ?? "正在检查本机识别能力。",
                            systemImage: speech.appleState == "ready" ? "checkmark.circle" : "info.circle"
                        )
                        .font(.system(size: AppFontSizes.sm))
                        .foregroundStyle(AppColors.textSecondary)
                        InfoTip("Apple 本机实时识别需要 macOS 26 或更新版本及支持的 Mac，当前使用简体中文。首次准备系统语言资源需要联网。系统识别就绪后，也可在本机转写已有录音文件。")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(speech.models) { model in modelRow(model) }
                        if speech.models.isEmpty {
                            Text("暂无可用的离线模型。")
                                .font(.system(size: AppFontSizes.sm))
                                .foregroundStyle(AppColors.textMuted)
                        }
                    }
                }

                Divider().overlay(AppColors.border)

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("允许将录音音频上传到云端")
                                .font(.system(size: AppFontSizes.sm, weight: .medium))
                            InfoTip("这是独立的音频上传授权。切换识别引擎或下载模型不会改变此授权。关闭后音频保存在本机，文字整理服务仍可接收转写文字。")
                        }
                        Text("独立音频上传授权。关闭后音频仅保留在本机，文本整理服务仍可处理转写文字。")
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.textMuted)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { provider.meetingAudioPolicy == "cloud_allowed" },
                        set: { store.send(.setMeetingAudioPolicy(policy: $0 ? "cloud_allowed" : "local_only")) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("允许将录音音频上传到云端")
                }

                if let message = provider.meetingAudioPolicyError ?? provider.meetingAudioStatus {
                    Text(message)
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.warning)
                }
            }
        }
    }

    private var cloudAsrPanel: some View {
        let catalog = provider.effectiveCatalog
        let qwenMeta = catalog.qwenAsrOption(for: draft.qwenAsrModel)
        let isQwen = draft.asrProvider == "qwen"
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                qwenAsrCard(selected: isQwen, catalog: catalog)
                deepseekAsrCard(selected: !isQwen, catalog: catalog)
            }

            if isQwen, let warning = qwenMeta.nonRealtimeWarning {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(AppColors.warning)
                    Text(warning)
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.warning)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadii.control))
            }

            HStack(spacing: 8) {
                Text(isQwen ? qwenMeta.endpointLabel : "当前 ASR 接口（HTTP 整段上传 <=120s 自动静音切段）")
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textMuted)
                Spacer()
                Text(draft.effectiveAsrEndpoint(catalog: catalog))
                    .font(.system(size: AppFontSizes.xs, design: .monospaced))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
        }
    }

    private func qwenAsrCard(selected: Bool, catalog: ProviderCatalogSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                draft.asrProvider = "qwen"
                draft.customAsrEndpoint = ""
            } label: {
                HStack(spacing: 8) {
                    Text("Qwen 阿里云百炼")
                        .font(.system(size: AppFontSizes.sm, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    KoeBadge("主力推荐 实时流式", tint: AppColors.success)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AppColors.accent : AppColors.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("官方 Qwen-Audio 3.1 系列，支持多语言与中文多方言；按实时/离线场景选择对应协议模型。")
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textSecondary)

            VStack(spacing: 6) {
                ForEach(catalog.qwenAsrModels) { option in
                    let picked = selected && draft.qwenAsrModel == option.id
                    Button {
                        draft.asrProvider = "qwen"
                        draft.qwenAsrModel = option.id
                        draft.customAsrEndpoint = ""
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.id)
                                    .font(.system(size: AppFontSizes.xs, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(AppColors.textPrimary)
                                    .lineLimit(1)
                                Text(option.note)
                                    .font(.system(size: AppFontSizes.xs))
                                    .foregroundStyle(AppColors.textSecondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            if let badge = option.badge {
                                KoeBadge(badge, tint: AppColors.success)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(picked ? AppColors.accentSoft : AppColors.surface0, in: RoundedRectangle(cornerRadius: AppRadii.control))
                        .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(picked ? AppColors.accent : AppColors.border))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? AppColors.surface0 : AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
        .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(selected ? AppColors.accent : AppColors.border))
    }

    private func deepseekAsrCard(selected: Bool, catalog: ProviderCatalogSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                draft.asrProvider = "deepseek"
                draft.customAsrEndpoint = ""
            } label: {
                HStack(spacing: 8) {
                    Text("DeepSeek 官方语音识别")
                        .font(.system(size: AppFontSizes.sm, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    KoeBadge("备选 非流式 <=120s", tint: AppColors.warning)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AppColors.accent : AppColors.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("官方独立工具接口，自动识别中/粤/英/日/韩等 21 语种，无需指定模型 ID。超 120 秒录音会在静音点自动切段（<=110s）顺序拼接。")
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textSecondary)

            HStack(spacing: 6) {
                specTile(label: "音频格式", value: "WAV / Opus")
                specTile(label: "单次上限", value: "120s / 8 MiB")
                specTile(label: "超长策略", value: "自动静音切段")
            }

            Text("POST \(catalog.defaultDeepseekAsrEndpoint)")
                .font(.system(size: AppFontSizes.xs, design: .monospaced))
                .foregroundStyle(AppColors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: 4))

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(AppColors.warning)
                Text("不支持边录边看实时字幕；录音结束后将自动切段转写。实时会议字幕请选用 Qwen 流式识别。")
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.warning)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadii.control))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? AppColors.surface0 : AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
        .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(selected ? AppColors.accent : AppColors.border))
    }

    private func specTile(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
            Text(value).font(.system(size: AppFontSizes.xs, weight: .semibold)).foregroundStyle(AppColors.textPrimary).lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: 4))
    }

    private func modelRow(_ model: SpeechModelSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name).font(.system(size: AppFontSizes.sm, weight: .medium))
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: model.sizeBytes), countStyle: .file))
                        .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                }
                Spacer()
                if model.state == "ready" {
                    KoeActionButton(speech.modelId == model.id ? "已选择" : "使用此模型", isPrimary: speech.modelId == model.id) {
                        store.send(.configureSpeech(engine: "downloaded", modelId: model.id))
                    }
                } else if model.state == "preparing" {
                    KoeActionButton("取消下载", systemImage: "xmark.circle") { store.send(.cancelSpeechModel) }
                } else {
                    KoeActionButton(
                        model.state == "downloaded" ? "加载模型" : model.state == "failed" ? "重试准备" : "下载",
                        systemImage: model.state == "downloaded" ? "play.circle" : "arrow.down.circle"
                    ) {
                        store.send(.prepareSpeechModel(modelId: model.id))
                    }
                }
            }
            if model.state == "downloaded" {
                Text("已下载，待加载").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
            }
            if model.state == "preparing" {
                ProgressView(value: Double(model.downloadedBytes), total: Double(max(model.sizeBytes, 1)))
                Text("已下载 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: model.downloadedBytes), countStyle: .file))")
                    .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
            }
            if let message = model.message {
                Text(message).font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(model.state == "failed" ? AppColors.danger : AppColors.textSecondary)
            }
        }.padding(12).background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
    }
}
