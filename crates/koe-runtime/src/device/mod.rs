pub(crate) mod custody;

use koe_engine::{
    commands::DeviceCommands,
    crypto::DeviceCrypto,
    session::{
        CaptureEvent, ConnectionPhaseTag, FinalizedRecording, SessionIngestOutcome,
        TransferPhaseTag, TransportSession,
    },
};
use serde_json::{json, Value};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum DeviceModalState {
    #[default]
    Hidden,
    ConnectGuide,
    Onboarding {
        step: u8,
    },
}

pub(crate) struct OnboardingStepSpec {
    pub title: &'static str,
    pub subtitle: &'static str,
    pub image_name: &'static str,
    pub highlight_target: &'static str,
    pub primary_label: &'static str,
}

pub(crate) const ONBOARDING_STEPS: [OnboardingStepSpec; 5] = [
    OnboardingStepSpec { title: "连接成功", subtitle: "录音豆与充电仓已就绪", image_name: "guide_connect_device", highlight_target: "none", primary_label: "继续" },
    OnboardingStepSpec { title: "开始录音", subtitle: "按一下录音豆侧边按键即可开始或结束录音", image_name: "guide_record", highlight_target: "record_button", primary_label: "下一步" },
    OnboardingStepSpec { title: "标记重点", subtitle: "录音过程中双击录音豆正面面板，自动标记关键时刻", image_name: "guide_mark", highlight_target: "center", primary_label: "下一步" },
    OnboardingStepSpec { title: "佩戴麦克风", subtitle: "支持衣领夹持或磁吸佩戴，保持麦克风朝向说话人", image_name: "guide_wear", highlight_target: "none", primary_label: "下一步" },
    OnboardingStepSpec { title: "下载录音", subtitle: "连接 Koe 后自动同步录音目录并取回音频生成纪要", image_name: "guide_sync", highlight_target: "none", primary_label: "我知道了" },
];

pub(crate) struct DeviceRuntime {
    pub session: TransportSession,
    pub awaiting_stop: bool,
    pub connection: Option<String>,
    pub device_name: Option<String>,
    pub modal: DeviceModalState,
    pub guide_user_requested: bool,
    pub onboarding_shown_in_session: bool,
    pub outbound: Vec<Vec<u8>>,
    pub finalized: Vec<FinalizedRecording>,
    pub explicitly_disconnected: bool,
    pub captures: std::collections::VecDeque<CaptureEvent>,
    pub auto_pull_attempted: std::collections::BTreeSet<u32>,
    pending_start_ms: u64,
    handshake_retry_ms: u64,
    handshake_retried: bool,
    status_poll_elapsed_ms: u64,
}

impl Default for DeviceRuntime {
    fn default() -> Self {
        Self {
            session: TransportSession::with_decoder_factory(Some(koe_opus::create_libopus_decoder)),
            awaiting_stop: false,
            connection: None,
            device_name: None,
            modal: DeviceModalState::Hidden,
            guide_user_requested: false,
            onboarding_shown_in_session: false,
            outbound: Vec::new(),
            finalized: Vec::new(),
            explicitly_disconnected: false,
            captures: Default::default(),
            auto_pull_attempted: Default::default(),
            pending_start_ms: 0,
            handshake_retry_ms: 0,
            handshake_retried: false,
            status_poll_elapsed_ms: 0,
        }
    }
}

impl DeviceRuntime {
    pub(super) fn reset_failed_transfer_if_idle(&mut self, quitting: bool) {
        if !quitting
            && matches!(
                self.session.transfer.phase,
                TransferPhaseTag::Failed
            )
        {
            self.session.reset_active_transfer();
        }
    }

    pub fn stop_recording(&mut self) {
        if self.awaiting_stop {
            self.outbound.push(DeviceCommands::pause_record());
            return;
        }
        self.awaiting_stop |= self.session.device_recording_active
            || self.session.pending_realtime_subscribe
            || (self.session.active_is_realtime && !self.session.transfer.quiet_draining);
        let outcome = self.session.stop_realtime_recording();
        self.accept(outcome);
    }

    pub fn is_connected(&self) -> bool {
        self.session.session_key.is_some()
            && self.session.connection_phase != ConnectionPhaseTag::Handshaking
    }

    pub fn open_guide(&mut self) {
        if self.is_connected() {
            self.modal = DeviceModalState::Onboarding { step: 0 };
            self.outbound.push(DeviceCommands::get_device_info());
        } else {
            self.modal = DeviceModalState::ConnectGuide;
            self.guide_user_requested = true;
        }
    }

