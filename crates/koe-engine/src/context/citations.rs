use std::collections::{BTreeMap, BTreeSet};

use crate::domain::SegmentId;

/// Pointer into an original audio recording or text material without copying its payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourcePointer {
    /// Stable recording or document key (`"file:<id>"`, `"path:<path>"`, or `"doc:<id>"`).
    pub recording_key: String,
    /// Optional local file path hint for audio playback.
    pub path: Option<String>,
    /// Start offset in milliseconds within the recording (`0` for text documents).
    pub start_ms: u64,
    /// Optional end offset in milliseconds within the recording.
    pub end_ms: Option<u64>,
    /// Stable 1-based utterance segment identity within the originating recording or document.
    pub segment_id: SegmentId,
}

impl SourcePointer {
    /// Builds the canonical `"doc:<document_id>"` recording key for a text-only document.
    #[must_use]
    pub fn document_key(document_id: &str) -> String {
        format!("doc:{document_id}")
    }

    /// Returns the document identifier if `recording_key` begins with `"doc:"`.
    #[must_use]
    pub fn document_id(&self) -> Option<&str> {
        self.recording_key.strip_prefix("doc:")
    }
}

/// One numbered sentence (`S1..Sn`) handed to an LLM prompt together with its audio/text pointer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceLine {
    /// Citation label (`"S1"`, `"S2"`, ...).
    pub label: String,
    /// Title of the originating recording or document.
    pub title: String,
    /// Quoted or truncated sentence text.
    pub text: String,
    /// Pointer back to the originating recording offset or document line.
    pub source: SourcePointer,
    /// Optional UTC timestamp in Unix seconds when the sentence was spoken.
    pub at_epoch_sec: Option<u64>,
}

fn epoch_sec_to_ymd_hm(epoch_sec: u64) -> (u32, u32, u32, u32, u32) {
    let days = epoch_sec / 86_400;
    let rem = epoch_sec % 86_400;
    let hour = (rem / 3600) as u32;
    let minute = ((rem % 3600) / 60) as u32;
    let z = days as i64 + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u32;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = (if m <= 2 { y + 1 } else { y }) as u32;
    (year, m, d, hour, minute)
}

/// Renders [`SourceLine`]s for an LLM prompt (`"[S1] M/D HH:MM Title：Text"`).
#[must_use]
pub fn render_source_lines(lines: &[SourceLine]) -> String {
    let mut out = Vec::with_capacity(lines.len());
    for line in lines {
        let time_prefix = match line.at_epoch_sec {
            Some(sec) => {
                let (_, month, day, hour, minute) = epoch_sec_to_ymd_hm(sec);
                format!("{month}/{day} {hour:02}:{minute:02} ")
            }
            None => String::new(),
        };
        out.push(format!(
            "[{}] {}{}：{}",
            line.label, time_prefix, line.title, line.text
        ));
    }
    out.join("\n")
}

/// Extracts unique `[S<digits>]` citation labels from `text` in order of first appearance.
#[must_use]
pub fn cited_labels(text: &str) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let mut result = Vec::new();
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'[' && i + 3 < bytes.len() && bytes[i + 1] == b'S' {
            let mut j = i + 2;
            while j < bytes.len() && bytes[j].is_ascii_digit() {
                j += 1;
            }
            if j > i + 2 && j < bytes.len() && bytes[j] == b']' {
                let label = &text[i + 1..j];
                if seen.insert(label.to_string()) {
                    result.push(label.to_string());
                }
                i = j + 1;
                continue;
            }
        }
        i += 1;
    }
    result
}

/// Rewrites `[S#]` citation labels in `text` from `from` source lines to the matching labels in `to`
/// (matched by `recording_key`, `start_ms`, and `segment_id`), stripping citations that have no match in `to`.
#[must_use]
pub fn relabel_citations(text: &str, from: &[SourceLine], to: &[SourceLine]) -> String {
    let key_of = |line: &SourceLine| -> (String, u64, SegmentId) {
        (
            line.source.recording_key.clone(),
            line.source.start_ms,
            line.source.segment_id,
        )
    };
    let mut target = BTreeMap::new();
    for line in to {
        target.insert(key_of(line), line.label.as_str());
    }
    let mut mapping = BTreeMap::new();
    for line in from {
        mapping.insert(line.label.as_str(), target.get(&key_of(line)).copied());
    }

    let mut out = String::with_capacity(text.len());
    let bytes = text.as_bytes();
    let mut cursor = 0;
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'[' && i + 3 < bytes.len() && bytes[i + 1] == b'S' {
            let mut j = i + 2;
            while j < bytes.len() && bytes[j].is_ascii_digit() {
                j += 1;
            }
            if j > i + 2 && j < bytes.len() && bytes[j] == b']' {
                out.push_str(&text[cursor..i]);
                let old_label = &text[i + 1..j];
                if let Some(Some(new_label)) = mapping.get(old_label) {
                    out.push('[');
                    out.push_str(new_label);
                    out.push(']');
                }
                i = j + 1;
                cursor = i;
                continue;
            }
        }
        i += 1;
    }
    if cursor < text.len() {
        out.push_str(&text[cursor..]);
    }
    out
}
