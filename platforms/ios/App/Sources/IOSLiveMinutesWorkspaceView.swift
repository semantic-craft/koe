import KoeAppleCore
import SwiftUI

struct IOSLiveMinutesWorkspaceView: View {
    let store: HostSessionStore
    let onSelectRecord: (String) -> Void
    let onOpenSource: (SourceSnapshot) -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(IOSFileActions.self) private var fileActions: IOSFileActions?
    @State private var showFinal: Bool?
    @State private var showSettings = false
    @State private var pendingDiagnosticsExport = false
    private var workspace: LiveMinutesWorkspaceSnapshot { store.liveMinutesWorkspace }

    var body: some View {
        IOSWorkspaceCaptureHeader(store: store, mode: .meeting, title: workspace.selectedTitle ?? "当前会议",
                                  source: workspace.sourceLabel, status: workspace.phaseBadgeLabel,
                                  isActive: workspace.isActive, canStart: workspace.canStart)
        if let error = workspace.error, !error.isEmpty {
            IOSCard { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(IOSColors.danger) }
        }
        if !workspace.configured {
            IOSCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("尚未配置文字整理服务").font(.headline)
                    Text("实时原文会继续保存。在模型设置中配置文字服务后，即可整理会议纪要。")
                    Button("打开模型设置") { showSettings = true }
                }
            }.sheet(isPresented: $showSettings, onDismiss: {
                if pendingDiagnosticsExport {
                    pendingDiagnosticsExport = false
                    fileActions?.exportDiagnosticsBundle()
                }
            }) {
                IOSSettingsView(
                    store: store,
                    onExportDiagnostics: fileActions == nil ? nil : { pendingDiagnosticsExport = true }
                )
            }
        }
        IOSLiveMinutesCoverageSlotView(store: store)
        if sizeClass == .regular {
            HStack(alignment: .top, spacing: 16) {
                transcript
                minutes
            }
        } else {
            transcript
            minutes
        }
        if !workspace.actionItems.isEmpty {
            IOSCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("行动与记忆").font(.headline)
                    ForEach(workspace.actionItems) { item in
                        IOSWorkspaceReviewRow(item: item, store: store, onOpenSource: onOpenSource)
                    }
                }
            }
        }
        if let id = workspace.selectedRecordId {
            IOSPrimaryButton("查看完整详情", isPrimary: false) { onSelectRecord(id) }
            IOSWorkspaceExport(title: "导出会议 Markdown") { analysis, sources in
                .forMeeting(recordId: id, title: workspace.selectedTitle, includeAnalysis: analysis, includeSources: sources)
            }
        }
        if !workspace.pastMeetings.isEmpty {
            Text("往期会议").font(.headline)
            ForEach(workspace.pastMeetings) { meeting in
                Button {
                    store.send(.selectLiveMinutesRecord(recordId: meeting.id))
                } label: {
                    IOSCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meeting.title)
                            Text("\(TimeLabel.duration(meeting.durationMs))  |  \(meeting.segmentCount) 段原文")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(workspace.isActive)
            }
        }
    }

    private var transcript: some View {
        IOSCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("实时原文").font(.headline)
                IOSWorkspaceTranscript(segments: workspace.segments, recordID: workspace.selectedRecordId,
                                       title: workspace.selectedTitle ?? "会议原文", onOpenSource: onOpenSource)
                ForEach(IOSWorkspaceLine.keyed(workspace.drafts)) { draft in
                    VStack(alignment: .leading, spacing: 4) {
                        IOSBadge("识别中")
                        Text(draft.text).foregroundStyle(.secondary)
                    }
                }
                if workspace.segments.isEmpty && workspace.drafts.isEmpty {
                    Text(workspace.isActive ? "等待实时转写…" : "本场会议暂无原文。").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var minutes: some View {
        let final = showFinal ?? (!workspace.isActive && !workspace.finalSections.isEmpty)
        let sections = final ? workspace.finalSections : workspace.liveSections
        return IOSCard {
            VStack(alignment: .leading, spacing: 12) {
                Picker("纪要版本", selection: Binding(get: { final }, set: { showFinal = $0 })) {
                    Text("实时整理").tag(false)
                    Text("会后定稿").tag(true)
                }.pickerStyle(.segmented)
                if sections.isEmpty {
                    Text(final ? "尚未生成会后定稿。" : "暂无实时整理条目。").foregroundStyle(.secondary)
                }
                ForEach(SummarySectionItem.keyed(sections)) { item in
                    Text(item.section.title).font(.headline)
                    Text(item.section.text).textSelection(.enabled)
                    IOSWorkspaceSources(sources: item.section.sources, onOpenSource: onOpenSource)
                }
            }
        }
        .onChange(of: workspace.selectedRecordId) { showFinal = nil }
        .onChange(of: workspace.isActive) { showFinal = nil }
    }
}
