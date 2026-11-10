//! Unified long-term personal memory, multi-modal timeline (`BTreeMap` UTC join),
//! 21-day calendar disambiguation, piggybacked thing tracking, `[^n]` citation self-healing,
//! optimistic-lock change proposals, on-device CAM++ voiceprint bank, and Google Drive
//! incremental backup planning.
//!
//! Architecture references:
//! - `screenpipe:crates/screenpipe-db/src/db/frames.rs:1142-1501` (`BTreeMap` timestamp join
//!   with negative `frame_id` `device_id: "audio-only"` synthetic fallback)
//! - `screenpipe:apps/screenpipe-app-tauri/components/rewind/timeline/subtitle-bar.tsx:1-308`
//! - `omi:app/lib/backend/schema/memory.dart:3-313` (`knowledge_ledger.v1` & review cards)
//! - `taosheng:DigestPrompt.kt`, `DigestThingExtraction.kt`, `AskEngine.kt`, `VoiceprintManager.kt`

use std::collections::{BTreeMap, BTreeSet};

use crate::domain::{SegmentId, TodoItem, UtteranceSegment, UtteranceSpine};

/// Padding window (`±15,000 ms`) used when pairing audio segments with screen frames
/// on the timeline (`screenpipe:crates/screenpipe-db/src/db/frames.rs:1351`).
pub const AUDIO_FRAME_PAD_MS: u64 = 15_000;

/// Lookbehind and lookahead window (`±60,000 ms`) for the bottom subtitle / Karaoke bar
/// (`screenpipe:apps/screenpipe-app-tauri/components/rewind/timeline/subtitle-bar.tsx:31-32`).
pub const SUBTITLE_WINDOW_MS: u64 = 60_000;

/// Maximum voiceprint embeddings retained per person before evicting the oldest sample
/// (`taosheng:VoiceprintManager.kt`).
pub const MAX_VOICEPRINT_SAMPLES_PER_PERSON: usize = 10;

/// Cosine similarity threshold (`0.65`) for automatic speaker attribution.
pub const VOICEPRINT_CONFIRM_THRESHOLD: f32 = 0.65;

/// Cosine similarity threshold (`0.45`) for surfacing an Omi-style `"这是谁?"` candidate chip.
pub const VOICEPRINT_SUGGEST_THRESHOLD: f32 = 0.45;

/// Audio capture source kind displayed on Track 1 of the Screenpipe timeline scrubber.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AudioDeviceKind {
    /// Anker soundcore Work D3200 wearable recording bean (BLE / SoftAP Opus).
    D3200Bean,
    /// Built-in or external macOS / iOS microphone input.
    MacMicInput,
    /// macOS ScreenCaptureKit / CoreAudio system output loopback.
    SystemAudioOutput,
}

impl AudioDeviceKind {
    /// Short stable wire label for JSON snapshots.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::D3200Bean => "d3200_bean",
            Self::MacMicInput => "mic_input",
            Self::SystemAudioOutput => "system_output",
        }
    }
}

/// Captured desktop screen frame metadata and consolidated OCR / Accessibility text
/// (`screenpipe:crates/screenpipe-db/src/migrations/20260613130000_unify_ocr_text_into_frames.sql`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScreenFrameContext {
    /// Positive database frame ID for real captures, or negative `-timestamp_ms` for synthetic audio-only slots.
    pub frame_id: i64,
    /// Capture timestamp in milliseconds from session or epoch start.
    pub timestamp_ms: u64,
    /// Active application name (e.g., `"Zoom"`, `"Google Chrome"`, `"Cursor"`).
    pub app_name: String,
    /// Active window title.
    pub window_name: String,
    /// Optional extracted browser URL.
    pub browser_url: Option<String>,
    /// Consolidated searchable OCR + Accessibility full text.
    pub full_text: String,
}

/// Spoken segment entry attached to a [`TimeSeriesFrame`] on the timeline.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioTimelineEntry {
    /// Canonical `UtteranceSpine` segment identifier (`S1..Sn`).
    pub segment_id: SegmentId,
    /// Start timestamp in milliseconds.
    pub start_ms: u64,
    /// End timestamp in milliseconds.
    pub end_ms: u64,
    /// Attributed speaker label (`"我"` for ID 0, contact name, or `"未知说话人"`).
    pub speaker: String,
    /// Source audio device kind.
    pub device_kind: AudioDeviceKind,
    /// Refined transcript text.
    pub text: String,
    /// Optional bilingual live translation (`Cicada`).
    pub translation: Option<String>,
    /// Whether this segment overlaps a hardware double-tap `SliceMark`.
    pub has_slice_mark: bool,
}

