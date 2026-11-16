use super::*;
use crate::{
    capture_studio::CaptureSelection,
    command::CaptureMode,
    live_minutes::{LiveMinutesScope, TranscriptLine},
    microphone::{MicrophoneStatus, Phase},
    projection::{origin, status},
};

const VOICE_INPUT_BOUNDARY_NOTE: &str =
    "Koe 负责维护录音豆低延迟待命音频流、双击控制边沿与本地伴侣桥接通道（koe.sock）。";

fn voice_step(
    number: u8,
    id: &str,
    title: &str,
    status: &str,
    status_label: &str,
    detail: impl Into<String>,
    action: Option<(&str, &str)>,
) -> Value {
    json!({
        "number": number,
        "id": id,
        "title": title,
        "status": status,
        "statusLabel": status_label,
        "detail": detail.into(),
        "actionLabel": action.map(|(l, _)| l),
        "actionCommand": action.map(|(_, c)| c),
    })
}

impl KoeRuntime {
    pub(super) fn live_minutes_workspace_json(
        &self,
        records: &[&ProductRecord],
        live_record_id: Option<&str>,
        live_duration_ms: u64,
        microphone: Option<&MicrophoneStatus<'_>>,
        capture_selection: &CaptureSelection,
    ) -> Value {
        let meeting_mic = self
            .microphone
            .as_ref()
            .filter(|m| m.mode == Some(CaptureMode::Meeting));
        let meeting_bean_active =
            self.bean_capture_mode == Some(CaptureMode::Meeting) && self.bean_capture_pending();
        let is_active = meeting_mic.is_some() || meeting_bean_active;

        let active_record_id = if let Some(m) = meeting_mic {
            Some(m.current_record_id().to_owned())
        } else if meeting_bean_active {
            live_record_id
                .map(str::to_owned)
                .or_else(|| match &self.selection.live_minutes_scope {
                    Some(LiveMinutesScope::Record(id)) => Some(id.clone()),
                    _ => None,
                })
        } else {
            None
        };

        let meeting_records: Vec<&ProductRecord> = records
            .iter()
            .copied()
            .filter(|r| r.is_live() && r.mode == RecordMode::Meeting)
            .collect();

        let past_meetings: Vec<Value> = meeting_records
            .iter()
            .filter(|r| Some(r.aggregate.recording_id.as_str()) != active_record_id.as_deref())
            .map(|r| {
                let rec_id = r.aggregate.recording_id.as_str();
                let duration_ms = if Some(rec_id) == live_record_id {
                    r.aggregate.duration_ms.max(live_duration_ms)
                } else {
                    r.aggregate.duration_ms
                };
                json!({
                    "id": rec_id,
                    "title": r.title,
                    "createdAtEpochSec": r.aggregate.created_at_epoch_sec,
                    "durationMs": duration_ms,
                    "source": origin(r.origin),
                    "status": status(r),
                    "segmentCount": r.aggregate.spine.len(),
                    "decisionCount": r.aggregate.minutes.as_ref().map_or(0, |m| m.decisions.len()),
                })
            })
            .collect();

        let selected_record_id = if is_active {
            active_record_id.clone()
        } else {
            self.selection
                .selected_live_minutes_record
                .as_deref()
                .filter(|id| {
                    self.workspace()
                        .record(id)
                        .is_some_and(|r| r.is_live() && r.mode == RecordMode::Meeting)
                })
                .map(str::to_owned)
                .or_else(|| {
                    meeting_records
                        .first()
                        .map(|r| r.aggregate.recording_id.clone())
                })
        };

        let selected_record = selected_record_id
            .as_deref()
            .and_then(|id| self.workspace().record(id))
            .filter(|r| r.is_live() && r.mode == RecordMode::Meeting);

        let phase = if let Some(m) = meeting_mic {
            match m.phase {
                Phase::Starting => "starting",
                Phase::Recording | Phase::Pausing => "recording",
                Phase::Paused => "paused",
                Phase::Stopping | Phase::CapacityReached | Phase::Cancelling | Phase::Saving => {
                    "finishing"
                }
            }
        } else if meeting_bean_active {
            if self.device.awaiting_stop || self.device.session.transfer.quiet_draining {
                "finishing"
            } else if self.captures.active.is_empty() {
                "starting"
            } else {
                "recording"
            }
        } else if selected_record.is_some_and(|r| {
            self.capture_speech(r)
                .is_some_and(|session| !session.terminal)
        }) {
            "finishing"
        } else if selected_record.is_some() {
            "ended"
        } else {
            "idle"
        };

        let configured = self.text_provider_configured();
        let source_label = if is_active {
            if meeting_mic.is_some() {
                microphone.map_or_else(|| capture_selection.label.clone(), |m| m.input_label.clone())
            } else {
                self.device
                    .device_name
                    .clone()
                    .unwrap_or_else(|| "Soundcore Work".into())
            }
        } else if let Some(r) = selected_record {
            origin(r.origin).to_owned()
        } else {
            capture_selection.label.clone()
        };

        let error = selected_record.and_then(|r| match &r.live_summary {
            AnalysisState::Failed { message, .. } => Some(message.as_str()),
            _ => match &r.analysis {
                AnalysisState::Failed { message, .. } => Some(message.as_str()),
                _ => None,
            },
        });

        let cov_data = selected_record.map(|r| {
            let rec_id = r.aggregate.recording_id.as_str();
            let eff_live_ms = if Some(rec_id) == live_record_id {
                live_duration_ms
            } else if meeting_mic.is_some_and(|m| m.current_record_id() == rec_id) {
                microphone.map_or(0, |m| m.duration_ms)
            } else {
                0
            };
            let rec_active =
                is_active && active_record_id.as_deref() == Some(r.aggregate.recording_id.as_str());
            compute_meeting_coverage(r, eff_live_ms, rec_active)
        });
        let coverage = cov_data.as_ref().map(|cov| {
            json!({
                "audioDurationMs": cov.audio_duration_ms,
                "transcribedDurationMs": cov.transcribed_duration_ms,
                "transcriptPercent": cov.transcript_percent,
                "totalSegments": cov.total_segments,
                "groundedSegments": cov.grounded_segments,
                "minutesPercent": cov.minutes_percent,
                "consolidationStage": cov.consolidation.as_str(),
                "consolidationLabel": cov.consolidation.label_zh(),
            })
        });

        let segments: Vec<_> = selected_record
            .map(|r| {
                r.aggregate
                    .spine
                    .segments()
                    .iter()
                    .map(TranscriptLine::from)
                    .collect()
            })
            .unwrap_or_default();
        let drafts: Vec<&str> = selected_record
            .and_then(|r| self.capture_speech(r))
            .map_or_else(Vec::new, |s| s.drafts().collect());
        let live_sections = selected_record.map_or_else(Vec::new, |r| self.minutes_sections(r));
        let final_sections = if !is_active
            && cov_data
                .as_ref()
                .is_some_and(|cov| cov.consolidation == ConsolidationStage::Ready)
        {
            selected_record.map_or_else(Vec::new, |r| self.minutes_sections(r))
        } else {
            Vec::new()
        };
        let action_items: Vec<Value> = selected_record_id
            .as_deref()
            .map(|id| {
                self.workspace()
                    .items()
                    .values()
                    .filter(|item| item.sources.iter().any(|s| s.record_id == id))
                    .filter_map(|item| self.sourced_item_json(item))
                    .collect()
            })
            .unwrap_or_default();
        let can_summarize = selected_record.is_some_and(|r| {
            !r.aggregate.spine.is_empty()
                && configured
                && !matches!(r.analysis, AnalysisState::Pending { .. })
        });
        let can_start = self.can_start_capture_mode(capture_selection);

        json!({
            "isActive": is_active,
            "canStart": can_start,
            "phase": phase,
            "configured": configured,
            "sourceLabel": source_label,
            "activeRecordId": active_record_id,
            "selectedRecordId": selected_record_id,
            "selectedTitle": selected_record.map(|r| &r.title),
            "minutesStale": selected_record.is_some_and(ProductRecord::is_minutes_stale),
            "canSummarize": can_summarize,
            "error": error,
            "coverage": coverage,
            "segments": segments,
            "drafts": drafts,
            "liveSections": live_sections,
            "finalSections": final_sections,
            "actionItems": action_items,
            "pastMeetings": past_meetings,
        })
    }

