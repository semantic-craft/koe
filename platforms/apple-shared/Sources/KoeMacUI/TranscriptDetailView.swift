import SwiftUI

struct StaleMinutesBanner: View {
    let recordId: String
    let isProcessing: Bool
    let store: HostSessionStore

    var body: some View {
        KoeCard {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("原文或说话人已更新，当前纪要待重新整理")
                        .font(.system(size: AppFontSizes.sm, weight: .medium)).foregroundStyle(AppColors.textPrimary)
                    Text("点击右侧按钮可按最新原文与说话人重新生成纪要，未操作前仍保留旧版内容。")
                        .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textSecondary)
                }
                Spacer()
                KoeActionButton("重新整理纪要", systemImage: "arrow.clockwise", isPrimary: true) {
                    store.send(.summarize(recordId: recordId))
                }.disabled(isProcessing)
            }
        }
    }
}

struct TranscriptDetailView: View {
    let detail: RecordDetailSnapshot
    let store: HostSessionStore
    var onScrollToSegment: (String) -> Void = { _ in }
    @State private var editingSegmentId: String?
    @State private var segmentTextDraft = ""
    @State private var namingSegmentId: String?
    @State private var segmentSpeakerDraft = ""
    @State private var renamingBatchSpeaker: String?
    @State private var batchSpeakerDraft = ""

    var body: some View {
        Group {
            if detail.segments.isEmpty {
                EmptyState(
                    icon: "text.bubble",
                    title: "还没有文字",
                    detail: detail.audioPath == nil ? "这条记录尚未包含原文。" : "录音已保留，配置转写服务后可以开始转写。"
                )
                if detail.audioPath != nil {
                    KoeActionButton("转写并整理", isPrimary: true) {
                        store.send(.transcribe(recordId: detail.id))
                    }.disabled(detail.isProcessing)
                }
            } else {
                if detail.minutesStale {
                    StaleMinutesBanner(recordId: detail.id, isProcessing: detail.isProcessing, store: store)
                }
                if !detail.canEditTranscript {
                    Text(detail.archived
                         ? "已开启归档保护，取消归档后可编辑原文与说话人。"
                         : "正在录音、同步或转写中，完成后可编辑原文与说话人。")
                        .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                }
                if detail.canRetranscribe {
                    VStack(alignment: .leading, spacing: 8) {
                        KoeActionButton("重新转写完整录音", systemImage: "arrow.clockwise") {
                            store.send(.transcribe(recordId: detail.id))
                        }.disabled(detail.isProcessing)
                        Text("保留原记录和来源，在新副本中重新转写完整录音。")
                            .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                    }
                }
                if !detail.speakers.isEmpty { speakerBar }
                ForEach(detail.segments) { segment in segmentCard(segment) }
            }
        }
        .onChange(of: detail.id) { _, _ in resetDrafts() }
        .onChange(of: detail.canEditTranscript) { _, editable in
            if !editable { resetDrafts() }
        }
    }

