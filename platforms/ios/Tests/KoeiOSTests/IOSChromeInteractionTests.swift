import KoeAppleCore
import SwiftUI
import XCTest
@testable import KoeiOSApp

@MainActor
final class IOSChromeInteractionTests: XCTestCase {
    func testDraggingKeepsPreviewLocalUntilRelease() {
        var draft: Double?
        var seeks: [UInt64] = []
        let scrubber = IOSPlaybackScrubber(draft: Binding(get: { draft }, set: { draft = $0 }),
                                           positionMs: 1000, seek: { seeks.append($0) })
        scrubber.editingChanged(true)
        scrubber.value.wrappedValue = 2500
        scrubber.value.wrappedValue = 3900
        XCTAssertEqual(scrubber.value.wrappedValue, 3900)
        XCTAssertEqual(seeks, [])
        scrubber.editingChanged(false)
        scrubber.editingChanged(false)
        XCTAssertEqual(seeks, [3900])
        XCTAssertNil(draft)
    }

    func testMiniPlayerFollowsVisibleRouteAndPlayableAsset() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ios-rich-snapshot", withExtension: "json"))
        let playback = try JSONDecoder().decode(HostSnapshot.self, from: Data(contentsOf: url)).playback
        let id = try XCTUnwrap(playback.recordId)
        XCTAssertEqual(IOSMiniPlayerBar.miniPlayerRecordID(playback, visibleRoute: nil), id)
        XCTAssertEqual(IOSMiniPlayerBar.miniPlayerRecordID(playback, visibleRoute: .workspace(.quickNote)), id)
        XCTAssertEqual(IOSMiniPlayerBar.miniPlayerRecordID(playback, visibleRoute: .record("other")), id)
        XCTAssertNil(IOSMiniPlayerBar.miniPlayerRecordID(playback, visibleRoute: .record(id)))
        XCTAssertNil(IOSMiniPlayerBar.miniPlayerRecordID(HostSnapshot.empty.playback, visibleRoute: nil))
    }

    func testSourceFocusBelongsToThePushedRecord() throws {
        try withStore { store in
            store.send(.createNote(title: "原文", text: "第一段\n第二段"))
            let detail = try XCTUnwrap(store.recordDetail.detail)
            let segment = try XCTUnwrap(detail.segments.last)
            let view = IOSRecordDetailView(store: store, recordId: detail.id)
            XCTAssertNil(view.focusTarget)
            store.send(.openSource(recordId: detail.id, segmentId: segment.id))
            XCTAssertEqual(view.focusTarget, segment.id)
            XCTAssertNil(IOSRecordDetailView(store: store, recordId: "other").focusTarget)
        }
    }

    func testConfirmingSingleRemovalPreservesOtherTrashUntilEmptyConfirmed() throws {
        try withStore { store in
            var ids: [String] = []
            for title in ["一", "二"] {
                store.send(.createNote(title: title, text: title))
                let id = try XCTUnwrap(store.recordDetail.detail?.id)
                store.send(.trashRecord(recordId: id))
                ids.append(id)
            }
            let removal = IOSTrashRemoval.record(ids[0])
            XCTAssertEqual(Set(store.trashRecords.map(\.id)), Set(ids))
            removal.confirm(in: store)
            XCTAssertEqual(store.trashRecords.map(\.id), [ids[1]])
            IOSTrashRemoval.all.confirm(in: store)
            XCTAssertTrue(store.trashRecords.isEmpty)
        }
    }

    private func withStore(_ body: (HostSessionStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path, credentials: NativeCredentialsiOS(forceIsolated: true))
        defer { store.shutdown() }
        try body(store)
    }
}
