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
    Settings,
}

#[derive(Deserialize)]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub(crate) enum Command {
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
    PlaybackProgress {
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

#[derive(Clone, Default)]
pub(crate) struct Location {
    pub page: Page,
    pub record: Option<String>,
    pub segment: Option<String>,
}

#[derive(Default)]
pub(crate) struct Playback {
    pub record: Option<String>,
    pub position_ms: u64,
    pub playing: bool,
}
