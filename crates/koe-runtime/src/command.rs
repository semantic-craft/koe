use serde::Deserialize;

#[derive(Clone, Copy, Default, Deserialize, serde::Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Page {
    #[default]
    Today,
    Records,
    Detail,
    Tasks,
    Memory,
    Ask,
    Trash,
    Settings,
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
    StartMicrophone {
        input_id: String,
        #[serde(default)]
        include_system: bool,
        #[serde(default)]
        clock_ns: Option<u64>,
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
    ImportFlutterLibrary {
        path: String,
    },
    ImportFile {
        path: String,
    },
    CreateNote {
        title: String,
        text: String,
    },
    RenameRecord {
        record_id: String,
        title: String,
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
