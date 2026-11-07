//! Safe Rust core kernel for Koe audio recording, BLE protocol framing,
//! cryptographic stream decryption, Ogg Opus container muxing, and WAV framing.
//!
//! Every module in this crate is compiled under `#![forbid(unsafe_code)]` and
//! verified for byte-for-byte differential parity against the legacy Dart
//! reference implementation across deterministic `SplitMix64` seeds.
//!
//! # Examples
//!
//! ```
//! use koe_core::frame::ProtocolFrame;
//! use koe_core::ogg_opus::OggOpus;
//! use koe_core::wav::OpusWave;
//!
//! let pkt = ProtocolFrame::encode(0x01, 0x01, &[]);
//! assert!(ProtocolFrame::verify_checksum(&pkt));
//!
//! let wav = OpusWave::wav_header(1920);
//! assert!(OggOpus::is_wav(&wav));
//! ```

#![forbid(unsafe_code)]
#![deny(missing_docs)]

pub mod cicada;
pub mod commands;
pub mod context;
pub mod crypto;
pub mod domain;
pub mod frame;
pub mod hash;
pub mod library;
pub mod mcp_acp;
pub mod minutes;
pub mod models;
pub mod ogg_opus;
pub mod prng;
pub mod session;
pub mod slice_marks;
pub mod transport;
pub mod wav;
pub mod wifi;

pub use cicada::{
    analysis_source_blocks, build_translation_instruction, decode_koepack_v2, encode_koepack_v2,
    format_caption_journal_key, live_minute_citations, merge_minutes_history,
    pending_translation_segments, translation_system_prompt, validate_live_minutes_json,
    CaptionJournalStatus, CaptionTranslationTicket, CicadaEvent, CicadaOutcome, CicadaReducer,
    CicadaState, LiveCaptionsQueue, MaterialPackError, MaterialPackV2, MinutesHistoryMergeOutcome,
    PackMaterialMeta, PackMinutesV2, PortableMinutesEntry, RollingMinutesScheduler,
    RollingMinutesTicket, RollingRequestStatus, RollingTickDecision, CICADA_HOUR_WINDOW_MS,
    CICADA_MAX_CALLS_PER_HOUR, CICADA_MAX_SINGLE_WINDOW_CHARS, CICADA_MAX_TOTAL_SOURCE_CHARS,
    CICADA_MAX_WAITING_CAPTIONS, CICADA_ROLLING_CHAR_THRESHOLD, CICADA_ROLLING_INTERVAL_SEC,
    CICADA_SILENCE_AUTO_STOP_MS, CICADA_SOURCE_BLOCK_MAX_RUNES, CICADA_TRANSLATION_SYSTEM_PROMPT,
    KOEPACK_FORMAT_NAME, KOEPACK_MAGIC, KOEPACK_MAX_MANIFEST_BYTES, KOEPACK_MAX_MINUTES_HISTORY,
};
pub use hash::{is_valid_sha256_hex, sha256_hex};
pub use context::{
    filter_open_mine_todos, sort_context_timeline, ContextEvent, ContextOutcome, ContextReducer,
    ContextState,
};
pub use domain::{
    AiProviderCommand, ContextItem, ContextKind, ContextSource, MeetingMinutesV2, MinuteCause,
    MinuteCustomSection, MinuteFishbone, MinutePoint, MinuteTerm, MinuteTermAdoption, MinuteTopic,
    SegmentId, TodoItem, TodoKind, TodoStatus, UtteranceSegment, UtteranceSpine,
};
pub use mcp_acp::{
    is_supported_mcp_tool, McpAcpEvent, McpAcpOutcome, McpAcpReducer, McpAcpState, KOE_MCP_TOOLS,
};
pub use minutes::{
    contains_calculation_phrase, contains_percentage, validate_calculation_grounding,
    validate_minutes_grounding, MinutesEvent, MinutesOutcome, MinutesReducer, MinutesState,
    MinutesValidationError,
};
pub use wifi::{
    normalize_wifi_chunk, WifiBatchPhase, WifiBatchProgress, WifiEndpoint, WIFI_DEFAULT_WS_PORT,
    WIFI_KEEPALIVE_INTERVAL_MS, WIFI_KEEPALIVE_PAYLOAD, WIFI_UDP_PORT, WIFI_WS_FINISH_TEXT,
};
