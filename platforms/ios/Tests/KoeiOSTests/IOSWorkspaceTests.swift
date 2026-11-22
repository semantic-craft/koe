import KoeAppleCore
import SwiftUI
import ViewInspector
import XCTest
@testable import KoeiOSApp

@MainActor
final class IOSWorkspaceTests: XCTestCase {
    private func withWorkspace(_ body: (HostSessionStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path, credentials: NativeCredentialsiOS(forceIsolated: true))
        defer { store.shutdown() }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ios-rich-snapshot", withExtension: "json"))
        var fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        fixture["generation"] = 0
        let data = try JSONSerialization.data(withJSONObject: fixture)
        XCTAssertTrue(store.loadDebugSnapshotFixtureJSON(String(decoding: data, as: UTF8.self)))
        try body(store)
    }

    func testLiveTranscriptDraftErrorActionsAndLockedHistory() throws {
        try withWorkspace { store in
            let workspace = store.liveMinutesWorkspace
            let view = IOSModeWorkspacesView(store: store, route: .liveMinutes, onSelectRecord: { _ in
                XCTFail("往期会议应在页内切换")
            }, onOpenSource: { _ in })
            let root = try view.inspect()
            for text in [workspace.segments[0].text, workspace.drafts[0], workspace.actionItems[0].text, workspace.error!] {
                XCTAssertNoThrow(try root.find(text: text))
            }
            XCTAssertTrue(try root.find(button: workspace.pastMeetings[0].title).isDisabled())
        }
    }

    func testQuickNoteShowsSelectedTranscriptAnalysisAndReview() throws {
        try withWorkspace { store in
            let card = store.quickNoteWorkspace.cards[0]
            let root = try IOSModeWorkspacesView(store: store, route: .quickNote, onSelectRecord: { _ in }, onOpenSource: { _ in }).inspect()
            for text in [card.segments[0].text, card.gist!, card.topics[0].summary, card.nextSteps[0].text] {
                XCTAssertNoThrow(try root.find(text: text))
            }
            XCTAssertNoThrow(try root.find(button: "采纳"))
            XCTAssertNoThrow(try root.find(button: "忽略"))
        }
    }

    func testAllDayShowsDailyReviewAndSourcedDecisions() throws {
        try withWorkspace { store in
            let day = store.allDayWorkspace
            let root = try IOSModeWorkspacesView(store: store, route: .allDay, onSelectRecord: { _ in }, onOpenSource: { _ in }).inspect()
            for text in [day.dailyReview!.overview, day.reviewDecisions[0].text, day.reviewTasks[0].text, day.reviewMemories[0].text] {
                XCTAssertNoThrow(try root.find(text: text))
            }
        }
    }

    func testSavingTodayDraftIgnoresAnUnrelatedObserverError() throws {
        try withWorkspace { store in
            // The native adapter may report an unrelated error as the Rust snapshot arrives.
            store.onSnapshotChanged = { [weak store] _ in store?.reportNativeError("旧的麦克风错误") }
            var draft = "保留本次保存结果"
            let saved = draft
            IOSTodayView.submitQuickNote(draft: &draft, store: store)
            XCTAssertTrue(draft.isEmpty)
            XCTAssertEqual(store.quickNoteWorkspace.cards.first?.segments.first?.text, saved)
            XCTAssertNotNil(store.navigation.effectiveError)
        }
    }

    func testTodayOffersCaptureSourceSelection() throws {
        try withWorkspace { store in
            let root = try IOSTodayView(store: store, onOpenWorkspace: { _ in }).inspect()
            XCTAssertNoThrow(try root.find(viewWithAccessibilityIdentifier: "capture-source-picker"))
            let sheet = try IOSCaptureSourceSheet(store: store).inspect()
            for input in store.captureStudio.studio.inputs {
                XCTAssertTrue(try sheet.find(button: input.name).isDisabled())
            }
            XCTAssertNoThrow(try sheet.find(text: "正在录音，请先结束当前录音再切换输入源。"))
        }
    }

