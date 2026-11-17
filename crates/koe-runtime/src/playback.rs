use super::*;
use serde_json::json;

struct PlaybackLane<'a> {
    id: &'a str,
    path: Option<PathBuf>,
    capture: Option<&'a CaptureLaneRecord>,
}

impl KoeRuntime {
    fn playback_lanes<'a>(&self, record: &'a ProductRecord) -> Vec<PlaybackLane<'a>> {
        let path = |id: &str| {
            recording_assets::audio_path(&self.root, id)
                .ok()
                .filter(|p| p.is_file())
        };
        if record.capture_lanes.is_empty() {
            vec![PlaybackLane {
                id: "original",
                path: path(&record.aggregate.recording_id),
                capture: None,
            }]
        } else {
            record
                .capture_lanes
                .iter()
                .map(|l| PlaybackLane {
                    id: &l.lane,
                    path: l.asset_id.as_deref().and_then(path),
                    capture: Some(l),
                })
                .collect()
        }
    }

    fn selected_playback_lane(&self) -> Option<PlaybackLane<'_>> {
        let record = self
            .workspace()
            .record(self.selection.playback.record.as_deref()?)
            .filter(|r| r.is_live())?;
        let lanes = self.playback_lanes(record);
        let index = lanes
            .iter()
            .position(|l| {
                Some(l.id) == self.selection.playback.lane.as_deref() && l.path.is_some()
            })
            .or_else(|| lanes.iter().position(|l| l.path.is_some()))?;
        lanes.into_iter().nth(index)
    }

    pub(super) fn select_playback_lane(&mut self, lane: String) -> Result<(), String> {
        let record = self
            .workspace()
            .record(
                self.selection
                    .playback
                    .record
                    .as_deref()
                    .ok_or("先选择一条录音")?,
            )
            .ok_or("录音不存在")?;
        record.ensure_live().map_err(|e| e.to_string())?;
        if !self
            .playback_lanes(record)
            .iter()
            .any(|l| l.id == lane && l.path.is_some())
        {
            return Err("该音源没有可播放的音频".into());
        }
        self.selection.playback.lane = Some(lane);
        self.selection.playback.request_id = self.selection.playback.request_id.saturating_add(1);
        Ok(())
    }

    pub(super) fn seek_playback(&mut self, position_ms: u64) -> Result<(), String> {
        let id = self
            .selection
            .location
            .record
            .clone()
            .ok_or("先选择一条录音")?;
        let record = self.workspace().record(&id).ok_or("录音不存在")?;
        record.ensure_live().map_err(|e| e.to_string())?;
        let duration = record.aggregate.duration_ms;
        self.selection.playback.record = Some(id);
        self.selection.playback.position_ms = position_ms.min(duration);
        self.selection.playback.request_id = self.selection.playback.request_id.saturating_add(1);
        Ok(())
    }

    pub(super) fn set_playback(&mut self, playing: bool) -> Result<(), String> {
        if let Some(id) = self.selection.playback.record.as_deref() {
            if let Some(record) = self.workspace().record(id) {
                record.ensure_live().map_err(|e| e.to_string())?;
            }
        }
        if self.selected_playback_lane().is_none() {
            return Err("这条记录没有可播放的音频".into());
        }
        self.selection.playback.playing = playing;
        self.selection.playback.request_id = self.selection.playback.request_id.saturating_add(1);
        Ok(())
    }

    pub(super) fn clamped_playback_position(
        &self,
        record_id: &str,
        request_id: u64,
        position_ms: u64,
    ) -> Option<u64> {
        if self.selection.playback.record.as_deref() != Some(record_id)
            || self.selection.playback.request_id != request_id
        {
            return None;
        }
        let record = self.workspace().record(record_id).filter(|r| r.is_live())?;
        Some(position_ms.min(record.aggregate.duration_ms))
    }

    pub(super) fn playback_json(&self) -> Value {
        let playback = &self.selection.playback;
        let record = playback
            .record
            .as_deref()
            .and_then(|id| self.workspace().record(id))
            .filter(|r| r.is_live());
        let lanes: Vec<_> = record
            .map(|r| self.playback_lanes(r))
            .unwrap_or_default()
            .iter()
            .map(|l| {
                json!({
                    "id":l.id,"available":l.path.is_some(),
                    "interruption":l.capture.and_then(|l|l.interruption.as_deref())
                })
            })
            .collect();
        let selected = self.selected_playback_lane();
        let asset = selected.as_ref().map(|l| {
            let duration_ns = record.map_or(0, |r| r.capture_lanes.iter().filter_map(|l| l.timeline.last()?.end_ns(l.sample_rate?))
                .max().unwrap_or(0).max(r.aggregate.duration_ms.saturating_mul(1_000_000)));
            let segments: Vec<_> = l.capture.map(|l| l.timeline.iter().map(|s| json!({
                "sourceStartSample":s.sample_offset,"sampleCount":s.sample_count,"timelineStartNs":s.start_ns
            })).collect()).unwrap_or_default();
            json!({"audioPath":l.path.as_ref().map(|p|p.to_string_lossy()),"sampleRate":l.capture.and_then(|l|l.sample_rate),"durationNs":duration_ns,"segments":segments})
        });
        json!({"recordId":record.map(|r| &r.aggregate.recording_id),"requestId":playback.request_id,"lane":selected.map(|l|l.id),
            "positionMs":playback.position_ms,"isPlaying":playback.playing,"lanes":lanes,"asset":asset})
    }
}