/// Unified multi-modal time-series slot on the 3-track Screenpipe scrubber
/// (`screenpipe:crates/screenpipe-engine/src/routes/streaming.rs:333-353`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TimeSeriesFrame {
    /// Positive ID for screen-backed frames; negative `-timestamp_ms` for `device_id: "audio-only"`.
    pub frame_id: i64,
    /// Slot anchor timestamp in milliseconds.
    pub timestamp_ms: u64,
    /// `"screen"` when backed by a real [`ScreenFrameContext`], or `"audio-only"` when screen capture is off.
    pub device_id: String,
    /// Foreground application name (`"Audio Recording"` in `audio-only` mode).
    pub app_name: String,
    /// Window title or summary caption.
    pub window_name: String,
    /// Optional browser URL when `device_id == "screen"`.
    pub browser_url: Option<String>,
    /// Consolidated OCR / Accessibility text on screen at `timestamp_ms`.
    pub ocr_text: String,
    /// Spoken audio segments overlapping `[timestamp_ms - 15s, timestamp_ms + 15s]`.
    pub audio_entries: Vec<AudioTimelineEntry>,
    /// Whether a D3200 hardware double-tap `SliceMark` falls in this slot.
    pub has_slice_mark: bool,
    /// Memory / Thing diamond badge label (`◆`) pinned to this slot, if any.
    pub memory_diamond: Option<String>,
}

/// In-memory multi-modal timeline cache modeled on Screenpipe's `HotFrameCache`
/// (`screenpipe:crates/screenpipe-engine/src/hot_frame_cache.rs:75-192`).
///
/// Decouples screen frames from audio transcriptions and joins them dynamically by
/// timestamp in a `BTreeMap`, enabling zero-migration toggling between `audio-only`
/// wearable mode and `audio + screen` desktop mode.
#[derive(Debug, Clone, Default)]
pub struct HotTimelineStore {
    /// Whether desktop screen context capture is currently active.
    pub screen_capture_enabled: bool,
    /// Current scrubber playhead position in milliseconds.
    pub playhead_ms: u64,
    /// Screen frames indexed by `timestamp_ms`.
    pub frames: BTreeMap<u64, ScreenFrameContext>,
}

impl HotTimelineStore {
    /// Creates a new timeline store with optional default desktop screen context frames.
    #[must_use]
    pub fn new(screen_capture_enabled: bool) -> Self {
        let mut store = Self {
            screen_capture_enabled,
            playhead_ms: 0,
            frames: BTreeMap::new(),
        };
        if screen_capture_enabled {
            store.seed_default_screen_context();
        }
        store
    }

    /// Seeds representative desktop screen frames (Zoom, Chrome GDPR PDF, Cursor IDE)
    /// so `audio + screen` mode immediately demonstrates timestamp unification.
    pub fn seed_default_screen_context(&mut self) {
        self.insert_screen_frame(ScreenFrameContext {
            frame_id: 4091,
            timestamp_ms: 500,
            app_name: "Google Chrome".to_string(),
            window_name: "EU_GDPR_DPIA_Checklist_2026.pdf".to_string(),
            browser_url: Some("https://eur-lex.europa.eu/gdpr/dpia-2026.pdf".to_string()),
            full_text: "Article 35 Data Protection Impact Assessment Filing Deadline: 18 Nov 2026"
                .to_string(),
        });
        self.insert_screen_frame(ScreenFrameContext {
            frame_id: 4092,
            timestamp_ms: 2_500,
            app_name: "Cursor".to_string(),
            window_name: "koe — crates/koe-engine/src/memory_hub.rs".to_string(),
            browser_url: None,
            full_text: "Google Drive incremental encrypted backup day-YYYY-MM-DD.zip.enc"
                .to_string(),
        });
    }

    /// Inserts or updates a screen frame in the `BTreeMap`.
    pub fn insert_screen_frame(&mut self, frame: ScreenFrameContext) {
        self.frames.insert(frame.timestamp_ms, frame);
    }

    /// Toggles desktop screen capture mode. When enabled and empty, seeds default context frames.
    pub fn set_screen_capture_enabled(&mut self, enabled: bool) {
        self.screen_capture_enabled = enabled;
        if enabled && self.frames.is_empty() {
            self.seed_default_screen_context();
        }
    }

