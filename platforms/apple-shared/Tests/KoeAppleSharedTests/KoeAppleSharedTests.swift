import Foundation
import Testing
@testable import KoeAppleShared

@Suite("Native product contract")
struct KoeAppleSharedTests {
    @Test("An older snapshot cannot replace the current state")
    @MainActor
    func rejectsStaleSnapshot() {
        var gate = ViewRequestGeneration()
        let acceptedFirst = gate.acceptRustGeneration(4)
        let acceptedStale = gate.acceptRustGeneration(3)
        let acceptedNext = gate.acceptRustGeneration(5)
        #expect(acceptedFirst)
        #expect(!acceptedStale)
        #expect(acceptedNext)
    }

    @Test("Invalid payload exposes an error without replacing the last usable snapshot")
    @MainActor
    func invalidSnapshotIsVisible() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let before = store.snapshot
        store.applySnapshotJSON("{invalid}")
        #expect(store.nativeError != nil)
        #expect(store.snapshot == before)
    }

    @Test("Separate notes keep their text and source identity through review and reopen")
    @MainActor
    func recordReviewAndPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        #expect(store.handle != 0)
        #expect(store.snapshot.records.isEmpty)
        store.send("create_note", ["title": "Architecture", "text": "The engine owns recording state."])
        let first = try #require(store.snapshot.detail)
        let segment = try #require(first.segments.first)
        store.send("create_task", ["recordId": first.id, "segmentId": segment.id])
        let task = try #require(store.snapshot.tasks.first)
        store.send("review_item", ["itemId": task.id, "decision": "accept"])
        store.send("complete_task", ["itemId": task.id, "completed": true])
        store.send("create_note", ["title": "Notebook", "text": "The notebook is on the shelf."])
        let second = try #require(store.snapshot.detail)
        #expect(second.id != first.id)
        store.send("select_record", ["recordId": first.id])
        #expect(store.snapshot.detail?.segments == first.segments)
        store.send("ask", ["question": "recording state", "scope": "record", "recordId": first.id])
        let answer = try #require(store.snapshot.ask.messages.last)
        #expect(answer.mode == "retrieval")
        #expect(!answer.sources.isEmpty)
        #expect(answer.sources.allSatisfy { $0.recordId == first.id })
        let source = try #require(answer.sources.first)
        store.send("open_source", ["recordId": source.recordId, "segmentId": source.segmentId])
        #expect(store.snapshot.focusSegmentId == segment.id)
        store.shutdown()
        let restored = HostSessionStore(workspacePath: directory.path)
        defer { restored.shutdown() }
        #expect(restored.snapshot.records.count == 2)
        #expect(restored.snapshot.tasks.first(where: { $0.id == task.id })?.completed == true)
        restored.send("select_record", ["recordId": second.id])
        #expect(restored.snapshot.detail?.segments == second.segments)
        #expect(restored.snapshot.error == nil)
        #expect(restored.nativeError == nil)
    }
}