    private var speakerBar: some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("说话人").font(.system(size: AppFontSizes.xs, weight: .medium)).foregroundStyle(AppColors.textMuted)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(detail.speakers) { sp in speakerChip(sp) }
                        }
                    }
                }
                if let targetSpeaker = renamingBatchSpeaker,
                   detail.canEditTranscript,
                   detail.speakers.contains(where: { $0.name == targetSpeaker }) {
                    HStack(spacing: 10) {
                        TextField("将「\(targetSpeaker)」批量改为新名称", text: $batchSpeakerDraft)
                            .textFieldStyle(.roundedBorder).font(.system(size: AppFontSizes.sm))
                            .onSubmit { submitBatchRename(from: targetSpeaker) }
                        KoeActionButton("批量改名", isPrimary: true) { submitBatchRename(from: targetSpeaker) }
                            .disabled(batchSpeakerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("取消") { renamingBatchSpeaker = nil }
                            .buttonStyle(.borderless).font(.system(size: AppFontSizes.xs))
                    }
                    let others = detail.speakers.filter { $0.name != targetSpeaker }
                    if !others.isEmpty {
                        HStack(spacing: 10) {
                            Text("快捷合并").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(others) { other in
                                        KoeActionButton("合并到 \(other.name)") {
                                            mergeSpeaker(from: targetSpeaker, to: other.name)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func speakerChip(_ sp: SpeakerSummarySnapshot) -> some View {
        let isSelected = renamingBatchSpeaker == sp.name && detail.canEditTranscript
        return Button {
            onScrollToSegment(sp.firstSegmentId)
            if detail.canEditTranscript {
                if renamingBatchSpeaker == sp.name {
                    renamingBatchSpeaker = nil
                } else {
                    renamingBatchSpeaker = sp.name
                    batchSpeakerDraft = sp.name
                }
            }
        } label: {
            Text("\(sp.name) \(sp.segmentCount) 段")
                .font(.system(size: AppFontSizes.xs, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? AppColors.accent : AppColors.textSecondary)
                .padding(.horizontal, 10).frame(minHeight: 30)
                .background(isSelected ? AppColors.accentSoft : AppColors.bgSubtle,
                            in: RoundedRectangle(cornerRadius: AppRadii.control))
                .overlay(RoundedRectangle(cornerRadius: AppRadii.control)
                    .stroke(isSelected ? AppColors.accent : AppColors.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func segmentCard(_ segment: SegmentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            segmentHeader(segment)
            if namingSegmentId == segment.id && detail.canEditTranscript {
                segmentSpeakerEditor(segment)
            }
            if editingSegmentId == segment.id && detail.canEditTranscript {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("修正这段原文", text: $segmentTextDraft, axis: .vertical)
                        .textFieldStyle(.roundedBorder).font(.system(size: AppFontSizes.sm))
                        .onSubmit { applySegmentText(segment.id, text: segmentTextDraft) }
                    HStack(spacing: 12) {
                        KoeActionButton("保存修改", isPrimary: true) {
                            applySegmentText(segment.id, text: segmentTextDraft)
                        }
                        .disabled(segmentTextDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("取消") { editingSegmentId = nil }
                            .buttonStyle(.borderless).font(.system(size: AppFontSizes.xs))
                    }
                }
            } else {
                Text(segment.text).font(.system(size: AppFontSizes.sm)).lineSpacing(7).textSelection(.enabled)
            }
            if let orig = segment.originalText {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("识别原文：\(orig)")
                        .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted).textSelection(.enabled)
                    if detail.canEditTranscript {
                        Button("恢复识别原文") { applySegmentText(segment.id, text: orig) }
                            .buttonStyle(.borderless).font(.system(size: AppFontSizes.xs))
                    }
                }
            }
            segmentFooter(segment)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(store.recordDetail.focusSegmentId == segment.id ? AppColors.accentSoft : AppColors.surface1,
                    in: RoundedRectangle(cornerRadius: 7)).id(segment.id)
    }

    private func segmentHeader(_ segment: SegmentSnapshot) -> some View {
        HStack(spacing: 10) {
            Button {
                if segment.timed != false { store.send(.seek(positionMs: segment.startMs)) }
            } label: {
                Text(segment.timed == false ? "无时码" : TimeLabel.duration(segment.startMs))
                    .monospacedDigit()
                    .foregroundStyle(segment.timed == false ? AppColors.textMuted : AppColors.accent)
            }
            .buttonStyle(.borderless).disabled(segment.timed == false)

            if detail.canEditTranscript {
                Button(segment.speaker ?? "设置说话人") {
                    segmentSpeakerDraft = segment.speaker ?? ""
                    namingSegmentId = segment.id
                    editingSegmentId = nil
                }
                .buttonStyle(.borderless)
                .foregroundStyle(segment.speaker == nil ? AppColors.textMuted : AppColors.textSecondary)
            } else {
                Text(segment.speaker ?? "原文").foregroundStyle(AppColors.textMuted)
            }

            if segment.isEdited { KoeBadge("已编辑", tint: AppColors.textSecondary) }
            Spacer()
            Menu {
                if let orig = segment.originalText {
                    Button("恢复识别原文") { applySegmentText(segment.id, text: orig) }
                        .disabled(!detail.canEditTranscript)
                    Divider()
                }
                Button("标记重点") { store.send(.addHighlight(recordId: detail.id, segmentId: segment.id)) }
                Button("设为待办") { store.send(.createTask(recordId: detail.id, segmentId: segment.id)) }
                Button("记住") { store.send(.saveMemory(recordId: detail.id, segmentId: segment.id)) }
            } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26) }
                .menuStyle(.borderlessButton).frame(width: 28)
        }
        .font(.system(size: AppFontSizes.xs))
    }

    private func segmentSpeakerEditor(_ segment: SegmentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("此段说话人（留空清除）", text: $segmentSpeakerDraft)
                    .textFieldStyle(.roundedBorder).font(.system(size: AppFontSizes.xs))
                    .onSubmit { submitSegmentSpeaker(segment.id) }
                KoeActionButton("保存说话人") { submitSegmentSpeaker(segment.id) }
                Button("清除") { applySegmentSpeaker(segment.id, speaker: "") }
                    .buttonStyle(.borderless).font(.system(size: AppFontSizes.xs))
                Button("取消") { namingSegmentId = nil }
                    .buttonStyle(.borderless).font(.system(size: AppFontSizes.xs))
            }
            if !detail.speakers.isEmpty {
                HStack(spacing: 10) {
                    Text("已有说话人").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(detail.speakers) { sp in
                                Button(sp.name) { applySegmentSpeaker(segment.id, speaker: sp.name) }
                                    .buttonStyle(.borderless).font(.system(size: AppFontSizes.xs))
                            }
                        }
                    }
                }
            }
        }
    }

    private func segmentFooter(_ segment: SegmentSnapshot) -> some View {
        HStack(spacing: 16) {
            if detail.canEditTranscript {
                Button("编辑原文") {
                    segmentTextDraft = segment.text
                    editingSegmentId = segment.id
                    namingSegmentId = nil
                }
                Button(segment.speaker == nil ? "标注说话人" : "改说话人") {
                    segmentSpeakerDraft = segment.speaker ?? ""
                    namingSegmentId = segment.id
                    editingSegmentId = nil
                }
            }
            Button("标记重点") { store.send(.addHighlight(recordId: detail.id, segmentId: segment.id)) }
            Button("设为待办") { store.send(.createTask(recordId: detail.id, segmentId: segment.id)) }
            Button("记住") { store.send(.saveMemory(recordId: detail.id, segmentId: segment.id)) }
        }
        .buttonStyle(.borderless).font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
    }

    private func resetDrafts() {
        editingSegmentId = nil
        segmentTextDraft = ""
        namingSegmentId = nil
        segmentSpeakerDraft = ""
        renamingBatchSpeaker = nil
        batchSpeakerDraft = ""
    }

    private func applySegmentText(_ segmentId: String, text: String) {
        store.send(.editSegmentText(recordId: detail.id, segmentId: segmentId, text: text))
        if store.navigation.effectiveError == nil && editingSegmentId == segmentId {
            editingSegmentId = nil
        }
    }

    private func submitSegmentSpeaker(_ segmentId: String) {
        applySegmentSpeaker(segmentId, speaker: segmentSpeakerDraft)
    }

    private func applySegmentSpeaker(_ segmentId: String, speaker: String) {
        store.send(.setSegmentSpeaker(recordId: detail.id, segmentId: segmentId, speaker: speaker))
        if store.navigation.effectiveError == nil { namingSegmentId = nil }
    }

    private func submitBatchRename(from fromSpeaker: String) {
        mergeSpeaker(from: fromSpeaker, to: batchSpeakerDraft)
    }

    private func mergeSpeaker(from fromSpeaker: String, to toSpeaker: String) {
        store.send(.renameSpeaker(recordId: detail.id, fromSpeaker: fromSpeaker, toSpeaker: toSpeaker))
        if store.navigation.effectiveError == nil {
            renamingBatchSpeaker = nil
            batchSpeakerDraft = ""
        }
    }
}
