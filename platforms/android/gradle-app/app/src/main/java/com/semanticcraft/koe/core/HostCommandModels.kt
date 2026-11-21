package com.semanticcraft.koe.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
enum class ReviewDecision {
    @SerialName("accept") ACCEPT,
    @SerialName("dismiss") DISMISS,
    @SerialName("reset") RESET,
}

@Serializable
sealed interface HostCommand {
    fun toJsonString(): String = HostJson.json.encodeToString(serializer(), this)

    val commandType: String
        get() = when (this) {
            is Navigate -> "navigate"
            Back -> "back"
            ClearError -> "clear_error"
            is SelectRecord -> "select_record"
            is OpenSource -> "open_source"
            is ImportFile -> "import_file"
            is CreateNote -> "create_note"
            is RenameRecord -> "rename_record"
            is SetRecordProject -> "set_record_project"
            is SelectQuickNoteRecord -> "select_quick_note_record"
            is SelectAllDayDate -> "select_all_day_date"
            is SelectLiveMinutesRecord -> "select_live_minutes_record"
            is SetRecordArchived -> "set_record_archived"
            is BatchSetRecordArchived -> "batch_set_record_archived"
            is BatchSetRecordProject -> "batch_set_record_project"
            is TrashRecord -> "trash_record"
            is BatchTrashRecords -> "batch_trash_records"
            is RestoreRecord -> "restore_record"
            is BatchRestoreRecords -> "batch_restore_records"
            is PurgeRecord -> "purge_record"
            EmptyTrash -> "empty_trash"
            DismissUndoTrash -> "dismiss_undo_trash"
            is ExportWorkspaceMarkdown -> "export_workspace_markdown"
            is ExportRecordsMarkdown -> "export_records_markdown"
            is ReviewItem -> "review_item"
            is CompleteTask -> "complete_task"
            is EditItem -> "edit_item"
            is SaveMemory -> "save_memory"
            is CreateTask -> "create_task"
            is AddHighlight -> "add_highlight"
            is EditSegmentText -> "edit_segment_text"
            is SetSegmentSpeaker -> "set_segment_speaker"
            is RenameSpeaker -> "rename_speaker"
            is SetAskScope -> "set_ask_scope"
            is Ask -> "ask"
            is Transcribe -> "transcribe"
            is Summarize -> "summarize"
            is Playback -> "playback"
            is SelectPlaybackLane -> "select_playback_lane"
            is Seek -> "seek"
            is StartCaptureMode -> "start_capture_mode"
            is CaptureActionCommand -> "capture_action"
            is StartMicrophone -> "start_microphone"
            PauseMicrophone -> "pause_microphone"
            StopMicrophone -> "stop_microphone"
            CancelMicrophone -> "cancel_microphone"
            RetryMicrophoneSave -> "retry_microphone_save"
            is SelectCaptureSource -> "select_capture_source"
            is SetCaptureSystemAudio -> "set_capture_system_audio"
            DeviceOpenGuide -> "device_open_guide"
            DeviceOnboardingNext -> "device_onboarding_next"
            DeviceCloseGuide -> "device_close_guide"
            DeviceRefresh -> "device_refresh"
            DeviceRelease -> "device_release"
            is DeviceDownload -> "device_download"
            DeviceDownloadAll -> "device_download_all"
            is SetBleAutoConnect -> "set_ble_auto_connect"
            is ConfigureSpeech -> "configure_speech"
            is PrepareSpeechModel -> "prepare_speech_model"
            CancelSpeechModel -> "cancel_speech_model"
            is SetMeetingAudioPolicy -> "set_meeting_audio_policy"
            is ConfigureProvider -> "configure_provider"
            is RetryProviderCredentials -> "retry_provider_credentials"
            is ClearProviderCredential -> "clear_provider_credential"
            CheckAppUpdate -> "check_app_update"
        }

    @Serializable @SerialName("navigate") data class Navigate(val section: String) : HostCommand
    @Serializable @SerialName("back") data object Back : HostCommand
    @Serializable @SerialName("clear_error") data object ClearError : HostCommand

