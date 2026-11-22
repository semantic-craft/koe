import KoeAppleCore
import SwiftUI
import ViewInspector
import XCTest
@testable import KoeiOSApp

@MainActor
final class IOSDetailWorkflowTests: XCTestCase {
    private var directory: URL!
    private var store: HostSessionStore!

    override func setUp() async throws {
        directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = HostSessionStore(workspacePath: directory.path, credentials: NativeCredentialsiOS(forceIsolated: true))
    }

    override func tearDown() async throws {
        store.shutdown()
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func loadFixture(_ change: (inout [String: Any]) -> Void = { _ in }) throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ios-rich-snapshot", withExtension: "json"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        change(&json)
        XCTAssertTrue(store.loadDebugSnapshotFixtureJSON(String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)))
    }

    func testStaleMinutesSourcesAndAssociatedReviewsAreAvailable() throws {
        try loadFixture { json in
            var detail = json["detail"] as! [String: Any]
            detail["minutesStale"] = true
            json["detail"] = detail
            json["focusSegmentId"] = NSNull()
        }
        let id = try XCTUnwrap(store.recordDetail.detail?.id)
        let view = IOSRecordDetailView(store: store, recordId: id)
        XCTAssertNoThrow(try view.inspect().find(button: "重新整理纪要"))
        XCTAssertNoThrow(try view.inspect().find(button: "重命名"))
        XCTAssertNoThrow(try view.inspect().find(button: "移入回收站"))
        XCTAssertNoThrow(try view.inspect().find(IOSSourceLink.self))
        XCTAssertNoThrow(try view.inspect().find(button: "采纳"))
        XCTAssertNoThrow(try view.inspect().find(text: store.memories[0].text))
    }

    func testDetailAsksAboutThePushedRecord() throws {
        store.send(.createNote(title: "测试范围", text: "下周汇报"))
        let note = try XCTUnwrap(store.recordDetail.detail)
        var opened = false
        let view = IOSRecordDetailView(store: store, recordId: note.id, onAsk: { opened = true })
        try view.inspect().find(button: "问这条记录").tap()
        XCTAssertTrue(opened)
        XCTAssertEqual(store.ask.recordId, note.id)
        XCTAssertEqual(store.ask.scope, "record")
    }

    func testAskCanSelectARecordOtherThanTheCurrentDetail() throws {
        store.send(.createNote(title: "上次会议", text: "讨论排期"))
        let first = try XCTUnwrap(store.recordDetail.detail?.id)
        store.send(.createNote(title: "今天会议", text: "确认排期"))
        try IOSAskView(store: store, onOpenSource: { _ in }).inspect().find(button: "上次会议").tap()
        XCTAssertEqual(store.ask.recordId, first)
    }

    func testActionsOfferCompletedAndDismissedFilters() throws {
        let view = try IOSActionsView(store: store, onOpenSource: { _ in }).inspect()
        XCTAssertNoThrow(try view.find(text: "已完成"))
        XCTAssertNoThrow(try view.find(text: "已忽略"))
    }

    func testDeviceShowsBothTransferAndStorageAndLinksTheSyncedFile() throws {
        try loadFixture { json in
            var device = json["device"] as! [String: Any]
            device["progress"] = 0.42
            device["files"] = [
                ["id": 101, "title": "已完成", "durationMs": 1000, "synced": true, "recordId": "rec-meeting-1"],
                ["id": 102, "title": "正在取回", "durationMs": 2000, "downloading": true]
            ]
            json["device"] = device
        }
        var opened: String?
        let view = try IOSDeviceSheetView(store: store, onOpenRecord: { opened = $0 }).inspect()
        let ratios = try view.findAll(ViewType.ProgressView.self).compactMap { try $0.fractionCompleted() }
        XCTAssertEqual(ratios.sorted(), [0.01, 0.42])
        try view.find(button: "查看记录").tap()
        XCTAssertEqual(opened, "rec-meeting-1")
    }

    func testSettingsOfferRecoveryForUnavailableDeepSeekAndOfficialPresets() throws {
        try loadFixture { json in
            var provider = json["provider"] as! [String: Any]
            provider["deepseekCredentialState"] = "missing_saved"
            json["provider"] = provider
        }
        let view = try IOSSettingsView(store: store).inspect()
        try view.find(button: "重试读取安全配置").tap()
        XCTAssertTrue(store.recentTraceEntries.contains { $0.name == "retry_provider_credentials" })
        XCTAssertNoThrow(try view.find(button: "Qwen 语音 + DeepSeek 文本"))
        XCTAssertNoThrow(try view.find(button: "导出诊断追踪"))
    }

    func testEditingTitleTranscriptAndSpeakersPreservesTheOriginalAndMergesSegments() throws {
        store.send(.createNote(title: "草稿", text: "原句\n下一段"))
        let detail = try XCTUnwrap(store.recordDetail.detail)
        let first = try XCTUnwrap(detail.segments.first)
        let second = try XCTUnwrap(detail.segments.last)
        func save(_ edit: IOSRecordEdit, _ value: String) throws {
            let editor = IOSRecordEditorSheet(store: store, edit: edit)
            editor.save(value)
        }
        try save(.title(detail), "定稿")
        XCTAssertEqual(store.records.first?.title, "定稿")
        try save(.text(detail.id, first), "修订句")
        let edited = try XCTUnwrap(store.recordDetail.detail?.segments.first)
        XCTAssertTrue(edited.isEdited)
        XCTAssertEqual(edited.originalText, "原句")
        XCTAssertEqual(edited.text, "修订句")
        try save(.speaker(detail.id, first), "甲")
        try save(.speaker(detail.id, second), "乙")
        try save(.renameSpeaker(detail.id, "甲"), "乙")
        XCTAssertEqual(store.recordDetail.detail?.segments.compactMap(\.speaker), ["乙", "乙"])
    }

    func testMinutesLinkFocusesTheCitedSegmentAndTrashHonorsArchiveProtection() throws {
        store.send(.createNote(title: "纪要证据", text: "第一段\n第二段"))
        let detail = try XCTUnwrap(store.recordDetail.detail)
        let segment = try XCTUnwrap(detail.segments.last)
        let source = SourceSnapshot(recordId: detail.id, title: detail.title, segment: segment)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.snapshot)) as? [String: Any])
        var payload = try XCTUnwrap(json["detail"] as? [String: Any])
        payload["summary"] = [["title": "决定", "text": "确认第二项", "sources": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(source))]]]
        json["detail"] = payload
        XCTAssertTrue(store.loadDebugSnapshotFixtureJSON(String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)))
        let view = IOSRecordDetailView(store: store, recordId: detail.id)
        try view.inspect().find(IOSSourceLink.self).find(ViewType.Button.self).tap()
        XCTAssertEqual(view.focusTarget, segment.id)
        store.send(.setRecordArchived(recordId: detail.id, archived: true))
        XCTAssertTrue(try view.inspect().find(button: "移入回收站").isDisabled())
        store.send(.setRecordArchived(recordId: detail.id, archived: false))
        try view.inspect().find(button: "移入回收站").tap()
        XCTAssertEqual(store.trashRecords.map(\.id), [detail.id])
    }

    func testReviewEditsCompleteRestoreAndRemoveKeepTheirSourceRecord() throws {
        store.send(.createNote(title: "工作纪要", text: "准备材料"))
        let detail = try XCTUnwrap(store.recordDetail.detail)
        let segment = try XCTUnwrap(detail.segments.first)
        store.send(.createTask(recordId: detail.id, segmentId: segment.id))
        store.send(.saveMemory(recordId: detail.id, segmentId: segment.id))
        let taskID = try XCTUnwrap(store.tasks.first?.id)
        let memoryID = try XCTUnwrap(store.memories.first?.id)
        store.send(.reviewItem(itemId: taskID, decision: .reset))
        let detailView = IOSRecordDetailView(store: store, recordId: detail.id)
        try detailView.inspect().find(button: "采纳").tap()
        let accepted = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(accepted.state, "accepted")
        let taskEditor = IOSItemEditorSheet(store: store, task: accepted)
        taskEditor.save("周一准备材料", deadline: "周一")
        XCTAssertEqual(store.tasks.first?.due, "周一")
        XCTAssertEqual(store.tasks.first?.text, "周一准备材料")
        let complete = try detailView.inspect().find(viewWithAccessibilityLabel: "标记已完成")
        try complete.button().tap()
        XCTAssertTrue(IOSTaskFilter.completed.matches(try XCTUnwrap(store.tasks.first)))
        XCTAssertFalse(IOSTaskFilter.pending.matches(try XCTUnwrap(store.tasks.first)))

        let memory = try XCTUnwrap(store.memories.first)
        IOSItemEditorSheet(store: store, memory: memory).save("下周核对", deadline: "")
        XCTAssertEqual(store.memories.first?.text, "下周核对")
        try detailView.inspect().find(button: "移除").tap()
        let dismissed = try XCTUnwrap(store.memories.first)
        XCTAssertEqual(dismissed.state, "dismissed")
        try IOSMemoryCard(store: store, memory: dismissed, onOpenSource: { _ in }).inspect().find(button: "恢复").tap()
        XCTAssertEqual(store.memories.first?.id, memoryID)
        XCTAssertEqual(store.recordDetail.recordMemories.first?.state, "proposed")
        let source = try detailView.inspect().find(IOSSourceLink.self)
        try source.find(ViewType.Button.self).tap()
        XCTAssertEqual(detailView.focusTarget, segment.id)
    }

    func testRecordQueryCombinesOrderingAndProjectWithBatchSelection() throws {
        var ids: [String] = []
        for (index, title) in ["旧", "中", "新"].enumerated() {
            store.send(.createNote(title: title, text: title), nowEpochSec: UInt64(1000 + index))
            ids.append(try XCTUnwrap(store.recordDetail.detail?.id))
        }
        func menu(_ selection: [String]) -> IOSRecordBatchMenu {
            IOSRecordBatchMenu(store: store, selected: store.records.filter { selection.contains($0.id) },
                               projects: ["同步"], onSuccess: {})
        }
        try menu([ids[0], ids[2]]).inspect().find(button: "同步").tap()
        var query = IOSRecordListQuery()
        query.project = .project("同步")
        XCTAssertEqual(query.results(in: store.records).map(\.title), ["新", "旧"])
        query.order = .oldest
        XCTAssertEqual(query.results(in: store.records).map(\.title), ["旧", "新"])
        try menu([ids[0]]).inspect().find(button: "批量归档").tap()
        try menu(ids).inspect().find(button: "移入回收站（2）").tap()
        XCTAssertEqual(Set(store.trashRecords.map(\.id)), Set(ids.suffix(2)))
        XCTAssertEqual(store.records.first?.archived, true)

        try loadFixture()
        query.project = .all
        query.order = .longest
        XCTAssertEqual(query.results(in: store.records).map(\.durationMs), store.records.map(\.durationMs).sorted(by: >))
    }

    func testTimedSourceCanSeekWithoutRetainedAudioAndUntimedTextCannot() throws {
        store.send(.createNote(title: "无音频归档", text: "保留的转写"))
        let detail = try XCTUnwrap(store.recordDetail.detail)
        let first = try XCTUnwrap(detail.segments.first)
        let timed = SegmentSnapshot(id: first.id, text: first.text, startMs: 1000, endMs: 2000, timed: true)
        let button = try IOSSegmentPlaybackButton(store: store, recordID: detail.id, segment: timed).inspect().find(ViewType.Button.self)
        XCTAssertFalse(button.isDisabled())
        try button.tap()
        XCTAssertEqual(store.playback.recordId, detail.id)
        XCTAssertFalse(store.playback.isPlaying)
        XCTAssertTrue(store.recentTraceEntries.contains { $0.name == "seek" })
        let untimed = SegmentSnapshot(id: first.id, text: first.text, startMs: 0, endMs: 0, timed: false)
        XCTAssertTrue(try IOSSegmentPlaybackButton(store: store, recordID: detail.id, segment: untimed).inspect().find(ViewType.Button.self).isDisabled())
    }

    func testSuccessfulQuestionClearsDraftDespiteObserverReportingAnotherError() throws {
        store.send(.createNote(title: "建筑", text: "屋顶修缮计划"))
        var draft = " 屋顶 "
        let composer = IOSAskComposer(store: store, questionDraft: Binding(get: { draft }, set: { draft = $0 }))
        store.onTraceRecorded = { [weak store] in store?.reportNativeError("设备提示") }
        defer { store.onTraceRecorded = nil }
        try composer.inspect().find(button: "发送").tap()
        XCTAssertEqual(store.navigation.effectiveError, "设备提示")
        XCTAssertEqual(draft, "")
        XCTAssertEqual(store.ask.messages.first?.text, "屋顶")
        store.shutdown()
        draft = "保留问题"
        try composer.inspect().find(button: "发送").tap()
        XCTAssertEqual(draft, "保留问题")
    }

    func testOfficialPresetsSwitchSpeechEngineAndExplainOnlyNonStreamingModels() throws {
        var draft = ModelSettingsDraft()
        let view = IOSModelPresets(store: store, draft: Binding(get: { draft }, set: { draft = $0 }))
        try view.inspect().find(button: "DeepSeek 官方全套").tap()
        XCTAssertEqual(draft.matchedPreset(speechEngine: store.settings.speech.engine), "deepseek-full")
        XCTAssertNoThrow(try IOSSpeechModeNotice(draft: draft).inspect().find(ViewType.Text.self, where: { try $0.string().contains("120 秒") }))
        try view.inspect().find(button: "Qwen 语音 + DeepSeek 文本").tap()
        XCTAssertEqual(draft.matchedPreset(speechEngine: store.settings.speech.engine), "hybrid")
        for model in ModelSettingsCatalog.qwenAsrModels {
            draft.qwenAsrModel = model.id
            let labels = try IOSSpeechModeNotice(draft: draft).inspect().findAll(ViewType.Text.self)
            XCTAssertEqual(try labels.map { try $0.string() }, model.nonRealtimeWarning.map { [$0] } ?? [])
        }
    }
}