    /// Builds unified [`TimeSeriesFrame`] slots by joining `UtteranceSpine` segments,
    /// hardware `slice_marks_ms`, and extracted `things` against `self.frames` over UTC timestamps.
    #[must_use]
    pub fn build_time_series(
        &self,
        spine: &UtteranceSpine,
        slice_marks_ms: &[u64],
        things: &[ThingRecord],
    ) -> Vec<TimeSeriesFrame> {
        let mut map: BTreeMap<u64, TimeSeriesFrame> = BTreeMap::new();

        if self.screen_capture_enabled {
            for (&ts, sf) in &self.frames {
                map.insert(
                    ts,
                    TimeSeriesFrame {
                        frame_id: sf.frame_id,
                        timestamp_ms: ts,
                        device_id: "screen".to_string(),
                        app_name: sf.app_name.clone(),
                        window_name: sf.window_name.clone(),
                        browser_url: sf.browser_url.clone(),
                        ocr_text: sf.full_text.clone(),
                        audio_entries: Vec::new(),
                        has_slice_mark: false,
                        memory_diamond: None,
                    },
                );
            }
        }

        for seg in spine.segments() {
            let seg_has_mark = slice_marks_ms.iter().any(|&mark| {
                let lo = mark.saturating_sub(10_000);
                let hi = mark.saturating_add(10_000);
                seg.start_ms <= hi && seg.end_ms >= lo
            });
            let entry = AudioTimelineEntry {
                segment_id: seg.id,
                start_ms: seg.start_ms,
                end_ms: seg.end_ms,
                speaker: seg.speaker.clone().unwrap_or_else(|| "我".to_string()),
                device_kind: AudioDeviceKind::D3200Bean,
                text: seg.text.clone(),
                translation: seg.translation.clone(),
                has_slice_mark: seg_has_mark,
            };

            let search_start = seg.start_ms.saturating_sub(AUDIO_FRAME_PAD_MS);
            let search_end = seg.end_ms.saturating_add(AUDIO_FRAME_PAD_MS);
            let matching_keys: Vec<u64> = if self.screen_capture_enabled {
                map.range(search_start..=search_end)
                    .filter(|(_, slot)| slot.device_id == "screen")
                    .map(|(&k, _)| k)
                    .collect()
            } else {
                Vec::new()
            };

            if matching_keys.is_empty() {
                let synth_id = -((seg.start_ms as i64).saturating_add(1));
                let slot = map.entry(seg.start_ms).or_insert_with(|| TimeSeriesFrame {
                    frame_id: synth_id,
                    timestamp_ms: seg.start_ms,
                    device_id: "audio-only".to_string(),
                    app_name: "Audio Recording".to_string(),
                    window_name: "D3200 随身录音".to_string(),
                    browser_url: None,
                    ocr_text: String::new(),
                    audio_entries: Vec::new(),
                    has_slice_mark: false,
                    memory_diamond: None,
                });
                slot.has_slice_mark |= seg_has_mark;
                slot.audio_entries.push(entry);
            } else {
                for k in matching_keys {
                    if let Some(slot) = map.get_mut(&k) {
                        slot.has_slice_mark |= seg_has_mark;
                        slot.audio_entries.push(entry.clone());
                    }
                }
            }
        }

        for &mark in slice_marks_ms {
            let lo = mark.saturating_sub(2_500);
            let hi = mark.saturating_add(2_500);
            let mut matched = false;
            for (_, slot) in map.range_mut(lo..=hi) {
                slot.has_slice_mark = true;
                matched = true;
            }
            if !matched {
                if let Some((_, slot)) = map.range_mut(..=mark).next_back() {
                    slot.has_slice_mark = true;
                } else if let Some((_, slot)) = map.iter_mut().next() {
                    slot.has_slice_mark = true;
                } else {
                    let synth_id = -((mark as i64).saturating_add(1));
                    map.insert(
                        mark,
                        TimeSeriesFrame {
                            frame_id: synth_id,
                            timestamp_ms: mark,
                            device_id: "audio-only".to_string(),
                            app_name: "Audio Recording".to_string(),
                            window_name: "D3200 重点标记".to_string(),
                            browser_url: None,
                            ocr_text: String::new(),
                            audio_entries: Vec::new(),
                            has_slice_mark: true,
                            memory_diamond: None,
                        },
                    );
                }
            }
        }

        for thing in things {
            if let Some((_, slot)) = map.range_mut(..=thing.timestamp_ms).next_back() {
                slot.memory_diamond = Some(format!("寻物: {}", thing.item_name));
            } else if let Some((_, slot)) = map.iter_mut().next() {
                slot.memory_diamond = Some(format!("寻物: {}", thing.item_name));
            }
        }

        map.into_values().collect()
    }

    /// Computes the 3-line Karaoke / Screenpipe `SubtitleBar` window (`[prev, active, next]`)
    /// centered around `self.playhead_ms`.
    #[must_use]
    pub fn subtitle_window(&self, spine: &UtteranceSpine) -> Vec<String> {
        let segs = spine.segments();
        if segs.is_empty() {
            return vec![
                "等待 D3200 录音豆或麦克风输入...".to_string(),
                "双击录音豆可打下硬件 SliceMark 重点标记".to_string(),
                "底部时间轴支持纯音频与电脑画面零迁移切换".to_string(),
            ];
        }
        let active_idx = segs
            .iter()
            .position(|s| self.playhead_ms >= s.start_ms && self.playhead_ms <= s.end_ms)
            .or_else(|| {
                segs.iter()
                    .enumerate()
                    .min_by_key(|(_, s)| s.start_ms.abs_diff(self.playhead_ms))
                    .map(|(idx, _)| idx)
            })
            .unwrap_or(0);

        let fmt_seg = |s: &UtteranceSegment| -> String {
            let spk = s.speaker.as_deref().unwrap_or("我");
            format!("[{} {}] {}", s.id, spk, s.text)
        };

        let prev = if active_idx > 0 {
            fmt_seg(&segs[active_idx - 1])
        } else {
            "--- 会话起点 ---".to_string()
        };
        let curr = fmt_seg(&segs[active_idx]);
        let next = if active_idx + 1 < segs.len() {
            fmt_seg(&segs[active_idx + 1])
        } else {
            "--- 实时流尾端 ---".to_string()
        };
        vec![prev, curr, next]
    }
}