    pub fn onboarding_next(&mut self) {
        self.modal = match self.modal {
            DeviceModalState::Onboarding { step }
                if usize::from(step) + 1 < ONBOARDING_STEPS.len() =>
            {
                DeviceModalState::Onboarding { step: step + 1 }
            }
            _ => DeviceModalState::Hidden,
        };
        self.guide_user_requested = false;
    }

    pub fn close_guide(&mut self) {
        self.modal = DeviceModalState::Hidden;
        self.guide_user_requested = false;
    }

    pub fn refresh(&mut self) {
        self.auto_pull_attempted.clear();
        if self.session.session_key.is_some() {
            self.outbound.push(DeviceCommands::get_device_info());
            let frame = self.session.request_full_catalog();
            if !frame.is_empty() {
                self.outbound.push(frame);
            }
        }
    }

    pub fn disconnect(&mut self) {
        self.explicitly_disconnected = true;
        self.connection = None;
        self.awaiting_stop = false;
        self.pending_start_ms = 0;
        self.outbound.clear();
        self.auto_pull_attempted.clear();
        self.handshake_retry_ms = 0;
        self.handshake_retried = false;
        self.status_poll_elapsed_ms = 0;
        self.session.on_disconnected();
        self.collect_finalized();
        self.modal = DeviceModalState::Hidden;
        self.guide_user_requested = false;
    }

    pub fn guide_json(&self) -> Value {
        match self.modal {
            DeviceModalState::Hidden => Value::Null,
            DeviceModalState::ConnectGuide => json!({
                "mode": "connect_guide",
                "step": 0,
                "totalSteps": ONBOARDING_STEPS.len(),
                "title": "连接 Soundcore Work",
                "subtitle": "将麦克风放入充电仓，短按充电仓下方按钮完成连接",
                "imageName": "guide_connect_case",
                "highlightTarget": "case_button",
                "primaryLabel": "重新扫描"
            }),
            DeviceModalState::Onboarding { step } => {
                let idx = usize::from(step).min(ONBOARDING_STEPS.len() - 1);
                let spec = &ONBOARDING_STEPS[idx];
                json!({
                    "mode": "onboarding",
                    "step": idx,
                    "totalSteps": ONBOARDING_STEPS.len(),
                    "title": spec.title,
                    "subtitle": spec.subtitle,
                    "imageName": spec.image_name,
                    "highlightTarget": spec.highlight_target,
                    "primaryLabel": spec.primary_label
                })
            }
        }
    }

    pub fn event(
        &mut self,
        event: &str,
        connection: &str,
        device_name: Option<&str>,
        env: &crate::observability::env::RuntimeEnv,
    ) -> Result<(), String> {
        if let Some(name) = device_name.map(str::trim).filter(|s| !s.is_empty()) {
            self.device_name = Some(name.replace('·', " "));
        }
        match event {
            "scanning" => {
                self.explicitly_disconnected = false;
                if !self.is_connected() {
                    self.connection = Some(connection.to_owned());
                    self.outbound.clear();
                    self.handshake_retry_ms = 0;
                    self.handshake_retried = false;
                    self.session.on_scanning();
                }
            }
            "connecting" => {
                self.explicitly_disconnected = false;
                self.connection = Some(connection.to_string());
                self.outbound.clear();
                self.handshake_retry_ms = 0;
                self.handshake_retried = false;
                self.session.on_connecting();
            }
            "ready"
                if self.connection.as_deref() == Some(connection)
                    && self.session.connection_phase != ConnectionPhaseTag::Scanning =>
            {
                self.explicitly_disconnected = false;
                let mut private_key = [0u8; 32];
                env.fill_random(&mut private_key)?;
                let frames = self
                    .session
                    .on_gatt_ready(private_key)
                    .ok_or("设备握手未能启动")?;
                self.handshake_retry_ms = 0;
                self.handshake_retried = false;
                self.outbound.extend(frames);
            }
            "disconnected" if self.connection.as_deref() == Some(connection) => {
                self.connection = None;
                self.outbound.clear();
                self.auto_pull_attempted.clear();
                self.handshake_retry_ms = 0;
                self.handshake_retried = false;
                self.status_poll_elapsed_ms = 0;
                self.session.on_transport_interrupted();
                self.collect_finalized();
            }
            "ready" | "disconnected" => return Ok(()),
            _ => return Err("无法识别设备事件".into()),
        }
        Ok(())
    }

    pub fn ingest(&mut self, bytes: &[u8], now: u64) -> bool {
        if self.explicitly_disconnected {
            return false;
        }
        let outcome = self.session.ingest_ble_chunk(bytes, now);
        self.accept(outcome)
    }

