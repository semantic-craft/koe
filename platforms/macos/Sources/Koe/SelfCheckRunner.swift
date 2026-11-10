import Foundation
import KoeAppleShared

public enum KoeSelfCheckRunner {
    @MainActor
    public static func runVerifySelf() -> Int32 {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("koe-verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }
        guard store.handle != 0, store.snapshot.records.isEmpty else { return fail("initial workspace") }
        store.send("create_note", ["title": "Architecture review", "text": "Keep recording ownership in Rust. The native host renders snapshots."])
        guard let first = store.snapshot.detail, let segment = first.segments.first else { return fail("create note") }
        store.send("create_task", ["recordId": first.id, "segmentId": segment.id])
        guard let task = store.snapshot.tasks.first else { return fail("create task") }
        store.send("review_item", ["itemId": task.id, "decision": "accept"])
        store.send("create_note", ["title": "Independent discussion", "text": "The blue notebook is on the shelf."])
        guard store.snapshot.records.count == 2 else { return fail("record isolation") }
        store.send("select_record", ["recordId": first.id])
        guard store.snapshot.detail?.segments == first.segments else { return fail("select record") }
        store.send("ask", ["question": "recording ownership", "scope": "record", "recordId": first.id])
        guard let answer = store.snapshot.ask.messages.last,
              answer.role == "assistant", !answer.sources.isEmpty,
              answer.sources.allSatisfy({ $0.recordId == first.id }) else { return fail("scoped source retrieval") }
        let source = answer.sources[0]
        store.send("open_source", ["recordId": source.recordId, "segmentId": source.segmentId])
        guard store.snapshot.selectedRecordId == first.id, store.snapshot.focusSegmentId == segment.id else {
            return fail("source navigation")
        }
        guard store.snapshot.error == nil, store.nativeError == nil else { return fail("unexpected error") }
        print("koe-verify-self: PASS (version=2, records=2, scoped_sources=\(answer.sources.count))")
        return 0
    }

    @MainActor
    public static func runSmokeTest() -> Int32 {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("koe-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        store.send("create_note", ["title": "Persistence check", "text": "Use a durable recording identifier for every saved item."])
        guard let detail = store.snapshot.detail, let segment = detail.segments.first else {
            store.shutdown()
            return fail("create persistence fixture")
        }
        store.send("save_memory", ["recordId": detail.id, "segmentId": segment.id])
        guard let memory = store.snapshot.memories.first else { store.shutdown(); return fail("save memory") }
        store.send("review_item", ["itemId": memory.id, "decision": "accept"])
        store.shutdown()
        let restored = HostSessionStore(workspacePath: directory.path)
        defer { restored.shutdown() }
        restored.send("select_record", ["recordId": detail.id])
        guard restored.snapshot.records.count == 1,
              restored.snapshot.detail?.segments == detail.segments,
              restored.snapshot.memories.contains(where: { $0.id == memory.id && $0.state == "accepted" }),
              restored.snapshot.error == nil, restored.nativeError == nil else { return fail("restore saved state") }
        print("koe-smoke-test: PASS (version=2, persisted_record=1, accepted_memory=1)")
        return 0
    }

    private static func fail(_ stage: String) -> Int32 {
        fputs("Koe self-check failed: \(stage)\n", stderr)
        return 1
    }
}
