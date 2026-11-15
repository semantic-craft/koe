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
        guard store.snapshot.device.autoConnect == true,
              store.snapshot.device.companionMode == "disabled",
              store.snapshot.device.standbyReady == false else { return fail("initial companion state") }
        store.send("set_companion_mode", ["mode": "collar_standby"])
        guard store.snapshot.device.companionMode == "collar_standby" else { return fail("set companion mode") }
        store.send("device_release")
        guard store.snapshot.device.autoConnect == false else { return fail("device release") }
        store.send("set_ble_auto_connect", ["enabled": true])
        store.send("set_companion_mode", ["mode": "disabled"])
        guard store.snapshot.device.autoConnect == true,
              store.snapshot.device.companionMode == "disabled" else { return fail("restore companion defaults") }
        store.send("sync_audio_inputs", ["inputs": [
            ["id": "built-in-mic", "name": "MacBook Pro 麦克风", "transport": "built_in", "isDefault": true],
            ["id": "bt-airpods", "name": "AirPods Pro", "transport": "bluetooth", "isDefault": false]
        ]])
        guard store.snapshot.capture.selectedSource == "input:bt-airpods",
              store.snapshot.capture.selectedBadge == "Mac 蓝牙",
              store.snapshot.capture.inputs.first?.id == "bt-airpods" else { return fail("sync audio inputs bluetooth priority") }
        store.send("select_capture_source", ["source": "input:built-in-mic"])
        guard store.snapshot.capture.selectedSource == "input:built-in-mic",
              store.snapshot.capture.selectionMode == "manual" else { return fail("select capture source") }
        store.send("navigate", ["section": "capture"])
        guard store.snapshot.section == "capture", store.snapshot.canGoBack == true else { return fail("navigate capture") }
        store.send("back")
        guard store.snapshot.section == "today" else { return fail("navigate back from capture") }
        guard store.snapshot.workspaces != nil else { return fail("mode workspaces projection") }
        for modeSection in ["notes", "all_day", "live_minutes", "voice_input", "today"] {
            store.send("navigate", ["section": modeSection])
            guard store.snapshot.section == modeSection,
                  store.snapshot.device.companionMode == "disabled",
                  store.snapshot.activeCapture == nil,
                  store.drainHostActions().isEmpty else {
                return fail("pure navigation \(modeSection)")
            }
        }
        store.send("create_note", [
            "title": "Architecture review",
            "text": "Keep recording ownership in Rust. The native host renders snapshots.\nVerify speaker merge and reversible inline edits."
        ])
        guard let first = store.snapshot.detail, first.segments.count == 2 else { return fail("create note") }
        let segment = first.segments[0]
        let secondSegment = first.segments[1]
        store.send("create_task", ["recordId": first.id, "segmentId": segment.id])
        guard let task = store.snapshot.tasks.first else { return fail("create task") }
        store.send("review_item", ["itemId": task.id, "decision": "accept"])
        store.send("create_note", ["title": "Independent discussion", "text": "The blue notebook is on the shelf."])
        guard let second = store.snapshot.detail, store.snapshot.records.count == 2 else { return fail("record isolation") }
        store.send("select_record", ["recordId": first.id])
        guard store.snapshot.detail?.segments == first.segments else { return fail("select record") }
        store.send("set_segment_speaker", ["recordId": first.id, "segmentId": segment.id, "speaker": "发言人 1："])
        store.send("set_segment_speaker", ["recordId": first.id, "segmentId": secondSegment.id, "speaker": "林工"])
        guard store.snapshot.detail?.speakers.first?.name == "发言人 1",
              store.snapshot.detail?.speakers.count == 2 else { return fail("set segment speaker") }
        store.send("edit_segment_text", [
            "recordId": first.id,
            "segmentId": segment.id,
            "text": "Keep recording ownership strictly in Rust. The native host renders snapshots."
        ])
        guard let editedSeg = store.snapshot.detail?.segments.first(where: { $0.id == segment.id }),
              editedSeg.isEdited == true,
              editedSeg.originalText == segment.text else { return fail("edit segment text") }
        store.send("rename_speaker", ["recordId": first.id, "fromSpeaker": "发言人 1", "toSpeaker": "林工"])
        guard store.snapshot.detail?.speakers == [
            SpeakerSummarySnapshot(name: "林工", segmentCount: 2, firstSegmentId: segment.id)
        ] else { return fail("rename speaker merge") }
        store.send("edit_segment_text", ["recordId": first.id, "segmentId": segment.id, "text": segment.text])
        guard let revertedSeg = store.snapshot.detail?.segments.first(where: { $0.id == segment.id }),
              revertedSeg.isEdited == false,
              revertedSeg.originalText == nil else { return fail("revert segment text") }
        store.send("ask", ["question": "recording ownership", "scope": "record", "recordId": first.id])
        guard let answer = store.snapshot.ask.messages.last,
              answer.role == "assistant", !answer.sources.isEmpty,
              answer.sources.allSatisfy({ $0.recordId == first.id }) else { return fail("scoped source retrieval") }
        let source = answer.sources[0]
        store.send("open_source", ["recordId": source.recordId, "segmentId": source.segmentId])
        guard store.snapshot.selectedRecordId == first.id, store.snapshot.focusSegmentId == segment.id else {
            return fail("source navigation")
        }
        store.send("set_record_archived", ["recordId": second.id, "archived": true], nowEpochSec: 1_800_000_000)
        guard store.snapshot.records.first(where: { $0.id == second.id })?.archived == true else {
            return fail("archive lock")
        }
        store.send("trash_record", ["recordId": second.id], nowEpochSec: 1_800_000_005)
        guard store.snapshot.error != nil,
              store.snapshot.trashRecords.isEmpty,
              store.snapshot.records.contains(where: { $0.id == second.id }) else {
            return fail("archive blocks trash")
        }
        store.clearError()
        store.send("set_record_archived", ["recordId": second.id, "archived": false], nowEpochSec: 1_800_000_010)
        store.send("trash_record", ["recordId": second.id], nowEpochSec: 1_800_000_015)
        guard !store.snapshot.records.contains(where: { $0.id == second.id }),
              store.snapshot.trashRecords.contains(where: { $0.id == second.id }),
              store.snapshot.undoTrash?.recordId == second.id else {
            return fail("trash record")
        }
        store.send("restore_record", ["recordId": second.id], nowEpochSec: 1_800_000_020)
        guard store.snapshot.records.contains(where: { $0.id == second.id }),
              store.snapshot.trashRecords.isEmpty,
              store.snapshot.undoTrash == nil else {
            return fail("restore record")
        }
        store.send("trash_record", ["recordId": second.id], nowEpochSec: 1_800_000_025)
        store.send("purge_record", ["recordId": second.id], nowEpochSec: 1_800_000_030)
        guard !store.snapshot.records.contains(where: { $0.id == second.id }),
              store.snapshot.trashRecords.isEmpty,
              store.snapshot.undoTrash == nil else {
            return fail("purge record")
        }
        guard store.snapshot.error == nil, store.nativeError == nil else { return fail("unexpected error") }
        print("koe-verify-self: PASS (version=2, records=1, scoped_sources=\(answer.sources.count))")
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
        store.send("set_record_project", ["recordId": detail.id, "project": "自检项目"])
        guard store.snapshot.workspaces?.quickNote.inboxCount == 0 else {
            store.shutdown()
            return fail("set record project inbox count")
        }
        store.send("set_companion_mode", ["mode": "meeting_and_collar"])
        store.send("set_ble_auto_connect", ["enabled": false])
        store.shutdown()
        let restored = HostSessionStore(workspacePath: directory.path)
        defer { restored.shutdown() }
        restored.send("select_record", ["recordId": detail.id])
        guard restored.snapshot.records.count == 1,
              restored.snapshot.records.first?.project == "自检项目",
              restored.snapshot.detail?.segments == detail.segments,
              restored.snapshot.memories.contains(where: { $0.id == memory.id && $0.state == "accepted" }),
              restored.snapshot.device.companionMode == "meeting_and_collar",
              restored.snapshot.device.autoConnect == false,
              restored.snapshot.error == nil, restored.nativeError == nil else { return fail("restore saved state") }
        print("koe-smoke-test: PASS (version=2, persisted_record=1, accepted_memory=1)")
        return 0
    }

    private static func fail(_ stage: String) -> Int32 {
        fputs("Koe self-check failed: \(stage)\n", stderr)
        return 1
    }
}
