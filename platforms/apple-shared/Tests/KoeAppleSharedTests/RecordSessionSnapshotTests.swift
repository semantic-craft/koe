import Foundation
import Testing
@testable import KoeAppleShared

@Suite("Record retention and trash snapshot contract")
struct RecordSessionSnapshotTests {
    @Test("HostSnapshot decodes archived flags, trashRecords, and undoTrash with legacy defaults")
    @MainActor
    func trashAndArchiveSnapshotDecoding() throws {
        let legacyRecordJSON = """
        {
          "version": 2,
          "generation": 12,
          "section": "detail",
          "canGoBack": true,
          "selectedRecordId": "rec-legacy",
          "focusSegmentId": null,
          "records": [
            {
              "id": "rec-legacy",
              "title": "旧快照记录",
              "createdAtEpochSec": 1700000100,
              "durationMs": 4000,
              "source": "随手记",
              "status": "已有文字",
              "segmentCount": 1,
              "preview": "兼容旧字段"
            }
          ],
          "detail": {
            "id": "rec-legacy",
            "title": "旧快照记录",
            "createdAtEpochSec": 1700000100,
            "durationMs": 4000,
            "source": "随手记",
            "status": "已有文字",
            "segments": [],
            "summary": [],
            "highlights": [],
            "audioPath": null,
            "canRetranscribe": false,
            "isProcessing": false
          },
          "tasks": [],
          "memories": [],
          "ask": { "scope": "all", "recordId": null, "phase": "idle", "messages": [] },
          "device": { "state": "未连接", "connected": false, "busy": false, "files": [], "progress": 0.0 },
          "provider": { "configured": false, "model": "qwen-plus" },
          "playback": { "recordId": null, "positionMs": 0, "isPlaying": false },
          "error": null,
          "notice": null
        }
        """
        let legacy = try JSONDecoder().decode(HostSnapshot.self, from: Data(legacyRecordJSON.utf8))
        #expect(legacy.records.first?.archived == false)
        #expect(legacy.detail?.archived == false)
        #expect(legacy.trashRecords.isEmpty)
        #expect(legacy.undoTrash == nil)

        let retentionJSON = """
        {
          "version": 2,
          "generation": 13,
          "section": "trash",
          "canGoBack": false,
          "selectedRecordId": null,
          "focusSegmentId": null,
          "records": [
            {
              "id": "rec-archived",
              "title": "关键评审",
              "createdAtEpochSec": 1800000000,
              "durationMs": 12000,
              "source": "Mac 麦克风",
              "status": "已有文字",
              "segmentCount": 2,
              "preview": "保留正式决议",
              "archived": true
            }
          ],
          "trashRecords": [
            {
              "id": "rec-trashed",
              "title": "临时试音",
              "createdAtEpochSec": 1799990000,
              "durationMs": 5000,
              "source": "Mac 麦克风",
              "segmentCount": 1,
              "preview": "麦克风音量检查",
              "trashedAtMs": 1800000000000,
              "expiresAtMs": 1802592000000,
              "remainingDays": 30
            }
          ],
          "undoTrash": {
            "recordId": "rec-trashed",
            "title": "临时试音"
          },
          "detail": {
            "id": "rec-archived",
            "title": "关键评审",
            "createdAtEpochSec": 1800000000,
            "durationMs": 12000,
            "source": "Mac 麦克风",
            "status": "已有文字",
            "archived": true,
            "segments": [],
            "summary": [],
            "highlights": [],
            "audioPath": "/tmp/rec-archived.wav",
            "canRetranscribe": false,
            "isProcessing": false
          },
          "tasks": [],
          "memories": [],
          "ask": { "scope": "all", "recordId": null, "phase": "idle", "messages": [] },
          "device": { "state": "未连接", "connected": false, "busy": false, "files": [], "progress": 0.0 },
          "provider": { "configured": false, "model": "qwen-plus" },
          "playback": { "recordId": null, "positionMs": 0, "isPlaying": false },
          "error": null,
          "notice": null
        }
        """
        let decoded = try JSONDecoder().decode(HostSnapshot.self, from: Data(retentionJSON.utf8))
        #expect(decoded.records.first?.archived == true)
        #expect(decoded.detail?.archived == true)
        #expect(decoded.trashRecords.count == 1)
        let trashed = try #require(decoded.trashRecords.first)
        #expect(trashed.id == "rec-trashed")
        #expect(trashed.title == "临时试音")
        #expect(trashed.trashedAtMs == 1_800_000_000_000)
        #expect(trashed.expiresAtMs == 1_802_592_000_000)
        #expect(trashed.remainingDays == 30)
        #expect(decoded.undoTrash == UndoTrashSnapshot(recordId: "rec-trashed", title: "临时试音"))
    }

    @Test("Archive protection, soft trash, undo dismiss, restore, purge, and 30-day expiry over C ABI v2")
    @MainActor
    func archiveLockSoftTrashRestorePurgeAndExpiryOverHostSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        let t0: UInt64 = 1_800_000_000

