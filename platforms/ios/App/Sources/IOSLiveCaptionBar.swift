import KoeAppleCore
import SwiftUI

struct IOSLiveCaptionBar: View {
    let store: HostSessionStore
    let onOpenRecord: (String) -> Void

    var body: some View {
        if let caption = store.liveCaption {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: AppFontSizes.sm))
                    .foregroundStyle(IOSColors.accent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(caption.status)
                        .font(.system(size: AppFontSizes.xs, weight: .medium))
                        .foregroundStyle(IOSColors.textMuted)
                    Text(caption.text.isEmpty ? "开始说话，字幕会显示在这里" : caption.text)
                        .font(.system(size: AppFontSizes.sm))
                        .foregroundStyle(IOSColors.textPrimary)
                        .lineLimit(2)
                        .accessibilityIdentifier("live-caption-text")
                }

                Spacer(minLength: 4)

                IOSPrimaryButton("查看", isPrimary: false) {
                    onOpenRecord(caption.recordId)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(IOSColors.accentSoft, in: RoundedRectangle(cornerRadius: IOSRadii.card))
            .overlay(
                RoundedRectangle(cornerRadius: IOSRadii.card)
                    .stroke(IOSColors.border, lineWidth: 1)
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("live-caption-bar")
        }
    }
}