    func testCaptureSourceRowsSelectTheExactRustInputAndRestoreAutomaticSelection() throws {
        try withWorkspace { store in
            store.send(.syncAudioInputs(inputs: [
                .init(id: "builtin", name: "内置麦克风", transport: "built_in", isDefault: true),
                .init(id: "bt:two", name: "蓝牙耳机", transport: "bluetooth", isDefault: false),
                .init(id: "usb:one", name: "USB 麦克风", transport: "usb", isDefault: false),
            ]))
            let sheet = IOSCaptureSourceSheet(store: store)
            for input in store.captureStudio.studio.inputs {
                try sheet.inspect().find(button: input.name).tap()
                XCTAssertEqual(store.captureStudio.studio.selectedSource, input.sourceKey)
                XCTAssertEqual(store.captureStudio.studio.selectedInputId, input.id)
            }
            try sheet.inspect().find(button: "Soundcore Work 录音豆").tap()
            XCTAssertEqual(store.captureStudio.studio.selectedSource, "bean")
            try sheet.inspect().find(button: "自动优先").tap()
            XCTAssertEqual(store.captureStudio.studio.selectionMode, "auto")
        }
    }

    func testAllDayEventOpensFirstSegmentAndIntervalsHaveNoRecordAction() throws {
        try withWorkspace { store in
            var opened: SourceSnapshot?
            var record: String?
            let spans = store.allDayWorkspace.spans
            @MainActor func row(_ span: AllDaySpanSnapshot) -> IOSAllDaySpanRow {
                IOSAllDaySpanRow(span: span, onSelectRecord: { record = $0 }, onOpenSource: { opened = $0 })
            }
            let event = try XCTUnwrap(spans.first { $0.kind == "event" })
            try row(event).inspect().find(button: "回到原文").tap()
            XCTAssertEqual(opened, try XCTUnwrap(event.firstSegment))
            XCTAssertNil(record)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
            json.removeValue(forKey: "firstSegment")
            let legacy = try JSONDecoder().decode(AllDaySpanSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
            try row(legacy).inspect().find(button: "打开记录").tap()
            XCTAssertEqual(record, event.primaryRecordId)
            for kind in ["pause", "unrecorded_gap"] {
                let span = try XCTUnwrap(spans.first { $0.kind == kind })
                let interval = try row(span).inspect()
                XCTAssertNoThrow(try interval.find(ViewType.Label.self, containing: span.statusSummaryLabel))
                XCTAssertTrue(interval.findAll(ViewType.Button.self).isEmpty)
            }
        }
    }

    func testProjectMenusAssignOnlyTheChosenCards() throws {
        try withWorkspace { store in
            for title in ["一", "二", "三"] { store.send(.createNote(title: title, text: title)) }
            let cards = store.quickNoteWorkspace.cards
            XCTAssertEqual(cards.count, 3)
            store.send(.setRecordProject(recordId: cards[2].id, project: "资料"))
            store.send(.setRecordProject(recordId: cards[1].id, project: "另一个项目"))
            var selection: Set<String>?
            let list = IOSQuickNoteCardList(store: store, cards: cards, projects: store.quickNoteWorkspace.projects,
                                            inspectedID: cards[0].id, selection: Binding(get: { selection }, set: { selection = $0 }))
            let single = try list.inspect().find(IOSProjectMenu.self)
            try single.find(button: "资料").tap()
            XCTAssertEqual(store.quickNoteWorkspace.cards.first { $0.id == cards[0].id }?.project, "资料")
            try list.inspect().find(button: "多选").tap()
            for card in [cards[0], cards[2]] { try list.inspect().find(button: card.title).tap() }
            XCTAssertEqual(selection, Set([cards[0].id, cards[2].id]))
            try list.inspect().find(button: "移回收件箱").tap()
            XCTAssertNil(selection)
            XCTAssertEqual(store.quickNoteWorkspace.inboxCount, 2)
            XCTAssertEqual(store.quickNoteWorkspace.cards.first { $0.id == cards[1].id }?.project, "另一个项目")
        }
    }

    func testWorkspaceReviewButtonsAndSourceLinksUpdateRustState() throws {
        try withWorkspace { store in
            store.send(.createNote(title: "设计", text: "核对录音"))
            let detail = try XCTUnwrap(store.recordDetail.detail)
            let segment = try XCTUnwrap(detail.segments.first)
            store.send(.createTask(recordId: detail.id, segmentId: segment.id))
            store.send(.saveMemory(recordId: detail.id, segmentId: segment.id))
            let card = try XCTUnwrap(store.quickNoteWorkspace.cards.first)
            XCTAssertEqual(card.nextSteps.count, 2)
            for item in card.nextSteps {
                store.send(.reviewItem(itemId: item.id, decision: .reset))
                let proposed = try XCTUnwrap(store.quickNoteWorkspace.cards.first?.nextSteps.first { $0.id == item.id })
                var source: SourceSnapshot?
                // Display the real Rust item in the daily slice as well, so the button
                // must carry its persisted identity through the workspace's view hierarchy.
                var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.snapshot)) as? [String: Any])
                var workspaces = try XCTUnwrap(snapshot["workspaces"] as? [String: Any])
                var day = try XCTUnwrap(workspaces["allDay"] as? [String: Any])
                day[item.kind == "task" ? "reviewTasks" : "reviewMemories"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([proposed]))
                workspaces["allDay"] = day
                snapshot["workspaces"] = workspaces
                XCTAssertTrue(store.loadDebugSnapshotFixtureJSON(String(decoding: try JSONSerialization.data(withJSONObject: snapshot), as: UTF8.self)))
                let mode: IOSModeWorkspaceRoute = item.kind == "task" ? .quickNote : .allDay
                let view = IOSModeWorkspacesView(store: store, route: mode, onSelectRecord: { _ in }, onOpenSource: { source = $0 })
                let row = try view.inspect().find(IOSWorkspaceReviewRow.self, where: { try $0.actualView().item.id == item.id })
                try row.find(IOSSourceLink.self).find(ViewType.Button.self).tap()
                XCTAssertEqual(source?.recordId, detail.id)
                XCTAssertEqual(source?.segmentId, segment.id)
                if item.kind == "task" {
                    try row.find(button: "采纳").tap()
                    XCTAssertEqual(store.snapshot.tasks.first?.state, "accepted")
                } else {
                    try row.find(button: "忽略").tap()
                    XCTAssertFalse(store.quickNoteWorkspace.cards[0].nextSteps.contains { $0.id == item.id })
                    XCTAssertNil(store.navigation.effectiveError)
                }
            }
        }
    }

    func testIdleMeetingSwitchesInPlaceAndTranscriptTargetsTheSelectedRecord() throws {
        try withWorkspace { store in
            var opened: SourceSnapshot?
            var pushed: String?
            let view = IOSLiveMinutesWorkspaceView(store: store, onSelectRecord: { pushed = $0 }, onOpenSource: { opened = $0 })
            let live = store.liveMinutesWorkspace
            try view.inspect().find(button: live.segments[0].text).tap()
            XCTAssertEqual(opened?.recordId, live.selectedRecordId)
            XCTAssertEqual(opened?.segmentId, live.segments[0].id)
            for index in 0..<2 {
                store.startCapture(.meeting, stayOnPage: true)
                let mic = try XCTUnwrap(store.snapshot.microphone)
                store.send(.microphonePrepared(recordId: mic.recordId, sessionId: mic.sessionId, epoch: 0, clockNs: 1_000_000_000))
                store.send(.microphoneStarted(recordId: mic.recordId, sessionId: mic.sessionId, lane: "microphone", sampleRate: 16000))
                _ = store.ingestMicrophonePCM(recordId: mic.recordId, sessionId: mic.sessionId, lane: "microphone",
                                              sequence: 0, epoch: 0, capturedStartNs: 1_000_000_000, samples: Array(repeating: 0, count: 320))
                store.performCaptureAction(.end)
                store.send(.microphoneStopped(recordId: mic.recordId, sessionId: mic.sessionId, lane: "microphone", sequence: 1, epoch: 0))
                store.send(.renameRecord(recordId: mic.recordId, title: "会议 \(index)"))
            }
            let other = try XCTUnwrap(store.liveMinutesWorkspace.pastMeetings.first { $0.id != store.liveMinutesWorkspace.selectedRecordId })
            try view.inspect().find(button: other.title).tap()
            XCTAssertEqual(store.liveMinutesWorkspace.selectedRecordId, other.id)
            XCTAssertNil(pushed)
            try view.inspect().find(button: "查看完整详情").tap()
            XCTAssertEqual(pushed, other.id)
        }
    }

}
