import KoeAppleCore
import SwiftUI

struct IOSLiveMinutesCoverageSlotView: View {
    let store: HostSessionStore

    var body: some View {
        if let coverage = store.liveMinutesCoverage {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("处理进度").font(.headline)
                    IOSInfoTip("转写覆盖按已转写音频时长计算，纪要覆盖按有引用的原文句数计算。会后整理阶段显示本场会议的收尾状态。", title: "覆盖指标说明")
                }
                HStack(spacing: 10) {
                    metricCard(
                        title: "转写覆盖",
                        primary: "\(coverage.transcriptPercent)%",
                        detail: "\(TimeLabel.duration(coverage.transcribedDurationMs)) / \(TimeLabel.duration(coverage.audioDurationMs))"
                    )
                    metricCard(
                        title: "纪要覆盖",
                        primary: "\(coverage.minutesPercent)%",
                        detail: "\(coverage.groundedSegments) / \(coverage.totalSegments) 句原文"
                    )
                }
                IOSCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("会后整理阶段")
                                .font(.system(size: AppFontSizes.xs))
                                .foregroundStyle(IOSColors.textMuted)
                            Text(coverage.consolidationLabel)
                                .font(.system(size: AppFontSizes.sm, weight: .semibold))
                                .foregroundStyle(IOSColors.textPrimary)
                        }
                        Spacer()
                        IOSBadge("仅引用原文", tint: IOSColors.textSecondary)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("live-minutes-coverage")
        }
    }

    private func metricCard(title: String, primary: String, detail: String) -> some View {
        IOSCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(IOSColors.textMuted)
                Text(primary)
                    .font(.system(size: AppFontSizes.md, weight: .semibold))
                    .foregroundStyle(IOSColors.textPrimary)
                    .monospacedDigit()
                Text(detail)
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(IOSColors.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }
}
