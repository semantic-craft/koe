//! Durable serial analysis job queue (`NativeAnalysisQueue`) and resumable 20-second
//! transcription window checkpoint store, modeled after `olgvroe/Vecta`
//! (`App/NativeAnalysisQueue.swift` and `AI/Worker/WholeRecording.swift`).

use std::io;
use std::path::Path;

use koe_client_base::atomic_fs::{read_checked_string, write_atomic};
use koe_engine::domain::SummaryFormat;
use koe_engine::minutes::JsonValue;

/// Maximum number of durable jobs retained in [`NativeAnalysisQueue`] (`5,000`, matching Vecta).
pub const MAX_ANALYSIS_QUEUE_JOBS: usize = 5_000;

/// Default transcription checkpoint window duration in milliseconds (`20,000` ms = 20 s).
pub const CHECKPOINT_WINDOW_DURATION_MS: u64 = 20_000;

/// Default overlap between adjacent transcription windows in milliseconds (`2,000` ms = 2 s).
pub const CHECKPOINT_WINDOW_OVERLAP_MS: u64 = 2_000;

/// Lifecycle phase of a durable analysis job in [`NativeAnalysisQueue`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnalysisJobPhase {
    /// Waiting in the serial queue for admission.
    Queued,
    /// Executing windowed ASR transcription and speaker attribution.
    Transcribing,
    /// Executing grounded LLM summarization and 6-card visual editorial extraction.
    Summarizing,
    /// Successfully completed and persisted to the workspace.
    Completed,
    /// Terminated with a recoverable or terminal error.
    Failed,
}

impl AnalysisJobPhase {
    /// Returns the wire string representation of this job phase.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Transcribing => "transcribing",
            Self::Summarizing => "summarizing",
            Self::Completed => "completed",
            Self::Failed => "failed",
        }
    }

    /// Parses a wire string into an [`AnalysisJobPhase`].
    #[must_use]
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim() {
            "queued" => Some(Self::Queued),
            "transcribing" => Some(Self::Transcribing),
            "summarizing" => Some(Self::Summarizing),
            "completed" => Some(Self::Completed),
            "failed" => Some(Self::Failed),
            _ => None,
        }
    }
}

/// Frozen snapshot of the user's summary recipe at the moment a recording is enqueued,
/// matching Vecta's `RecipeSnapshot` so mid-flight template edits do not corrupt active jobs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AnalysisRecipeSnapshot {
    /// Selected summary format (`MeetingBrief`, `ActionItems`, etc.).
    pub summary_format: SummaryFormat,
    /// Active built-in template identifier (`"general"`, `"retro"`, `"1on1"`, `"interview"`).
    pub template_id: String,
    /// Frozen custom section headings at enqueue time.
    pub custom_headings: Vec<String>,
    /// Whether 6-card visual editorial generation is requested.
    pub wants_visual_cards: bool,
}

impl Default for AnalysisRecipeSnapshot {
    fn default() -> Self {
        Self {
            summary_format: SummaryFormat::DecisionMemo,
            template_id: "general".to_string(),
            custom_headings: Vec::new(),
            wants_visual_cards: true,
        }
    }
}

/// Resumable 20-second transcription window checkpoint persisted per recording,
/// allowing interrupted ASR runs to resume from `completed_windows` without re-transcribing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranscriptWindowCheckpoint {
    /// Recording identifier (`id`).
    pub recording_id: u32,
    /// Number of 20-second windows already transcribed and committed.
    pub completed_windows: u32,
    /// Total planned 20-second windows for the recording.
    pub total_windows: u32,
    /// Last committed audio offset in milliseconds.
    pub resume_from_ms: u64,
    /// Recognized segment count committed up to `resume_from_ms`.
    pub committed_segments: usize,
}

