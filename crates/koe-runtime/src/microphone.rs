use super::*;
use koe_client_services::capture_asset::CaptureAsset;
use serde_json::json;

#[derive(PartialEq, Eq)]
pub(super) enum Phase {
    Starting,
    Recording,
    Stopping,
    Cancelling,
    Saving,
}
pub(super) struct Microphone {
    record_id: String,
    session_id: String,
    input_id: String,
    created_at: u64,
    phase: Phase,
    next_sequence: u64,
    asset: Option<CaptureAsset>,
    sample_rate: Option<u32>,
    producer_stopped: bool,
    pub(super) save_error: Option<String>,
    interruption: Option<String>,
}
impl Microphone {
    fn matches(&self, record: &str, session: &str, lane: &str) -> bool {
        self.record_id == record && self.session_id == session && lane == "microphone"
    }
}
impl KoeRuntime {
    pub(super) fn start_microphone(&mut self, input_id: String, now: u64) -> Result<(), String> {
        if self.microphone.is_some() {
            return Err("请先结束当前麦克风录音并完成保存".into());
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
        self.microphone = Some(Microphone {
            record_id: id.clone(),
            session_id: format!("{id}-session"),
            input_id,
            created_at: now,
            phase: Phase::Starting,
            next_sequence: 0,
            asset: None,
            sample_rate: None,
            producer_stopped: false,
            save_error: None,
            interruption: None,
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
            } else if m.phase != Phase::Cancelling {
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
        if m.phase != Phase::Starting {
            return Ok(());
        }
        m.sample_rate = Some(rate);
        match CaptureAsset::create(&self.root, &m.record_id, rate) {
            Ok(asset) => {
                m.asset = Some(asset);
                m.phase = Phase::Recording;
                Ok(())
            }
            Err(error) => {
                m.phase = Phase::Stopping;
                m.save_error = Some(error.clone());
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
        if m.producer_stopped || m.phase == Phase::Starting {
            return Err("采集会话尚未就绪或已经结束".into());
        }
        if sequence != m.next_sequence {
            return Err("麦克风音频块顺序不连续".into());
        }
        if samples.is_empty() || samples.len() > 8192 {
            return Err("麦克风音频块无效或过大".into());
        }
        if m.phase != Phase::Cancelling {
            let result = m
                .asset
                .as_mut()
                .ok_or("麦克风音频尚未就绪")?
                .append(samples);
            if let Err(error) = result {
                m.save_error = Some(error.clone());
                m.phase = Phase::Stopping;
                return Err(error);
            }
        }
        m.next_sequence += 1;
        m.save_error = None;
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
        m.interruption = Some(message.chars().take(500).collect());
        if m.phase != Phase::Cancelling && m.phase != Phase::Saving {
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
        if sequence != m.next_sequence {
            return Err("仍有麦克风音频等待保存".into());
        }
        m.producer_stopped = true;
        if m.phase != Phase::Cancelling {
            m.phase = Phase::Saving;
        }
        self.save_microphone()
    }
    pub(super) fn save_microphone(&mut self) -> Result<(), String> {
        let Some(mut m) = self.microphone.take() else {
            return Ok(());
        };
        if !m.producer_stopped {
            let result = if m.asset.is_none() {
                m.sample_rate
                    .ok_or_else(|| "正在等待麦克风权限或输入格式".to_string())
                    .and_then(|rate| {
                        m.asset = Some(CaptureAsset::create(&self.root, &m.record_id, rate)?);
                        m.save_error = None;
                        Ok(())
                    })
            } else {
                Err("正在等待麦克风停止并排空音频".into())
            };
            if let Err(error) = &result {
                m.save_error = Some(error.clone());
            }
            self.microphone = Some(m);
            return result;
        }
        let result: Result<(), String> = (|| {
            if m.phase == Phase::Cancelling || m.asset.as_ref().is_none_or(|a| a.is_empty()) {
                if let Some(asset) = &mut m.asset {
                    asset.discard()?;
                }
                self.notice = Some(
                    m.interruption
                        .clone()
                        .unwrap_or_else(|| "未保存空录音或已取消的录音".into()),
                );
                return Ok(());
            }
            let asset = m.asset.as_mut().ok_or("麦克风音频尚未就绪")?;
            asset.publish()?;
            let duration = asset.duration_ms();
            self.commit(|w| {
                w.insert_record(
                    m.record_id.clone(),
                    "Mac 麦克风录音".into(),
                    RecordOrigin::Microphone,
                    0,
                    m.created_at,
                    duration,
                )
            })?;
            asset.release_staging();
            self.open_record(&m.record_id, None)?;
            self.notice = Some(match &m.interruption {
                Some(reason) => format!("采集中断，已保存收到的音频：{reason}"),
                None => "麦克风录音已保存到本机".into(),
            });
            Ok(())
        })();
        if let Err(error) = &result {
            m.save_error = Some(error.clone());
            self.microphone = Some(m);
        }
        result
    }
    pub(super) fn microphone_json(&self) -> Value {
        let Some(m) = &self.microphone else {
            return Value::Null;
        };
        json!({"recordId":m.record_id,"sessionId":m.session_id,"lane":"microphone","inputId":m.input_id,
            "phase":match m.phase {Phase::Starting=>"starting",Phase::Recording=>"recording",Phase::Stopping=>"stopping",Phase::Cancelling=>"cancelling",Phase::Saving=>"saving"},
            "nextSequence":m.next_sequence,"durationMs":m.asset.as_ref().map_or(0,|a|a.duration_ms()),"error":m.save_error,"interruption":m.interruption})
    }
}
