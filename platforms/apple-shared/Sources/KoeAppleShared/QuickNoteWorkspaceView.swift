import SwiftUI

public struct QuickNoteWorkspaceView: View {
    public let store: HostSessionStore
    private let onExportWorkspace: (WorkspaceExportRequest) -> Void

    @State private var selectedFilter: QuickNoteFilterSelection = .all
    @State private var draftTitle = ""
    @State private var draftText = ""
    @State private var includeAnalysis = true
    @State private var includeSources = true

    public init(
        store: HostSessionStore,
        onExportWorkspace: @escaping (WorkspaceExportRequest) -> Void = { _ in }
    ) {
        self.store = store
        self.onExportWorkspace = onExportWorkspace
    }

    private var quickNote: QuickNoteWorkspaceSnapshot {
        store.snapshot.workspaces?.quickNote ?? .empty
    }

    private var canStartOrStopSession: Bool {
        if quickNote.isActive { return true }
        return quickNote.canStart
    }

    private var visibleCards: [QuickNoteCardSnapshot] {
        quickNote.filteredCards(for: selectedFilter)
    }

    private var activeCard: QuickNoteCardSnapshot? {
        quickNote.resolvedSelectedCard(for: selectedFilter)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerAndControlStrip
                quickInputCard
                workflowStrip
                filterBar

                if quickNote.cards.isEmpty {
                    EmptyState(
                        icon: "bolt.horizontal",
                        title: "还没有随心闪记",
                        detail: "使用上方开始一段语音闪记，或直接输入一段文字想法。"
                    )
                } else if visibleCards.isEmpty {
                    EmptyState(
                        icon: "tray",
                        title: "当前分组没有闪记",
                        detail: "切换收件箱或项目筛选查看其他已保存的闪记。"
                    )
                } else {
                    cardSelectorStrip
                    if let card = activeCard {
                        QuickNoteCardInspectorView(
                            card: card,
                            projects: quickNote.projects,
                            store: store,
                            includeAnalysis: $includeAnalysis,
                            includeSources: $includeSources,
                            onExportWorkspace: onExportWorkspace
                        )
                    }
                }

                Text(quickNote.mcpReadNote)
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textMuted)
                    .padding(.top, 4)
            }
            .padding(30)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onChange(of: quickNote.projects) { _, updated in
            if case .project(let name) = selectedFilter,
               !updated.contains(where: { $0.name == name }) {
                selectedFilter = .all
            }
        }
    }

    private var headerAndControlStrip: some View {
        HStack(alignment: .top, spacing: 16) {
            PageHeading(
                title: "随心闪记",
                subtitle: "说一段就收一段，完整保留原话，同时给出独立 AI 理解和下一步整理。"
            )
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                KoeBadge(quickNote.sourceLabel, tint: AppColors.textSecondary)
                if quickNote.isActive {
                    KoeBadge("记录中", tint: AppColors.success)
                }
                KoeActionButton(
                    quickNote.isActive ? "结束当前闪记" : "开始一段闪记",
                    systemImage: quickNote.isActive ? "stop.fill" : "waveform",
                    isPrimary: true
                ) {
                    if quickNote.isActive {
                        store.performCaptureAction(.end)
                    } else {
                        store.startCapture(.quickNote, stayOnPage: true)
                    }
                }
                .disabled(!canStartOrStopSession)
            }
        }
    }

    private var quickInputCard: some View {
        KoeCard {
            HStack(spacing: 10) {
                TextField("输入闪记标题（可选）", text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 210)
                    .onSubmit { saveQuickTextNote() }
                TextField("随手记下一段想法，回车直接保存", text: $draftText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveQuickTextNote() }
                KoeActionButton("保存文字闪记", systemImage: "plus", isPrimary: false) {
                    saveQuickTextNote()
                }
                .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var workflowStrip: some View {
        let stages = ["录音或输入", "原文保留", "AI 理解", "收件箱与项目归类", "复查与导出"]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                    HStack(spacing: 6) {
                        Text("\(index + 1)")
                            .font(.system(size: AppFontSizes.xs, weight: .semibold))
                            .foregroundStyle(AppColors.accent)
                            .frame(width: 20, height: 20)
                            .background(AppColors.accentSoft, in: RoundedRectangle(cornerRadius: 4))
                        Text(stage)
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.textSecondary)
                        if index < stages.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: AppFontSizes.xs))
                                .foregroundStyle(AppColors.textMuted)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AppColors.bgPanel, in: RoundedRectangle(cornerRadius: AppRadii.control))
            .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(AppColors.border))
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterPill("全部 (\(quickNote.totalCount))", isSelected: selectedFilter == .all) {
                    selectedFilter = .all
                }
                filterPill("收件箱 (\(quickNote.inboxCount))", isSelected: selectedFilter == .inbox) {
                    selectedFilter = .inbox
                }
                ForEach(quickNote.projects) { project in
                    filterPill(
                        "\(project.name) (\(project.count))",
                        isSelected: selectedFilter == .project(project.name)
                    ) {
                        selectedFilter = .project(project.name)
                    }
                }
            }
        }
    }

    private var cardSelectorStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(visibleCards) { card in
                    let selected = activeCard?.id == card.id
                    Button {
                        store.send("select_quick_note_record", ["recordId": card.id])
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(card.title)
                                    .font(.system(size: AppFontSizes.sm, weight: selected ? .semibold : .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                KoeBadge(
                                    card.project ?? "收件箱",
                                    tint: card.project == nil ? AppColors.warning : AppColors.textSecondary
                                )
                            }
                            Text(card.segments.first?.text ?? card.status)
                                .font(.system(size: AppFontSizes.xs))
                                .foregroundStyle(AppColors.textMuted)
                                .lineLimit(1)
                            Text("\(TimeLabel.date(card.createdAtEpochSec))  \(card.source)")
                                .font(.system(size: AppFontSizes.xs))
                                .foregroundStyle(AppColors.textMuted)
                        }
                        .padding(12)
                        .frame(width: 250, alignment: .leading)
                        .background(
                            selected ? AppColors.accentSoft : AppColors.surface1,
                            in: RoundedRectangle(cornerRadius: AppRadii.cardOuter)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadii.cardOuter)
                                .stroke(selected ? AppColors.accent : AppColors.border)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func filterPill(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: AppFontSizes.xs, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? AppColors.accent : AppColors.textMuted)
                .padding(.horizontal, 12)
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

    private func saveQuickTextNote() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.send("create_note", [
            "title": draftTitle,
            "text": trimmed,
            "stayOnPage": true
        ])
        guard store.snapshot.error == nil && store.nativeError == nil else { return }
        draftTitle = ""
        draftText = ""
    }
}
