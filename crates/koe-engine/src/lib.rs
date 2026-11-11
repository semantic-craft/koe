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

pub mod cicada;
pub mod commands;
pub mod context;
pub mod crypto;
pub mod domain;
pub mod frame;
pub mod library;
pub mod memory_hub;
pub mod minutes;
pub mod models;
pub mod ogg_opus;
pub mod product;
pub mod session;
pub mod slice_marks;
pub mod transport;
pub mod wav;
pub mod wifi;

pub use cicada::{
    analysis_source_blocks, build_translation_instruction, clamp_summary_on_punctuation,
    decode_koepack, encode_koepack, enforce_rolling_topic_budget, format_caption_journal_key,
    live_minute_citations, merge_minutes_history, pending_translation_segments,
    refine_spine_in_place, translation_system_prompt, validate_live_minutes_json,
    CaptionJournalStatus, CaptionTranslationTicket, CicadaEvent, CicadaOutcome, CicadaReducer,
    CicadaState, LiveCaptionsQueue, MaterialPack, MaterialPackError, MinutesHistoryMergeOutcome,
    PackMaterialMeta, PackMinutes, PortableMinutesEntry, RollingMinutesScheduler,
    RollingMinutesTicket, RollingRequestStatus, RollingTickDecision, CICADA_EDITABLE_TOPICS,
    CICADA_HOUR_WINDOW_MS, CICADA_LIVE_MAX_TOPICS, CICADA_MAX_CALLS_PER_HOUR,
    CICADA_MAX_SINGLE_WINDOW_CHARS, CICADA_MAX_TOTAL_SOURCE_CHARS, CICADA_MAX_WAITING_CAPTIONS,
    CICADA_ROLLING_CHAR_THRESHOLD, CICADA_ROLLING_INTERVAL_SEC, CICADA_SILENCE_AUTO_STOP_MS,
    CICADA_SOURCE_BLOCK_MAX_RUNES, CICADA_TOPIC_SUMMARY_CHAR_LIMIT,
    CICADA_TRANSLATION_SYSTEM_PROMPT, KOEPACK_FORMAT_NAME, KOEPACK_MAGIC,
    KOEPACK_MAX_MANIFEST_BYTES, KOEPACK_MAX_MINUTES_HISTORY,
};
pub use context::{
    apply_place_update, apply_sweep_line_diarization, attribute_speaker_turns_sweep_line,
    build_morning_brief, cited_labels, commitment_instruction, commitment_source,
    compare_timeline_entries, compute_project_progress, delete_project_and_unlink,
    evaluate_diary_export, export_context_markdown, filter_open_mine_todos, format_coarse_place,
    is_delegation_request, is_followup_question, names_todo, pack_context_source_lines,
    parse_commitment_response, parse_due_str, query_terms, rank_texts, reconcile_system_todo_sync,
    relabel_citations, render_source_lines, select_focus_project, sort_context_timeline,
    sort_todos, stem_latin_token, sync_derived_context_items, AskMessage, AskPromptPlan, AskRole,
    AskScope, AskSession, AskStatus, AskStepOutcome, CommitmentChanges, ContextEvent,
    ContextOutcome, ContextReducer, ContextSearchIndex, ContextState, DiaryDraft, DiaryEntry,
    DiaryError, DiaryExportDecision, DiaryGenerationBlocked, DiaryPeriod, MorningBrief,
    PlaceCaptureSource, Project, ProjectProgress, ProjectStatus, RecordingOrigin,
    RecordingPlaceTag, ScoringMode, SearchHit, SourceLine, SourcePointer, SpeakerAttributionResult,
    SpeakerDiarizationInterval, SystemSyncOutcome, SystemTaskSnapshot, SystemTodoLink,
    TimelineEntry, TodoClarification, TodoUpdateAction, ASK_MAX_CORPUS_CHARS, ASK_SYSTEM_PROMPT,
    ASK_TOP_K_LIMIT, COMMITMENT_SYSTEM_PROMPT, DELEGATION_CLOSED_NOTICE, DIARY_SYSTEM_PROMPT,
    RANK_BACKGROUND_THRESHOLD_CHARS, STOP_PAIRS,
};
pub use domain::{
    AiProviderCommand, ContextItem, ContextKind, ContextSource, EditorialCardRole, KoePackSummary,
    MeetingMinutes, MinuteCause, MinuteCustomSection, MinuteFishbone, MinutePoint, MinuteTerm,
    MinuteTermAdoption, MinuteTopic, RecordingAggregate, RecordingLifecyclePhase, SegmentId,
    SummaryFormat, TodoItem, TodoKind, TodoStatus, UtteranceSegment, UtteranceSpine,
    VisualSummaryCard,
};
pub use hash::{is_valid_sha256_hex, sha256_hex};
pub use memory_hub::{
    build_twenty_one_day_calendar_table, civil_to_days, days_to_civil, detect_todo_done_hints,
    extract_things_from_spine, resolve_relative_date_zh, validate_and_heal_ask_citations,
    AskChangeProposal, AudioDeviceKind, AudioTimelineEntry, CalendarDayRow, DoneHint,
    GoogleDriveBackupStatus, HotTimelineStore, PipeSkillSpec, ReviewCardItem, ScreenFrameContext,
    SpeakerVoiceProfile, ThingAction, ThingRecord, TimeSeriesFrame, VoiceprintBank,
    AUDIO_FRAME_PAD_MS, MAX_VOICEPRINT_SAMPLES_PER_PERSON, SUBTITLE_WINDOW_MS,
    VOICEPRINT_CONFIRM_THRESHOLD, VOICEPRINT_SUGGEST_THRESHOLD,
};
pub use minutes::{
    contains_calculation_phrase, contains_percentage, parse_persisted_meeting_minutes_json,
    validate_calculation_grounding, validate_minutes_citations, validate_minutes_grounding,
    MinutesEvent, MinutesOutcome, MinutesReducer, MinutesState, MinutesValidationError,
};
pub use product::CompanionRoutingMode;
pub use session::{CustodyReceipt, RawCompanionSignal};
pub use wifi::{
    normalize_wifi_chunk, WifiBatchPhase, WifiBatchProgress, WifiEndpoint, WIFI_DEFAULT_WS_PORT,
    WIFI_KEEPALIVE_INTERVAL_MS, WIFI_KEEPALIVE_PAYLOAD, WIFI_UDP_PORT, WIFI_WS_FINISH_TEXT,
};