        func captureMicRecord(nowEpochSec: UInt64, title: String) throws -> (id: String, audioPath: String) {
            store.send("start_microphone", ["inputId": "built-in", "includeSystem": false, "clockNs": 1_000_000_000], nowEpochSec: nowEpochSec)
            let mic = try #require(store.snapshot.microphone)
            store.send("microphone_started", ["recordId": mic.recordId, "sessionId": mic.sessionId, "lane": "microphone", "sampleRate": 16000], nowEpochSec: nowEpochSec)
            let ingest = store.ingestMicrophonePCM(
                recordId: mic.recordId,
                sessionId: mic.sessionId,
                lane: "microphone",
                sequence: 0,
                epoch: 0,
                capturedStartNs: 1_000_000_000,
                samples: [Int16](repeating: 180, count: 320),
                nowEpochSec: nowEpochSec
            )
            #expect(ingest.status == .accepted)
            store.send("stop_microphone", nowEpochSec: nowEpochSec)
            store.send("microphone_stopped", ["recordId": mic.recordId, "sessionId": mic.sessionId, "lane": "microphone", "sequence": 1, "epoch": 0], nowEpochSec: nowEpochSec)
            store.send("rename_record", ["recordId": mic.recordId, "title": title], nowEpochSec: nowEpochSec)
            let detail = try #require(store.snapshot.detail)
            let audioPath = try #require(detail.audioPath)
            #expect(FileManager.default.fileExists(atPath: audioPath))
            return (mic.recordId, audioPath)
        }

        let rec1 = try captureMicRecord(nowEpochSec: t0, title: "季度预算会议")
        let rec2 = try captureMicRecord(nowEpochSec: t0 + 10, title: "测试试音片段")

        store.send("set_record_archived", ["recordId": rec1.id, "archived": true], nowEpochSec: t0 + 20)
        #expect(store.snapshot.records.first(where: { $0.id == rec1.id })?.archived == true)

        store.send("trash_record", ["recordId": rec1.id], nowEpochSec: t0 + 25)
        #expect(store.snapshot.error != nil)
        #expect(store.snapshot.trashRecords.isEmpty)
        #expect(store.snapshot.records.contains(where: { $0.id == rec1.id }))
        store.clearError()

        store.send("set_record_archived", ["recordId": rec1.id, "archived": false], nowEpochSec: t0 + 30)
        #expect(store.snapshot.records.first(where: { $0.id == rec1.id })?.archived == false)

        store.send("trash_record", ["recordId": rec1.id], nowEpochSec: t0 + 40)
        #expect(!store.snapshot.records.contains(where: { $0.id == rec1.id }))
        #expect(store.snapshot.trashRecords.map(\.id) == [rec1.id])
        #expect(store.snapshot.trashRecords.first?.remainingDays == 30)
        #expect(store.snapshot.undoTrash == UndoTrashSnapshot(recordId: rec1.id, title: "季度预算会议"))
        #expect(FileManager.default.fileExists(atPath: rec1.audioPath))

        store.send("dismiss_undo_trash", nowEpochSec: t0 + 41)
        #expect(store.snapshot.undoTrash == nil)
        #expect(store.snapshot.trashRecords.map(\.id) == [rec1.id])

        store.send("restore_record", ["recordId": rec1.id], nowEpochSec: t0 + 45)
        #expect(store.snapshot.records.contains(where: { $0.id == rec1.id }))
        #expect(store.snapshot.trashRecords.isEmpty)
        #expect(FileManager.default.fileExists(atPath: rec1.audioPath))

        store.send("trash_record", ["recordId": rec1.id], nowEpochSec: t0 + 50)
        #expect(store.snapshot.undoTrash?.recordId == rec1.id)
        store.send("purge_record", ["recordId": rec1.id], nowEpochSec: t0 + 55)
        #expect(!store.snapshot.records.contains(where: { $0.id == rec1.id }))
        #expect(store.snapshot.trashRecords.isEmpty)
        #expect(store.snapshot.undoTrash == nil)
        #expect(!FileManager.default.fileExists(atPath: rec1.audioPath))

        let trashEpoch = t0 + 100
        store.send("trash_record", ["recordId": rec2.id], nowEpochSec: trashEpoch)
        #expect(store.snapshot.trashRecords.map(\.id) == [rec2.id])
        #expect(store.snapshot.undoTrash?.recordId == rec2.id)

        store.pollTimers(elapsedMs: 8_000, nowEpochSec: trashEpoch + 29 * 86_400)
        #expect(store.snapshot.undoTrash == nil)
        #expect(store.snapshot.trashRecords.map(\.id) == [rec2.id])
        #expect(store.snapshot.trashRecords.first?.remainingDays == 1)
        #expect(FileManager.default.fileExists(atPath: rec2.audioPath))

        store.pollTimers(elapsedMs: 1_000, nowEpochSec: trashEpoch + 30 * 86_400)
        #expect(store.snapshot.trashRecords.isEmpty)
        #expect(!store.snapshot.records.contains(where: { $0.id == rec2.id }))
        #expect(!FileManager.default.fileExists(atPath: rec2.audioPath))
        #expect(store.snapshot.error == nil)
        #expect(store.nativeError == nil)
        store.shutdown()

        let reopened = HostSessionStore(workspacePath: directory.path)
        defer { reopened.shutdown() }
        #expect(reopened.snapshot.records.isEmpty)
        #expect(reopened.snapshot.trashRecords.isEmpty)
        #expect(reopened.snapshot.error == nil)
        #expect(reopened.nativeError == nil)
    }
}
