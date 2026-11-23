import SwiftUI

struct QuickNoteCardInspectorView: View {
    let card: QuickNoteCardSnapshot
    let projects: [QuickNoteProjectCountSnapshot]
    let store: HostSessionStore
    @Binding var includeAnalysis: Bool
    @Binding var includeSources: Bool
    let onExportWorkspace: (WorkspaceExportRequest) -> Void

    @State private var projectDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            actionHeaderCard

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    rawTranscriptColumn.frame(minWidth: 380, maxWidth: .infinity)
                    analysisAndNextStepsColumn.frame(minWidth: 360, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 16) {
                    rawTranscriptColumn
                    analysisAndNextStepsColumn
                }
            }
        }
        .onAppear { projectDraft = card.project ?? "" }
        .onChange(of: card.id) { _, _ in projectDraft = card.project ?? "" }
    }

    private var actionHeaderCard: some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(card.title)
                        .font(.system(size: AppFontSizes.md, weight: .semibold))
                        .lineLimit(1)
                    KoeBadge(
                        card.project ?? "收件箱",
                        tint: card.project == nil ? AppColors.warning : AppColors.accent
                    )
                    KoeBadge(card.status, tint: AppColors.textSecondary)
                    Spacer()
                    KoeActionButton("问本次内容", systemImage: "bubble.left.and.text.bubble.right") {
                        store.send(.setAskScope(scope: "record", recordId: card.id))
                        store.send(.navigate(section: "ask"))
                    }
                    KoeActionButton("完整校对与播放", systemImage: "slider.horizontal.below.rectangle") {
                        store.send(.selectRecord(recordId: card.id))
                    }
                }

                HStack(spacing: 10) {
                    if !projects.isEmpty {
                        Menu {
                            ForEach(projects) { project in
                                Button(project.name) {
                                    projectDraft = project.name
                                    store.send(.setRecordProject(recordId: card.id, project: project.name))
                                }
                            }
                        } label: {
                            Label("已有项目", systemImage: "folder")
                                .font(.system(size: AppFontSizes.xs))
                                .padding(.horizontal, 10)
                                .frame(minHeight: 30)
                        }
                    }

                    TextField("归入项目名称", text: $projectDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .onSubmit { assignTypedProject() }

                    KoeActionButton("归入项目", systemImage: "folder.badge.plus") {
                        assignTypedProject()
                    }
                    .disabled(projectDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if card.project != nil {
                        KoeActionButton("移回收件箱", systemImage: "tray.and.arrow.down") {
                            projectDraft = ""
                            store.send(.setRecordProject(recordId: card.id))
                        }
                    }

                    Spacer(minLength: 8)

                    Toggle("附带 AI 整理", isOn: $includeAnalysis)
                        .font(.system(size: AppFontSizes.xs))
                        .toggleStyle(.checkbox)
                    Toggle("附带来源标签", isOn: $includeSources)
                        .font(.system(size: AppFontSizes.xs))
                        .toggleStyle(.checkbox)
                    KoeActionButton("导出 Markdown", systemImage: "square.and.arrow.up") {
                        onExportWorkspace(
                            WorkspaceExportRequest.forQuickNote(
                                card,
                                includeAnalysis: includeAnalysis,
                                includeSources: includeSources
                            )
                        )
                    }
                }
            }
        }
    }

    private var rawTranscriptColumn: some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("原文保留")
                        .font(.system(size: AppFontSizes.md, weight: .semibold))
                    Spacer()
                    Text("点击任意原话跳转校对与定位")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                }

                if card.segments.isEmpty {
                    Text(card.status)
                        .font(.system(size: AppFontSizes.sm))
                        .foregroundStyle(AppColors.textMuted)
                        .padding(.vertical, 12)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(card.segments.enumerated()), id: \.element.id) { index, segment in
                            segmentRow(index: index + 1, segment: segment)
                        }
                    }
                }
            }
        }
    }

    private func segmentRow(index: Int, segment: SegmentSnapshot) -> some View {
        Button {
            store.send(.openSource(recordId: card.id, segmentId: segment.id))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("[S\(index)]")
                        .font(.system(size: AppFontSizes.xs, weight: .medium))
                        .foregroundStyle(AppColors.accent)
                        .monospacedDigit()
                    if let speaker = segment.speaker, !speaker.isEmpty {
                        KoeBadge(speaker, tint: AppColors.textSecondary)
                    }
                    if segment.timed == true || (segment.timed == nil && card.durationMs > 0) {
                        Text(TimeLabel.duration(segment.startMs))
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.textMuted)
                            .monospacedDigit()
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

    private var analysisAndNextStepsColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            KoeCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("这段话在说什么")
                            .font(.system(size: AppFontSizes.md, weight: .semibold))
                        Spacer()
                        if card.minutesStale {
                            KoeBadge("原文已改，待更新", tint: AppColors.warning)
                        }
                        if card.canSummarize {
                            KoeActionButton(
                                card.gist == nil && card.topics.isEmpty ? "生成理解" : "重新整理",
                                systemImage: "sparkles"
                            ) {
                                store.send(.summarize(recordId: card.id))
                            }
                        }
                    }

                    if let gist = card.gist {
                        Text(gist)
                            .font(.system(size: AppFontSizes.sm))
                            .foregroundStyle(AppColors.textPrimary)
                    }

                    if !card.topics.isEmpty {
                        ForEach(card.topics) { topic in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(topic.title)
                                    .font(.system(size: AppFontSizes.sm, weight: .medium))
                                if !topic.summary.isEmpty {
                                    Text(topic.summary)
                                        .font(.system(size: AppFontSizes.xs))
                                        .foregroundStyle(AppColors.textSecondary)
                                }
                                ForEach(topic.sources) { source in
                                    SourceLink(source: source, store: store)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppColors.bgPanel, in: RoundedRectangle(cornerRadius: AppRadii.control))
                        }
                    } else if card.gist == nil {
                        Text(card.canSummarize ? "尚未生成 AI 理解，原文已完整保留。" : "在模型设置中配置文本服务后可生成 AI 理解。")
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.textMuted)
                    }
                }
            }

            KoeCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("下一步确认")
                        .font(.system(size: AppFontSizes.md, weight: .semibold))

                    if card.nextSteps.isEmpty {
                        Text("还没有关联到本条闪记的待办或记忆。")
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.textMuted)
                        if let firstSegment = card.segments.first {
                            HStack(spacing: 8) {
                                KoeActionButton("从首段建待办", systemImage: "checklist") {
                                    store.send(.createTask(recordId: card.id, segmentId: firstSegment.id))
                                }
                                KoeActionButton("从首段存记忆", systemImage: "bookmark") {
                                    store.send(.saveMemory(recordId: card.id, segmentId: firstSegment.id))
                                }
                            }
                        }
                    } else {
                        ForEach(card.nextSteps) { item in
                            WorkspaceReviewItemRow(item: item, store: store)
                        }
                    }
                }
            }
        }
    }

    private func assignTypedProject() {
        let trimmed = projectDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.send(.setRecordProject(recordId: card.id, project: trimmed))
    }
}

