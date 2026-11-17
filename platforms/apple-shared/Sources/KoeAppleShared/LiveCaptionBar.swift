import SwiftUI

public struct LiveCaptionSnapshot: Codable, Equatable, Sendable {
    public let recordId: String
    public let text: String
    public let status: String
}

struct LiveCaptionBar: View {
    let store: HostSessionStore

    var body: some View {
        if let caption = store.liveCaption {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform")
                    .foregroundStyle(AppColors.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(caption.status)
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textSecondary)
                    Text(caption.text.isEmpty ? "开始说话，字幕会显示在这里" : caption.text)
                        .font(.system(size: AppFontSizes.md))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("live-caption-text")
                }
                Spacer(minLength: 8)
                KoeActionButton("查看记录", systemImage: "text.alignleft") {
                    store.send(.selectRecord(recordId: caption.recordId))
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.accent.opacity(0.08))
            .overlay(alignment: .bottom) { Rectangle().fill(AppColors.border).frame(height: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("live-caption-bar")
        }
    }
}
