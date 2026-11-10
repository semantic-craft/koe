use super::*;
use koe_client_services::capture_asset::{AppendOutcome, CaptureAsset};
use koe_engine::product::CaptureLaneRecord;
use serde_json::json;
use std::collections::BTreeMap;

#[derive(PartialEq, Eq)]
pub(super) enum Phase {
    Starting,
    Recording,
    Stopping,
    CapacityReached,
    Cancelling,
    Saving,
}
struct Lane {
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
    phase: Phase,
    lanes: BTreeMap<String, Lane>,
    pub(super) save_error: Option<String>,
}
impl Microphone {
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
            phase: Phase::Starting,
            lanes,
            save_error: None,
        });
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
        record: &str,
        session: &str,
        lane: &str,
        sequence: u64,
        samples: &[i16],
    ) -> Result<(), String> {
        let Some(m) = &mut self.microphone else {
            return Ok(());
        };
        if !m.matches(record, session, lane) {
            return Ok(());
        }
        let l = m.lanes.get_mut(lane).unwrap();
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
            let result = l.asset.as_mut().ok_or("音频尚未就绪")?.append(samples);
            match result {
                Ok(AppendOutcome::Written) => {}
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
    ) {
        let Some(m) = &mut self.microphone else {
            return;
        };
        if !m.matches(record, session, lane) {
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
    ) -> Result<(), String> {
        let Some(m) = &mut self.microphone else {
            return Ok(());
        };
        if !m.matches(record, session, lane) {
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
                    asset_id: nonempty.then(|| l.asset_id.clone()),
                    sample_rate: l.sample_rate,
                    duration_ms: l.asset.as_ref().map_or(0, |a| a.duration_ms()),
                    interruption: l
                        .interruption
                        .clone()
                        .or_else(|| (!nonempty).then(|| "该路没有收到音频".into())),
                });
            }
            let duration = outcomes.iter().map(|l| l.duration_ms).max().unwrap_or(0);
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
        let lanes: BTreeMap<_,_> = m.lanes.iter().map(|(name,l)| (name, json!({"nextSequence":l.next_sequence,"durationMs":l.asset.as_ref().map_or(0,|a|a.duration_ms()),"stopped":l.producer_stopped,"error":l.save_error,"interruption":l.interruption,"started":l.sample_rate.is_some()}))).collect();
        let mic = &m.lanes["microphone"];
        json!({"recordId":m.record_id,"sessionId":m.session_id,"lane":"microphone","inputId":m.input_id,
            "phase":match m.phase {Phase::Starting=>"starting",Phase::Recording=>"recording",Phase::Stopping | Phase::CapacityReached=>"stopping",Phase::Cancelling=>"cancelling",Phase::Saving=>"saving"},
            "nextSequence":mic.next_sequence,"durationMs":mic.asset.as_ref().map_or(0,|a|a.duration_ms()),"error":m.save_error,"interruption":mic.interruption,"lanes":lanes})
    }
}
