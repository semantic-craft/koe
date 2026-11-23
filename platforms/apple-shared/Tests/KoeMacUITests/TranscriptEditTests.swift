#if canImport(AppKit)
import AppKit
#endif
import Foundation
import SwiftUI
import Testing
@testable import KoeMacUI

@Suite("Transcript segment editing and speaker merge over C ABI v2")
struct TranscriptEditTests {
    @Test("Inline edit_segment_text latches originalText, updates BM25 retrieval and citations, and collapses on revert")
    @MainActor
    func editSegmentTextLatchesProvenanceUpdatesSearchAndReverts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)

        store.send(.createNote(title: "Product architecture sync", text: "Ship quantum telemetry pipeline on Friday.\nKeep audio assets immutable."), nowEpochSec: 1_800_000_000)

        let initialDetail = try #require(store.snapshot.detail)
        #expect(initialDetail.canEditTranscript == true)
        #expect(initialDetail.minutesStale == false)
        #expect(initialDetail.segments.count == 2)

        let seg0 = initialDetail.segments[0]
        #expect(seg0.isEdited == false)
        #expect(seg0.originalText == nil)

        store.send(.createTask(recordId: initialDetail.id, segmentId: seg0.id))
        store.send(.addHighlight(recordId: initialDetail.id, segmentId: seg0.id))
        let taskBefore = try #require(store.snapshot.tasks.first)
        #expect(taskBefore.sources.first?.segmentId == seg0.id)
        #expect(taskBefore.sources.first?.quote == "Ship quantum telemetry pipeline on Friday.")

        store.send(.editSegmentText(recordId: initialDetail.id, segmentId: seg0.id, text: "Ship deterministic local indexing on Thursday."), nowEpochSec: 1_800_000_010)
        #expect(store.snapshot.error == nil)

        let editedDetail = try #require(store.snapshot.detail)
        let editedSeg0 = try #require(editedDetail.segments.first(where: { $0.id == seg0.id }))
        #expect(editedSeg0.text == "Ship deterministic local indexing on Thursday.")
        #expect(editedSeg0.originalText == "Ship quantum telemetry pipeline on Friday.")
        #expect(editedSeg0.isEdited == true)

        let taskAfterEdit = try #require(store.snapshot.tasks.first)
        #expect(taskAfterEdit.sources.first?.recordId == initialDetail.id)
        #expect(taskAfterEdit.sources.first?.segmentId == seg0.id)
        #expect(taskAfterEdit.sources.first?.quote == "Ship deterministic local indexing on Thursday.")
        #expect(editedDetail.highlights.first?.segmentId == seg0.id)
        #expect(editedDetail.highlights.first?.quote == "Ship deterministic local indexing on Thursday.")

        store.send(.ask(question: "deterministic local indexing", scope: "record", recordId: initialDetail.id), nowEpochSec: 1_800_000_015)
        let answer = try #require(store.snapshot.ask.messages.last)
        #expect(answer.mode == "retrieval")
        #expect(answer.sources.first?.segmentId == seg0.id)
        #expect(answer.sources.first?.quote == "Ship deterministic local indexing on Thursday.")

        store.send(.selectRecord(recordId: initialDetail.id), nowEpochSec: 1_800_000_016)
        store.send(.editSegmentText(recordId: initialDetail.id, segmentId: seg0.id, text: "Ship quantum telemetry pipeline on Friday."), nowEpochSec: 1_800_000_020)
        #expect(store.snapshot.error == nil)

        let revertedDetail = try #require(store.snapshot.detail)
        let revertedSeg0 = try #require(revertedDetail.segments.first(where: { $0.id == seg0.id }))
        #expect(revertedSeg0.text == "Ship quantum telemetry pipeline on Friday.")
        #expect(revertedSeg0.isEdited == false)
        #expect(revertedSeg0.originalText == nil)
        store.shutdown()
    }

    @Test("set_segment_speaker normalizes punctuation, clears empty speaker, and rename_speaker merges speakers")
    @MainActor
    func speakerAssignmentNormalizationClearAndBatchMerge() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        store.send(.createNote(title: "Design review", text: "Opening agenda item.\nBudget follow-up.\nClosing summary."), nowEpochSec: 1_800_000_100)
        let detail0 = try #require(store.snapshot.detail)
        #expect(detail0.segments.count == 3)
        let (seg0, seg1, seg2) = (detail0.segments[0], detail0.segments[1], detail0.segments[2])

        store.send(.setSegmentSpeaker(recordId: detail0.id, segmentId: seg0.id, speaker: "发言人 1："), nowEpochSec: 1_800_000_105)
        store.send(.setSegmentSpeaker(recordId: detail0.id, segmentId: seg1.id, speaker: "Alice:"), nowEpochSec: 1_800_000_106)
        store.send(.setSegmentSpeaker(recordId: detail0.id, segmentId: seg2.id, speaker: "发言人 1"), nowEpochSec: 1_800_000_107)
        #expect(store.snapshot.error == nil)

        let detailNamed = try #require(store.snapshot.detail)
        #expect(detailNamed.segments[0].speaker == "发言人 1")
        #expect(detailNamed.segments[1].speaker == "Alice")
        #expect(detailNamed.segments[2].speaker == "发言人 1")
        #expect(detailNamed.speakers == [
            SpeakerSummarySnapshot(name: "发言人 1", segmentCount: 2, firstSegmentId: seg0.id),
            SpeakerSummarySnapshot(name: "Alice", segmentCount: 1, firstSegmentId: seg1.id),
        ])

        store.send(.renameSpeaker(recordId: detail0.id, fromSpeaker: "发言人 1", toSpeaker: "Alice"), nowEpochSec: 1_800_000_110)
        #expect(store.snapshot.error == nil)

        let detailMerged = try #require(store.snapshot.detail)
        #expect(detailMerged.segments.allSatisfy { $0.speaker == "Alice" })
        #expect(detailMerged.speakers == [SpeakerSummarySnapshot(name: "Alice", segmentCount: 3, firstSegmentId: seg0.id)])

        store.send(.ask(question: "Alice", scope: "record", recordId: detail0.id), nowEpochSec: 1_800_000_112)
        let askReply = try #require(store.snapshot.ask.messages.last)
        #expect(askReply.text.contains("Alice："))
        #expect(!askReply.sources.isEmpty)
        store.send(.selectRecord(recordId: detail0.id), nowEpochSec: 1_800_000_113)

        store.send(.setSegmentSpeaker(recordId: detail0.id, segmentId: seg0.id, speaker: ""), nowEpochSec: 1_800_000_115)
        #expect(store.snapshot.error == nil)

        let detailCleared = try #require(store.snapshot.detail)
        #expect(detailCleared.segments[0].speaker == nil)
        #expect(detailCleared.speakers == [SpeakerSummarySnapshot(name: "Alice", segmentCount: 2, firstSegmentId: seg1.id)])
    }

    @Test("Archive protection flips canEditTranscript to false and blocks segment text and speaker edits")
    @MainActor
    func archiveLockBlocksTranscriptMutationsUntilUnarchived() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        store.send(.createNote(title: "Board resolution", text: "Approve Q4 roadmap.\nFreeze schema v2."), nowEpochSec: 1_800_000_200)
        let detail0 = try #require(store.snapshot.detail)
        let seg0 = try #require(detail0.segments.first)
        store.send(.setSegmentSpeaker(recordId: detail0.id, segmentId: seg0.id, speaker: "Chair"), nowEpochSec: 1_800_000_201)
        #expect(store.snapshot.detail?.canEditTranscript == true)

        store.send(.setRecordArchived(recordId: detail0.id, archived: true), nowEpochSec: 1_800_000_205)
        let archivedDetail = try #require(store.snapshot.detail)
        #expect(archivedDetail.archived == true)
        #expect(archivedDetail.canEditTranscript == false)

        store.send(.editSegmentText(recordId: detail0.id, segmentId: seg0.id, text: "Tampered text"), nowEpochSec: 1_800_000_206)
        #expect(store.snapshot.error?.contains("归档") == true)
        #expect(store.snapshot.detail?.segments.first?.text == "Approve Q4 roadmap.")
        store.clearError()

        store.send(.renameSpeaker(recordId: detail0.id, fromSpeaker: "Chair", toSpeaker: "Guest"), nowEpochSec: 1_800_000_207)
        #expect(store.snapshot.error?.contains("归档") == true)
        #expect(store.snapshot.detail?.segments.first?.speaker == "Chair")
        store.clearError()

        store.send(.setRecordArchived(recordId: detail0.id, archived: false), nowEpochSec: 1_800_000_210)
        #expect(store.snapshot.detail?.canEditTranscript == true)

        store.send(.editSegmentText(recordId: detail0.id, segmentId: seg0.id, text: "Approve Q4 roadmap unanimously."), nowEpochSec: 1_800_000_212)
        #expect(store.snapshot.error == nil)
        #expect(store.snapshot.detail?.segments.first?.text == "Approve Q4 roadmap unanimously.")
    }

    @Test("Legacy JSON payloads decode defaults and RecordDetailView + TranscriptDetailView render cleanly")
    @MainActor
    func backwardCompatibleDecodingAndViewRendering() throws {
        let legacyDetailJSON = """
        {
          "id": "rec-legacy-2", "title": "Legacy Snapshot", "createdAtEpochSec": 1700000500,
          "durationMs": 8000, "source": "随手记", "status": "已有文字",
          "segments": [{ "id": "1", "text": "Legacy segment without edit metadata", "startMs": 0, "endMs": 4000, "speaker": "Speaker A" }],
          "summary": [], "highlights": [], "audioPath": null, "canRetranscribe": false, "isProcessing": false
        }
        """
        let legacyDetail = try JSONDecoder().decode(RecordDetailSnapshot.self, from: Data(legacyDetailJSON.utf8))
        #expect(legacyDetail.minutesStale == false)
        #expect(legacyDetail.canEditTranscript == false)
        #expect(legacyDetail.speakers.isEmpty)
        #expect(legacyDetail.segments.first?.originalText == nil)
        #expect(legacyDetail.segments.first?.isEdited == false)

        let richDetailJSON = """
        {
          "id": "rec-rich-1", "title": "Edited Meeting", "createdAtEpochSec": 1800000500,
          "durationMs": 12000, "source": "录音豆", "status": "原文已变更待重算",
          "archived": false, "minutesStale": true, "canEditTranscript": true,
          "speakers": [
            { "name": "张显伟", "segmentCount": 1, "firstSegmentId": "10" },
            { "name": "林工", "segmentCount": 1, "firstSegmentId": "11" }
          ],
          "segments": [
            { "id": "10", "text": "修正后的架构决议", "originalText": "修整后的架构决意", "isEdited": true, "startMs": 0, "endMs": 6000, "timed": true, "speaker": "张显伟" },
            { "id": "11", "text": "保持 C ABI 单写者边界", "originalText": null, "isEdited": false, "startMs": 6000, "endMs": 12000, "timed": true, "speaker": "林工" }
          ],
          "summary": [{ "title": "摘要", "text": "旧版摘要仍可阅读", "sources": [] }],
          "highlights": [], "audioPath": null, "canRetranscribe": false, "isProcessing": false
        }
        """
        let richDetail = try JSONDecoder().decode(RecordDetailSnapshot.self, from: Data(richDetailJSON.utf8))
        #expect(richDetail.minutesStale == true)
        #expect(richDetail.canEditTranscript == true)
        #expect(richDetail.speakers.count == 2)
        #expect(richDetail.segments[0].isEdited == true)
        #expect(richDetail.segments[0].originalText == "修整后的架构决意")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }
        store.send(.createNote(title: "UI Render Check", text: "First paragraph.\nSecond paragraph."))

        #if canImport(AppKit)
        let detailHost = NSHostingView(rootView: RecordDetailView(store: store))
        detailHost.frame = NSRect(x: 0, y: 0, width: 1040, height: 680)
        detailHost.layoutSubtreeIfNeeded()

        let transcriptHost = NSHostingView(rootView: TranscriptDetailView(detail: richDetail, store: store) { _ in })
        transcriptHost.frame = NSRect(x: 0, y: 0, width: 760, height: 680)
        transcriptHost.layoutSubtreeIfNeeded()

        let readOnlyHost = NSHostingView(rootView: TranscriptDetailView(detail: legacyDetail, store: store))
        readOnlyHost.frame = NSRect(x: 0, y: 0, width: 760, height: 680)
        readOnlyHost.layoutSubtreeIfNeeded()
        #expect(detailHost.fittingSize.width >= 0)
        #expect(transcriptHost.fittingSize.width >= 0)
        #expect(readOnlyHost.fittingSize.width >= 0)
        #endif
    }
}
