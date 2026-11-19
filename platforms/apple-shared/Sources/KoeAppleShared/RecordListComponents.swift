import SwiftUI

struct RecordRow: View {
    let record: RecordSnapshot
    let store: HostSessionStore
    let projects: [String]
    let isManaging: Bool
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var renameDraft: String
    let onToggleSelect: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onExportRecord: (String) -> Void

    @State private var isHovered = false
    @State private var showProjectPopover = false
    @FocusState private var isRenameFocused: Bool

    private var metadataLine: String {
        var parts = [TimeLabel.date(record.createdAtEpochSec), record.source]
        if record.durationMs > 0 {
            parts.append(TimeLabel.duration(record.durationMs))
        }
        return parts.joined(separator: "  ")
    }

    var body: some View {
        HStack(spacing: 14) {
            if isManaging {
                selectionCheckbox
            }

            rowLeadingAndBody

            if !isRenaming {
                if !isManaging && (isHovered || showProjectPopover) {
                    hoverActionButtons
                } else {
                    metadataBadges
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: AppRadii.control))
        .overlay(alignment: .bottom) { Rectangle().fill(AppColors.border).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onChange(of: isRenaming, initial: true) { _, active in
            if active {
                isRenameFocused = true
            }
        }
        .contextMenu {
            Button("重命名") {
                onBeginRename()
            }
            Menu("归类到项目") {
                Button("移回收件箱（清除项目）") {
                    store.send(.setRecordProject(recordId: record.id, project: nil))
                }
                if !projects.isEmpty {
                    Divider()
                    ForEach(projects, id: \.self) { name in
                        Button(name) {
                            store.send(.setRecordProject(recordId: record.id, project: name))
                        }
                    }
                }
            }
            Button("导出 Markdown") {
                onExportRecord(record.id)
            }
            Divider()
            Button(record.archived ? "取消归档保护" : "归档保护") {
                store.send(.setRecordArchived(recordId: record.id, archived: !record.archived))
            }
            Button("移到回收站") {
                store.send(.trashRecord(recordId: record.id))
            }
            .disabled(!record.canTrash)
        }
    }

    private var rowBackground: Color {
        if isManaging && isSelected {
            return AppColors.accentSoft
        }
        if isHovered && !isRenaming {
            return AppColors.bgPanel
        }
        return Color.clear
    }

    private var selectionCheckbox: some View {
        Button {
            onToggleSelect()
        } label: {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: AppFontSizes.md))
                .foregroundStyle(isSelected ? AppColors.accent : AppColors.textMuted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? "取消选择 \(record.title)" : "选择 \(record.title)")
    }

    @ViewBuilder
    private var rowLeadingAndBody: some View {
        if isRenaming {
            HStack(spacing: 12) {
                recordIcon
                TextField("记录标题", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: AppFontSizes.sm))
                    .focused($isRenameFocused)
                    .onSubmit { onCommitRename() }
                KoeActionButton("保存", isPrimary: true) {
                    onCommitRename()
                }
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                KoeActionButton("取消") {
                    onCancelRename()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Button {
                if isManaging {
                    onToggleSelect()
                } else {
                    store.send(.selectRecord(recordId: record.id))
                }
            } label: {
                HStack(spacing: 14) {
                    recordIcon
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.title)
                            .font(.system(size: AppFontSizes.sm, weight: .medium))
                            .foregroundStyle(AppColors.textPrimary)
                            .lineLimit(1)
                        Text(record.preview.isEmpty ? record.source : record.preview)
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.textMuted)
                            .lineLimit(1)
                        Text(metadataLine)
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.textMuted)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var recordIcon: some View {
        Image(systemName: record.durationMs > 0 ? "waveform" : "doc.text")
            .foregroundStyle(AppColors.accent)
            .frame(width: 38, height: 38)
            .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: 7))
    }

    private var metadataBadges: some View {
        HStack(spacing: 8) {
            KoeBadge(record.modeLabel, tint: AppColors.accent)
            if let project = record.project, !project.isEmpty {
                KoeBadge(project, tint: AppColors.textSecondary)
            } else if record.isQuickNoteInbox {
                KoeBadge("收件箱", tint: AppColors.warning)
            }
            if record.archived {
                KoeBadge("已归档", tint: AppColors.textSecondary)
            }
            KoeBadge(record.status)
            if !isManaging {
                Image(systemName: "chevron.right")
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textMuted)
            }
        }
    }

