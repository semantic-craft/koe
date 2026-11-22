use super::*;
use crate::speech::CaptureOrigin;
use crate::command::{CaptureMode, CaptureTiming};
use koe_client_services::capture_asset::{AppendOutcome, CaptureAsset};
use koe_engine::product::{place_capture_span, CaptureLaneRecord, CaptureSpan};
use serde_json::json;
use std::collections::BTreeMap;

#[derive(PartialEq, Eq)]
pub(super) enum Phase {
    Starting,
    Recording,
    Pausing,
    Paused,
    Stopping,
    CapacityReached,
    Cancelling,
    Saving,
}
struct Lane {
    timeline: Vec<CaptureSpan>,
    paused: bool,
    asset_id: String,
    next_sequence: u64,
    asset: Option<CaptureAsset>,
    sample_rate: Option<u32>,
    producer_stopped: bool,
    interruption: Option<String>,
    save_error: Option<String>,
}
pub(super) struct Microphone {
    record_id: String,
    current_record_id: String,
    segment_offset_ns: u64,
    session_id: String,
    pub(super) input_id: String,
    created_at: u64,
    segment_started_at: Option<u64>,
    clock_ns: Option<u64>,
    epoch: u64,
    epoch_offset_ns: u64,
    pub(super) phase: Phase,
    pub(super) mode: Option<CaptureMode>,
    lanes: BTreeMap<String, Lane>,
    pub(super) level: f64,
    pub(super) save_error: Option<String>,
}
pub(super) struct MicrophoneStatus<'a> {
    pub phase: &'static str,
    pub duration_ms: u64,
    pub input_label: String,
    input_badge: String,
    pub interruption: Option<&'a str>,
}

