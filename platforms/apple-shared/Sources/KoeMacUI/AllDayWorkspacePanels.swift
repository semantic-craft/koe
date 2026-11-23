import SwiftUI

struct AllDayEventSpanCard: View {
    let span: AllDaySpanSnapshot
    let store: HostSessionStore

    var body: some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(span.timeRangeLabel)
                        .font(.system(size: AppFontSizes.xs, weight: .semibold))
                        .foregroundStyle(AppColors.accent)
                        .monospacedDigit()
                    KoeBadge(TimeLabel.duration(span.durationMs), tint: AppColors.textSecondary)
                    if let sliceBadge = span.sliceBadgeText {
                        KoeBadge(sliceBadge, tint: AppColors.accent)
                    }
                    ForEach(span.speakers, id: \.self) { speaker in
                        KoeBadge(speaker, tint: AppColors.textSecondary)
                    }
                    Spacer()
                    if span.firstSegment != nil || span.primaryRecordId != nil {
                        KoeActionButton("回到原文", systemImage: "arrow.up.right") {
                            if let first = span.firstSegment {
                                store.send(.openSource(
                                    recordId: first.recordId,
                                    segmentId: first.segmentId
                                ))
                            } else if let recordId = span.primaryRecordId {
                                store.send(.selectRecord(recordId: recordId))
                            }
                        }
                    }
                }

                Text(span.title ?? "对话片段")
                    .font(.system(size: AppFontSizes.md, weight: .semibold))

                if !span.summaryPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(span.summaryPoints, id: \.self) { point in
                            Text("- \(point)")
                                .font(.system(size: AppFontSizes.sm))
                                .foregroundStyle(AppColors.textSecondary)
                        }
                    }
                } else if !span.preview.isEmpty {
                    Text(span.preview)
                        .font(.system(size: AppFontSizes.sm))
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(3)
                }
            }
        }
    }
}

struct AllDayIntervalMarkerRow: View {
    let icon: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: AppFontSizes.sm))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textMuted)
                .monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColors.bgPanel, in: RoundedRectangle(cornerRadius: AppRadii.control))
        .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(AppColors.border))
    }
}

private enum AllDayReviewTab: String, CaseIterable, Identifiable {
    case tasks
    case decisions
    case memories

    var id: String { rawValue }
}

struct AllDayReviewColumn: View {
    let allDay: AllDayWorkspaceSnapshot
    let store: HostSessionStore

    @State private var selectedTab: AllDayReviewTab = .tasks

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            KoeCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("集中复查")
                        .font(.system(size: AppFontSizes.md, weight: .semibold))

                    HStack(spacing: 8) {
                        reviewTabPill(.tasks, title: "待办 (\(allDay.reviewTasks.count))")
                        reviewTabPill(.decisions, title: "决定 (\(allDay.reviewDecisions.count))")
                        reviewTabPill(.memories, title: "记忆 (\(allDay.reviewMemories.count))")
                    }

                    switch selectedTab {
                    case .tasks:
                        if allDay.reviewTasks.isEmpty {
                            emptyTabHint("当日还没有待确认或已采纳的待办。")
                        } else {
                            ForEach(allDay.reviewTasks) { item in
                                WorkspaceReviewItemRow(item: item, store: store)
                            }
                        }
                    case .decisions:
                        if allDay.reviewDecisions.isEmpty {
                            emptyTabHint("当日已验证纪要中还没有记录明确决定。")
                        } else {
                            ForEach(allDay.reviewDecisions) { decision in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(decision.text)
                                        .font(.system(size: AppFontSizes.sm))
                                        .foregroundStyle(AppColors.textPrimary)
                                    ForEach(decision.sources) { source in
                                        SourceLink(source: source, store: store)
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppColors.bgPanel, in: RoundedRectangle(cornerRadius: AppRadii.control))
                            }
                        }
                    case .memories:
                        if allDay.reviewMemories.isEmpty {
                            emptyTabHint("当日还没有沉淀出待确认或已采纳的记忆。")
                        } else {
                            ForEach(allDay.reviewMemories) { item in
                                WorkspaceReviewItemRow(item: item, store: store)
                            }
                        }
                    }
                }
            }

            KoeCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("当日回顾")
                        .font(.system(size: AppFontSizes.md, weight: .semibold))

                    if let review = allDay.dailyReview {
                        Text(review.overview)
                            .font(.system(size: AppFontSizes.sm))
                            .foregroundStyle(AppColors.textPrimary)

                        if !review.highlights.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(review.highlights, id: \.self) { highlight in
                                    Text("- \(highlight)")
                                        .font(.system(size: AppFontSizes.xs))
                                        .foregroundStyle(AppColors.textSecondary)
                                }
                            }
                        }

                        if !review.sources.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(review.sources) { source in
                                    SourceLink(source: source, store: store)
                                }
                            }
                        }
                    } else {
                        Text("当日回顾仅汇总已录音并带有原话引用的片段，不会对暂停或未录音空档生成推测内容。")
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.textMuted)
                    }
                }
            }
        }
    }

    private func reviewTabPill(_ tab: AllDayReviewTab, title: String) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            Text(title)
                .font(.system(size: AppFontSizes.xs, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? AppColors.accent : AppColors.textMuted)
                .monospacedDigit()
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background(
                    isSelected ? AppColors.accentSoft : AppColors.bgSubtle,
                    in: RoundedRectangle(cornerRadius: AppRadii.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadii.control)
                        .stroke(isSelected ? AppColors.accent.opacity(0.35) : AppColors.border)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func emptyTabHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppFontSizes.xs))
            .foregroundStyle(AppColors.textMuted)
            .padding(.vertical, 6)
    }
}
