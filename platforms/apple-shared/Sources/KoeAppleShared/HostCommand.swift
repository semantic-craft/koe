import Foundation

public enum HostCommand: Encodable, Equatable, Sendable {
    case navigate(section: String)
    case back
    case clearError

    case selectRecord(recordId: String)
    case openSource(recordId: String, segmentId: String)
    case importFile(path: String)
    case createNote(title: String, text: String, stayOnPage: Bool = false)
    case renameRecord(recordId: String, title: String)
    case setRecordProject(recordId: String, project: String? = nil)
    case selectQuickNoteRecord(recordId: String?)
    case selectAllDayDate(date: String)
    case selectLiveMinutesRecord(recordId: String?)
    case setRecordArchived(recordId: String, archived: Bool)
    case trashRecord(recordId: String)
    case restoreRecord(recordId: String)
    case purgeRecord(recordId: String)
    case emptyTrash
    case dismissUndoTrash
    case exportWorkspaceMarkdown(
        recordId: String? = nil,
        date: String? = nil,
        path: String,
        includeAnalysis: Bool = true,
        includeSources: Bool = true
    )

    case reviewItem(itemId: String, decision: String)
    case completeTask(itemId: String, completed: Bool)
    case editItem(itemId: String, text: String, due: String?)
    case saveMemory(recordId: String, segmentId: String)
    case createTask(recordId: String, segmentId: String)
    case addHighlight(recordId: String, segmentId: String)
    case editSegmentText(recordId: String, segmentId: String, text: String)
    case setSegmentSpeaker(recordId: String, segmentId: String, speaker: String?)
    case renameSpeaker(recordId: String, fromSpeaker: String, toSpeaker: String)

    case setAskScope(scope: String, recordId: String?)
    case ask(question: String, scope: String, recordId: String?)
    case transcribe(recordId: String)
    case summarize(recordId: String)

    case playback(isPlaying: Bool)
    case selectPlaybackLane(lane: String)
    case seek(positionMs: UInt64)

    case startCaptureMode(mode: CaptureMode, stayOnPage: Bool = false)
    case captureAction(action: CaptureAction, clockNs: UInt64? = nil)
    case selectCaptureSource(source: String)
    case setCaptureSystemAudio(enabled: Bool)

    case deviceOpenGuide
    case deviceOnboardingNext
    case deviceCloseGuide
    case deviceRefresh
    case deviceRelease
    case deviceDownload(fileId: UInt32)
    case setBleAutoConnect(enabled: Bool)

    case configureSpeech(engine: String, modelId: String? = nil)
    case prepareSpeechModel(modelId: String)
    case cancelSpeechModel
    case setMeetingAudioPolicy(policy: String)
    case configureProvider(
        apiKey: String? = nil,
        model: String,
        asrEndpoint: String? = nil,
        chatEndpoint: String? = nil
    )
    case retryProviderCredentials(authorize: Bool = false)
    case clearProviderCredential

    private enum CodingKeys: String, CodingKey {
        case type, section, recordId, segmentId, path, title, text, stayOnPage
        case project, date, archived, includeAnalysis, includeSources
        case itemId, decision, completed, due, speaker, fromSpeaker, toSpeaker
        case question, scope, positionMs, isPlaying, lane
        case enabled, mode, action, clockNs, source, fileId
        case engine, modelId, policy, apiKey, model, asrEndpoint, chatEndpoint, authorize
    }