    pub fn tick(&mut self, elapsed_ms: u64, now: u64) -> Result<bool, String> {
        if self.session.pending_realtime_subscribe && self.session.active_file_id.is_none() {
            self.pending_start_ms = self.pending_start_ms.saturating_add(elapsed_ms);
            if self.pending_start_ms >= 15_000 {
                self.stop_recording();
                self.pending_start_ms = 0;
                return Err("录音豆未确认开始录音，已发送停止指令；请检查设备后重试".into());
            }
        } else {
            self.pending_start_ms = 0;
        }

        let mut handshake_retried_now = false;
        if self.session.connection_phase == ConnectionPhaseTag::Handshaking {
            self.handshake_retry_ms = self.handshake_retry_ms.saturating_add(elapsed_ms);
            if self.handshake_retry_ms >= 2_000 && !self.handshake_retried {
                self.handshake_retried = true;
                if self.session.session_key.is_none() {
                    if let Some(priv_key) = self.session.ecdh_private_key {
                        if let Some(pub_key) = DeviceCrypto::p256_public_key(&priv_key) {
                            self.outbound
                                .push(DeviceCommands::notify_encrypt_public_key(&pub_key));
                            handshake_retried_now = true;
                        }
                    }
                }
                if self.session.telemetry.is_none() {
                    self.outbound.push(DeviceCommands::get_device_info());
                    handshake_retried_now = true;
                }
            }
        } else {
            self.handshake_retry_ms = 0;
            self.handshake_retried = false;
        }

        let outcome = self.session.poll_timers(elapsed_ms, now);
        let mut changed = self.accept(outcome) || handshake_retried_now;
        if self.connection.is_some()
            && self.is_connected()
            && self.outbound.is_empty()
            && !self.session.pending_realtime_subscribe
            && !self.session.is_catalog_loading()
            && self.session.active_file_id.is_none()
            && matches!(
                self.session.transfer.phase,
                TransferPhaseTag::Idle | TransferPhaseTag::Failed
            )
        {
            self.status_poll_elapsed_ms = self.status_poll_elapsed_ms.saturating_add(elapsed_ms);
            if self.status_poll_elapsed_ms >= 5_000 {
                self.status_poll_elapsed_ms = 0;
                self.outbound.push(DeviceCommands::get_device_info());
                changed = true;
            }
        } else {
            self.status_poll_elapsed_ms = 0;
        }
        Ok(changed)
    }

    pub fn accept(&mut self, outcome: SessionIngestOutcome) -> bool {
        let changed = outcome != SessionIngestOutcome::default();
        if outcome.recording_stopped {
            self.awaiting_stop = false;
        } else if outcome.session_key_established && self.awaiting_stop {
            self.outbound.push(DeviceCommands::pause_record());
        }
        self.outbound.extend(outcome.outbound_tx_frames);
        if (outcome.telemetry_updated || outcome.session_key_established)
            && self.is_connected()
            && self.session.telemetry.is_some()
        {
            self.handshake_retry_ms = 0;
            self.handshake_retried = false;
            if self.modal == DeviceModalState::ConnectGuide
                || (self.guide_user_requested && !self.onboarding_shown_in_session)
            {
                self.modal = DeviceModalState::Onboarding { step: 0 };
                self.onboarding_shown_in_session = true;
                self.guide_user_requested = false;
            }
        }
        if outcome.session_key_established
            && self.is_connected()
            && self.session.is_offline_pull_suspended()
        {
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
    }
}

impl crate::KoeRuntime {
    pub(crate) fn device_json(&self) -> Value {
        let (live_record_id, live_duration_ms) = self.live_bean_capture_progress();
        self.device_json_with_live(live_record_id, live_duration_ms)
    }