impl Microphone {
    pub(super) fn can_pause(&self) -> bool {
        self.phase == Phase::Recording && self.clock_ns.is_some()
    }
    pub(super) fn current_record_id(&self) -> &str {
        &self.current_record_id
    }
    pub(super) fn owns_id(&self, id: &str) -> bool {
        self.current_record_id == id || self.lanes.values().any(|l| l.asset_id == id)
    }
    pub(super) fn audio_filenames(&self) -> std::collections::BTreeSet<String> {
        let mut files = std::collections::BTreeSet::from([
            format!("{}.wav", self.record_id),
            format!("{}.opus", self.record_id),
        ]);
        for lane in self.lanes.values() {
            files.insert(format!("{}.wav", lane.asset_id));
        }
        files
    }
    fn matches(&self, record: &str, session: &str, lane: &str) -> bool {
        self.record_id == record && self.session_id == session && self.lanes.contains_key(lane)
    }
    pub(super) fn lane_receipt_state(
        &self,
        record: &str,
        session: &str,
        lane: &str,
    ) -> Option<(u64, bool)> {
        if !self.matches(record, session, lane) {
            return None;
        }
        let lane = self.lanes.get(lane)?;
        Some((lane.next_sequence, lane.save_error.is_some()))
    }
    fn refresh_error(&mut self) {
        self.save_error = self.lanes.values().find_map(|l| l.save_error.clone());
    }
    /// A lane failure only ends the session once no lane can still deliver audio.
    fn all_lanes_failed_or_stopped(&self) -> bool {
        self.lanes
            .values()
            .all(|l| l.producer_stopped || l.interruption.is_some())
    }
    fn lanes_ready(&self) -> bool {
        self.lanes
            .values()
            .all(|l| l.asset.is_some() || l.producer_stopped)
            && self.lanes.values().any(|l| l.asset.is_some())
    }
    fn lanes_paused(&self) -> bool {
        self.lanes.values().all(|l| l.paused || l.producer_stopped)
    }
}
impl KoeRuntime {
    pub(super) fn start_microphone(
        &mut self,
        input_id: String,
        include_system: bool,
        clock_ns: Option<u64>,
        now: u64,
    ) -> Result<(), String> {
        if include_system && !self.platform.supports_system_audio {
            return Err("当前平台不支持录制系统音频".into());
        }
        if self.microphone.is_some() {
            return Err("请先结束当前录音并完成保存".into());
        }
        if self.is_bean_meeting_recording() {
            return Err("录音豆正在录音中，请先结束当前录音".into());
        }
        if self.store.requires_reopen() {
            return Err("工作区保存结果未知，请重新打开后录音".into());
        }
        if input_id.len() > 256 {
            return Err("输入设备标识过长".into());
        }
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_nanos();
        let id = format!("mic-{now}-{nonce}");
        let mut lanes = BTreeMap::new();
        for lane in if include_system {
            &["microphone", "system"][..]
        } else {
            &["microphone"][..]
        } {
            lanes.insert(
                (*lane).into(),
                Lane {
                    timeline: Vec::new(),
                    paused: false,
                    asset_id: if *lane == "microphone" {
                        id.clone()
                    } else {
                        format!("{id}-system")
                    },
                    next_sequence: 0,
                    asset: None,
                    sample_rate: None,
                    producer_stopped: false,
                    interruption: None,
                    save_error: None,
                },
            );
        }
        self.microphone = Some(Microphone {
            record_id: id.clone(),
            current_record_id: id.clone(),
            segment_offset_ns: 0,
            session_id: format!("{id}-session"),
            input_id,
            created_at: now,
            segment_started_at: Some(now),
            clock_ns,
            epoch: 0,
            epoch_offset_ns: 0,
            phase: Phase::Starting,
            mode: None,
            lanes,
            level: 0.0,
            save_error: None,
        });
        Ok(())
    }
    pub(super) fn microphone_prepared(
        &mut self,
        record: &str,
        session: &str,
        epoch: u64,
        clock_ns: u64,
    ) -> Result<(), String> {
        let Some(m) = &mut self.microphone else {
            return Ok(());
        };
        if m.record_id != record || m.session_id != session || m.epoch != epoch {
            return Ok(());
        }
        if m.phase != Phase::Starting || m.lanes.values().any(|l| l.sample_rate.is_some()) {
            return Ok(());
        }
        match m.clock_ns {
            Some(previous) if previous != clock_ns => Err("采集时钟已经确认，不能覆盖".into()),
            _ => {
                m.clock_ns = Some(clock_ns);
                Ok(())
            }
        }
    }
    pub(super) fn pause_microphone(&mut self) -> Result<(), String> {
        let m = self.microphone.as_mut().ok_or("没有活动录音")?;
        if !m.can_pause() {
            return Err("当前录音尚不能暂停".into());
        }
        m.phase = Phase::Pausing;
        m.level = 0.0;
        Ok(())
    }
    pub(super) fn microphone_paused(
        &mut self,
        record: &str,
        session: &str,
        lane: &str,
        sequence: u64,
        epoch: u64,
    ) -> Result<(), String> {
        let Some(m) = &mut self.microphone else {
            return Ok(());
        };
        if !m.matches(record, session, lane) || epoch != m.epoch {
            return Ok(());
        }
        if m.phase != Phase::Pausing {
            return Err("当前未请求暂停".into());
        }
        let Some(l) = m.lanes.get_mut(lane) else {
            return Ok(());
        };
        if sequence != l.next_sequence {
            return Err("仍有音频等待保存".into());
        }
        l.paused = true;
        m.level = 0.0;
        if m.lanes_paused() {
            m.phase = Phase::Paused;
        }
        Ok(())
    }
    pub(super) fn resume_microphone(&mut self, clock_ns: u64) -> Result<(), String> {
        let m = self.microphone.as_mut().ok_or("没有活动录音")?;
        if m.phase != Phase::Paused {
            return Err("等待所有音源暂停并排空后才能继续".into());
        }
        let offset = m
            .lanes
            .values()
            .filter_map(|l| l.timeline.last()?.end_ns(l.sample_rate?))
            .max()
            .map(|offset| offset.saturating_add(m.segment_offset_ns))
            .unwrap_or(m.segment_offset_ns.max(m.epoch_offset_ns));
        let previous_end = m
            .clock_ns
            .and_then(|n| n.checked_add(offset - m.epoch_offset_ns))
            .ok_or("采样时钟无效")?;
        if clock_ns < previous_end {
            return Err("恢复时钟早于已接收音频".into());
        }
        m.epoch = m.epoch.checked_add(1).ok_or("采集代次耗尽")?;
        m.clock_ns = Some(clock_ns);
        m.epoch_offset_ns = offset;
        m.phase = Phase::Recording;
        for l in m.lanes.values_mut().filter(|l| !l.producer_stopped) {
            l.paused = false;
        }
        Ok(())
    }
    pub(super) fn stop_microphone(&mut self, cancel: bool) -> Result<(), String> {
        if let Some(m) = &mut self.microphone {
            if m.phase == Phase::Saving {
                return Err("正在保存录音，请完成保存后继续".into());
            }
            m.level = 0.0;
            if cancel {
                m.phase = Phase::Cancelling;
            } else if !matches!(m.phase, Phase::Cancelling | Phase::CapacityReached) {
                m.phase = Phase::Stopping;
            }
        }
        Ok(())
    }
    pub(super) fn microphone_started(
        &mut self,
        record: &str,
        session: &str,
        lane: &str,
        rate: u32,
    ) -> Result<(), String> {
        let Some(m) = &mut self.microphone else {
            return Ok(());
        };
        if !m.matches(record, session, lane) {
            return Ok(());
        }
        if !matches!(m.phase, Phase::Starting | Phase::Recording) {
            return Ok(());
        }
        let Some(l) = m.lanes.get_mut(lane) else {
            return Ok(());
        };
        if l.sample_rate.is_some() || l.producer_stopped {
            return Ok(());
        }
        if !(8000..=96000).contains(&rate) {
            l.interruption = Some("音频格式不受支持，未保存该路录音".into());
            if m.all_lanes_failed_or_stopped() {
                m.phase = Phase::Stopping;
            }
            return Err("音频采样率不受支持".into());
        }
        l.sample_rate = Some(rate);
        match CaptureAsset::create(&self.root, &l.asset_id, rate) {
            Ok(asset) => {
                l.asset = Some(asset);
                if m.phase == Phase::Starting && m.lanes_ready() {
                    m.phase = Phase::Recording;
                }
                Ok(())
            }
            Err(error) => {
                l.save_error = Some(error.clone());
                m.refresh_error();
                m.phase = Phase::Stopping;
                Err(error)
            }
        }
    }
    pub(super) fn microphone_chunk(
        &mut self,
        identity: (&str, &str, &str),
        sequence: u64,
        samples: &[i16],
        timing: Option<CaptureTiming>,
    ) -> Result<(), String> {
        let (record, session, lane) = identity;
        let Some(m) = &mut self.microphone else {
            return Ok(());
        };
        if !m.matches(record, session, lane) {
            return Ok(());
        }
        let Some(l) = m.lanes.get_mut(lane) else {
            return Ok(());
        };
        if l.paused || timing.is_some_and(|t| t.epoch != m.epoch) {
            return Err("采集代次已结束".into());
        }
        if l.producer_stopped {
            return Err("采集会话已经结束".into());
        }
        if sequence != l.next_sequence {
            return Err("音频块顺序不连续".into());
        }
        if samples.is_empty() || samples.len() > 8192 {
            return Err("音频块无效或过大".into());
        }
        if !matches!(m.phase, Phase::Cancelling | Phase::CapacityReached) {
            let placement = match (m.clock_ns, timing.map(|t| t.captured_start_ns)) {
                (Some(base), Some(at)) => {
                    let start = at
                        .checked_sub(base)
                        .and_then(|n| n.checked_add(m.epoch_offset_ns))
                        .and_then(|n| n.checked_sub(m.segment_offset_ns))
                        .ok_or("采样时钟无效")?;
                    Some(
                        place_capture_span(
                            &l.timeline,
                            l.sample_rate.ok_or("音频尚未就绪")?,
                            m.epoch,
                            start,
                            samples.len(),
                        )
                        .map_err(|_| "采样时间重叠、间隔过大或时间轴已满")?,
                    )
                }
                (None, None) => None,
                _ => return Err("采样时钟缺失或未初始化".into()),
            };
            let result = l.asset.as_mut().ok_or("音频尚未就绪")?.append(samples);
            match result {
                Ok(AppendOutcome::Written) => {
                    if let Some((span, merge)) = placement {
                        if merge {
                            if let Some(last) = l.timeline.last_mut() {
                                *last = span;
                            } else {
                                l.timeline.push(span);
                            }
                        } else {
                            l.timeline.push(span);
                        }
                    }
                    if lane == "microphone" {
                        let sum_sq: f64 = samples
                            .iter()
                            .map(|&s| {
                                let v = f64::from(s) / 32768.0;
                                v * v
                            })
                            .sum();
                        let rms = if samples.is_empty() {
                            0.0
                        } else {
                            (sum_sq / samples.len() as f64).sqrt()
                        };
                        m.level = (rms * 4.0).clamp(0.0, 1.0);
                    }
                }
                Ok(AppendOutcome::CapacityReached) => {
                    m.level = 0.0;
                    l.interruption = Some(
                        "录音达到 WAV 长度上限，已保留此前收到的音频。请新建录音继续。".into(),
                    );
                    m.phase = Phase::CapacityReached;
                    for other in m.lanes.values_mut() {
                        other
                            .interruption
                            .get_or_insert_with(|| "另一路达到 WAV 长度上限，会话已中断".into());
                    }
                }
                Err(error) => {
                    m.level = 0.0;
                    l.interruption
                        .get_or_insert_with(|| error.chars().take(500).collect());
                    l.save_error = Some(error.clone());
                    m.refresh_error();
                    m.phase = Phase::Stopping;
                    return Err(error);
                }
            }
        }
        let Some(l) = m.lanes.get_mut(lane) else {
            return Ok(());
        };
        l.next_sequence += 1;
        l.save_error = None;
        let rate = l.sample_rate.unwrap_or(16000);
        m.refresh_error();
        let id = m.current_record_id.clone();
        let mic_mode = m.mode;
        let created = *m.segment_started_at.get_or_insert(self.last_now_sec);
        let written =
            lane == "microphone" && !matches!(m.phase, Phase::Cancelling | Phase::CapacityReached);
        let rotate = self
            .all_day
            .run
            .as_ref()
            .is_some_and(|r| r.source == "microphone" && !r.stopping)
            && m.lanes
                .get("microphone")
                .and_then(|l| l.asset.as_ref())
                .is_some_and(|a| a.duration_ms() >= crate::all_day::SEGMENT_MS);
        if written {
            if self.workspace().record(&id).is_none() {
                let group = self.all_day_group("microphone");
                let record_title = self.platform.mic_recording_label();
                self.commit(|w| {
                    w.insert_record(
                        id.clone(),
                        record_title,
                        RecordOrigin::Microphone,
                        0,
                        created,
                        0,
                    )?;
                    if let Some(group) = group {
                        if w.record(&id).is_some_and(|r| r.all_day.is_none()) {
                            w.group_all_day(&id, group)?;
                        }
                    } else if let Some(cm) = mic_mode {
                        w.set_record_mode(&id, cm.to_record_mode())?;
                    }
                    Ok(())
                })?;
            }
            let pcm: Vec<u8> = if rate == 16000 {
                samples.iter().flat_map(|s| s.to_le_bytes()).collect()
            } else {
                let wave = koe_engine::wav::OpusWave::wav_header_with_rate(
                    (samples.len() * 2) as u32,
                    rate,
                )
                .to_vec();
                let mut bytes = wave;
                bytes.extend(samples.iter().flat_map(|s| s.to_le_bytes()));
                koe_engine::wav::parse_pcm_wave(&bytes)
                    .map_err(|e| format!("音频格式无效：{e:?}"))?
                    .mono_16khz()
            };
            self.feed_speech(&id, &pcm, Some(CaptureOrigin::Microphone))?;
        }
        if rotate {
            self.rotate_microphone_segment()?;
        }
        Ok(())
    }
    pub(super) fn microphone_failed(
        &mut self,
        record: &str,
        session: &str,
        lane: &str,
        message: String,
        epoch: Option<u64>,
    ) {
        let Some(m) = &mut self.microphone else {
            return;
        };
        if !m.matches(record, session, lane) || (m.clock_ns.is_some() && epoch != Some(m.epoch)) {
            return;
        }
        let Some(l) = m.lanes.get_mut(lane) else {
            return;
        };
        if l.producer_stopped {
            return;
        }
        m.level = 0.0;
        l.interruption.get_or_insert_with(|| {
            let text: String = message.trim().chars().take(500).collect();
            if text.is_empty() {
                "音源中断".into()
            } else {
                text
            }
        });
        if !matches!(
            m.phase,
            Phase::Cancelling | Phase::Saving | Phase::CapacityReached
        ) && m.all_lanes_failed_or_stopped()
        {
            m.phase = Phase::Stopping;
        }
    }
    pub(super) fn microphone_stopped(
        &mut self,
        record: &str,
        session: &str,
        lane: &str,
        sequence: u64,
        epoch: Option<u64>,
    ) -> Result<(), String> {
        let Some(m) = &mut self.microphone else {
            return Ok(());
        };
        if !m.matches(record, session, lane) || (m.clock_ns.is_some() && epoch != Some(m.epoch)) {
            return Ok(());
        }
        let Some(l) = m.lanes.get_mut(lane) else {
            return Ok(());
        };
        if sequence != l.next_sequence {
            return Err("仍有音频等待保存".into());
        }
        m.level = 0.0;
        if !matches!(
            m.phase,
            Phase::Stopping | Phase::CapacityReached | Phase::Cancelling | Phase::Saving
        ) {
            l.interruption.get_or_insert_with(|| "音源意外停止".into());
        }
        l.producer_stopped = true;
        if matches!(m.phase, Phase::Stopping | Phase::CapacityReached)
            || (m.phase != Phase::Cancelling && m.all_lanes_failed_or_stopped())
        {
            m.phase = Phase::Stopping;
        } else if m.phase == Phase::Starting && m.lanes_ready() {
            m.phase = Phase::Recording;
        } else if m.phase == Phase::Pausing && m.lanes_paused() {
            m.phase = Phase::Paused;
            return Ok(());
        }
        if !m.lanes.values().all(|l| l.producer_stopped) {
            return Ok(());
        }
        if m.phase != Phase::Cancelling {
            m.phase = Phase::Saving;
        }
        self.save_microphone()
    }
    pub(super) fn save_microphone(&mut self) -> Result<(), String> {
        let Some(mut m) = self.microphone.take() else {
            return Ok(());
        };
        let result: Result<(), String> = (|| {
            if !m.lanes.values().all(|l| l.producer_stopped) {
                let mut recreated = false;
                for l in m
                    .lanes
                    .values_mut()
                    .filter(|l| !l.producer_stopped && l.asset.is_none())
                {
                    if let Some(rate) = l.sample_rate {
                        l.asset = Some(CaptureAsset::create(&self.root, &l.asset_id, rate)?);
                        l.save_error = None;
                        recreated = true;
                    }
                }
                m.refresh_error();
                return if recreated {
                    Ok(())
                } else {
                    Err("正在等待音源停止并排空音频".into())
                };
            }
            if m.phase == Phase::Cancelling
                || m.lanes
                    .values()
                    .all(|l| l.asset.as_ref().is_none_or(|a| a.is_empty()))
            {
                if m.phase == Phase::Cancelling {
                    let purged_id = m.current_record_id.clone();
                    self.cancel_capture_speech(&purged_id);
                    if self.workspace().record(&purged_id).is_some() {
                        self.commit(|w| {
                            w.trash_record(&purged_id, 1)?;
                            w.purge_record(&purged_id).map(|_| ())
                        })?;
                    }
                    self.detach_records_from_session(&std::collections::BTreeSet::from([
                        purged_id,
                    ]));
                }
                for l in m.lanes.values_mut() {
                    if let Some(asset) = &mut l.asset {
                        asset.discard()?;
                    }
                }
                let reasons: Vec<_> = m
                    .lanes
                    .iter()
                    .filter_map(|(name, l)| {
                        l.interruption
                            .as_ref()
                            .map(|reason| format!("{name}: {reason}"))
                    })
                    .collect();
                self.notice = Some(if m.phase == Phase::Cancelling || reasons.is_empty() {
                    "未保存空录音或已取消的录音".into()
                } else {
                    format!("未保存录音：{}", reasons.join("；"))
                });
                return Ok(());
            }
            let mut outcomes = Vec::new();
            for (name, l) in &mut m.lanes {
                let nonempty = l.asset.as_ref().is_some_and(|a| !a.is_empty());
                if let Some(asset) = &mut l.asset {
                    if nonempty {
                        asset.publish()?;
                    } else {
                        asset.discard()?;
                    }
                }
                outcomes.push(CaptureLaneRecord {
                    lane: name.clone(),
                    timeline: l.timeline.clone(),
                    asset_id: nonempty.then(|| l.asset_id.clone()),
                    sample_rate: l.sample_rate,
                    duration_ms: l.asset.as_ref().map_or(0, |a| a.duration_ms()),
                    interruption: l
                        .interruption
                        .clone()
                        .or_else(|| (!nonempty).then(|| "该路没有收到音频".into())),
                });
            }
            let duration = outcomes
                .iter()
                .map(|l| {
                    l.timeline
                        .last()
                        .and_then(|s| s.end_ns(l.sample_rate?))
                        .map_or(l.duration_ms, |n| n / 1_000_000)
                })
                .max()
                .unwrap_or(0);
            let partial = outcomes.iter().any(|l| l.interruption.is_some());
            let group = self.all_day_group("microphone");
            let mic_mode = m.mode;
            let record_title = if m.lanes.len() > 1 {
                self.platform.dual_recording_label()
            } else {
                self.platform.mic_recording_label()
            };
            self.commit(|w| {
                w.insert_record(
                    m.current_record_id.clone(),
                    record_title,
                    RecordOrigin::Microphone,
                    0,
                    m.segment_started_at.unwrap_or(m.created_at),
                    duration,
                )?;
                w.finish_capture(&m.current_record_id, duration, &[])?;
                if let Some(group) = group {
                    if w.record(&m.current_record_id)
                        .is_some_and(|r| r.all_day.is_none())
                    {
                        w.group_all_day(&m.current_record_id, group)?;
                    }
                } else if let Some(cm) = mic_mode {
                    w.set_record_mode(&m.current_record_id, cm.to_record_mode())?;
                }
                w.set_capture_lanes(&m.current_record_id, outcomes)
            })?;
            if mic_mode == Some(CaptureMode::QuickNote) {
                self.selection.selected_quick_note_record = Some(m.current_record_id.clone());
            } else if mic_mode == Some(CaptureMode::Meeting) {
                self.selection.selected_live_minutes_record = Some(m.current_record_id.clone());
            }
            for l in m.lanes.values() {
                if let Some(asset) = &l.asset {
                    asset.release_staging();
                }
            }
            self.finish_speech(&m.current_record_id);
            self.capture_saved(&m.current_record_id);
            self.poll_captures();
            if m.mode.is_none() && self.selection.location.page != Page::LiveMinutes {
                self.open_record(&m.current_record_id, None)?;
            }
            self.notice = Some(if partial {
                "采集中断，已保存收到的分路音频".into()
            } else {
                "录音已保存到本机".into()
            });
            Ok(())
        })();
        if result.is_err() || !m.lanes.values().all(|l| l.producer_stopped) {
            if let Err(error) = &result {
                m.save_error = Some(error.clone());
            }
            self.microphone = Some(m);
        }
        result
    }
    fn rotate_microphone_segment(&mut self) -> Result<(), String> {
        let Some(mut m) = self.microphone.take() else {
            return Ok(());
        };
        let result = (|| {
            let lane = m.lanes.get_mut("microphone").ok_or("缺少麦克风音源")?;
            let asset = lane.asset.as_mut().ok_or("音频尚未就绪")?;
            asset.publish()?;
            let timeline_end = lane
                .timeline
                .last()
                .and_then(|span| span.end_ns(lane.sample_rate?))
                .unwrap_or(asset.duration_ms() * 1_000_000);
            let duration = timeline_end / 1_000_000;
            let outcome = CaptureLaneRecord {
                lane: "microphone".into(),
                timeline: lane.timeline.clone(),
                asset_id: Some(lane.asset_id.clone()),
                sample_rate: lane.sample_rate,
                duration_ms: asset.duration_ms(),
                interruption: None,
            };
            self.commit(|w| {
                w.finish_capture(&m.current_record_id, duration, &[])?;
                w.set_capture_lanes(&m.current_record_id, vec![outcome])
            })?;
            asset.release_staging();
            self.finish_speech(&m.current_record_id);
            self.capture_saved(&m.current_record_id);
            self.poll_captures();
            m.segment_offset_ns = m.segment_offset_ns.saturating_add(timeline_end);
            let group = self.all_day_group("microphone").ok_or("全天听记已停止")?;
            let next = format!("{}-{}", group.run_id, group.ordinal);
            lane.asset = Some(CaptureAsset::create(
                &self.root,
                &next,
                lane.sample_rate.ok_or("音频尚未就绪")?,
            )?);
            lane.asset_id = next.clone();
            lane.timeline.clear();
            m.current_record_id = next;
            m.segment_started_at = None;
            Ok(())
        })();
        self.microphone = Some(m);
        result
    }
    pub(super) fn microphone_status(&self) -> Option<MicrophoneStatus<'_>> {
        let m = self.microphone.as_ref()?;
        let duration_ms = m
            .lanes
            .values()
            .map(|l| {
                l.timeline
                    .last()
                    .and_then(|s| s.end_ns(l.sample_rate?))
                    .map_or_else(
                        || l.asset.as_ref().map_or(0, |a| a.duration_ms()),
                        |n| n / 1_000_000,
                    )
            })
            .max()
            .unwrap_or(0);
        let (input_label, input_badge) = if m.input_id.is_empty() {
            if let Some(def) = self.capture_studio.inputs.iter().find(|i| i.is_default) {
                (def.name.clone(), def.transport.badge(&self.platform))
            } else {
                ("系统默认麦克风".to_string(), "系统默认".to_string())
            }
        } else if let Some(found) = self
            .capture_studio
            .inputs
            .iter()
            .find(|i| i.id == m.input_id)
        {
            (found.name.clone(), found.transport.badge(&self.platform))
        } else {
            (self.platform.mic_label(), "音频输入".to_string())
        };
        Some(MicrophoneStatus {
            phase: match m.phase {
                Phase::Starting => "starting",
                Phase::Recording => "recording",
                Phase::Pausing => "pausing",
                Phase::Paused => "paused",
                Phase::Stopping | Phase::CapacityReached => "stopping",
                Phase::Cancelling => "cancelling",
                Phase::Saving => "saving",
            },
            duration_ms: duration_ms + m.segment_offset_ns / 1_000_000,
            input_label,
            input_badge,
            interruption: m.lanes.values().find_map(|l| l.interruption.as_deref()),
        })
    }
    pub(super) fn microphone_json(&self, status: Option<&MicrophoneStatus<'_>>) -> Value {
        let Some((m, status)) = self.microphone.as_ref().zip(status) else {
            return Value::Null;
        };
        let lanes: BTreeMap<_,_> = m.lanes.iter().map(|(name,l)| (name, json!({"nextSequence":l.next_sequence,"sampleRate":l.sample_rate,"durationMs":l.asset.as_ref().map_or(0,|a|a.duration_ms()),"stopped":l.producer_stopped,"error":l.save_error,"interruption":l.interruption,"started":l.sample_rate.is_some()}))).collect();
        let next_sequence = m.lanes.get("microphone").map_or(0, |mic| mic.next_sequence);
        json!({"recordId":m.record_id,"sessionId":m.session_id,"epoch":m.epoch,"clockNs":m.clock_ns,"lane":"microphone","inputId":m.input_id,"inputLabel":status.input_label,"inputBadge":status.input_badge,
            "phase":status.phase,"nextSequence":next_sequence,"durationMs":status.duration_ms,"level":m.level,"error":m.save_error,"interruption":status.interruption,
            "includeSystem":m.lanes.contains_key("system"),"lanes":lanes})
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn microphone_json_does_not_panic_when_microphone_lane_is_missing() {
        let dir = std::env::temp_dir().join(format!(
            "koe-mic-missing-lane-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let mut runtime = KoeRuntime::open(&dir).unwrap();
        let now = 1_800_000_000;
        let _ = runtime.dispatch_json(r#"{"type":"start_microphone","inputId":""}"#, now);
        runtime
            .microphone
            .as_mut()
            .expect("active microphone session")
            .lanes
            .remove("microphone");
        let status = runtime.microphone_status();
        let projected = runtime.microphone_json(status.as_ref());
        assert_eq!(projected["nextSequence"], 0);
        drop(runtime);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