    public var commandType: String {
        switch self {
        case .navigate: "navigate"
        case .back: "back"
        case .clearError: "clear_error"
        case .selectRecord: "select_record"
        case .openSource: "open_source"
        case .importFile: "import_file"
        case .createNote: "create_note"
        case .renameRecord: "rename_record"
        case .setRecordProject: "set_record_project"
        case .selectQuickNoteRecord: "select_quick_note_record"
        case .selectAllDayDate: "select_all_day_date"
        case .selectLiveMinutesRecord: "select_live_minutes_record"
        case .setRecordArchived: "set_record_archived"
        case .trashRecord: "trash_record"
        case .restoreRecord: "restore_record"
        case .purgeRecord: "purge_record"
        case .emptyTrash: "empty_trash"
        case .dismissUndoTrash: "dismiss_undo_trash"
        case .exportWorkspaceMarkdown: "export_workspace_markdown"
        case .reviewItem: "review_item"
        case .completeTask: "complete_task"
        case .editItem: "edit_item"
        case .saveMemory: "save_memory"
        case .createTask: "create_task"
        case .addHighlight: "add_highlight"
        case .editSegmentText: "edit_segment_text"
        case .setSegmentSpeaker: "set_segment_speaker"
        case .renameSpeaker: "rename_speaker"
        case .setAskScope: "set_ask_scope"
        case .ask: "ask"
        case .transcribe: "transcribe"
        case .summarize: "summarize"
        case .playback: "playback"
        case .selectPlaybackLane: "select_playback_lane"
        case .seek: "seek"
        case .startCaptureMode: "start_capture_mode"
        case .captureAction: "capture_action"
        case .selectCaptureSource: "select_capture_source"
        case .setCaptureSystemAudio: "set_capture_system_audio"
        case .deviceOpenGuide: "device_open_guide"
        case .deviceOnboardingNext: "device_onboarding_next"
        case .deviceCloseGuide: "device_close_guide"
        case .deviceRefresh: "device_refresh"
        case .deviceRelease: "device_release"
        case .deviceDownload: "device_download"
        case .setBleAutoConnect: "set_ble_auto_connect"
        case .configureSpeech: "configure_speech"
        case .prepareSpeechModel: "prepare_speech_model"
        case .cancelSpeechModel: "cancel_speech_model"
        case .setMeetingAudioPolicy: "set_meeting_audio_policy"
        case .configureProvider: "configure_provider"
        case .retryProviderCredentials: "retry_provider_credentials"
        case .clearProviderCredential: "clear_provider_credential"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(commandType, forKey: .type)
        switch self {
        case .back, .clearError, .emptyTrash, .dismissUndoTrash,
             .deviceOpenGuide, .deviceOnboardingNext, .deviceCloseGuide, .deviceRefresh, .deviceRelease,
             .cancelSpeechModel, .clearProviderCredential:
            break
        case let .navigate(section):
            try c.encode(section, forKey: .section)
        case let .selectRecord(recordId),
             let .trashRecord(recordId),
             let .restoreRecord(recordId),
             let .purgeRecord(recordId),
             let .transcribe(recordId),
             let .summarize(recordId):
            try c.encode(recordId, forKey: .recordId)
        case let .openSource(recordId, segmentId),
             let .saveMemory(recordId, segmentId),
             let .createTask(recordId, segmentId),
             let .addHighlight(recordId, segmentId):
            try c.encode(recordId, forKey: .recordId)
            try c.encode(segmentId, forKey: .segmentId)
        case let .importFile(path):
            try c.encode(path, forKey: .path)
        case let .createNote(title, text, stayOnPage):
            try c.encode(title, forKey: .title)
            try c.encode(text, forKey: .text)
            try c.encode(stayOnPage, forKey: .stayOnPage)
        case let .renameRecord(recordId, title):
            try c.encode(recordId, forKey: .recordId)
            try c.encode(title, forKey: .title)
        case let .setRecordProject(recordId, project):
            try c.encode(recordId, forKey: .recordId)
            try c.encodeIfPresent(project, forKey: .project)
        case let .selectQuickNoteRecord(recordId),
             let .selectLiveMinutesRecord(recordId):
            try c.encodeIfPresent(recordId, forKey: .recordId)
        case let .selectAllDayDate(date):
            try c.encode(date, forKey: .date)
        case let .setRecordArchived(recordId, archived):
            try c.encode(recordId, forKey: .recordId)
            try c.encode(archived, forKey: .archived)
        case let .exportWorkspaceMarkdown(recordId, date, path, includeAnalysis, includeSources):
            try c.encodeIfPresent(recordId, forKey: .recordId)
            try c.encodeIfPresent(date, forKey: .date)
            try c.encode(path, forKey: .path)
            try c.encode(includeAnalysis, forKey: .includeAnalysis)
            try c.encode(includeSources, forKey: .includeSources)
        case let .reviewItem(itemId, decision):
            try c.encode(itemId, forKey: .itemId)
            try c.encode(decision, forKey: .decision)
        case let .completeTask(itemId, completed):
            try c.encode(itemId, forKey: .itemId)
            try c.encode(completed, forKey: .completed)
        case let .editItem(itemId, text, due):
            try c.encode(itemId, forKey: .itemId)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(due, forKey: .due)
        case let .editSegmentText(recordId, segmentId, text):
            try c.encode(recordId, forKey: .recordId)
            try c.encode(segmentId, forKey: .segmentId)
            try c.encode(text, forKey: .text)
        case let .setSegmentSpeaker(recordId, segmentId, speaker):
            try c.encode(recordId, forKey: .recordId)
            try c.encode(segmentId, forKey: .segmentId)
            try c.encodeIfPresent(speaker, forKey: .speaker)
        case let .renameSpeaker(recordId, fromSpeaker, toSpeaker):
            try c.encode(recordId, forKey: .recordId)
            try c.encode(fromSpeaker, forKey: .fromSpeaker)
            try c.encode(toSpeaker, forKey: .toSpeaker)
        case let .setAskScope(scope, recordId):
            try c.encode(scope, forKey: .scope)
            try c.encodeIfPresent(recordId, forKey: .recordId)
        case let .ask(question, scope, recordId):
            try c.encode(question, forKey: .question)
            try c.encode(scope, forKey: .scope)
            try c.encodeIfPresent(recordId, forKey: .recordId)
        case let .playback(isPlaying):
            try c.encode(isPlaying, forKey: .isPlaying)
        case let .selectPlaybackLane(lane):
            try c.encode(lane, forKey: .lane)
        case let .seek(positionMs):
            try c.encode(positionMs, forKey: .positionMs)
        case let .startCaptureMode(mode, stayOnPage):
            try c.encode(mode, forKey: .mode)
            try c.encode(stayOnPage, forKey: .stayOnPage)
        case let .captureAction(action, clockNs):
            try c.encode(action, forKey: .action)
            try c.encodeIfPresent(clockNs, forKey: .clockNs)
        case let .selectCaptureSource(source):
            try c.encode(source, forKey: .source)
        case let .setCaptureSystemAudio(enabled),
             let .setBleAutoConnect(enabled):
            try c.encode(enabled, forKey: .enabled)
        case let .deviceDownload(fileId):
            try c.encode(fileId, forKey: .fileId)
        case let .configureSpeech(engine, modelId):
            try c.encode(engine, forKey: .engine)
            try c.encodeIfPresent(modelId, forKey: .modelId)
        case let .prepareSpeechModel(modelId):
            try c.encode(modelId, forKey: .modelId)
        case let .setMeetingAudioPolicy(policy):
            try c.encode(policy, forKey: .policy)
        case let .configureProvider(apiKey, model, asrEndpoint, chatEndpoint):
            try c.encodeIfPresent(apiKey, forKey: .apiKey)
            try c.encode(model, forKey: .model)
            try c.encodeIfPresent(asrEndpoint, forKey: .asrEndpoint)
            try c.encodeIfPresent(chatEndpoint, forKey: .chatEndpoint)
        case let .retryProviderCredentials(authorize):
            try c.encode(authorize, forKey: .authorize)
        }
    }
}
