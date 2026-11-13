//! Downloadable speech models and in-process, 16 kHz mono PCM16 transcription.

mod artifacts;
mod worker;
pub use worker::OfflineSpeechWorker;

/// A pinned, downloadable speech model.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OfflineSpeechModel {
    /// Stable identifier persisted by the runtime.
    pub id: &'static str,
    /// User-facing model name.
    pub name: &'static str,
    /// Exact artifact length in bytes.
    pub size_bytes: u64,
    /// Supported ISO language codes.
    pub languages: &'static [&'static str],
}

/// Models offered by the embedded speech engine.
#[must_use]
pub fn offline_speech_models() -> &'static [OfflineSpeechModel] {
    &[
        OfflineSpeechModel {
            id: "sensevoice-small",
            name: "SenseVoice Small",
            size_bytes: 252_684_608,
            languages: &["zh", "yue", "en", "ja", "ko"],
        },
        OfflineSpeechModel {
            id: "qwen3-asr-0.6b",
            name: "Qwen3 ASR 0.6B",
            size_bytes: 850_423_456,
            languages: &[
                "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th",
                "vi", "ja", "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa",
                "el", "ro", "hu", "mk",
            ],
        },
    ]
}

/// Text with model-provided timing relative to the submitted audio.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OfflineSpeechSegment {
    /// Inclusive start offset in milliseconds.
    pub start_ms: u64,
    /// End offset in milliseconds.
    pub end_ms: u64,
    /// Recognized text.
    pub text: String,
}

/// Progress and terminal results returned by the offline speech worker.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OfflineSpeechEvent {
    /// Download progress, followed by loading and a terminal preparation result.
    Preparing {
        /// Requested model identifier.
        model_id: String,
        /// Bytes downloaded or verified in the existing artifact.
        downloaded_bytes: u64,
        /// Expected artifact length.
        total_bytes: u64,
    },
    /// The artifact was verified and an inference session is loaded.
    Ready {
        /// Loaded model identifier.
        model_id: String,
    },
    /// Download, verification, loading, or cancellation failed.
    PreparationFailed {
        /// Requested model identifier.
        model_id: String,
        /// Actionable failure description.
        error: String,
    },
    /// Recognition completed for the submitted operation.
    Transcribed {
        /// Caller-owned operation identity.
        operation_id: u64,
        /// Recognized text.
        text: String,
        /// Model-provided timing segments.
        segments: Vec<OfflineSpeechSegment>,
    },
    /// Recognition could not complete.
    TranscriptionFailed {
        /// Caller-owned operation identity.
        operation_id: u64,
        /// Actionable failure description.
        error: String,
    },
}