/// One row in the 21-day explicit calendar table (`-1..=+20` days) injected into Digest prompts
/// (`taosheng:DigestPrompt.kt`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CalendarDayRow {
    /// Day offset relative to today (`-1` = yesterday, `0` = today, `1` = tomorrow, etc.).
    pub offset_days: i32,
    /// ISO-8601 date string (`YYYY-MM-DD`).
    pub iso_date: String,
    /// Chinese weekday label (`"周一".."周日"`).
    pub weekday_zh: String,
    /// Relative alias in Chinese (`"昨天"`, `"今天"`, `"明天"`, `"本周四"`, `"下周三"`, etc.).
    pub relative_label_zh: String,
}

const fn is_leap_year(year: i32) -> bool {
    (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
}

const fn days_in_month(year: i32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => {
            if is_leap_year(year) {
                29
            } else {
                28
            }
        }
        _ => 30,
    }
}

/// Converts a Gregorian `(year, month, day)` to days since `1970-01-01` (Howard Hinnant algorithm).
#[must_use]
pub const fn civil_to_days(year: i32, month: u32, day: u32) -> i64 {
    let y = year as i64 - if month <= 2 { 1 } else { 0 };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as u64;
    let m = month as u64;
    let d = day as u64;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe as i64 - 719_468
}

/// Converts days since `1970-01-01` back to `(year, month, day)` and `weekday` (`1 = Monday..7 = Sunday`).
#[must_use]
pub const fn days_to_civil(days_since_epoch: i64) -> (i32, u32, u32, u32) {
    let z = days_since_epoch + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = (y + if m <= 2 { 1 } else { 0 }) as i32;
    let weekday_mon_1 = ((days_since_epoch + 3).rem_euclid(7) + 1) as u32;
    (year, m as u32, d as u32, weekday_mon_1)
}

const fn weekday_name_zh(weekday_mon_1: u32) -> &'static str {
    match weekday_mon_1 {
        1 => "周一",
        2 => "周二",
        3 => "周三",
        4 => "周四",
        5 => "周五",
        6 => "周六",
        _ => "周日",
    }
}

/// Builds TaoSheng's 21-day explicit lookup table (`-1` day to `+19` days = 21 days total)
/// so relative date expressions (`"这周四"`, `"下周三"`, `"明天"`) map to exact ISO dates.
#[must_use]
pub fn build_twenty_one_day_calendar_table(anchor_ymd: (i32, u32, u32)) -> Vec<CalendarDayRow> {
    let (ay, am, ad) = anchor_ymd;
    let clamped_d = ad.min(days_in_month(ay, am)).max(1);
    let base_days = civil_to_days(ay, am, clamped_d);
    let (_, _, _, base_wd) = days_to_civil(base_days);

    let mut rows = Vec::with_capacity(21);
    for offset in -1..=19 {
        let (y, m, d, wd) = days_to_civil(base_days + i64::from(offset));
        let iso_date = format!("{y:04}-{m:02}-{d:02}");
        let wd_zh = weekday_name_zh(wd).to_string();
        let days_since_this_monday = i32::try_from(base_wd - 1).unwrap_or(0) + offset;
        let week_bucket = days_since_this_monday.div_euclid(7);
        let rel = match offset {
            -1 => "昨天".to_string(),
            0 => "今天".to_string(),
            1 => "明天".to_string(),
            2 => "后天".to_string(),
            _ => match week_bucket {
                0 => format!("本{wd_zh}"),
                1 => format!("下{wd_zh}"),
                2 => format!("下下{wd_zh}"),
                _ => iso_date.clone(),
            },
        };
        rows.push(CalendarDayRow {
            offset_days: offset,
            iso_date,
            weekday_zh: wd_zh,
            relative_label_zh: rel,
        });
    }
    rows
}

