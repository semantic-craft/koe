import Foundation
import Testing
@testable import KoeAppleShared

@Suite("Mode workspaces snapshot and decoupled controls")
struct ModeWorkspacesTests {
    @Test("Live HostSessionStore decodes unified workspaces projection and legacy JSON stays compatible")
    @MainActor
    func workspacesProjectionAndLegacyCompatibility() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let workspaces = try #require(store.snapshot.workspaces)
        #expect(workspaces.picker.cards.map(\.id) == ["notes", "all_day", "live_minutes"])
        #expect(workspaces.picker.cards.map(\.title) == ["随心闪记", "全天听记", "实时纪要"])
        #expect(workspaces.picker.beanBadge == "录音豆 未连接")
        #expect(workspaces.picker.canConnectBean == true)
        #expect(workspaces.picker.canSwitchToBean == false)
        #expect(workspaces.picker.guidanceText == "当前使用电脑麦克风，也可将录音豆放入充电仓按键连接后再选模式。")
        _ = TodayView(store: store).body
        #expect(!workspaces.quickNote.mcpReadNote.isEmpty)

        let legacyJSON = """
        {
          "version": 2,
          "generation": 5,
          "section": "today",
          "canGoBack": false,
          "selectedRecordId": null,
          "focusSegmentId": null,
          "records": [
            {
              "id": "legacy-1",
              "title": "旧版闪记",
              "createdAtEpochSec": 1700000000,
              "durationMs": 0,
              "source": "文字记录",
              "status": "就绪",
              "segmentCount": 1,
              "preview": "保留旧版快照兼容",
              "archived": false
            }
          ],
          "detail": null,
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
        let decoded = try JSONDecoder().decode(HostSnapshot.self, from: Data(legacyJSON.utf8))
        #expect(decoded.workspaces == nil)
        let legacyRecord = try #require(decoded.records.first)
        #expect(legacyRecord.mode == nil)
        #expect(legacyRecord.project == nil)
        #expect(legacyRecord.modeLabel == "随心闪记")
        #expect(legacyRecord.matches(filter: .inbox, query: ""))
    }

    @Test("Sidebar navigation across three modes stays side-effect-free while Mode Picker session switches stay on page")
    @MainActor
    func decoupledNavigationAndModePickerSwitches() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        for destination in ["notes", "all_day", "live_minutes", "today"] {
            store.send("navigate", ["section": destination])
            #expect(store.snapshot.section == destination)
            #expect(store.snapshot.activeCapture == nil)
        }

        let meetingCard = try #require(store.snapshot.workspaces?.picker.cards.first(where: { $0.id == "live_minutes" }))
        store.toggleModeSession(meetingCard)
        #expect(store.snapshot.section == "today")
        #expect(store.snapshot.workspaces?.liveMinutes.isActive == true)

        let activeMeetingCard = try #require(store.snapshot.workspaces?.picker.cards.first(where: { $0.id == "live_minutes" }))
        let mic = try #require(store.snapshot.microphone)
        store.toggleModeSession(activeMeetingCard)
        #expect(store.snapshot.activeCapture?.phase == "stopping")
        store.send("microphone_stopped", [
            "recordId": mic.recordId,
            "sessionId": mic.sessionId,
            "lane": "microphone",
            "sequence": mic.nextSequence,
            "epoch": mic.epoch
        ])
        #expect(store.snapshot.activeCapture == nil)
        #expect(store.snapshot.workspaces?.liveMinutes.isActive == false)
    }

    @Test("QuickNote project assignment, RecordListView category/search filtering, and AllDay span decoding")
    @MainActor
    func projectAssignmentFilteringAndAllDaySpans() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        store.send("create_note", ["title": "API 方案", "text": "讨论 C ABI 快照结构"])
        let firstId = try #require(store.snapshot.detail?.id)
        store.send("create_note", ["title": "读书清单", "text": "周末阅读系统设计章节"])
        #expect(store.snapshot.workspaces?.quickNote.inboxCount == 2)
        #expect(store.snapshot.records.filter { $0.matches(filter: .inbox, query: "") }.count == 2)

        store.send("set_record_project", ["recordId": firstId, "project": "Koe 架构"])
        let quickNote = try #require(store.snapshot.workspaces?.quickNote)
        #expect(quickNote.inboxCount == 1)
        #expect(quickNote.projects == [QuickNoteProjectCountSnapshot(name: "Koe 架构", count: 1)])

        let assigned = try #require(store.snapshot.records.first(where: { $0.id == firstId }))
        #expect(assigned.project == "Koe 架构")
        #expect(!assigned.matches(filter: .inbox, query: ""))
        #expect(assigned.matches(filter: .quickNote, query: "Koe 架构"))
        #expect(!assigned.matches(filter: .quickNote, query: "不存在的关键词"))

        let allDayJSON = """
        {
          "isActive": false,
          "isPaused": false,
          "canPause": false,
          "canResume": false,
          "sourceLabel": "系统默认麦克风",
          "selectedDate": "2026-11-15",
          "availableDates": ["2026-11-15"],
          "totalRecordedMs": 420000,
          "eventCount": 1,
          "pauseCount": 1,
          "gapCount": 1,
          "spans": [
            {
              "kind": "event",
              "id": "ev-1",
              "title": "上午架构评审",
              "startEpochSec": 1763172000,
              "endEpochSec": 1763172600,
              "durationMs": 420000,
              "recordIds": ["r-1", "r-2"],
              "primaryRecordId": "r-1",
              "firstSegment": null,
              "preview": "确认四层边界保持不变",
              "summaryPoints": ["接口保持稳定"],
              "speakers": ["Alice"],
              "segmentCount": 4
            },
            {
              "kind": "pause",
              "id": "pause-1",
              "recordId": "r-1",
              "startEpochSec": 1763172300,
              "endEpochSec": 1763172360,
              "durationMs": 60000
            },
            {
              "kind": "unrecorded_gap",
              "id": "gap-1",
              "startEpochSec": 1763172600,
              "endEpochSec": 1763176200,
              "durationMs": 3600000
            }
          ],
          "reviewTasks": [],
          "reviewMemories": [],
          "reviewDecisions": [],
          "dailyReview": {
            "overview": "完成上午架构评审",
            "highlights": ["确认四层边界"],
            "sources": []
          }
        }
        """
        let decodedAllDay = try JSONDecoder().decode(AllDayWorkspaceSnapshot.self, from: Data(allDayJSON.utf8))
        #expect(decodedAllDay.spans.map(\.kind) == ["event", "pause", "unrecorded_gap"])
        #expect(decodedAllDay.spans[0].recordIds == ["r-1", "r-2"])
        #expect(decodedAllDay.spans[1].recordId == "r-1")
        #expect(decodedAllDay.spans[2].durationMs == 3_600_000)
        #expect(decodedAllDay.dailyReview?.overview == "完成上午架构评审")
    }

    @Test("QuickNote filter selection, active card resolution, and customizable Markdown export preserve raw transcript first")
    @MainActor
    func quickNoteFilteringSelectionAndWorkspaceExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        store.send("create_note", ["title": "产品/路线图", "text": "第一阶段聚焦四模式工作区。"])
        let roadmapId = try #require(store.snapshot.detail?.id)
        store.send("create_note", ["title": "买咖啡豆", "text": "下班顺路买浅烘咖啡豆。"])
        let inboxId = try #require(store.snapshot.detail?.id)

        store.send("set_record_project", ["recordId": roadmapId, "project": "2026 规划"])
        store.send("select_quick_note_record", ["recordId": inboxId])

        let quickNote = try #require(store.snapshot.workspaces?.quickNote)
        #expect(quickNote.filteredCards(for: .all).count == 2)
        #expect(quickNote.filteredCards(for: .inbox).map(\.id) == [inboxId])
        #expect(quickNote.filteredCards(for: .project("2026 规划")).map(\.id) == [roadmapId])
        #expect(quickNote.resolvedSelectedCard(for: .all)?.id == inboxId)
        #expect(quickNote.resolvedSelectedCard(for: .project("2026 规划"))?.id == roadmapId)

        let roadmapCard = try #require(quickNote.cards.first(where: { $0.id == roadmapId }))
        let request = WorkspaceExportRequest.forQuickNote(
            roadmapCard,
            includeAnalysis: false,
            includeSources: false
        )
        #expect(request.suggestedFilename == "产品-路线图.md")
        let exportURL = directory.appendingPathComponent(request.suggestedFilename)
        store.send(request.command(path: exportURL.path))
        #expect(store.snapshot.error == nil)
        let exported = try String(contentsOf: exportURL, encoding: .utf8)
        #expect(exported.contains("# 产品/路线图"))
        #expect(exported.contains("## 原文"))
        #expect(exported.contains("第一阶段聚焦四模式工作区。"))
        #expect(!exported.contains("## AI 整理"))
        #expect(!exported.contains("## 来源引用"))

        _ = QuickNoteWorkspaceView(store: store).body
    }

    @Test("AllDay span presentation labels, clock-safe resume notification, and day Markdown export stay truthful")
    @MainActor
    func allDaySpanLabelsResumeSafetyAndDayExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let spansJSON = """
        [
          {
            "kind": "event",
            "id": "ev-cross",
            "title": "跨切片方案同步",
            "startEpochSec": 1763172000,
            "endEpochSec": 1763172480,
            "durationMs": 480000,
            "recordIds": ["s-1", "s-2"],
            "primaryRecordId": "s-1",
            "firstSegment": null,
            "preview": "连续两段切片合并展示",
            "summaryPoints": [],
            "speakers": ["Bob"],
            "segmentCount": 6
          },
          {
            "kind": "pause",
            "id": "pause-1",
            "recordId": "s-1",
            "startEpochSec": 1763172200,
            "endEpochSec": 1763172260,
            "durationMs": 60000
          },
          {
            "kind": "unrecorded_gap",
            "id": "gap-1",
            "startEpochSec": 1763172480,
            "endEpochSec": 1763176080,
            "durationMs": 3600000
          }
        ]
        """
        let spans = try JSONDecoder().decode([AllDaySpanSnapshot].self, from: Data(spansJSON.utf8))
        #expect(spans[0].sliceBadgeText == "跨 2 个切片")
        #expect(spans[1].statusSummaryLabel.hasPrefix("已暂停录音"))
        #expect(spans[2].statusSummaryLabel.hasPrefix("未录音空档"))
        let middleDot = String(UnicodeScalar(0x00B7)!)
        #expect(spans.allSatisfy { !$0.statusSummaryLabel.contains(middleDot) })

        var resumePosted = false
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name("KoeResumeMicrophone"),
            object: nil,
            queue: nil
        ) { _ in
            resumePosted = true
        }
        defer { NotificationCenter.default.removeObserver(token) }
        store.performCaptureAction(.resume)
        #expect(resumePosted)

        let dayRequest = WorkspaceExportRequest.forAllDay(
            date: "2026-11-15",
            includeAnalysis: true,
            includeSources: true
        )
        #expect(dayRequest.suggestedFilename == "全天听记-2026-11-15.md")
        let dayURL = directory.appendingPathComponent(dayRequest.suggestedFilename)
        store.send(dayRequest.command(path: dayURL.path))
        #expect(store.snapshot.error == nil)
        let dayMarkdown = try String(contentsOf: dayURL, encoding: .utf8)
        #expect(dayMarkdown.contains("2026-11-15"))

        _ = AllDayWorkspaceView(store: store).body
    }

    @Test("ModePickerSnapshot decodes phone handoff fields with legacy fallback and HostCommand encodes deviceRelease")
    @MainActor
    func modePickerPhoneHandoffSnapshotAndCommands() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let initialPicker = try #require(store.snapshot.workspaces?.picker)
        #expect(initialPicker.beanControlOwner == "mac")
        #expect(initialPicker.beanBadgeTone == "muted")
        #expect(initialPicker.canReleaseToPhone == true)

        #expect(HostCommand.deviceRelease.commandType == "device_release")
        let encodedCommand = try JSONEncoder().encode(HostCommand.deviceRelease)
        let decodedCommand = try JSONSerialization.jsonObject(with: encodedCommand) as? [String: Any]
        #expect(decodedCommand?["type"] as? String == "device_release")

        store.send(.deviceRelease)
        #expect(store.snapshot.device.autoConnect == false)
        let releasedPicker = try #require(store.snapshot.workspaces?.picker)
        #expect(releasedPicker.beanControlOwner == "phone")
        #expect(releasedPicker.beanBadge == "已让出给手机")
        #expect(releasedPicker.beanBadgeTone == "muted")
        #expect(releasedPicker.canReleaseToPhone == true)
        _ = TodayView(store: store).body
        _ = CaptureView(store: store).body
        _ = SettingsDoctorView(store: store).body
        _ = CompanionSettingsCard(store: store).body

        store.send(.deviceOpenGuide)
        #expect(store.snapshot.device.autoConnect == true)
        let reclaimedPicker = try #require(store.snapshot.workspaces?.picker)
        #expect(reclaimedPicker.beanControlOwner == "mac")

        store.send("device_event", ["event": "scanning", "connectionId": "scan-tone"])
        let scanningPicker = try #require(store.snapshot.workspaces?.picker)
        #expect(scanningPicker.beanBadgeTone == "warning")

        let legacyPickerJSON = """
        {
          "sourceLabel": "系统默认麦克风",
          "sourceBadge": "系统默认",
          "beanBadge": "录音豆 未连接",
          "guidanceText": "当前使用电脑麦克风",
          "canSwitchToBean": false,
          "canConnectBean": true,
          "cards": []
        }
        """
        let legacyPicker = try JSONDecoder().decode(ModePickerSnapshot.self, from: Data(legacyPickerJSON.utf8))
        #expect(legacyPicker.beanControlOwner == "mac")
        #expect(legacyPicker.beanBadgeTone == "muted")
        #expect(legacyPicker.canReleaseToPhone == true)

        let phonePickerJSON = """
        {
          "sourceLabel": "系统默认麦克风",
          "sourceBadge": "系统默认",
          "beanBadge": "已让出给手机",
          "beanBadgeTone": "success",
          "beanControlOwner": "phone",
          "guidanceText": "已释放 Mac 蓝牙占用",
          "canSwitchToBean": false,
          "canConnectBean": true,
          "canReleaseToPhone": false,
          "cards": []
        }
        """
        let phonePicker = try JSONDecoder().decode(ModePickerSnapshot.self, from: Data(phonePickerJSON.utf8))
        #expect(phonePicker.beanControlOwner == "phone")
        #expect(phonePicker.beanBadgeTone == "success")
        #expect(phonePicker.canReleaseToPhone == false)
    }
}