    pub(crate) fn device_json_with_live(
        &self,
        live_record_id: Option<&str>,
        live_duration_ms: u64,
    ) -> Value {
        let device = &self.device.session;
        let (device_phase, device_state) = match device.connection_phase {
            ConnectionPhaseTag::Disconnected => ("disconnected", "未连接"),
            ConnectionPhaseTag::Scanning => ("scanning", "正在查找录音豆"),
            ConnectionPhaseTag::Connecting => ("connecting", "正在连接"),
            ConnectionPhaseTag::Handshaking => ("handshaking", "正在握手"),
            ConnectionPhaseTag::Connected => ("connected", "已连接"),
        };
        let connected = self.device.is_connected();
        let telemetry = device.telemetry.as_ref();
        let battery_pct = telemetry.and_then(|t| t.battery);
        let box_battery_pct = telemetry.and_then(|t| t.box_battery);
        let status_detail = match device.connection_phase {
            ConnectionPhaseTag::Disconnected => {
                "将麦克风放入充电仓，短按下方按钮开启广播".to_string()
            }
            ConnectionPhaseTag::Scanning => "正在等待录音豆蓝牙广播…".to_string(),
            ConnectionPhaseTag::Connecting => "正在建立蓝牙连接…".to_string(),
            ConnectionPhaseTag::Handshaking => "正在完成安全握手与电量同步…".to_string(),
            ConnectionPhaseTag::Connected => match (battery_pct, box_battery_pct) {
                (Some(mic), Some(case_pct)) => format!("麦克风 {mic}%  充电仓 {case_pct}%"),
                (Some(mic), None) => format!("麦克风 {mic}%"),
                _ => "已就绪".to_string(),
            },
        };
        let device_name = self
            .device
            .device_name
            .as_deref()
            .unwrap_or("Soundcore Work");
        let files: Vec<_> = device
            .catalog
            .iter()
            .map(|f| {
                let synced = self.is_device_file_synced(f.file_id);
                let downloading = device.active_file_id == Some(f.file_id)
                    && matches!(device.transfer.phase, TransferPhaseTag::PullingOffline);
                let record_id = if synced {
                    self.workspace()
                        .records()
                        .values()
                        .filter(|r| {
                            r.is_live()
                                && r.origin == koe_engine::product::RecordOrigin::Bean
                                && r.all_day.is_none()
                                && r.aggregate.file_id == f.file_id
                        })
                        .max_by_key(|r| r.aggregate.created_at_epoch_sec)
                        .map(|r| r.aggregate.recording_id.clone())
                } else {
                    None
                };
                json!({
                    "id": f.file_id,
                    "title": format!("录音 {}", f.file_id),
                    "durationMs": f.duration_ms,
                    "synced": synced,
                    "downloading": downloading,
                    "recordId": record_id,
                })
            })
            .collect();
        let storage_used_ratio = telemetry.and_then(|t| {
            let total = u64::from(t.total_memory_kb?);
            let free = u64::from(t.free_memory_kb?).min(total);
            (total > 0).then_some(((total - free) as f64 / total as f64).clamp(0.0, 1.0))
        });
        let progress = if device.transfer.expected_wire_bytes > 0 {
            (f64::from(device.transfer.received_wire_bytes)
                / f64::from(device.transfer.expected_wire_bytes))
            .clamp(0.0, 1.0)
        } else {
            0.0
        };
        let transfer_phase = if device.is_offline_pull_suspended() {
            "suspended"
        } else {
            match device.transfer.phase {
                TransferPhaseTag::Idle | TransferPhaseTag::QueryingCatalog => "idle",
                TransferPhaseTag::StreamingRealtime => "streaming_realtime",
                TransferPhaseTag::PullingOffline => "pulling_offline",
                TransferPhaseTag::Failed => "failed",
            }
        };
        let device_busy = self.is_device_busy();
        let device_recording = device.device_recording_active;
        let teardown_stop_frames_hex = if device_recording {
            vec![koe_engine::prng::to_hex_upper(
                &DeviceCommands::pause_record(),
            )]
        } else {
            Vec::new()
        };
        json!({
            "phase": device_phase,
            "state": device_state,
            "statusDetail": status_detail,
            "connected": connected,
            "busy": device_busy,
            "stopping": self.device.awaiting_stop,
            "recording": device_recording,
            "transferPhase": transfer_phase,
            "transferErrorCode": device.transfer.error_code,
            "audioDecryptReady": device.active_file_key.is_some() && device.active_nonce.is_some(),
            "liveDurationMs": live_duration_ms,
            "liveBytes": device.transfer.received_wire_bytes,
            "liveRecordId": live_record_id,
            "deviceName": device_name,
            "batteryPercent": battery_pct,
            "charging": telemetry.is_some_and(|t| t.charging),
            "boxBatteryPercent": box_battery_pct,
            "boxCharging": telemetry.is_some_and(|t| t.box_charging),
            "serialNumber": telemetry.map(|t| t.serial_number.clone()).unwrap_or_default(),
            "firmwareVersion": telemetry.map(|t| t.firmware_version.clone()).unwrap_or_default(),
            "storageLabel": telemetry.map(|t| t.storage_label()).unwrap_or_else(|| "—".to_string()),
            "storageUsedRatio": storage_used_ratio,
            "files": files,
            "progress": progress,
            "autoConnect": self.workspace().ble_auto_connect(),
            "teardownStopFramesHex": teardown_stop_frames_hex,
            "guide": self.device.guide_json(),
        })
    }
}