/// Resolves a Chinese relative date mention in `text` against the 21-day calendar table.
#[must_use]
pub fn resolve_relative_date_zh(text: &str, anchor_ymd: (i32, u32, u32)) -> Option<String> {
    let table = build_twenty_one_day_calendar_table(anchor_ymd);
    let normalized = text
        .replace("星期", "周")
        .replace("礼拜", "周")
        .replace("周天", "周日")
        .replace("這周", "本周")
        .replace("这周", "本周");

    for row in table.iter().rev() {
        if row.offset_days >= 3 && normalized.contains(&row.relative_label_zh) {
            return Some(row.iso_date.clone());
        }
    }
    for (kw, offset) in [("后天", 2), ("明天", 1), ("今天", 0), ("昨天", -1)] {
        if normalized.contains(kw) {
            return table
                .iter()
                .find(|r| r.offset_days == offset)
                .map(|r| r.iso_date.clone());
        }
    }
    for row in &table {
        if row.offset_days >= 0 && normalized.contains(&row.weekday_zh) {
            return Some(row.iso_date.clone());
        }
    }
    None
}

/// Four canonical movement states for piggybacked thing extraction (`taosheng:DigestThingExtraction.kt`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThingAction {
    /// Item was placed at a specific location (`Placed`).
    Placed,
    /// Item was lent to a person (`Lent`).
    Lent,
    /// Item was returned (`Returned`).
    Returned,
    /// Item was taken away (`TakenAway`).
    TakenAway,
}

impl ThingAction {
    /// Chinese badge label for UI display.
    #[must_use]
    pub const fn label_zh(self) -> &'static str {
        match self {
            Self::Placed => "放置",
            Self::Lent => "借出",
            Self::Returned => "归还",
            Self::TakenAway => "带走",
        }
    }
}

/// Extracted physical item whereabouts record (`taosheng:ThingRepository.kt`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThingRecord {
    /// Stable record identifier (`"thing_1"`, `"thing_2"`, ...).
    pub id: String,
    /// Extracted item name.
    pub item_name: String,
    /// Movement state (`Placed`, `Lent`, `Returned`, `TakenAway`).
    pub action: ThingAction,
    /// Destination drawer/room or borrower name.
    pub location_or_person: String,
    /// Grounded source utterance segment ID (`S1..Sn`).
    pub citation: SegmentId,
    /// Utterance start timestamp in milliseconds.
    pub timestamp_ms: u64,
}

/// Extracts physical item movements (`Placed`, `Lent`, `Returned`, `TakenAway`) piggybacked
/// on the `UtteranceSpine` without extra network calls.
#[must_use]
pub fn extract_things_from_spine(spine: &UtteranceSpine) -> Vec<ThingRecord> {
    let mut out = Vec::new();
    for seg in spine.segments() {
        let t = seg.text.trim();
        let action_and_loc = if let Some(idx) = t.find("放在") {
            Some((ThingAction::Placed, &t[idx + "放在".len()..]))
        } else if let Some(idx) = t.find("放进") {
            Some((ThingAction::Placed, &t[idx + "放进".len()..]))
        } else if let Some(idx) = t.find("放") {
            if t.contains("抽屉") || t.contains("桌") || t.contains("包") || t.contains("柜") {
                Some((ThingAction::Placed, &t[idx + "放".len()..]))
            } else {
                None
            }
        } else if let Some(idx) = t.find("借给") {
            Some((ThingAction::Lent, &t[idx + "借给".len()..]))
        } else if let Some(idx) = t.find("还给") {
            Some((ThingAction::Returned, &t[idx + "还给".len()..]))
        } else {
            t.find("带走")
                .map(|idx| (ThingAction::TakenAway, &t[idx + "带走".len()..]))
        };

        if let Some((action, tail)) = action_and_loc {
            let loc = tail
                .trim_matches(|c: char| "了。，,！!？? ".contains(c))
                .to_string();
            let item = extract_item_head(t);
            if !item.is_empty() && !loc.is_empty() {
                out.push(ThingRecord {
                    id: format!("thing_{}", out.len() + 1),
                    item_name: item,
                    action,
                    location_or_person: loc,
                    citation: seg.id,
                    timestamp_ms: seg.start_ms,
                });
            }
        }
    }
    out
}

fn extract_item_head(text: &str) -> String {
    let cleaned = text
        .trim_start_matches("我把")
        .trim_start_matches("把")
        .trim_start_matches("刚才");
    for sep in ["放在", "放进", "借给", "还给", "带走", "放"] {
        if let Some(pos) = cleaned.find(sep) {
            let candidate = cleaned[..pos]
                .trim_end_matches("我")
                .trim_matches(|c: char| " ，,。".contains(c));
            if !candidate.is_empty() {
                return candidate.to_string();
            }
        }
    }
    "随身物品".to_string()
}

