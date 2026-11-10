use koe_engine::session::{
    CaptureEvent, FinalizedRecording, SessionIngestOutcome, TransportSession,
};
use std::{fs::File, io::Read};

pub(crate) struct DeviceRuntime {
    pub session: TransportSession,
    pub connection: Option<String>,
    pub outbound: Vec<Vec<u8>>,
    pub finalized: Vec<FinalizedRecording>,
    pub captures: std::collections::VecDeque<CaptureEvent>,
    pending_start_ms: u64,
}

impl Default for DeviceRuntime {
    fn default() -> Self {
        Self {
            session: TransportSession::with_decoder_factory(Some(koe_opus::create_libopus_decoder)),
            connection: None,
            outbound: Vec::new(),
            finalized: Vec::new(),
            captures: Default::default(),
            pending_start_ms: 0,
        }
    }
}

impl DeviceRuntime {
    pub fn event(&mut self, event: &str, connection: &str) -> Result<(), String> {
        match event {
            "scanning" => self.session.on_scanning(),
            "connecting" => {
                self.connection = Some(connection.to_string());
                self.outbound.clear();
                self.session.on_connecting();
            }
            "ready" if self.connection.as_deref() == Some(connection) => {
                let mut private_key = [0u8; 32];
                File::open("/dev/urandom")
                    .and_then(|mut f| f.read_exact(&mut private_key))
                    .map_err(|_| "无法生成设备连接密钥".to_string())?;
                let frames = self
                    .session
                    .on_gatt_ready(private_key)
                    .ok_or("设备握手未能启动")?;
                self.outbound.extend(frames);
            }
            "disconnected" if self.connection.as_deref() == Some(connection) => {
                self.connection = None;
                self.outbound.clear();
                self.session.on_transport_interrupted();
                self.collect_finalized();
            }
            "ready" | "disconnected" => return Ok(()),
            _ => return Err("无法识别设备事件".into()),
        }
        Ok(())
    }

    pub fn ingest(&mut self, bytes: &[u8], now: u64) -> bool {
        let outcome = self.session.ingest_ble_chunk(bytes, now);
        self.accept(outcome)
    }

    pub fn tick(&mut self, elapsed_ms: u64, now: u64) -> Result<bool, String> {
        if self.session.pending_realtime_subscribe && self.session.active_file_id.is_none() {
            self.pending_start_ms = self.pending_start_ms.saturating_add(elapsed_ms);
            if self.pending_start_ms >= 15_000 {
                let outcome = self.session.stop_realtime_recording();
                self.accept(outcome);
                self.pending_start_ms = 0;
                return Err("录音豆未确认开始录音，已发送停止指令；请检查设备后重试".into());
            }
        } else {
            self.pending_start_ms = 0;
        }
        let outcome = self.session.poll_timers(elapsed_ms, now);
        Ok(self.accept(outcome))
    }

    pub fn accept(&mut self, outcome: SessionIngestOutcome) -> bool {
        let changed = outcome != SessionIngestOutcome::default();
        self.outbound.extend(outcome.outbound_tx_frames);
        if outcome.session_key_established && self.session.is_offline_pull_suspended() {
            if let Some(frame) = self.session.resume_offline_pull() {
                self.outbound.push(frame);
            }
        }
        self.collect_finalized();
        changed
    }

    fn collect_finalized(&mut self) {
        while let Some(recording) = self.session.take_next_finalized() {
            self.finalized.push(recording);
        }
        self.captures.extend(self.session.take_capture_events());
        self.session.take_live_pcm16();
    }
}
