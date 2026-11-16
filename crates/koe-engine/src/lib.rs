//! Pure deterministic Rust domain and protocol engine for Koe audio recording,
//! BLE protocol framing, cryptographic stream decryption, Ogg Opus container muxing,
//! WAV framing, `UtteranceSpine (S1..Sn)`, anti-hallucination minutes grounding,
//! and Chinese bigram + Latin stem BM25 retrieval.
//!
//! Zero file I/O, zero network, and zero UI framework dependencies.
//! Every module in this crate is compiled under `#![forbid(unsafe_code)]`.
//!
//! # Examples
//!
//! ```
//! use koe_engine::frame::ProtocolFrame;
//! use koe_engine::ogg_opus::OggOpus;
//! use koe_engine::wav::OpusWave;
//!
//! let pkt = ProtocolFrame::encode(0x01, 0x01, &[]);
//! assert!(ProtocolFrame::verify_checksum(&pkt));
//!
//! let wav = OpusWave::wav_header(1920);
//! assert!(OggOpus::is_wav(&wav));
//! ```

#![forbid(unsafe_code)]
#![deny(missing_docs)]

pub use koe_client_base::hash;
pub use koe_client_base::prng;

pub mod commands;
pub mod context;
pub mod crypto;
pub mod domain;
pub mod frame;
pub mod koepack;
pub mod minutes;
pub mod models;
pub mod ogg_opus;
pub mod product;
pub mod session;
pub mod slice_marks;
pub mod transport;
pub mod wav;

pub use koepack::{
    decode_koepack, MaterialPack, MaterialPackError, PackMaterialMeta, PackMinutes,
    PortableMinutesEntry, KOEPACK_FORMAT_NAME, KOEPACK_MAGIC, KOEPACK_MAX_MANIFEST_BYTES,
    KOEPACK_MAX_MINUTES_HISTORY,
};
pub use context::{
    cited_labels, is_delegation_request, is_followup_question, rank_texts, relabel_citations,
    render_source_lines, AskMessage, AskPromptPlan, AskRole, AskScope, AskSession, AskStatus,
    AskStepOutcome, ContextSearchIndex, ScoringMode, SearchHit, SourceLine, SourcePointer,
    ASK_MAX_CORPUS_CHARS, ASK_SYSTEM_PROMPT, ASK_TOP_K_LIMIT, DELEGATION_CLOSED_NOTICE,
};
pub use domain::{
    MeetingMinutes, MinuteCause, MinuteCustomSection, MinuteFishbone, MinutePoint, MinuteTerm,
    MinuteTermAdoption, MinuteTopic, RecordingAggregate, SegmentId, UtteranceSegment,
    UtteranceSpine,
};
pub use hash::{is_valid_sha256_hex, sha256_hex};
pub use minutes::{
    parse_persisted_meeting_minutes_json, validate_minutes_citations, validate_minutes_grounding,
    MinutesValidationError,
};
pub use product::RecordMode;
pub use session::{CustodyReceipt, RecordingEntry};