/// Gentle todo completion hint surfaced when later speech indicates an open todo was finished
/// (`taosheng:DigestPrompt.kt` `done_hints`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DoneHint {
    /// Open todo identifier.
    pub todo_id: String,
    /// Open todo title.
    pub todo_title: String,
    /// Grounded utterance segment ID (`S1..Sn`) that triggered the hint.
    pub evidence_segment: SegmentId,
    /// Exact quote from the utterance.
    pub evidence_quote: String,
}

/// Scans `spine` for completion expressions (`"已发"`, `"刚发"`, `"发给"`, `"交齐了"`, `"做完了"`, `"搞定了"`)
/// matching keywords in `open_todos` and returns gentle [`DoneHint`]s without mutating todo status.
#[must_use]
pub fn detect_todo_done_hints(open_todos: &[TodoItem], spine: &UtteranceSpine) -> Vec<DoneHint> {
    let completion_markers = [
        "刚发",
        "已发",
        "已经发",
        "发过去了",
        "做完了",
        "搞定了",
        "已完成",
        "提交了",
    ];
    let mut hints = Vec::new();
    for todo in open_todos {
        for seg in spine.segments() {
            let has_marker = completion_markers.iter().any(|m| seg.text.contains(m));
            if !has_marker {
                continue;
            }
            let shared_term = todo.title.chars().collect::<Vec<_>>().windows(2).any(|w| {
                let bigram: String = w.iter().collect();
                !bigram.trim().is_empty() && seg.text.contains(&bigram)
            });
            if shared_term {
                hints.push(DoneHint {
                    todo_id: todo.id.clone(),
                    todo_title: todo.title.clone(),
                    evidence_segment: seg.id,
                    evidence_quote: seg.text.clone(),
                });
                break;
            }
        }
    }
    hints
}

/// Validates and self-heals 1-based `[^n]` citations in an `AskEngine` answer against
/// `valid_refs` (`taosheng:AskCitations.kt` & `AskEngine.kt:52`).
///
/// Returns `(healed_answer, had_dangling_or_missing_citations)`.
#[must_use]
pub fn validate_and_heal_ask_citations(
    raw_answer: &str,
    valid_refs: &[SegmentId],
) -> (String, bool) {
    if valid_refs.is_empty() {
        return (raw_answer.to_string(), false);
    }
    let max_idx = valid_refs.len();
    let mut healed = String::with_capacity(raw_answer.len() + 16);
    let mut chars = raw_answer.chars().peekable();
    let mut had_valid_citation = false;
    let mut repaired = false;

    while let Some(ch) = chars.next() {
        if ch == '[' && chars.peek() == Some(&'^') {
            let _ = chars.next();
            let mut num_str = String::new();
            while let Some(&d) = chars.peek() {
                if d.is_ascii_digit() {
                    num_str.push(d);
                    let _ = chars.next();
                } else {
                    break;
                }
            }
            if chars.peek() == Some(&']') {
                let _ = chars.next();
                match num_str.parse::<usize>() {
                    Ok(idx) if (1..=max_idx).contains(&idx) => {
                        let seg_id = valid_refs[idx - 1];
                        healed.push_str(&format!("[^{idx} {seg_id}]"));
                        had_valid_citation = true;
                    }
                    _ => {
                        repaired = true;
                    }
                }
                continue;
            }
            healed.push_str("[^");
            healed.push_str(&num_str);
        } else {
            healed.push(ch);
        }
    }

    if !had_valid_citation {
        repaired = true;
        let first_seg = valid_refs[0];
        healed = format!("{} [^1 {first_seg}]", healed.trim_end());
    }
    (healed, repaired)
}

/// Optimistic-lock change proposal card (`taosheng:AskChanges.kt` + `omi:EditReceiptBlock`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AskChangeProposal {
    /// Unique proposal ID.
    pub proposal_id: String,
    /// Target todo item ID.
    pub target_todo_id: String,
    /// Previous todo title before the proposed change.
    pub before_title: String,
    /// Proposed new todo title.
    pub after_title: String,
    /// Proposed resolved ISO due date (`YYYY-MM-DD`).
    pub after_due: Option<String>,
    /// Snapshot `updated_at_ms` captured when the proposal was drafted.
    pub expected_updated_at_ms: u64,
    /// Whether the user has confirmed and applied this proposal.
    pub applied: bool,
}

impl AskChangeProposal {
    /// Verifies the optimistic lock (`expected_updated_at_ms == current_updated_at_ms`)
    /// and applies the change if uncontended.
    pub fn verify_and_apply(&mut self, current_updated_at_ms: u64) -> Result<(), String> {
        if self.expected_updated_at_ms != current_updated_at_ms {
            return Err(format!(
                "optimistic lock conflict: expected {}, found {}",
                self.expected_updated_at_ms, current_updated_at_ms
            ));
        }
        self.applied = true;
        Ok(())
    }
}