    @Serializable @SerialName("select_record") data class SelectRecord(val recordId: String) : HostCommand
    @Serializable @SerialName("open_source") data class OpenSource(val recordId: String, val segmentId: String) : HostCommand
    @Serializable @SerialName("import_file") data class ImportFile(val path: String) : HostCommand
    @Serializable @SerialName("create_note")
    data class CreateNote(val title: String, val text: String, val stayOnPage: Boolean = false) : HostCommand
    @Serializable @SerialName("rename_record") data class RenameRecord(val recordId: String, val title: String) : HostCommand
    @Serializable @SerialName("set_record_project")
    data class SetRecordProject(val recordId: String, val project: String? = null) : HostCommand
    @Serializable @SerialName("select_quick_note_record")
    data class SelectQuickNoteRecord(val recordId: String? = null) : HostCommand
    @Serializable @SerialName("select_all_day_date") data class SelectAllDayDate(val date: String) : HostCommand
    @Serializable @SerialName("select_live_minutes_record")
    data class SelectLiveMinutesRecord(val recordId: String? = null) : HostCommand
    @Serializable @SerialName("set_record_archived")
    data class SetRecordArchived(val recordId: String, val archived: Boolean) : HostCommand
    @Serializable @SerialName("batch_set_record_archived")
    data class BatchSetRecordArchived(val recordIds: List<String>, val archived: Boolean) : HostCommand
    @Serializable @SerialName("batch_set_record_project")
    data class BatchSetRecordProject(val recordIds: List<String>, val project: String? = null) : HostCommand
    @Serializable @SerialName("trash_record") data class TrashRecord(val recordId: String) : HostCommand
    @Serializable @SerialName("batch_trash_records")
    data class BatchTrashRecords(val recordIds: List<String>) : HostCommand
    @Serializable @SerialName("restore_record") data class RestoreRecord(val recordId: String) : HostCommand
    @Serializable @SerialName("batch_restore_records")
    data class BatchRestoreRecords(val recordIds: List<String>) : HostCommand
    @Serializable @SerialName("purge_record") data class PurgeRecord(val recordId: String) : HostCommand
    @Serializable @SerialName("empty_trash") data object EmptyTrash : HostCommand
    @Serializable @SerialName("dismiss_undo_trash") data object DismissUndoTrash : HostCommand
    @Serializable @SerialName("export_workspace_markdown")
    data class ExportWorkspaceMarkdown(
        val recordId: String? = null,
        val date: String? = null,
        val path: String,
        val includeAnalysis: Boolean = true,
        val includeSources: Boolean = true,
    ) : HostCommand
    @Serializable @SerialName("export_records_markdown")
    data class ExportRecordsMarkdown(
        val recordIds: List<String>,
        val directory: String,
        val includeAnalysis: Boolean = true,
        val includeSources: Boolean = true,
    ) : HostCommand

    @Serializable @SerialName("review_item") data class ReviewItem(val itemId: String, val decision: ReviewDecision) : HostCommand
    @Serializable @SerialName("complete_task") data class CompleteTask(val itemId: String, val completed: Boolean) : HostCommand
    @Serializable @SerialName("edit_item")
    data class EditItem(val itemId: String, val text: String, val due: String? = null) : HostCommand
    @Serializable @SerialName("save_memory") data class SaveMemory(val recordId: String, val segmentId: String) : HostCommand
    @Serializable @SerialName("create_task") data class CreateTask(val recordId: String, val segmentId: String) : HostCommand
    @Serializable @SerialName("add_highlight") data class AddHighlight(val recordId: String, val segmentId: String) : HostCommand
    @Serializable @SerialName("edit_segment_text")
    data class EditSegmentText(val recordId: String, val segmentId: String, val text: String) : HostCommand
    @Serializable @SerialName("set_segment_speaker")
    data class SetSegmentSpeaker(val recordId: String, val segmentId: String, val speaker: String? = null) : HostCommand
    @Serializable @SerialName("rename_speaker")
    data class RenameSpeaker(val recordId: String, val fromSpeaker: String, val toSpeaker: String) : HostCommand

