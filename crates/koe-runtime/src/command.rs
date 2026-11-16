use serde::Deserialize;

#[derive(Clone, Copy, Default, Deserialize, serde::Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Page {
    #[default]
    Today,
    VoiceInput,
    Notes,
    AllDay,
    Capture,
    Records,
    Detail,
    Tasks,
    Memory,
    Ask,
    LiveMinutes,
    Trash,
    Settings,
}

#[derive(Clone, Copy, Deserialize, serde::Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum CaptureMode {
    QuickNote,
    AllDay,
    Meeting,
    Dictation,
}

impl CaptureMode {
    pub(crate) const fn to_record_mode(self) -> koe_engine::product::RecordMode {
        match self {
            Self::QuickNote => koe_engine::product::RecordMode::QuickNote,
            Self::AllDay => koe_engine::product::RecordMode::AllDay,
            Self::Meeting => koe_engine::product::RecordMode::Meeting,
            Self::Dictation => koe_engine::product::RecordMode::Dictation,
        }
    }
}

const fn default_true() -> bool {
    true
}

#[derive(Clone, Copy, Deserialize, serde::Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum CaptureAction {
    Pause,
    Resume,
    End,
    EndDictation,
    RetrySave,
    RetryStop,
    Cancel,
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct CaptureTiming {
    pub epoch: u64,
    pub captured_start_ns: u64,
}