/// Omi-style unified 1-tap confirmation item (`omi:review_question_card.dart` & `memory_review_card.dart`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviewCardItem {
    /// Review item identifier.
    pub id: String,
    /// Category tag (`"speaker"`, `"done_hint"`, or `"memory"`).
    pub kind: String,
    /// User-facing prompt headline.
    pub headline: String,
    /// Grounded source citation label (`[S1..Sn]`).
    pub citation: String,
    /// Whether the user has confirmed or dismissed this review card.
    pub resolved: bool,
}

/// On-device CAM++ 192-dimensional L2-normalized speaker voiceprint bank (`taosheng:VoiceprintManager.kt`).
#[derive(Debug, Clone, Default)]
pub struct VoiceprintBank {
    /// Speaker ID `0` is always reserved for `"我"` (the device owner).
    pub profiles: BTreeMap<u32, SpeakerVoiceProfile>,
}

/// Voiceprint profile storing up to [`MAX_VOICEPRINT_SAMPLES_PER_PERSON`] embeddings.
#[derive(Debug, Clone, PartialEq)]
pub struct SpeakerVoiceProfile {
    /// Speaker numeric ID (`0 = 我`).
    pub speaker_id: u32,
    /// Display name.
    pub name: String,
    /// Ring buffer of L2-normalized embeddings (up to 10 samples).
    pub samples: Vec<Vec<f32>>,
}

impl VoiceprintBank {
    /// Creates a default bank pre-seeded with `ID 0 = 我`.
    #[must_use]
    pub fn with_owner() -> Self {
        let mut bank = Self {
            profiles: BTreeMap::new(),
        };
        bank.profiles.insert(
            0,
            SpeakerVoiceProfile {
                speaker_id: 0,
                name: "我 (ID 0)".to_string(),
                samples: vec![vec![1.0, 0.0, 0.0, 0.0]],
            },
        );
        bank
    }

    /// Enrolls a voiceprint sample for `speaker_id`, evicting the oldest sample when
    /// exceeding [`MAX_VOICEPRINT_SAMPLES_PER_PERSON`].
    pub fn enroll_sample(&mut self, speaker_id: u32, name: &str, embedding: Vec<f32>) {
        let norm = l2_normalize(&embedding);
        let profile = self
            .profiles
            .entry(speaker_id)
            .or_insert_with(|| SpeakerVoiceProfile {
                speaker_id,
                name: name.to_string(),
                samples: Vec::new(),
            });
        profile.name = name.to_string();
        if profile.samples.len() >= MAX_VOICEPRINT_SAMPLES_PER_PERSON {
            profile.samples.remove(0);
        }
        profile.samples.push(norm);
    }

    /// Matches `query_embedding` against enrolled profiles and returns `(speaker_id, name, cosine_sim)`.
    #[must_use]
    pub fn match_speaker(&self, query_embedding: &[f32]) -> Option<(u32, String, f32)> {
        let q = l2_normalize(query_embedding);
        let mut best: Option<(u32, String, f32)> = None;
        for profile in self.profiles.values() {
            if profile.samples.is_empty() {
                continue;
            }
            let dim = q.len();
            let mut mean = vec![0.0_f32; dim];
            for s in &profile.samples {
                for (i, &v) in s.iter().take(dim).enumerate() {
                    mean[i] += v;
                }
            }
            let mean_norm = l2_normalize(&mean);
            let sim: f32 = q.iter().zip(mean_norm.iter()).map(|(a, b)| a * b).sum();
            if best.as_ref().is_none_or(|(_, _, b_sim)| sim > *b_sim) {
                best = Some((profile.speaker_id, profile.name.clone(), sim));
            }
        }
        best
    }
}

fn l2_normalize(v: &[f32]) -> Vec<f32> {
    let norm_sq: f32 = v.iter().map(|x| x * x).sum();
    let norm = norm_sq.sqrt();
    if norm <= 1e-6 {
        return v.to_vec();
    }
    v.iter().map(|x| x / norm).collect()
}

/// Declarative Screenpipe-style `pipe.md` skill specification (`screenpipe:components/pipe-store.tsx`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PipeSkillSpec {
    /// Skill identifier (`"daily_recap"`, `"gdpr_compliance"`, `"things_scanner"`).
    pub id: String,
    /// Display title.
    pub title: String,
    /// Cron or trigger schedule description.
    pub schedule: String,
    /// Allowed modalities (`["@audio", "@screen"]`).
    pub modalities: Vec<String>,
}

/// Google Drive dual-mode backup status (`day-YYYY-MM-DD.zip.enc` encrypted volume + `/KoeNotes/` Markdown sync)
/// and 10-channel incremental push ledger (`sent_ids`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GoogleDriveBackupStatus {
    /// Active encrypted daily volume filename (`"day-2026-11-09.zip.enc"`).
    pub active_daily_volume: String,
    /// Target Markdown mirror folder on Google Drive (`"/KoeNotes/2026-11/"`).
    pub markdown_folder: String,
    /// Pending dirty day volumes waiting for upload.
    pub dirty_days: BTreeSet<String>,
    /// Deduplicated item IDs already pushed across the 10 incremental notification channels.
    pub pushed_sent_ids: BTreeSet<String>,
    /// Last successful sync epoch seconds (`0` if not yet synced in this session).
    pub last_synced_epoch_sec: u64,
}

