import SwiftUI

struct TrashView: View {
    let store: HostSessionStore
    @State private var purgeTarget: TrashRecordSnapshot?
    @State private var confirmEmptyTrash = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    PageHeading(title: "回收站", subtitle: "移入回收站的记录保留 30 天，到期后自动彻底清除。")
                    Spacer()
                    if !store.snapshot.trashRecords.isEmpty {
                        KoeActionButton("清空回收站", systemImage: "trash.slash") {
                            confirmEmptyTrash = true
                        }
                    }
                }
                if store.snapshot.trashRecords.isEmpty {
                    EmptyState(
                        icon: "trash",
                        title: "回收站是空的",
                        detail: "移入回收站的记录会在这里保留 30 天，期间随时可以恢复。"
                    )
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(store.snapshot.trashRecords) { item in
                            trashRow(item)
                        }
                    }
                }
            }
            .padding(30)
        }
        .onChange(of: store.snapshot.trashRecords) { _, items in
            if let target = purgeTarget, !items.contains(where: { $0.id == target.id }) {
                purgeTarget = nil
            }
            if items.isEmpty {
                confirmEmptyTrash = false
            }
        }
        .confirmationDialog(
            "彻底删除这条记录？",
            isPresented: Binding(
                get: { purgeTarget != nil },
                set: { if !$0 { purgeTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: purgeTarget
        ) { target in
            Button("彻底删除", role: .destructive) {
                store.send(.purgeRecord(recordId: target.id))
                purgeTarget = nil
            }
            Button("取消", role: .cancel) {
                purgeTarget = nil
            }
        } message: { target in
            Text("《\(target.title)》及其本地录音文件将被永久清除，无法恢复。")
        }
        .confirmationDialog(
            "清空回收站？",
            isPresented: $confirmEmptyTrash,
            titleVisibility: .visible
        ) {
            Button("清空回收站", role: .destructive) {
                store.send(.emptyTrash)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("回收站中的 \(store.snapshot.trashRecords.count) 条记录及其本地录音文件将被永久清除，无法恢复。")
        }
    }

    private func trashRow(_ item: TrashRecordSnapshot) -> some View {
        HStack(spacing: 14) {
            Image(systemName: item.durationMs > 0 ? "waveform" : "doc.text")
                .foregroundStyle(AppColors.textMuted)
                .frame(width: 38, height: 38)
                .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.system(size: AppFontSizes.sm, weight: .medium))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                if !item.preview.isEmpty {
                    Text(item.preview)
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                        .lineLimit(1)
                }
                HStack(spacing: 12) {
                    Text(item.source)
                    if item.durationMs > 0 {
                        Text(TimeLabel.duration(item.durationMs)).monospacedDigit()
                    }
                    Text("剩余 \(item.remainingDays) 天")
                    Text("\(TimeLabel.date(item.trashedAtMs / 1000)) 移入")
                }
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textMuted)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                KoeActionButton("恢复", systemImage: "arrow.uturn.backward") {
                    store.send(.restoreRecord(recordId: item.id))
                }
                KoeActionButton("彻底删除") {
                    purgeTarget = item
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface1, in: RoundedRectangle(cornerRadius: AppRadii.cardOuter))
        .overlay(RoundedRectangle(cornerRadius: AppRadii.cardOuter).stroke(AppColors.border))
    }
}