#[derive(Deserialize)]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub(crate) enum Command {
    PrepareVoiceInput,
    SetVoiceInputSession {
        enabled: bool,
    },
    StartCaptureMode {
        mode: CaptureMode,
        #[serde(default)]
        stay_on_page: bool,
    },
    CaptureAction {
        action: CaptureAction,
        #[serde(default)]
        clock_ns: Option<u64>,
    },
    ConfigureSpeech {
        engine: String,
        #[serde(default)]
        model_id: Option<String>,
    },
    PrepareSpeechModel {
        model_id: String,
    },
    CancelSpeechModel,
    StartAllDay {
        source: String,
        #[serde(default)]
        input_id: Option<String>,
    },
    StopAllDay,
    SetDictationActive {
        active: bool,
    },
    LocalAsrReadiness {
        state: crate::local_asr::Readiness,
        message: String,
    },
    LocalAsrResult {
        operation_id: u64,
        text: String,
        start_ms: u64,
        end_ms: u64,
        is_final: bool,
    },
    LocalAsrFinished {
        operation_id: u64,
    },
    LocalAsrFailed {
        operation_id: u64,
        message: String,
    },
    StartMicrophone {
        input_id: String,
        #[serde(default)]
        include_system: bool,
        #[serde(default)]
        clock_ns: Option<u64>,
    },
    SyncAudioInputs {
        inputs: Vec<crate::capture_studio::AudioInputDescriptor>,
    },
    SelectCaptureSource {
        source: String,
    },
    SetCaptureSystemAudio {
        enabled: bool,
    },
    PauseMicrophone,
    MicrophonePrepared {
        record_id: String,
        session_id: String,
        epoch: u64,
        clock_ns: u64,
    },
    ResumeMicrophone {
        clock_ns: u64,
    },
    MicrophonePaused {
        record_id: String,
        session_id: String,
        lane: String,
        sequence: u64,
        epoch: u64,
    },
    StopMicrophone,
    CancelMicrophone,
    RetryMicrophoneSave,
    MicrophoneStarted {
        record_id: String,
        session_id: String,
        lane: String,
        sample_rate: u32,
    },
    MicrophoneChunk {
        record_id: String,
        session_id: String,
        lane: String,
        sequence: u64,
        samples: Vec<i16>,
        #[serde(default)]
        timing: Option<CaptureTiming>,
    },
    MicrophoneStopped {
        record_id: String,
        session_id: String,
        lane: String,
        sequence: u64,
        #[serde(default)]
        epoch: Option<u64>,
    },
    MicrophoneFailed {
        record_id: String,
        session_id: String,
        lane: String,
        message: String,
        #[serde(default)]
        epoch: Option<u64>,
    },
    RequestQuit,
    CancelQuit,
    Navigate {
        section: Page,
    },
    Back,
    SelectRecord {
        record_id: String,
    },
    OpenSource {
        record_id: String,
        segment_id: String,
    },
    ImportFile {
        path: String,
    },
    CreateNote {
        title: String,
        text: String,
        #[serde(default)]
        stay_on_page: bool,
    },
    RenameRecord {
        record_id: String,
        title: String,
    },
    SetRecordProject {
        record_id: String,
        #[serde(default)]
        project: Option<String>,
    },
    SelectQuickNoteRecord {
        #[serde(default)]
        record_id: Option<String>,
    },
    SelectAllDayDate {
        date: String,
    },
    SelectLiveMinutesRecord {
        #[serde(default)]
        record_id: Option<String>,
    },
    SetRecordArchived {
        record_id: String,
        archived: bool,
    },
    TrashRecord {
        record_id: String,
    },
    RestoreRecord {
        record_id: String,
    },
    PurgeRecord {
        record_id: String,
    },
    EmptyTrash,
    DismissUndoTrash,
    ExportRecord {
        record_id: String,
        path: String,
    },
    ExportWorkspaceMarkdown {
        #[serde(default)]
        record_id: Option<String>,
        #[serde(default)]
        date: Option<String>,
        path: String,
        #[serde(default = "default_true")]
        include_analysis: bool,
        #[serde(default = "default_true")]
        include_sources: bool,
    },
    ReviewItem {
        item_id: String,
        decision: String,
    },
    CompleteTask {
        item_id: String,
        completed: bool,
    },
    EditItem {
        item_id: String,
        text: String,
        due: Option<String>,
    },
    SaveMemory {
        record_id: String,
        segment_id: String,
    },
    CreateTask {
        record_id: String,
        segment_id: String,
    },
    AddHighlight {
        record_id: String,
        segment_id: String,
    },
    EditSegmentText {
        record_id: String,
        segment_id: String,
        text: String,
    },
    SetSegmentSpeaker {
        record_id: String,
        segment_id: String,
        #[serde(default)]
        speaker: Option<String>,
    },
    RenameSpeaker {
        record_id: String,
        from_speaker: String,
        to_speaker: String,
    },
    Ask {
        question: String,
        scope: String,
        record_id: Option<String>,
    },
    SetAskScope {
        scope: String,
        record_id: Option<String>,
    },
    Transcribe {
        record_id: String,
    },
    SetMeetingAudioPolicy {
        policy: String,
    },
    Summarize {
        record_id: String,
    },
    ConfigureProvider {
        #[serde(default)]
        api_key: Option<String>,
        model: String,
        #[serde(default)]
        asr_endpoint: Option<String>,
        #[serde(default)]
        chat_endpoint: Option<String>,
    },
    ClearProviderCredential,
    RetryProviderCredentials {
        #[serde(default)]
        authorize: bool,
    },
    ClearError,
    Seek {
        position_ms: u64,
    },
    Playback {
        is_playing: bool,
    },
    SelectPlaybackLane {
        lane: String,
    },
    PlaybackProgress {
        record_id: String,
        request_id: u64,
        position_ms: u64,
        is_playing: bool,
    },
    DeviceEvent {
        event: String,
        connection_id: String,
        #[serde(default)]
        device_name: Option<String>,
    },
    DeviceOpenGuide,
    DeviceOnboardingNext,
    DeviceCloseGuide,
    DeviceRefresh,
    DeviceDisconnect,
    DeviceRelease,
    SetBleAutoConnect {
        enabled: bool,
    },
    SetCompanionMode {
        mode: String,
    },
    DeviceDownload {
        file_id: u32,
    },
    DeviceStart,
    DeviceStop,
}

#[derive(Clone, Default, PartialEq, Eq)]
pub(crate) struct Location {
    pub page: Page,
    pub record: Option<String>,
    pub segment: Option<String>,
}

#[derive(Default)]
pub(crate) struct Playback {
    pub record: Option<String>,
    pub lane: Option<String>,
    pub request_id: u64,
    pub position_ms: u64,
    pub playing: bool,
}
