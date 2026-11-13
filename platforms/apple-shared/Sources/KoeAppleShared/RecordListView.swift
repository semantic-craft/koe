import SwiftUI

struct RecordListView: View {
    let store: HostSessionStore
    @State private var showArchivedOnly = false
    private var archivedCount: Int {
        store.snapshot.records.filter(\.archived).count
    }
    private var filtered: [RecordSnapshot] {
        showArchivedOnly ? store.snapshot.records.filter(\.archived) : store.snapshot.records
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(title: "所有记录", subtitle: "每次讨论、每个想法，都可以回到原处。")
                if !store.snapshot.records.isEmpty || showArchivedOnly {
                    HStack(spacing: 8) {
                        filterPill("全部", count: store.snapshot.records.count, isSelected: !showArchivedOnly) {
                            showArchivedOnly = false
                        }
                        filterPill("已归档", count: archivedCount > 0 ? archivedCount : nil, isSelected: showArchivedOnly) {
                            showArchivedOnly = true
                        }
                        Spacer()
                    }
                }
                if store.snapshot.records.isEmpty && !showArchivedOnly {
                    EmptyState(icon: "rectangle.stack", title: "还没有记录", detail: "通过右上角导入文字、Markdown、WAV 或资料包，也可以新建文字记录。")
                } else if showArchivedOnly && filtered.isEmpty {
                    EmptyState(icon: "lock", title: "还没有已归档的记录", detail: "在记录上右键选择“归档保护”，或在详情页开启归档保护，防止重要录音被误删。")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { record in RecordRow(record: record, store: store) }
                    }
                }
            }.padding(30)
        }
    }
    private func filterPill(_ title: String, count: Int? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let count {
                    Text("\(count)").monospacedDigit()
                }
            }
            .font(.system(size: AppFontSizes.xs, weight: isSelected ? .medium : .regular))
            .foregroundStyle(isSelected ? AppColors.accent : AppColors.textMuted)
            .padding(.horizontal, 11).frame(minHeight: 30)
            .background(isSelected ? AppColors.accentSoft : AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
            .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(isSelected ? AppColors.accent.opacity(0.35) : AppColors.border))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct RecordRow: View {
    let record: RecordSnapshot
    let store: HostSessionStore
    var body: some View {
        Button { store.send("select_record", ["recordId": record.id]) } label: {
            HStack(spacing: 14) {
                Image(systemName: record.durationMs > 0 ? "waveform" : "doc.text")
                    .foregroundStyle(AppColors.accent).frame(width: 38, height: 38)
                    .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.title).font(.system(size: AppFontSizes.sm, weight: .medium)).lineLimit(1)
                    Text(record.preview.isEmpty ? record.source : record.preview)
                        .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted).lineLimit(1)
                    Text(TimeLabel.date(record.createdAtEpochSec)).font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                }
                Spacer(minLength: 10)
                if record.archived {
                    KoeBadge("已归档", tint: AppColors.textSecondary)
                }
                KoeBadge(record.status)
                Image(systemName: "chevron.right").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
            }.padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(AppColors.border).frame(height: 1) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .contextMenu {
            Button(record.archived ? "取消归档保护" : "归档保护") {
                store.send("set_record_archived", ["recordId": record.id, "archived": !record.archived])
            }
            Button("移到回收站") {
                store.send("trash_record", ["recordId": record.id])
            }
            .disabled(record.archived || record.status == "转写中" || record.status == "整理中")
        }
    }
}