impl Default for GoogleDriveBackupStatus {
    fn default() -> Self {
        let mut dirty = BTreeSet::new();
        dirty.insert("2026-11-09".to_string());
        Self {
            active_daily_volume: "day-2026-11-09.zip.enc".to_string(),
            markdown_folder: "/KoeNotes/2026-11/".to_string(),
            dirty_days: dirty,
            pushed_sent_ids: BTreeSet::new(),
            last_synced_epoch_sec: 0,
        }
    }
}

impl GoogleDriveBackupStatus {
    /// Marks all dirty daily volumes as uploaded and records `now_epoch_sec`.
    pub fn mark_synced(&mut self, now_epoch_sec: u64) {
        self.dirty_days.clear();
        self.last_synced_epoch_sec = now_epoch_sec.max(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn twenty_one_day_calendar_resolves_cross_week_dates() {
        // 2026-11-09 is a Monday.
        let anchor = (2026, 11, 9);
        let table = build_twenty_one_day_calendar_table(anchor);
        assert_eq!(table.len(), 21);
        assert_eq!(table[0].iso_date, "2026-11-08");
        assert_eq!(table[1].iso_date, "2026-11-09");
        assert_eq!(table[1].weekday_zh, "周一");

        assert_eq!(
            resolve_relative_date_zh("下周三前必须把 GDPR 补充材料交齐", anchor),
            Some("2026-11-18".to_string())
        );
        assert_eq!(
            resolve_relative_date_zh("这周四把 Google Drive 备份跑通", anchor),
            Some("2026-11-12".to_string())
        );
    }

    #[test]
    fn screenpipe_btreemap_timeline_switches_audio_only_and_screen_modes() {
        let mut spine = UtteranceSpine::default();
        let _ = spine.append_segment(
            "二号测试豆放进书房左抽屉第二格了",
            400,
            1_800,
            "zh",
            "local",
        );
        let things = extract_things_from_spine(&spine);
        assert_eq!(things.len(), 1);
        assert_eq!(things[0].action, ThingAction::Placed);
        assert_eq!(things[0].location_or_person, "书房左抽屉第二格");

        let mut store = HotTimelineStore::new(false);
        let audio_only_frames = store.build_time_series(&spine, &[600], &things);
        assert_eq!(audio_only_frames.len(), 1);
        assert_eq!(audio_only_frames[0].device_id, "audio-only");
        assert!(audio_only_frames[0].frame_id < 0);
        assert!(audio_only_frames[0].has_slice_mark);

        store.set_screen_capture_enabled(true);
        let hybrid_frames = store.build_time_series(&spine, &[600], &things);
        assert!(hybrid_frames
            .iter()
            .any(|f| f.device_id == "screen" && !f.audio_entries.is_empty()));
    }

    #[test]
    fn ask_citations_self_heal_dangling_indices_and_optimistic_lock_guards_changes() {
        let refs = vec![SegmentId::new(1).unwrap(), SegmentId::new(2).unwrap()];
        let (healed, repaired) =
            validate_and_heal_ask_citations("二号测试豆在书房左抽屉 [^99]", &refs);
        assert!(repaired);
        assert!(healed.contains("[^1 S1]"));
        assert!(!healed.contains("[^99]"));

        let mut proposal = AskChangeProposal {
            proposal_id: "prop_1".to_string(),
            target_todo_id: "todo_1".to_string(),
            before_title: "周五前提交".to_string(),
            after_title: "下周五前提交".to_string(),
            after_due: Some("2026-11-20".to_string()),
            expected_updated_at_ms: 1_000,
            applied: false,
        };
        assert!(proposal.verify_and_apply(2_000).is_err());
        assert!(proposal.verify_and_apply(1_000).is_ok());
        assert!(proposal.applied);
    }

    #[test]
    fn voiceprint_bank_caps_at_ten_samples_and_matches_cosine() {
        let mut bank = VoiceprintBank::with_owner();
        for i in 0..12 {
            bank.enroll_sample(2, "王晓东", vec![0.0, 1.0, (i as f32) * 0.01, 0.0]);
        }
        assert_eq!(
            bank.profiles[&2].samples.len(),
            MAX_VOICEPRINT_SAMPLES_PER_PERSON
        );
        let matched = bank.match_speaker(&[0.0, 0.99, 0.05, 0.0]).unwrap();
        assert_eq!(matched.0, 2);
        assert!(matched.2 > VOICEPRINT_CONFIRM_THRESHOLD);
    }
}