    @Serializable @SerialName("set_ask_scope")
    data class SetAskScope(val scope: String, val recordId: String? = null) : HostCommand
    @Serializable @SerialName("ask")
    data class Ask(val question: String, val scope: String, val recordId: String? = null) : HostCommand
    @Serializable @SerialName("transcribe") data class Transcribe(val recordId: String) : HostCommand
    @Serializable @SerialName("summarize") data class Summarize(val recordId: String) : HostCommand

    @Serializable @SerialName("playback") data class Playback(val isPlaying: Boolean) : HostCommand
    @Serializable @SerialName("select_playback_lane") data class SelectPlaybackLane(val lane: String) : HostCommand
    @Serializable @SerialName("seek") data class Seek(val positionMs: Long) : HostCommand

    @Serializable @SerialName("start_capture_mode")
    data class StartCaptureMode(val mode: CaptureMode, val stayOnPage: Boolean = false) : HostCommand
    @Serializable @SerialName("capture_action")
    data class CaptureActionCommand(val action: CaptureAction, val clockNs: Long? = null) : HostCommand
    @Serializable @SerialName("start_microphone")
    data class StartMicrophone(
        val inputId: String,
        val includeSystem: Boolean = false,
        val clockNs: Long? = null,
    ) : HostCommand
    @Serializable @SerialName("pause_microphone") data object PauseMicrophone : HostCommand
    @Serializable @SerialName("stop_microphone") data object StopMicrophone : HostCommand
    @Serializable @SerialName("cancel_microphone") data object CancelMicrophone : HostCommand
    @Serializable @SerialName("retry_microphone_save") data object RetryMicrophoneSave : HostCommand
    @Serializable @SerialName("select_capture_source") data class SelectCaptureSource(val source: String) : HostCommand
    @Serializable @SerialName("set_capture_system_audio") data class SetCaptureSystemAudio(val enabled: Boolean) : HostCommand

    @Serializable @SerialName("device_open_guide") data object DeviceOpenGuide : HostCommand
    @Serializable @SerialName("device_onboarding_next") data object DeviceOnboardingNext : HostCommand
    @Serializable @SerialName("device_close_guide") data object DeviceCloseGuide : HostCommand
    @Serializable @SerialName("device_refresh") data object DeviceRefresh : HostCommand
    @Serializable @SerialName("device_release") data object DeviceRelease : HostCommand
    @Serializable @SerialName("device_download") data class DeviceDownload(val fileId: Long) : HostCommand
    @Serializable @SerialName("device_download_all") data object DeviceDownloadAll : HostCommand
    @Serializable @SerialName("set_ble_auto_connect") data class SetBleAutoConnect(val enabled: Boolean) : HostCommand

    @Serializable @SerialName("configure_speech")
    data class ConfigureSpeech(val engine: String, val modelId: String? = null) : HostCommand
    @Serializable @SerialName("prepare_speech_model") data class PrepareSpeechModel(val modelId: String) : HostCommand
    @Serializable @SerialName("cancel_speech_model") data object CancelSpeechModel : HostCommand
    @Serializable @SerialName("set_meeting_audio_policy") data class SetMeetingAudioPolicy(val policy: String) : HostCommand
    @Serializable @SerialName("configure_provider")
    data class ConfigureProvider(
        val apiKey: String? = null,
        val deepseekApiKey: String? = null,
        val asrProvider: String? = null,
        val asrModel: String? = null,
        val llmProvider: String? = null,
        val model: String,
        val enableThinking: Boolean? = null,
        val qwenWorkspaceId: String? = null,
        val asrEndpoint: String? = null,
        val chatEndpoint: String? = null,
    ) : HostCommand
    @Serializable @SerialName("retry_provider_credentials")
    data class RetryProviderCredentials(val authorize: Boolean = false) : HostCommand
    @Serializable @SerialName("clear_provider_credential")
    data class ClearProviderCredential(val provider: String? = null) : HostCommand
    @Serializable @SerialName("check_app_update") data object CheckAppUpdate : HostCommand
}
