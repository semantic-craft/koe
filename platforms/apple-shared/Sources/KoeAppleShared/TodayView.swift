import SwiftUI

struct TodayView: View {
    let store: HostSessionStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(title: "模式选择", subtitle: "选择接下来要做的事。")
                HStack(spacing: 10) {
                    ForEach(store.snapshot.captureModes.filter { $0.mode != .dictation }) { entry in
                        CaptureModeButton(entry: entry, store: store)
                    }
                    Button { store.send("prepare_voice_input") } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("语音输入", systemImage: "character.cursor.ibeam")
                                .font(.system(size: AppFontSizes.sm, weight: .semibold))
                            Text("双击录音豆，向输入框听写").font(.system(size: AppFontSizes.xs))
                                .foregroundStyle(AppColors.textSecondary)
                            Text(store.snapshot.voiceInput.sourceLabel).font(.system(size: AppFontSizes.xs))
                                .foregroundStyle(AppColors.textMuted).lineLimit(1)
                        }
                        .padding(12).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        .background(AppColors.bgPanel, in: RoundedRectangle(cornerRadius: AppRadii.control))
                        .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(AppColors.border))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!store.snapshot.voiceInput.canPrepare)
                }
            }
            .padding(30).frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

}

struct NotesView: View {
    let store: HostSessionStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center) {
                    PageHeading(title: "随心记", subtitle: "回看留下的文字和录音原文。")
                    Spacer()
                    if let quick = store.snapshot.captureModes.first(where: { $0.mode == .quickNote }) {
                        KoeActionButton("随手记一条", systemImage: quick.mode.icon, isPrimary: true) {
                            store.startCapture(quick.mode)
                        }.disabled(!quick.available)
                    }
                }
                JournalTimeline(store: store, recordIds: store.snapshot.journal.noteRecordIds, title: "笔记与原文", showDates: true)
            }.padding(30).frame(maxWidth: 940, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

private struct JournalTimeline: View {
    let store: HostSessionStore
    let recordIds: [String]
    let title: String
    var showDates = false

    var body: some View {
        let byId = Dictionary(uniqueKeysWithValues: store.snapshot.records.map { ($0.id, $0) })
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: AppFontSizes.md, weight: .semibold))
            if recordIds.isEmpty {
                EmptyState(icon: "waveform", title: "还没有片段", detail: "保存的记录会出现在这里。")
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(recordIds.compactMap { byId[$0] }) { record in
                        entry(record)
                    }
                }
            }
        }
    }

    private func entry(_ record: RecordSnapshot) -> some View {
        Button { store.send("select_record", ["recordId": record.id]) } label: {
            KoeCard {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            let date = Date(timeIntervalSince1970: TimeInterval(record.createdAtEpochSec))
                            Text(showDates ? TimeLabel.date(record.createdAtEpochSec) : date.formatted(.dateTime.hour().minute()))
                            if let ordinal = record.ordinal, record.runId != nil {
                                Text("全天听记  第 \(ordinal) 段")
                            } else {
                                Text(record.source)
                            }
                        }
                        .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                        Text(record.title).font(.system(size: AppFontSizes.md, weight: .semibold))
                        if !record.preview.isEmpty {
                            Text(record.preview).font(.system(size: AppFontSizes.sm))
                                .foregroundStyle(AppColors.textSecondary).lineLimit(3)
                        } else {
                            Text(record.status).font(.system(size: AppFontSizes.sm))
                                .foregroundStyle(AppColors.textSecondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").foregroundStyle(AppColors.textMuted)
                }
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct CaptureModeButton: View {
    let entry: CaptureModeSnapshot
    let store: HostSessionStore

    var body: some View {
        Button { store.startCapture(entry.mode) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label(entry.mode.title, systemImage: entry.mode.icon)
                    .font(.system(size: AppFontSizes.sm, weight: .semibold))
                Text(entry.mode.purpose).font(.system(size: AppFontSizes.xs)).lineLimit(1)
                    .foregroundStyle(AppColors.textSecondary)
                Text(entry.sourceLabel).font(.system(size: AppFontSizes.xs)).lineLimit(1)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(AppColors.bgPanel, in: RoundedRectangle(cornerRadius: AppRadii.control))
            .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(AppColors.border))
            .opacity(entry.available ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!entry.available).accessibilityLabel(entry.mode.title)
    }
}
