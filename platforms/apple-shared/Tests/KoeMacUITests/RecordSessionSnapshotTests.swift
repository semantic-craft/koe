import Foundation
import Testing
@testable import KoeMacUI

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
            store.send(.startCaptureMode(mode: .quickNote, stayOnPage: true), nowEpochSec: nowEpochSec)
            let mic = try #require(store.snapshot.microphone)
            store.send(.microphonePrepared(recordId: mic.recordId, sessionId: mic.sessionId, epoch: 0, clockNs: 1_000_000_000), nowEpochSec: nowEpochSec)
            store.send(.microphoneStarted(recordId: mic.recordId, sessionId: mic.sessionId, lane: "microphone", sampleRate: 16000), nowEpochSec: nowEpochSec)
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
            store.send(.captureAction(action: .end), nowEpochSec: nowEpochSec)
            store.send(.microphoneStopped(recordId: mic.recordId, sessionId: mic.sessionId, lane: "microphone", sequence: 1, epoch: 0), nowEpochSec: nowEpochSec)
            store.send(.renameRecord(recordId: mic.recordId, title: title), nowEpochSec: nowEpochSec)
            store.send(.selectRecord(recordId: mic.recordId), nowEpochSec: nowEpochSec)
            let detail = try #require(store.snapshot.detail)
            let audioPath = try #require(detail.audioPath)
            #expect(FileManager.default.fileExists(atPath: audioPath))
            return (mic.recordId, audioPath)
        }

        let rec1 = try captureMicRecord(nowEpochSec: t0, title: "季度预算会议")
        let rec2 = try captureMicRecord(nowEpochSec: t0 + 10, title: "测试试音片段")

        store.send(.setRecordArchived(recordId: rec1.id, archived: true), nowEpochSec: t0 + 20)
        #expect(store.snapshot.records.first(where: { $0.id == rec1.id })?.archived == true)

        store.send(.trashRecord(recordId: rec1.id), nowEpochSec: t0 + 25)
        #expect(store.snapshot.error != nil)
        #expect(store.snapshot.trashRecords.isEmpty)
        #expect(store.snapshot.records.contains(where: { $0.id == rec1.id }))
        store.clearError()

        store.send(.setRecordArchived(recordId: rec1.id, archived: false), nowEpochSec: t0 + 30)
        #expect(store.snapshot.records.first(where: { $0.id == rec1.id })?.archived == false)

        store.send(.trashRecord(recordId: rec1.id), nowEpochSec: t0 + 40)
        #expect(!store.snapshot.records.contains(where: { $0.id == rec1.id }))
        #expect(store.snapshot.trashRecords.map(\.id) == [rec1.id])
        #expect(store.snapshot.trashRecords.first?.remainingDays == 30)
        #expect(store.snapshot.undoTrash == UndoTrashSnapshot(recordId: rec1.id, title: "季度预算会议"))
        #expect(FileManager.default.fileExists(atPath: rec1.audioPath))

        store.send(.dismissUndoTrash, nowEpochSec: t0 + 41)
        #expect(store.snapshot.undoTrash == nil)
        #expect(store.snapshot.trashRecords.map(\.id) == [rec1.id])

        store.send(.restoreRecord(recordId: rec1.id), nowEpochSec: t0 + 45)
        #expect(store.snapshot.records.contains(where: { $0.id == rec1.id }))
        #expect(store.snapshot.trashRecords.isEmpty)
        #expect(FileManager.default.fileExists(atPath: rec1.audioPath))

        store.send(.trashRecord(recordId: rec1.id), nowEpochSec: t0 + 50)
        #expect(store.snapshot.undoTrash?.recordId == rec1.id)
        store.send(.purgeRecord(recordId: rec1.id), nowEpochSec: t0 + 55)
        #expect(!store.snapshot.records.contains(where: { $0.id == rec1.id }))
        #expect(store.snapshot.trashRecords.isEmpty)
        #expect(store.snapshot.undoTrash == nil)
        #expect(!FileManager.default.fileExists(atPath: rec1.audioPath))

        let trashEpoch = t0 + 100
        store.send(.trashRecord(recordId: rec2.id), nowEpochSec: trashEpoch)
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

    @Test("RecordSortOrder and RecordProjectFilter sort and filter records accurately")
    func recordSortOrderAndProjectFilterWork() {
        let records = [
            RecordSnapshot(
                id: "r1", title: "Beta 会议", createdAtEpochSec: 200, durationMs: 3_000,
                source: "录音豆", status: "已整理", segmentCount: 1, preview: "短试音",
                archived: false, mode: "quick_note", project: nil
            ),
            RecordSnapshot(
                id: "r2", title: "Alpha 评审", createdAtEpochSec: 100, durationMs: 900_000,
                source: "麦克风", status: "已整理", segmentCount: 5, preview: "长会议",
                archived: true, mode: "meeting", project: "Q4 规划"
            ),
            RecordSnapshot(
                id: "r3", title: "Gamma 随记", createdAtEpochSec: 300, durationMs: 45_000,
                source: "麦克风", status: "已整理", segmentCount: 2, preview: "中等",
                archived: false, mode: "quick_note", project: "学术写作"
            ),
        ]

        #expect(RecordSortOrder.newest.sort(records).map(\.id) == ["r3", "r1", "r2"])
        #expect(RecordSortOrder.oldest.sort(records).map(\.id) == ["r2", "r1", "r3"])
        #expect(RecordSortOrder.longest.sort(records).map(\.id) == ["r2", "r3", "r1"])
        #expect(RecordSortOrder.shortest.sort(records).map(\.id) == ["r1", "r3", "r2"])
        #expect(RecordSortOrder.title.sort(records).map(\.id) == ["r2", "r1", "r3"])

        #expect(records.filter { $0.matches(filter: .all, projectFilter: .unassigned, query: "") }.map(\.id) == ["r1"])
        #expect(records.filter { $0.matches(filter: .all, projectFilter: .project("Q4 规划"), query: "") }.map(\.id) == ["r2"])
    }

    @Test("Batch record management commands work over C ABI v2 with undo and directory export")
    @MainActor
    func batchRecordManagementOverHostSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let exportDir = directory.appendingPathComponent("batch-export")
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }
        let t0: UInt64 = 1_800_100_000

        store.send(.createNote(title: "归档保护项", text: "重要讨论内容。", stayOnPage: true), nowEpochSec: t0)
        store.send(.createNote(title: "待清试音一", text: "测试麦克风一。", stayOnPage: true), nowEpochSec: t0 + 1)
        store.send(.createNote(title: "待清试音二", text: "测试麦克风二。", stayOnPage: true), nowEpochSec: t0 + 2)

        let ids = store.records.map(\.id)
        #expect(ids.count == 3)
        let protectedId = try #require(store.records.first(where: { $0.title == "归档保护项" })?.id)
        let disposableIds = store.records.filter { $0.id != protectedId }.map(\.id)

        store.send(.batchSetRecordProject(recordIds: ids, project: "项目甲"), nowEpochSec: t0 + 3)
        #expect(store.records.allSatisfy { $0.project == "项目甲" })

        store.send(.batchSetRecordArchived(recordIds: [protectedId], archived: true), nowEpochSec: t0 + 4)
        #expect(store.records.first(where: { $0.id == protectedId })?.archived == true)

        store.send(.exportRecordsMarkdown(recordIds: ids, directory: exportDir.path), nowEpochSec: t0 + 5)
        let exportedFiles = try FileManager.default.contentsOfDirectory(atPath: exportDir.path)
        #expect(exportedFiles.filter { $0.hasSuffix(".md") }.count == 3)

        store.send(.batchTrashRecords(recordIds: ids), nowEpochSec: t0 + 6)
        #expect(store.records.map(\.id) == [protectedId])
        #expect(store.navigation.trashCount == 2)
        let undo = try #require(store.navigation.undoTrash)
        #expect(Set(undo.effectiveRecordIds) == Set(disposableIds))
        #expect(undo.count == 2)

        store.send(.batchRestoreRecords(recordIds: undo.effectiveRecordIds), nowEpochSec: t0 + 7)
        #expect(store.records.count == 3)
        #expect(store.navigation.trashCount == 0)
        #expect(store.navigation.undoTrash == nil)
    }
}