/// A single durable recording analysis job managed by [`NativeAnalysisQueue`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AnalysisJob {
    /// Recording identifier (`id`).
    pub recording_id: u32,
    /// Unix epoch timestamp (seconds) when the job was enqueued.
    pub enqueued_at_epoch_sec: u64,
    /// Current execution phase.
    pub phase: AnalysisJobPhase,
    /// Frozen summary recipe snapshot captured at enqueue time.
    pub recipe: AnalysisRecipeSnapshot,
    /// Resumable transcription checkpoint state.
    pub checkpoint: TranscriptWindowCheckpoint,
    /// Optional failure reason if `phase == AnalysisJobPhase::Failed`.
    pub last_error: Option<String>,
}

/// Durable serial analysis job queue persisted atomically in `analysis-queue.json`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NativeAnalysisQueue {
    jobs: Vec<AnalysisJob>,
}

impl NativeAnalysisQueue {
    /// Creates an empty [`NativeAnalysisQueue`].
    #[must_use]
    pub const fn new() -> Self {
        Self { jobs: Vec::new() }
    }

    /// Returns all jobs in queue order.
    #[must_use]
    pub fn jobs(&self) -> &[AnalysisJob] {
        &self.jobs
    }

    /// Returns the number of unfinished (`Queued`, `Transcribing`, or `Summarizing`) jobs.
    #[must_use]
    pub fn pending_count(&self) -> usize {
        self.jobs
            .iter()
            .filter(|j| {
                matches!(
                    j.phase,
                    AnalysisJobPhase::Queued
                        | AnalysisJobPhase::Transcribing
                        | AnalysisJobPhase::Summarizing
                )
            })
            .count()
    }

    /// Enqueues or updates an [`AnalysisJob`] for `recording_id` with `duration_ms` and `recipe`.
    /// If an incomplete job for `recording_id` already exists, its checkpoint is preserved.
    pub fn enqueue(
        &mut self,
        recording_id: u32,
        duration_ms: u64,
        enqueued_at_epoch_sec: u64,
        recipe: AnalysisRecipeSnapshot,
    ) -> &AnalysisJob {
        let step_ms = CHECKPOINT_WINDOW_DURATION_MS.saturating_sub(CHECKPOINT_WINDOW_OVERLAP_MS);
        let total_windows = if duration_ms == 0 {
            1
        } else {
            ((duration_ms.saturating_add(step_ms - 1)) / step_ms).max(1) as u32
        };

        if let Some(idx) = self
            .jobs
            .iter()
            .position(|j| j.recording_id == recording_id)
        {
            let existing = &mut self.jobs[idx];
            existing.recipe = recipe;
            existing.checkpoint.total_windows = total_windows;
            if existing.phase == AnalysisJobPhase::Failed {
                existing.phase = AnalysisJobPhase::Queued;
                existing.last_error = None;
            }
            return &self.jobs[idx];
        }

        if self.jobs.len() >= MAX_ANALYSIS_QUEUE_JOBS {
            if let Some(completed_pos) = self
                .jobs
                .iter()
                .position(|j| j.phase == AnalysisJobPhase::Completed)
            {
                self.jobs.remove(completed_pos);
            } else {
                self.jobs.remove(0);
            }
        }

        self.jobs.push(AnalysisJob {
            recording_id,
            enqueued_at_epoch_sec,
            phase: AnalysisJobPhase::Queued,
            recipe,
            checkpoint: TranscriptWindowCheckpoint {
                recording_id,
                completed_windows: 0,
                total_windows,
                resume_from_ms: 0,
                committed_segments: 0,
            },
            last_error: None,
        });
        self.jobs.last().expect("just pushed job")
    }

    /// Advances the transcription window checkpoint for `recording_id`, enabling crash-resumable ASR.
    pub fn record_window_checkpoint(
        &mut self,
        recording_id: u32,
        completed_windows: u32,
        resume_from_ms: u64,
        committed_segments: usize,
    ) -> bool {
        let Some(job) = self
            .jobs
            .iter_mut()
            .find(|j| j.recording_id == recording_id)
        else {
            return false;
        };
        job.phase = AnalysisJobPhase::Transcribing;
        job.checkpoint.completed_windows = completed_windows.min(job.checkpoint.total_windows);
        job.checkpoint.resume_from_ms = resume_from_ms;
        job.checkpoint.committed_segments = committed_segments;
        true
    }

