import SwiftUI

private struct DraftItem: Identifiable {
    let id: String
    let text: String

    static func keyed(_ drafts: [String]) -> [DraftItem] {
        var counts: [String: Int] = [:]
        return drafts.map { draft in
            let count = (counts[draft] ?? 0) + 1
            counts[draft] = count
            return DraftItem(id: count == 1 ? draft : "\(draft)#\(count)", text: draft)
        }
    }
}

private enum MinutesStageTab: String, CaseIterable, Identifiable {
    case live
    case consolidated

    var id: String { rawValue }
}

private enum NarrowPaneTab: String, CaseIterable, Identifiable {
    case transcript
    case minutes

    var id: String { rawValue }
}

struct LiveMinutesSplitBody: View {
    let lm: LiveMinutesWorkspaceSnapshot
    let store: HostSessionStore

    @State private var selectedStage: MinutesStageTab = .live
    @State private var selectedNarrowPane: NarrowPaneTab = .transcript

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                transcriptCard.frame(minWidth: 420, maxWidth: .infinity)
                minutesAndActionsCard.frame(minWidth: 420, maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    pillButton("实时原文", isSelected: selectedNarrowPane == .transcript) {
                        selectedNarrowPane = .transcript
                    }
                    pillButton("纪要与行动", isSelected: selectedNarrowPane == .minutes) {
                        selectedNarrowPane = .minutes
                    }
                    Spacer()
                }
                if selectedNarrowPane == .transcript {
                    transcriptCard
                } else {
                    minutesAndActionsCard
                }
            }
        }
        .onAppear {
            selectedStage = lm.isActive ? .live : .consolidated
        }
        .onChange(of: lm.isActive) { _, active in
            selectedStage = active ? .live : .consolidated
        }
        .onChange(of: lm.selectedRecordId) { _, _ in
            selectedStage = lm.isActive ? .live : .consolidated
        }
    }

    private var transcriptCard: some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("实时原文")
                        .font(.system(size: AppFontSizes.md, weight: .semibold))
                    Spacer()
                    Text("点击任意句子定位与校对")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                }

                if lm.segments.isEmpty && lm.drafts.isEmpty {
                    Text(lm.isActive ? "等待实时转写原文，收到语音后会持续追加。" : "本场会议还没有转写原文。")
                        .font(.system(size: AppFontSizes.sm))
                        .foregroundStyle(AppColors.textMuted)
                        .padding(.vertical, 12)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(lm.segments.enumerated()), id: \.element.id) { idx, segment in
                            transcriptSegmentRow(index: idx + 1, segment: segment)
                        }
                        ForEach(DraftItem.keyed(lm.drafts)) { draft in
                            VStack(alignment: .leading, spacing: 5) {
                                KoeBadge("识别中", tint: AppColors.accent)
                                Text(draft.text)
                                    .font(.system(size: AppFontSizes.sm))
                                    .foregroundStyle(AppColors.textSecondary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
                        }
                    }
                }
            }
        }
    }

    private func transcriptSegmentRow(index: Int, segment: SegmentSnapshot) -> some View {
        Button {
            if let recordId = lm.selectedRecordId {
                store.send(.openSource(recordId: recordId, segmentId: segment.id))
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("[S\(index)]")
                        .font(.system(size: AppFontSizes.xs, weight: .medium))
                        .foregroundStyle(AppColors.accent)
                        .monospacedDigit()
                    Text(TimeLabel.duration(segment.startMs))
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                        .monospacedDigit()
                    if let speaker = segment.speaker, !speaker.isEmpty {
                        KoeBadge(speaker, tint: AppColors.textSecondary)
                    }
                    if segment.isEdited {
                        KoeBadge("已校对", tint: AppColors.success)
                    }
                    Spacer()
                }
                Text(segment.text)
                    .font(.system(size: AppFontSizes.sm))
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.bgPanel, in: RoundedRectangle(cornerRadius: AppRadii.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var minutesAndActionsCard: some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("结构化纪要与行动")
                        .font(.system(size: AppFontSizes.md, weight: .semibold))
                    Spacer()
                    pillButton("实时整理", isSelected: selectedStage == .live) {
                        selectedStage = .live
                    }
                    pillButton("会后完整纪要", isSelected: selectedStage == .consolidated) {
                        selectedStage = .consolidated
                    }
                }

                if let error = lm.error, !error.isEmpty {
                    Text("处理提示：\(error)")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.danger)
                }

                if !lm.configured {
                    HStack(spacing: 10) {
                        Text("尚未配置文字整理服务，仍会保留完整实时原文。")
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.textMuted)
                        Spacer()
                        KoeActionButton("打开设置", systemImage: "gearshape") {
                            store.send(.navigate(section: "settings"))
                        }
                    }
                }

                if selectedStage == .live {
                    sectionsList(
                        lm.liveSections,
                        emptyHint: lm.isActive ? "等待已确认原文，会议中会按议题增量更新纪要。" : "暂无实时整理条目，可点击上方生成完整纪要。"
                    )
                } else {
                    if lm.isActive {
                        Text("会议仍在进行中；停止录音后会对全部已确认原文做一次完整收尾整理。")
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.textMuted)
                    }
                    sectionsList(
                        lm.finalSections.isEmpty ? lm.liveSections : lm.finalSections,
                        emptyHint: "尚未生成会后完整纪要。"
                    )
                    Divider()
                    Text("行动与记忆确认 (\(lm.actionItems.count))")
                        .font(.system(size: AppFontSizes.sm, weight: .semibold))
                    if lm.actionItems.isEmpty {
                        Text("本场会议还没有待确认或已采纳的行动项。")
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.textMuted)
                    } else {
                        ForEach(lm.actionItems) { item in
                            WorkspaceReviewItemRow(item: item, store: store)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionsList(_ sections: [SummarySnapshot], emptyHint: String) -> some View {
        if sections.isEmpty {
            Text(emptyHint)
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textMuted)
                .padding(.vertical, 6)
        } else {
            ForEach(SummarySectionItem.keyed(sections)) { item in
                let section = item.section
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(.system(size: AppFontSizes.sm, weight: .semibold))
                    Text(section.text)
                        .font(.system(size: AppFontSizes.sm))
                        .foregroundStyle(AppColors.textSecondary)
                        .textSelection(.enabled)
                    ForEach(section.sources) { source in
                        SourceLink(source: source, store: store)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.bgPanel, in: RoundedRectangle(cornerRadius: AppRadii.control))
            }
        }
    }

    private func pillButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: AppFontSizes.xs, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? AppColors.accent : AppColors.textMuted)
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
}
