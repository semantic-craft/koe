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

        let micStart = try encodeObject(.startMicrophone(inputId: "built-in", includeSystem: true, clockNs: 99))
        #expect(micStart["type"] as? String == "start_microphone")
        #expect(micStart["inputId"] as? String == "built-in")
        #expect(micStart["includeSystem"] as? Bool == true)
        #expect(micStart["clockNs"] as? UInt64 == 99)

        let micBare = try encodeObject(.startMicrophone(inputId: "built-in"))
        #expect(micBare["includeSystem"] as? Bool == false)
        #expect(micBare["clockNs"] == nil)

        #expect(try encodeObject(.pauseMicrophone)["type"] as? String == "pause_microphone")
        #expect(try encodeObject(.stopMicrophone)["type"] as? String == "stop_microphone")
        #expect(try encodeObject(.cancelMicrophone)["type"] as? String == "cancel_microphone")
        #expect(try encodeObject(.retryMicrophoneSave)["type"] as? String == "retry_microphone_save")
        #expect(try encodeObject(.checkAppUpdate)["type"] as? String == "check_app_update")

        let syncMetaData = try JSONEncoder().encode(
            HostAdapterEvent.syncAppMetadata(version: "2.3.0", build: "12", updateEndpoint: "http://127.0.0.1:8080/latest")
        )
        let syncMetaObj = try #require(JSONSerialization.jsonObject(with: syncMetaData) as? [String: Any])
        #expect(syncMetaObj["type"] as? String == "sync_app_metadata")
        #expect(syncMetaObj["version"] as? String == "2.3.0")
        #expect(syncMetaObj["build"] as? String == "12")
        #expect(syncMetaObj["updateEndpoint"] as? String == "http://127.0.0.1:8080/latest")

        #expect(HostSection.menuSections.map(\.rawValue) == [
            "today", "notes", "all_day", "live_minutes", "ask", "records", "tasks", "settings"
        ])
        #expect(HostSection.title(for: "notes") == CaptureMode.quickNote.title)
        #expect(HostSection.title(for: "all_day") == CaptureMode.allDay.title)
        #expect(HostSection.title(for: "live_minutes") == CaptureMode.meeting.title)
        #expect(HostSection.notes.icon == CaptureMode.quickNote.icon)
        #expect(HostSection.allDay.icon == CaptureMode.allDay.icon)
        #expect(HostSection.liveMinutes.icon == CaptureMode.meeting.icon)
        #expect(HostSection.title(for: "detail", detailTitle: "周会") == "周会")
        #expect(HostSection.title(for: "settings") == "模型设置")
        #expect(HostSection.title(for: "capture") == "录音管理")

        let cfgObj = try encodeObject(.configureProvider(
            apiKey: "qwen-k",
            deepseekApiKey: "ds-k",
            asrProvider: "deepseek",
            asrModel: "",
            llmProvider: "deepseek",
            model: "deepseek-flash",
            enableThinking: true,
            qwenWorkspaceId: "ws-01"
        ))
        #expect(cfgObj["type"] as? String == "configure_provider")
        #expect(cfgObj["deepseekApiKey"] as? String == "ds-k")
        #expect(cfgObj["asrProvider"] as? String == "deepseek")
        #expect(cfgObj["llmProvider"] as? String == "deepseek")
        #expect(cfgObj["enableThinking"] as? Bool == true)
        #expect(cfgObj["qwenWorkspaceId"] as? String == "ws-01")

        let clearDsObj = try encodeObject(.clearProviderCredentialFor(provider: "deepseek"))
        #expect(clearDsObj["type"] as? String == "clear_provider_credential")
        #expect(clearDsObj["provider"] as? String == "deepseek")
        #expect(try encodeObject(.deviceDownloadAll)["type"] as? String == "device_download_all")
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
            store.send(.microphoneStopped(recordId: mic.recordId, sessionId: mic.sessionId, lane: "microphone", sequence: mic.nextSequence, epoch: mic.epoch))
        }
        #expect(store.sidebar.appVersion == AppUpdateSnapshot.defaultVersion)
        #expect(store.sidebar.appBuild == AppUpdateSnapshot.defaultBuild)
        #expect(!store.sidebar.hasAvailableUpdate)
        #expect(store.settings.appUpdate.phase == "idle")
        _ = AppUpdateSettingsCard(store: store).body
        _ = SidebarView(store: store).body
        _ = BeanDevicePopoverView(store: store).body
        _ = CaptureView(store: store).body
        _ = SettingsDoctorView(store: store).body
        #expect(store.nativeError == nil)
        #expect(store.snapshot.error == nil)

        var draft = ModelSettingsDraft()
        draft.llmProvider = "custom"
        draft.customLlmModel = ""
        draft.customChatEndpoint = "http://127.0.0.1:11434/v1/chat/completions"
        #expect(draft.resolvedLlmModelForSave.isEmpty)
        draft.selectLlmProvider("deepseek")
        #expect(draft.customChatEndpoint.isEmpty)
        #expect(draft.effectiveChatEndpoint() == "https://api.deepseek.com/chat/completions")
        #expect(draft.resolvedLlmModelForSave == "deepseek-flash")
        draft.selectLlmProvider("qwen")
        #expect(draft.effectiveChatEndpoint() == "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
        #expect(draft.resolvedLlmModelForSave == "qwen3.7-plus")
    }
}