struct WorkspaceReviewItemRow: View {
    let item: WorkspaceSourcedItemSnapshot
    let store: HostSessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if item.kind == "task" && item.state == "accepted" {
                    Button {
                        store.send(.completeTask(itemId: item.id, completed: !item.completed))
                    } label: {
                        Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: AppFontSizes.sm))
                            .foregroundStyle(item.completed ? AppColors.success : AppColors.textMuted)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        KoeBadge(
                            item.kind == "task" ? "待办" : "记忆",
                            tint: item.state == "proposed" ? AppColors.warning : AppColors.accent
                        )
                        if item.state == "proposed" {
                            KoeBadge("待确认", tint: AppColors.warning)
                        }
                        if let due = item.due, !due.isEmpty {
                            Text(due)
                                .font(.system(size: AppFontSizes.xs))
                                .foregroundStyle(AppColors.textMuted)
                        }
                    }
                    Text(item.text)
                        .font(.system(size: AppFontSizes.sm))
                        .foregroundStyle(item.completed ? AppColors.textMuted : AppColors.textPrimary)
                }
                Spacer(minLength: 6)
                if item.state == "proposed" {
                    HStack(spacing: 6) {
                        KoeActionButton("采纳", isPrimary: true) {
                            store.send(.reviewItem(itemId: item.id, decision: .accept))
                        }
                        KoeActionButton("忽略") {
                            store.send(.reviewItem(itemId: item.id, decision: .dismiss))
                        }
                    }
                }
            }
            ForEach(item.sources) { source in
                SourceLink(source: source, store: store)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.bgPanel, in: RoundedRectangle(cornerRadius: AppRadii.control))
    }
}