    /// Transitions `recording_id` to [`AnalysisJobPhase::Summarizing`].
    pub fn mark_summarizing(&mut self, recording_id: u32) -> bool {
        let Some(job) = self
            .jobs
            .iter_mut()
            .find(|j| j.recording_id == recording_id)
        else {
            return false;
        };
        job.phase = AnalysisJobPhase::Summarizing;
        job.checkpoint.completed_windows = job.checkpoint.total_windows;
        true
    }

    /// Marks `recording_id` as [`AnalysisJobPhase::Completed`].
    pub fn mark_completed(&mut self, recording_id: u32, committed_segments: usize) -> bool {
        let Some(job) = self
            .jobs
            .iter_mut()
            .find(|j| j.recording_id == recording_id)
        else {
            return false;
        };
        job.phase = AnalysisJobPhase::Completed;
        job.checkpoint.completed_windows = job.checkpoint.total_windows;
        job.checkpoint.committed_segments = committed_segments;
        job.last_error = None;
        true
    }

    /// Look up a job by `recording_id`.
    #[must_use]
    pub fn job(&self, recording_id: u32) -> Option<&AnalysisJob> {
        self.jobs.iter().find(|j| j.recording_id == recording_id)
    }

    /// Removes `recording_id` from the queue (e.g. when moved to trash).
    pub fn remove(&mut self, recording_id: u32) -> bool {
        let before = self.jobs.len();
        self.jobs.retain(|j| j.recording_id != recording_id);
        self.jobs.len() != before
    }

    /// Encodes the queue to a deterministic JSON document.
    #[must_use]
    pub fn to_json(&self) -> String {
        let mut out = String::from("{\"jobs\":[");
        for (idx, job) in self.jobs.iter().enumerate() {
            if idx > 0 {
                out.push(',');
            }
            out.push_str(&format!(
                "{{\"recording_id\":{},\"enqueued_at_epoch_sec\":{},\"phase\":\"{}\",\"summary_format\":\"{}\",\"template_id\":\"{}\",\"wants_visual_cards\":{},\"completed_windows\":{},\"total_windows\":{},\"resume_from_ms\":{},\"committed_segments\":{}}}",
                job.recording_id,
                job.enqueued_at_epoch_sec,
                job.phase.as_str(),
                job.recipe.summary_format.as_str(),
                escape_json(&job.recipe.template_id),
                job.recipe.wants_visual_cards,
                job.checkpoint.completed_windows,
                job.checkpoint.total_windows,
                job.checkpoint.resume_from_ms,
                job.checkpoint.committed_segments
            ));
        }
        out.push_str("]}");
        out
    }

