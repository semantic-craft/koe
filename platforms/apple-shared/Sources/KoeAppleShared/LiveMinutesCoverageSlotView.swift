import SwiftUI

struct LiveMinutesCoverageSlotView: View {
    let store: HostSessionStore

    var body: some View {
        if let cov = store.liveMinutesCoverage {
            HStack(spacing: 12) {
                coverageMetricCard(
                    title: "转写覆盖",
                    primary: "\(cov.transcriptPercent)%",
                    detail: "\(TimeLabel.duration(cov.transcribedDurationMs)) / \(TimeLabel.duration(cov.audioDurationMs)) 音频已转写"
                )
                coverageMetricCard(
                    title: "纪要覆盖",
                    primary: "\(cov.minutesPercent)%",
                    detail: "\(cov.groundedSegments) / \(cov.totalSegments) 句原文已引用"
                )
                coverageMetricCard(
                    title: "结束后整理",
                    primary: cov.consolidationLabel,
                    detail: "仅引用已确认原文，不虚构未录区间"
                )
            }
        }
    }

    private func coverageMetricCard(title: String, primary: String, detail: String) -> some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textMuted)
                Text(primary)
                    .font(.system(size: AppFontSizes.md, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }
}
