import KoeAppleCore
import SwiftUI

struct IOSModelPresets: View {
    let store: HostSessionStore
    @Binding var draft: ModelSettingsDraft

    var body: some View {
        Button("Qwen 语音 + DeepSeek 文本") { applyPreset("hybrid") }
        Button("DeepSeek 官方全套") { applyPreset("deepseek-full") }
    }

    private func applyPreset(_ preset: String) {
        if store.settings.speech.engine != "cloud", store.sendReturningError(.configureSpeech(engine: "cloud")) != nil { return }
        draft.applyPreset(preset, catalog: store.settings.provider.effectiveCatalog)
    }
}

struct IOSSpeechModeNotice: View {
    let draft: ModelSettingsDraft
    var catalog: ProviderCatalogSnapshot = .fallback

    var body: some View {
        if let warning = nonRealtimeWarning {
            Label(warning, systemImage: "info.circle").foregroundStyle(IOSColors.warning)
        }
    }

    private var nonRealtimeWarning: String? {
        if draft.asrProvider == "deepseek" {
            return "DeepSeek 语音在录音结束后转写，不提供实时字幕。单段最长 120 秒，长录音按静音点切段。"
        }
        return catalog.qwenAsrOption(for: draft.qwenAsrModel).nonRealtimeWarning
    }
}