    /// Decodes a [`NativeAnalysisQueue`] from a JSON document, resetting any mid-flight
    /// `Transcribing` or `Summarizing` jobs back to `Queued` while keeping their window checkpoints intact.
    pub fn from_json(raw: &str) -> Result<Self, String> {
        let root_val = JsonValue::parse(raw)?;
        let root = root_val
            .as_object()
            .ok_or_else(|| "expected JSON object".to_string())?;
        let Some(items) = root.get("jobs").and_then(JsonValue::as_array) else {
            return Err("missing jobs array".to_string());
        };
        let mut jobs = Vec::with_capacity(items.len().min(MAX_ANALYSIS_QUEUE_JOBS));
        for item in items.iter().take(MAX_ANALYSIS_QUEUE_JOBS) {
            let Some(obj) = item.as_object() else {
                continue;
            };
            let recording_id = obj
                .get("recording_id")
                .and_then(JsonValue::as_i64)
                .unwrap_or(0)
                .max(0) as u32;
            if recording_id == 0 {
                continue;
            }
            let enqueued_at_epoch_sec = obj
                .get("enqueued_at_epoch_sec")
                .and_then(JsonValue::as_i64)
                .unwrap_or(0)
                .max(0) as u64;
            let raw_phase = obj
                .get("phase")
                .and_then(JsonValue::as_str)
                .and_then(AnalysisJobPhase::parse)
                .unwrap_or(AnalysisJobPhase::Queued);
            let phase = match raw_phase {
                AnalysisJobPhase::Transcribing | AnalysisJobPhase::Summarizing => {
                    AnalysisJobPhase::Queued
                }
                other => other,
            };
            let summary_format = obj
                .get("summary_format")
                .and_then(JsonValue::as_str)
                .and_then(SummaryFormat::parse)
                .unwrap_or(SummaryFormat::DecisionMemo);
            let template_id = obj
                .get("template_id")
                .and_then(JsonValue::as_str)
                .unwrap_or("general")
                .to_string();
            let wants_visual_cards = obj
                .get("wants_visual_cards")
                .and_then(JsonValue::as_bool)
                .unwrap_or(true);
            let completed_windows = obj
                .get("completed_windows")
                .and_then(JsonValue::as_i64)
                .unwrap_or(0)
                .max(0) as u32;
            let total_windows = obj
                .get("total_windows")
                .and_then(JsonValue::as_i64)
                .unwrap_or(1)
                .max(1) as u32;
            let resume_from_ms = obj
                .get("resume_from_ms")
                .and_then(JsonValue::as_i64)
                .unwrap_or(0)
                .max(0) as u64;
            let committed_segments = obj
                .get("committed_segments")
                .and_then(JsonValue::as_i64)
                .unwrap_or(0)
                .max(0) as usize;
            jobs.push(AnalysisJob {
                recording_id,
                enqueued_at_epoch_sec,
                phase,
                recipe: AnalysisRecipeSnapshot {
                    summary_format,
                    template_id,
                    custom_headings: Vec::new(),
                    wants_visual_cards,
                },
                checkpoint: TranscriptWindowCheckpoint {
                    recording_id,
                    completed_windows: completed_windows.min(total_windows),
                    total_windows,
                    resume_from_ms,
                    committed_segments,
                },
                last_error: None,
            });
        }
        Ok(Self { jobs })
    }

    /// Atomically saves the queue to `<workspace_dir>/analysis-queue.json`.
    pub fn save_to_dir(&self, workspace_dir: &Path) -> io::Result<()> {
        let path = workspace_dir.join("analysis-queue.json");
        write_atomic(&path, self.to_json().as_bytes())
    }

    /// Loads the queue from `<workspace_dir>/analysis-queue.json` if present.
    pub fn load_from_dir(workspace_dir: &Path) -> io::Result<Self> {
        let path = workspace_dir.join("analysis-queue.json");
        if !path.exists() {
            return Ok(Self::new());
        }
        let raw = read_checked_string(&path)?;
        Self::from_json(&raw).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    }
}

fn escape_json(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for ch in raw.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn analysis_queue_persists_and_resumes_interrupted_window_checkpoints() {
        let dir = std::env::temp_dir().join(format!("koe-analysis-queue-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        let mut queue = NativeAnalysisQueue::new();
        queue.enqueue(
            20261109,
            65_000,
            1_775_000_000,
            AnalysisRecipeSnapshot {
                summary_format: SummaryFormat::ActionList,
                template_id: "retro".to_string(),
                custom_headings: vec!["阻碍项".to_string()],
                wants_visual_cards: true,
            },
        );
        assert_eq!(
            queue.job(20261109).expect("job").checkpoint.total_windows,
            4
        );
        assert!(queue.record_window_checkpoint(20261109, 2, 36_000, 14));
        assert_eq!(
            queue.job(20261109).expect("job").phase,
            AnalysisJobPhase::Transcribing
        );
        queue.save_to_dir(&dir).expect("atomic save succeeds");

        let reloaded = NativeAnalysisQueue::load_from_dir(&dir).expect("reload succeeds");
        let job = reloaded.job(20261109).expect("reloaded job exists");
        assert_eq!(job.phase, AnalysisJobPhase::Queued);
        assert_eq!(job.recipe.summary_format, SummaryFormat::ActionList);
        assert_eq!(job.recipe.template_id, "retro");
        assert_eq!(job.checkpoint.completed_windows, 2);
        assert_eq!(job.checkpoint.total_windows, 4);
        assert_eq!(job.checkpoint.resume_from_ms, 36_000);
        assert_eq!(job.checkpoint.committed_segments, 14);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
