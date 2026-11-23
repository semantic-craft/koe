//! Provider transport contracts, offline speech worker, and streaming provider workers for Koe.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

pub mod offline_speech;
pub use offline_speech::{
    offline_speech_models, OfflineSpeechEvent, OfflineSpeechModel, OfflineSpeechSegment,
    OfflineSpeechWorker,
};

mod http_client;
mod network;
pub use network::{
    parse_release_payload, validate_remote_http_url, validate_update_endpoint, AsrTransportMode,
    LiveEvent, LiveTranscription, ProviderConfig, ProviderEvent, ProviderLane, ProviderOutput,
    ProviderPool, ProviderRequest, ProviderTask, ReleaseAsset, RemoteRelease, ThinkingMode,
    TranscriptSegment, UpdateCheckOutcome, DASHSCOPE_ASR_ENDPOINT, DASHSCOPE_ASR_MODEL,
    DEEPSEEK_CHAT_ENDPOINT, DEEPSEEK_CHAT_MODEL,
};
