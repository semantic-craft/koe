use super::*;
use crate::command::CaptureTiming;
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
    session_id: String,
    input_id: String,
    created_at: u64,
    clock_ns: Option<u64>,
    epoch: u64,
    epoch_offset_ns: u64,
    phase: Phase,
    lanes: BTreeMap<String, Lane>,
    pub(super) save_error: Option<String>,
}
impl Microphone {
    pub(super) fn owns_id(&self, id: &str) -> bool {
        self.record_id == id || self.lanes.values().any(|l| l.asset_id == id)
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
    fn refresh_error(&mut self) {
        self.save_error = self.lanes.values().find_map(|l| l.save_error.clone());
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
        if self.microphone.is_some() {
            return Err("请先结束当前录音并完成保存".into());
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
            session_id: format!("{id}-session"),
            input_id,
            created_at: now,
            clock_ns,
            epoch: 0,
            epoch_offset_ns: 0,
            phase: Phase::Starting,
            lanes,
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
        if m.phase != Phase::Recording || m.clock_ns.is_none() {
            return Err("当前录音尚不能暂停".into());
        }
        m.phase = Phase::Pausing;
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
        let l = m.lanes.get_mut(lane).unwrap();
        if sequence != l.next_sequence {
            return Err("仍有音频等待保存".into());
        }
        l.paused = true;
        if m.lanes.values().all(|l| l.paused) {
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
            .unwrap_or(m.epoch_offset_ns);
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
        for l in m.lanes.values_mut() {
            l.paused = false;
        }
        Ok(())
    }
    pub(super) fn stop_microphone(&mut self, cancel: bool) -> Result<(), String> {
        if let Some(m) = &mut self.microphone {
            if m.phase == Phase::Saving {
                return Err("正在保存录音，请完成保存后继续".into());
            }
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
        let l = m.lanes.get_mut(lane).unwrap();
        if l.sample_rate.is_some() || l.producer_stopped {
            return Ok(());
        }
        if !(8000..=96000).contains(&rate) {
            l.interruption = Some("音频格式不受支持，未保存该路录音".into());
            m.phase = Phase::Stopping;
            return Err("音频采样率不受支持".into());
        }
        l.sample_rate = Some(rate);
        match CaptureAsset::create(&self.root, &l.asset_id, rate) {
            Ok(asset) => {
                l.asset = Some(asset);
                if m.lanes.values().all(|l| l.asset.is_some()) {
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
        let l = m.lanes.get_mut(lane).unwrap();
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
                            *l.timeline.last_mut().unwrap() = span;
                        } else {
                            l.timeline.push(span);
                        }
                    }
                }
                Ok(AppendOutcome::CapacityReached) => {
                    l.interruption = Some(
                        "录音达到 WAV 长度上限，已保留此前收到的音频。请新建录音继续。".into(),
                    );
                    m.phase = Phase::CapacityReached;
                    // Every lane will lose further callbacks after the shared stop request.
                    for other in m.lanes.values_mut() {
                        other
                            .interruption
                            .get_or_insert_with(|| "另一路达到 WAV 长度上限，会话已中断".into());
                    }
                }
                Err(error) => {
                    // Retrying custody repairs the bytes, not the prematurely ended capture.
                    l.interruption
                        .get_or_insert_with(|| error.chars().take(500).collect());
                    l.save_error = Some(error.clone());
                    m.refresh_error();
                    m.phase = Phase::Stopping;
                    return Err(error);
                }
            }
        }
        let l = m.lanes.get_mut(lane).unwrap();
        l.next_sequence += 1;
        l.save_error = None;
        m.refresh_error();
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
        let l = m.lanes.get_mut(lane).unwrap();
        if l.producer_stopped {
            return;
        }
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
        ) {
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
        let l = m.lanes.get_mut(lane).unwrap();
        if sequence != l.next_sequence {
            return Err("仍有音频等待保存".into());
        }
        if !matches!(
            m.phase,
            Phase::Stopping | Phase::CapacityReached | Phase::Cancelling | Phase::Saving
        ) {
            l.interruption.get_or_insert_with(|| "音源意外停止".into());
        }
        l.producer_stopped = true;
        if m.phase != Phase::Cancelling {
            m.phase = Phase::Stopping;
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
            self.commit(|w| {
                w.insert_record(
                    m.record_id.clone(),
                    if m.lanes.len() > 1 {
                        "Mac 双路录音".into()
                    } else {
                        "Mac 麦克风录音".into()
                    },
                    RecordOrigin::Microphone,
                    0,
                    m.created_at,
                    duration,
                )?;
                w.set_capture_lanes(&m.record_id, outcomes)
            })?;
            for l in m.lanes.values() {
                if let Some(asset) = &l.asset {
                    asset.release_staging();
                }
            }
            self.open_record(&m.record_id, None)?;
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
    pub(super) fn microphone_json(&self) -> Value {
        let Some(m) = &self.microphone else {
            return Value::Null;
        };
        let lanes: BTreeMap<_,_> = m.lanes.iter().map(|(name,l)| (name, json!({"nextSequence":l.next_sequence,"sampleRate":l.sample_rate,"durationMs":l.asset.as_ref().map_or(0,|a|a.duration_ms()),"stopped":l.producer_stopped,"error":l.save_error,"interruption":l.interruption,"started":l.sample_rate.is_some()}))).collect();
        let mic = &m.lanes["microphone"];
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
        json!({"recordId":m.record_id,"sessionId":m.session_id,"epoch":m.epoch,"clockNs":m.clock_ns,"lane":"microphone","inputId":m.input_id,
            "phase":match m.phase {Phase::Starting=>"starting",Phase::Recording=>"recording",Phase::Pausing=>"pausing",Phase::Paused=>"paused",Phase::Stopping | Phase::CapacityReached=>"stopping",Phase::Cancelling=>"cancelling",Phase::Saving=>"saving"},
            "nextSequence":mic.next_sequence,"durationMs":duration_ms,"error":m.save_error,"interruption":mic.interruption,"lanes":lanes})
    }
}