    pub(super) fn voice_input_workspace_json(&self) -> Value {
        let session_enabled =
            self.active_companion_mode() == CompanionRoutingMode::CollarStandby;
        let available = self.ensure_voice_input_available().is_ok();
        let can_toggle = !self.is_quitting()
            && !self.store.requires_reopen()
            && (session_enabled || available);
        let standby_ready = self.is_standby_ready();
        let device_connected = self.device.is_connected();
        let device_name = self
            .device
            .device_name
            .as_deref()
            .unwrap_or("Soundcore Work");
        let battery_percent = self
            .device
            .session
            .telemetry
            .as_ref()
            .and_then(|t| t.battery);
        let capture_active = self.companion.capture_active || self.any_dictation_active();
        let companion_subscribers = self
            .companion
            .bridge_subscribers
            .max(self.companion.manual_gate_subscribers);
        let companion_epoch = &self.companion.epoch;
        let companion_sequence = self.companion.sequence;
        let forwarded_audio_frames = self.companion.forwarded_audio_frames;
        let last_dictation_text = self
            .companion
            .last_dictation_text
            .as_deref()
            .filter(|t| !t.trim().is_empty());
        let bridge_socket_path = crate::companion::resolve_bridge_socket_path(&self.root)
            .map(|p| p.to_string_lossy().into_owned());
        let has_companion_dictation = last_dictation_text.is_some();
        let engine_speech_ready =
            self.speech_ready(&self.workspace().provider_configuration().speech_engine);

        let step1 = if device_connected {
            voice_step(
                1,
                "ble_connection",
                "蓝牙连接",
                "ready",
                "已连接",
                format!("{device_name} 蓝牙链路与鉴权已就绪。"),
                None,
            )
        } else {
            voice_step(
                1,
                "ble_connection",
                "蓝牙连接",
                "pending",
                "等待连接",
                "将录音豆取出充电仓或短按配对键，Koe 会自动建立蓝牙连接。",
                Some(("连接引导", "device_open_guide")),
            )
        };

        let step2 = if standby_ready {
            voice_step(
                2,
                "standby_stream",
                "待命流就绪",
                "ready",
                "已就绪",
                "16 kHz 低延迟待命音频流已建立，可随时双击正面或按快捷键听写。",
                None,
            )
        } else if !session_enabled {
            voice_step(
                2,
                "standby_stream",
                "待命流就绪",
                "pending",
                "待开启",
                "开启语音输入会话后，Koe 会将录音豆切入领夹麦待命模式。",
                Some(("开启语音输入", "enable_voice_input")),
            )
        } else if !available {
            voice_step(
                2,
                "standby_stream",
                "待命流就绪",
                "blocked",
                "设备占用中",
                "当前有其他录音任务正在使用音源，请先结束当前记录。",
                None,
            )
        } else {
            voice_step(
                2,
                "standby_stream",
                "待命流就绪",
                "pending",
                "准备中",
                "连接录音豆后将自动启动低延迟待命流。",
                None,
            )
        };

        let step3 = if companion_subscribers > 0 {
            voice_step(
                3,
                "companion_bridge",
                "伴侣桥接",
                "ready",
                "已连接桥接",
                format!("已检测到 {companion_subscribers} 个伴侣订阅连接，音频帧与听写事件可实时转发。"),
                None,
            )
        } else {
            voice_step(
                3,
                "companion_bridge",
                "伴侣桥接",
                "pending",
                "等待订阅",
                "外部输入工具或伴侣客户端可通过本机 koe.sock 订阅实时语音与听写事件。",
                None,
            )
        };

        let step4 = voice_step(
            4,
            "shortcut_guide",
            "触发方式",
            "ready",
            "双击或命令",
            "开启待命后可直接双击录音豆正面，或由伴侣客户端发送听写控制命令触发收音。",
            None,
        );

        let step5 = if has_companion_dictation {
            voice_step(
                5,
                "speech_readiness",
                "语音识别就绪",
                "ready",
                "已验证",
                "已收到伴侣识别结果，语音转写链路工作正常。",
                None,
            )
        } else if engine_speech_ready {
            voice_step(
                5,
                "speech_readiness",
                "语音识别就绪",
                "ready",
                "已就绪",
                "语音识别引擎与模型已就绪，可随时听写验证。",
                None,
            )
        } else {
            voice_step(
                5,
                "speech_readiness",
                "语音识别就绪",
                "pending",
                "待配置",
                "在设置中配置语音识别引擎或准备本机识别模型后，即可生成听写文本。",
                None,
            )
        };

        let step6 = if has_companion_dictation {
            voice_step(
                6,
                "cursor_input_test",
                "光标输入测试",
                "ready",
                "已通过",
                "已在伴侣通道检测到真实听写文本输出。",
                None,
            )
        } else if capture_active {
            voice_step(
                6,
                "cursor_input_test",
                "光标输入测试",
                "pending",
                "正在收音",
                "正在向伴侣发送实时语音帧，松开快捷键或再次双击完成上屏测试。",
                None,
            )
        } else {
            voice_step(
                6,
                "cursor_input_test",
                "光标输入测试",
                "pending",
                "待测试",
                "将光标放入下方测试框，按住快捷键或双击录音豆正面说一句话验证输入。",
                None,
            )
        };

        json!({
            "sessionEnabled": session_enabled,
            "canToggleSession": can_toggle,
            "standbyReady": standby_ready,
            "deviceConnected": device_connected,
            "deviceName": device_name,
            "batteryPercent": battery_percent,
            "captureActive": capture_active,
            "companionSubscribers": companion_subscribers,
            "companionEpoch": companion_epoch,
            "companionSequence": companion_sequence,
            "forwardedAudioFrames": forwarded_audio_frames,
            "lastDictationText": last_dictation_text,
            "bridgeSocketPath": bridge_socket_path,
            "boundaryNote": VOICE_INPUT_BOUNDARY_NOTE,
            "steps": [step1, step2, step3, step4, step5, step6],
        })
    }
}
