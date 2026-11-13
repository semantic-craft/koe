import SwiftUI

struct VoiceInputView: View {
    let store: HostSessionStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(title: "语音输入", subtitle: "用录音豆在当前输入框中听写。")
                KoeCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Label(store.snapshot.voiceInput.deviceStatus, systemImage: "waveform")
                            .font(.system(size: AppFontSizes.md, weight: .semibold))
                        Text(store.snapshot.voiceInput.message)
                            .font(.system(size: AppFontSizes.sm))
                            .foregroundStyle(AppColors.textSecondary)
                        KoeActionButton("重新连接", systemImage: "arrow.clockwise") {
                            store.send("prepare_voice_input")
                        }.disabled(!store.snapshot.voiceInput.canPrepare)
                    }
                }
                Text("Responsay 负责识别语音并将文字输入到光标所在的位置。")
                    .font(.system(size: AppFontSizes.sm)).foregroundStyle(AppColors.textMuted)
            }
            .padding(30).frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
