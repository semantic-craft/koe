import Foundation
import Testing
@testable import KoeAppleShared

@Suite("HostCommand typed contract")
struct HostCommandTests {
    private func encodeObject(_ command: HostCommand) throws -> [String: Any] {
        let data = try JSONEncoder().encode(command)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("HostCommand encodes flat snake_case tags and camelCase fields for nil and non-nil optionals")
    func flatJSONShapeAndOptionals() throws {
        let askAll = try encodeObject(.setAskScope(scope: "all", recordId: nil))
        #expect(askAll["type"] as? String == "set_ask_scope")
        #expect(askAll["scope"] as? String == "all")
        #expect(askAll["recordId"] == nil)
        #expect(askAll.count == 2)

        let askRecord = try encodeObject(.setAskScope(scope: "record", recordId: "rec-42"))
        #expect(askRecord["type"] as? String == "set_ask_scope")
        #expect(askRecord["scope"] as? String == "record")
        #expect(askRecord["recordId"] as? String == "rec-42")
        #expect(askRecord.count == 3)

        let editNoDue = try encodeObject(.editItem(itemId: "task-1", text: "Follow up", due: nil))
        #expect(editNoDue["type"] as? String == "edit_item")
        #expect(editNoDue["itemId"] as? String == "task-1")
        #expect(editNoDue["text"] as? String == "Follow up")
        #expect(editNoDue["due"] == nil)

        let editWithDue = try encodeObject(.editItem(itemId: "task-1", text: "Follow up", due: "2026-11-20"))
        #expect(editWithDue["due"] as? String == "2026-11-20")

        let clearProject = try encodeObject(.setRecordProject(recordId: "rec-42", project: nil))
        #expect(clearProject["type"] as? String == "set_record_project")
        #expect(clearProject["recordId"] as? String == "rec-42")
        #expect(clearProject["project"] == nil)

        let setProject = try encodeObject(.setRecordProject(recordId: "rec-42", project: "Koe"))
        #expect(setProject["project"] as? String == "Koe")

        let capture = try encodeObject(.startCaptureMode(mode: .quickNote, stayOnPage: true))
        #expect(capture["type"] as? String == "start_capture_mode")
        #expect(capture["mode"] as? String == "quick_note")
        #expect(capture["stayOnPage"] as? Bool == true)
    }

    @Test("HostSessionStore.send(HostCommand) roundtrips optional and capture commands through KoeRuntime")
    @MainActor
    func runtimeRoundtrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        store.send(.createNote(
            title: "Typed Dispatch",
            text: "Engine owns recording identity.\nHost sends typed commands.",
            stayOnPage: false
        ))
        #expect(store.nativeError == nil)
        #expect(store.snapshot.error == nil)
        let detail = try #require(store.snapshot.detail)
        let firstSeg = try #require(detail.segments.first)

        store.send(.setRecordProject(recordId: detail.id, project: "Architecture"))
        #expect(store.snapshot.records.first(where: { $0.id == detail.id })?.project == "Architecture")
        store.send(.setRecordProject(recordId: detail.id, project: nil))
        #expect(store.snapshot.records.first(where: { $0.id == detail.id })?.project == nil)

        store.send(.createTask(recordId: detail.id, segmentId: firstSeg.id))
        let task = try #require(store.snapshot.tasks.first)
        store.send(.reviewItem(itemId: task.id, decision: "accept"))
        store.send(.editItem(itemId: task.id, text: "Verify typed ABI command", due: "2026-11-20"))
        #expect(store.snapshot.tasks.first(where: { $0.id == task.id })?.due == "2026-11-20")
        store.send(.editItem(itemId: task.id, text: "Verify typed ABI command", due: nil))
        #expect(store.snapshot.tasks.first(where: { $0.id == task.id })?.due == nil)

        store.send(.setAskScope(scope: "record", recordId: detail.id))
        #expect(store.snapshot.ask.scope == "record")
        #expect(store.snapshot.ask.recordId == detail.id)
        store.send(.setAskScope(scope: "all", recordId: nil))
        #expect(store.snapshot.ask.scope == "all")
        #expect(store.snapshot.ask.recordId == nil)
        store.send(.ask(question: "recording identity", scope: "all", recordId: nil))
        #expect(store.snapshot.ask.messages.last?.mode == "retrieval")

        store.send(.startCaptureMode(mode: .quickNote, stayOnPage: true))
        #expect(store.snapshot.activeCapture?.mode == .quickNote)
        store.send(.captureAction(action: .cancel))
        if let mic = store.snapshot.microphone {
            store.send("microphone_stopped", [
                "recordId": mic.recordId,
                "sessionId": mic.sessionId,
                "lane": "microphone",
                "sequence": mic.nextSequence,
                "epoch": mic.epoch
            ])
        }
        #expect(store.nativeError == nil)
        #expect(store.snapshot.error == nil)
    }
}
