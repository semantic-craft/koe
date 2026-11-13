import SwiftUI

struct SpeechSettingsCard: View {
    let store: HostSessionStore
    private var speech: SpeechSnapshot { store.snapshot.speech }

    var body: some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("语音识别", systemImage: "waveform")
                    .font(.system(size: AppFontSizes.md, weight: .medium))
                Picker("识别引擎", selection: Binding(
                    get: { speech.engine },
                    set: { store.send("configure_speech", ["engine": $0]) }
                )) {
                    Text("Apple 本机识别").tag("apple_speech")
                    Text("下载离线模型").tag("downloaded")
                    Text("云端识别").tag("cloud")
                }
                if speech.engine == "apple_speech" {
                    HStack {
                        Label(speech.appleMessage ?? "正在检查本机识别能力。",
                              systemImage: speech.appleState == "ready" ? "checkmark.circle" : "info.circle")
                            .font(.system(size: AppFontSizes.sm)).foregroundStyle(AppColors.textSecondary)
                        InfoTip("Apple 本机实时识别需要 macOS 26 或更新版本及支持的 Mac，当前使用简体中文。首次准备系统语言资源需要联网。已有录音文件的本机补转写尚未支持。实际可用性以系统检查结果为准。")
                    }
                } else if speech.engine == "downloaded" {
                    ForEach(speech.models) { model in modelRow(model) }
                    if speech.models.isEmpty {
                        Text("暂无可用的离线模型。")
                            .font(.system(size: AppFontSizes.sm)).foregroundStyle(AppColors.textMuted)
                    }
                } else {
                    Text("云端识别使用下方服务配置；允许上传音频后才能处理。")
                        .font(.system(size: AppFontSizes.sm)).foregroundStyle(AppColors.textSecondary)
                }
                Divider()
                HStack {
                    Toggle("允许将录音音频上传到云端", isOn: Binding(
                        get: { store.snapshot.provider.meetingAudioPolicy == "cloud_allowed" },
                        set: { store.send("set_meeting_audio_policy", ["policy": $0 ? "cloud_allowed" : "local_only"]) }
                    ))
                    InfoTip("这是独立的音频上传授权。切换识别引擎或下载模型不会改变此授权。关闭后音频保存在本机，文字整理服务仍可接收转写文字。")
                }
                if let message = store.snapshot.provider.meetingAudioPolicyError ?? store.snapshot.provider.meetingAudioStatus {
                    Text(message).font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.warning)
                }
            }
        }
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
                        store.send("configure_speech", ["engine": "downloaded", "modelId": model.id])
                    }
                } else if model.state == "preparing" {
                    KoeActionButton("取消下载", systemImage: "xmark.circle") { store.send("cancel_speech_model") }
                } else {
                    KoeActionButton(model.state == "failed" ? "重新下载" : "下载", systemImage: "arrow.down.circle") {
                        store.send("prepare_speech_model", ["modelId": model.id])
                    }
                }
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
