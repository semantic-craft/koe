import KoeAppleCore
import SwiftUI

struct IOSWorkspaceCaptureHeader: View {
    let store: HostSessionStore
    let mode: CaptureMode
    let title: String
    let source: String
    let status: String
    let isActive: Bool
    let canStart: Bool

    var body: some View {
        IOSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text(title).font(.headline)
                    Spacer(minLength: 4)
                    IOSBadge(status, tint: isActive ? IOSColors.success : IOSColors.textSecondary)
                }
                IOSCaptureSourceButton(store: store, title: source)
                if isActive {
                    IOSCaptureActionButtons(store: store, mode: mode)
                } else {
                    IOSPrimaryButton("开始\(mode.title)", systemImage: "mic.fill") {
                        store.startCapture(mode, stayOnPage: true)
                    }.disabled(!canStart)
                }
            }
        }
    }
}

struct IOSWorkspaceExport: View {
    let title: String
    let request: (Bool, Bool) -> WorkspaceExportRequest
    @Environment(IOSFileActions.self) private var files
    @State private var includeAnalysis = true
    @State private var includeSources = true

    var body: some View {
        IOSCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("附带 AI 分析", isOn: $includeAnalysis)
                Toggle("附带来源引用", isOn: $includeSources)
                IOSPrimaryButton(title, systemImage: "square.and.arrow.up", isPrimary: false) {
                    files.exportWorkspace(request(includeAnalysis, includeSources))
                }
            }
            .font(.subheadline)
        }
    }
}

struct IOSWorkspaceSources: View {
    let sources: [SourceSnapshot]
    let onOpenSource: (SourceSnapshot) -> Void

    var body: some View {
        ForEach(sources) { source in
            IOSSourceLink(source: source) { onOpenSource(source) }
        }
    }
}

struct IOSWorkspaceReviewRow: View {
    let item: WorkspaceSourcedItemSnapshot
    let store: HostSessionStore
    let onOpenSource: (SourceSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                IOSBadge(item.kind == "task" ? "待办" : "记忆")
                if item.state == "proposed" {
                    IOSBadge("待确认", tint: IOSColors.warning)
                } else if item.state == "accepted" {
                    IOSBadge(item.completed ? "已完成" : "已采纳", tint: IOSColors.success)
                }
                if let due = item.due { Text(due).font(.caption) }
            }
            Text(item.text)
            IOSWorkspaceSources(sources: item.sources, onOpenSource: onOpenSource)
            if item.state == "proposed" {
                HStack {
                    IOSPrimaryButton("采纳") { store.send(.reviewItem(itemId: item.id, decision: .accept)) }
                    IOSPrimaryButton("忽略", isPrimary: false) { store.send(.reviewItem(itemId: item.id, decision: .dismiss)) }
                }
            }
        }
    }
}

struct IOSWorkspaceTranscript: View {
    let segments: [SegmentSnapshot]
    let recordID: String?
    let title: String
    let onOpenSource: (SourceSnapshot) -> Void

    var body: some View {
        ForEach(segments) { segment in
            Button {
                if let recordID {
                    onOpenSource(SourceSnapshot(recordId: recordID, title: title, segment: segment))
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(TimeLabel.duration(segment.startMs)).monospacedDigit()
                        if let speaker = segment.speaker { Text(speaker) }
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.caption).foregroundStyle(IOSColors.accent)
                    Text(segment.text).multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(recordID == nil)
        }
    }
}


// Snapshot strings have no server ID. Keep identical lines distinct when a draft repeats.
struct IOSWorkspaceLine: Identifiable {
    struct ID: Hashable {
        let text: String
        let occurrence: Int
    }
    let id: ID
    var text: String { id.text }

    static func keyed(_ lines: [String]) -> [Self] {
        var counts: [String: Int] = [:]
        return lines.map { line in
            counts[line, default: 0] += 1
            return Self(id: ID(text: line, occurrence: counts[line, default: 0]))
        }
    }
}