    private var hoverActionButtons: some View {
        HStack(spacing: 6) {
            rowIconButton(systemImage: "pencil", label: "重命名", tint: AppColors.textSecondary) {
                onBeginRename()
            }
            rowIconButton(systemImage: "folder", label: "归类项目", tint: AppColors.textSecondary) {
                showProjectPopover = true
            }
            .popover(isPresented: $showProjectPopover, arrowEdge: .bottom) {
                RecordProjectPickerPopover(
                    title: "归类到项目",
                    currentProject: record.project,
                    existingProjects: projects,
                    onSelect: { project in
                        store.send(.setRecordProject(recordId: record.id, project: project))
                        showProjectPopover = false
                    }
                )
            }
            rowIconButton(
                systemImage: record.archived ? "lock.open" : "lock",
                label: record.archived ? "取消归档保护" : "归档保护",
                tint: AppColors.textSecondary
            ) {
                store.send(.setRecordArchived(recordId: record.id, archived: !record.archived))
            }
            rowIconButton(
                systemImage: "trash",
                label: record.archived ? "已开启归档保护，取消归档后可移入回收站" : "移到回收站",
                tint: AppColors.danger
            ) {
                store.send(.trashRecord(recordId: record.id))
            }
            .disabled(!record.canTrash)
        }
    }

    private func rowIconButton(
        systemImage: String,
        label: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: AppFontSizes.xs, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(AppColors.surface0, in: RoundedRectangle(cornerRadius: AppRadii.control))
                .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(AppColors.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct RecordProjectPickerPopover: View {
    let title: String
    let currentProject: String?
    let existingProjects: [String]
    let onSelect: (String?) -> Void

    @State private var draftProject = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: AppFontSizes.xs, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)

            HStack(spacing: 8) {
                TextField("输入新项目名称", text: $draftProject)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: AppFontSizes.xs))
                    .onSubmit { submitDraft() }
                KoeActionButton("归类", isPrimary: true) {
                    submitDraft()
                }
                .disabled(draftProject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !existingProjects.isEmpty {
                Divider().overlay(AppColors.border)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(existingProjects, id: \.self) { name in
                            let selected = currentProject == name
                            Button {
                                onSelect(name)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(name)
                                        .font(.system(size: AppFontSizes.xs, weight: selected ? .semibold : .regular))
                                        .foregroundStyle(AppColors.textPrimary)
                                        .lineLimit(1)
                                    Spacer()
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: AppFontSizes.xs))
                                            .foregroundStyle(AppColors.accent)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                                .background(
                                    selected ? AppColors.accentSoft : Color.clear,
                                    in: RoundedRectangle(cornerRadius: AppRadii.control)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            Divider().overlay(AppColors.border)
            Button {
                onSelect(nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tray")
                    Text("移回收件箱（清除项目）")
                    Spacer()
                }
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textSecondary)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 264)
        .background(AppColors.surface0)
        .preferredColorScheme(.light)
    }

    private func submitDraft() {
        let trimmed = draftProject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSelect(trimmed)
    }
}

struct BatchRecordActionBar: View {
    let selectedRecords: [RecordSnapshot]
    let existingProjects: [String]
    let onAssignProject: (String?) -> Void
    let onSetArchived: (Bool) -> Void
    let onExportMarkdown: () -> Void
    let onTrash: () -> Void

    @State private var showProjectPopover = false

    private var selectedCount: Int { selectedRecords.count }
    private var archivedCount: Int { selectedRecords.filter(\.archived).count }
    private var deletableCount: Int { selectedRecords.filter(\.canTrash).count }
    private var allArchived: Bool { selectedCount > 0 && archivedCount == selectedCount }

    var body: some View {
        HStack(spacing: 10) {
            Text("已选 \(selectedCount) 条")
                .font(.system(size: AppFontSizes.xs, weight: .medium))
                .foregroundStyle(AppColors.textPrimary)
                .monospacedDigit()

            if archivedCount > 0 {
                KoeBadge("其中 \(archivedCount) 条已归档保护", tint: AppColors.textSecondary)
            }

            Spacer(minLength: 8)

            KoeActionButton("归类项目", systemImage: "folder") {
                showProjectPopover = true
            }
            .disabled(selectedCount == 0)
            .popover(isPresented: $showProjectPopover, arrowEdge: .top) {
                RecordProjectPickerPopover(
                    title: "批量归类到项目",
                    currentProject: nil,
                    existingProjects: existingProjects,
                    onSelect: { project in
                        onAssignProject(project)
                        showProjectPopover = false
                    }
                )
            }

            KoeActionButton(
                allArchived ? "取消归档" : "归档保护",
                systemImage: allArchived ? "lock.open" : "lock"
            ) {
                onSetArchived(!allArchived)
            }
            .disabled(selectedCount == 0)

            KoeActionButton("导出 Markdown", systemImage: "square.and.arrow.up") {
                onExportMarkdown()
            }
            .disabled(selectedCount == 0)

            Button {
                onTrash()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text(deletableCount > 0 ? "移到回收站 (\(deletableCount))" : "移到回收站")
                }
                .font(.system(size: AppFontSizes.xs, weight: .medium))
                .foregroundStyle(AppColors.danger)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .background(AppColors.danger.opacity(0.07), in: RoundedRectangle(cornerRadius: AppRadii.control))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadii.control)
                        .stroke(AppColors.danger.opacity(0.35))
                )
                .opacity(deletableCount > 0 ? 1.0 : 0.42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(deletableCount == 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(AppColors.surface1)
        .overlay(alignment: .top) { Rectangle().fill(AppColors.border).frame(height: 1) }
    }
}
