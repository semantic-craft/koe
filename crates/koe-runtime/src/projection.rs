use super::*;
use chrono::{DateTime, Local};
use koe_engine::{
    context::{AskRole, AskStatus},
    session::{ConnectionPhaseTag, TransferPhaseTag},
    transport::OPUS_FRAME_BYTES,
};
use serde_json::json;

impl KoeRuntime {
    pub(super) fn sorted_records(&self) -> Vec<&ProductRecord> {
        let mut records: Vec<_> = self.workspace().records().values().collect();
        records.sort_by_key(|r| {
            std::cmp::Reverse((
                r.aggregate.created_at_epoch_sec,
                r.aggregate.recording_id.clone(),
            ))
        });
        records
    }

    pub(super) fn live_record_row_json(
        &self,
        record: &ProductRecord,
        live_record_id: Option<&str>,
        live_duration_ms: u64,
    ) -> Value {
        let is_live = Some(record.aggregate.recording_id.as_str()) == live_record_id;
        let duration_ms = if is_live {
            record.aggregate.duration_ms.max(live_duration_ms)
        } else {
            record.aggregate.duration_ms
        };
        let preview = if is_live {
            record
                .aggregate
                .spine
                .segments()
                .last()
                .map(|s| s.text.chars().take(100).collect::<String>())
                .unwrap_or_default()
        } else {
            record
                .aggregate
                .spine
                .segments()
                .first()
                .map(|s| s.text.chars().take(100).collect::<String>())
                .unwrap_or_default()
        };
        json!({
            "id": record.aggregate.recording_id,
            "title": record.title,
            "createdAtEpochSec": record.aggregate.created_at_epoch_sec,
            "durationMs": duration_ms,
            "source": origin(record.origin),
            "mode": record.mode.as_str(),
            "project": record.project,
            "runId": record.all_day.as_ref().map(|s| &s.run_id),
            "ordinal": record.all_day.as_ref().map(|s| s.ordinal),
            "status": status(record),
            "segmentCount": record.aggregate.spine.len(),
            "preview": preview,
            "archived": record.is_archived(),
        })
    }

    pub(super) fn tasks_and_memories_json(&self) -> (Vec<Value>, Vec<Value>) {
        let mut tasks = Vec::new();
        let mut memories = Vec::new();
        for item in self.workspace().items().values() {
            let sources: Vec<_> = item
                .sources
                .iter()
                .filter_map(|s| self.source_json(s))
                .collect();
            if sources.is_empty() {
                continue;
            }
            let state = match item.review {
                ReviewState::Proposed => "proposed",
                ReviewState::Accepted => "accepted",
                ReviewState::Dismissed => "dismissed",
            };
            let row = json!({
                "id": item.id,
                "text": item.text,
                "state": state,
                "completed": item.completed,
                "due": item.due,
                "sources": sources,
            });
            if item.kind == ItemKind::Task {
                tasks.push(row);
            } else {
                memories.push(row);
            }
        }
        (tasks, memories)
    }

    pub(super) fn ask_phase(&self) -> &'static str {
        let ask = self.workspace().ask_session();
        if ask.in_flight {
            "pending"
        } else if ask
            .messages
            .last()
            .is_some_and(|m| m.status == AskStatus::Failed)
        {
            "failed"
        } else if ask.messages.is_empty() {
            "idle"
        } else {
            "ready"
        }
    }

    pub(super) fn ask_json(&self) -> Value {
        let ask = self.workspace().ask_session();
        let messages: Vec<_> = ask
            .messages
            .iter()
            .map(|m| {
                let sources: Vec<_> = m
                    .sources
                    .iter()
                    .filter_map(|line| {
                        self.source_json(&SourceRef {
                            record_id: line.source.recording_key.clone(),
                            segment_id: line.source.segment_id,
                        })
                    })
                    .collect();
                json!({
                    "id": m.id,
                    "role": if m.role == AskRole::User { "user" } else { "assistant" },
                    "text": m.text,
                    "mode": if m.notice { "retrieval" } else { "answer" },
                    "sources": sources,
                })
            })
            .collect();
        let (scope, ask_record) = match self.workspace().ask_scope() {
            SearchScope::All => ("all", None),
            SearchScope::Record(id) => ("record", Some(id)),
        };
        json!({
            "scope": scope,
            "recordId": ask_record,
            "phase": self.ask_phase(),
            "messages": messages,
        })
    }

    pub(super) fn device_json(&self) -> Value {
        let (live_record_id, live_duration_ms) = self.live_bean_capture_progress();
        self.device_json_with_live(live_record_id, live_duration_ms)
    }

    fn device_json_with_live(&self, live_record_id: Option<&str>, live_duration_ms: u64) -> Value {
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
            .clone()
            .unwrap_or_else(|| "Soundcore Work".to_string());
        let files: Vec<_> = device
            .catalog
            .iter()
            .filter(|f| {
                !self.is_standby_file(f.file_id)
                    && !self.workspace().is_reclaimed_standby_file(f.file_id)
            })
            .map(|f| {
                json!({
                    "id": f.file_id,
                    "title": format!("录音 {}", f.file_id),
                    "durationMs": f.duration_ms,
                })
            })
            .collect();
        let progress = if device.transfer.expected_wire_bytes > 0 {
            (f64::from(device.transfer.received_wire_bytes)
                / f64::from(device.transfer.expected_wire_bytes))
            .clamp(0.0, 1.0)
        } else {
            0.0
        };
        let transfer_phase = if device.is_offline_pull_suspended() {
            "suspended"
        } else if self.companion.standby_stream_owned
            && matches!(device.transfer.phase, TransferPhaseTag::StreamingRealtime)
        {
            "collar_standby"
        } else {
            match device.transfer.phase {
                TransferPhaseTag::Idle | TransferPhaseTag::QueryingCatalog => "idle",
                TransferPhaseTag::StreamingRealtime => "streaming_realtime",
                TransferPhaseTag::PullingOffline => "pulling_offline",
                TransferPhaseTag::Failed => "failed",
            }
        };
        let device_busy = (matches!(
            device.transfer.phase,
            TransferPhaseTag::PullingOffline | TransferPhaseTag::StreamingRealtime
        ) || device.device_recording_active
            || self.device.awaiting_stop)
            && !self.companion.standby_stream_owned;
        let device_recording =
            device.device_recording_active && !self.companion.standby_stream_owned;
        let teardown_stop_frames_hex = if self.is_standby_ready()
            || device_recording
            || self.workspace().companion_mode() == CompanionRoutingMode::CollarStandby
        {
            vec![koe_client_base::prng::to_hex_upper(
                &koe_engine::commands::DeviceCommands::pause_record(),
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
            "files": files,
            "progress": progress,
            "autoConnect": self.workspace().ble_auto_connect(),
            "companionMode": self.workspace().companion_mode().as_str(),
            "standbyReady": self.is_standby_ready(),
            "teardownStopFramesHex": teardown_stop_frames_hex,
            "guide": self.device.guide_json(),
        })
    }

    pub(super) fn provider_json(&self) -> Value {
        let config = self.workspace().provider_configuration();
        json!({
            "meetingAudioPolicy": config.meeting_audio_policy.as_str(),
            "meetingAudioPolicyError": self.audio_policy_error,
            "meetingAudioStatus": if config.meeting_audio_policy == MeetingAudioPolicy::LocalOnly {
                Some("音频只保存在本机；云端语音上传已关闭。".to_string())
            } else {
                self.ensure_meeting_audio_upload().err()
            },
            "configured": self.text_provider_configured(),
            "model": config.model,
            "asrEndpoint": config.asr_endpoint,
            "chatEndpoint": config.chat_endpoint,
            "credentialState": self.credential_state(),
            "isolated": self.credentials.isolated(),
        })
    }

    pub(super) fn project(&self, now: u64) -> Value {
        let records = self.sorted_records();
        let (live_record_id, live_duration_ms) = self.live_bean_capture_progress();
        let now = if now > 0 { now } else { self.last_now_sec };
        let rows: Vec<_> = records
            .iter()
            .copied()
            .filter(|r| r.is_live())
            .map(|record| self.live_record_row_json(record, live_record_id, live_duration_ms))
            .collect();
        let mut trashed_records: Vec<_> = self
            .workspace()
            .records()
            .values()
            .filter(|r| r.is_trashed())
            .collect();
        trashed_records.sort_by(|a, b| {
            b.retention()
                .trashed_at_ms()
                .cmp(&a.retention().trashed_at_ms())
                .then_with(|| {
                    b.aggregate
                        .created_at_epoch_sec
                        .cmp(&a.aggregate.created_at_epoch_sec)
                })
                .then_with(|| a.aggregate.recording_id.cmp(&b.aggregate.recording_id))
        });
        let trash_rows: Vec<_> = trashed_records
            .iter()
            .filter_map(|record| {
                let trashed_at_ms = record.retention().trashed_at_ms()?;
                let expires_at_ms = record.retention().expires_at_ms()?;
                let reference_now_ms = if now > 0 {
                    now.saturating_mul(1000)
                } else {
                    trashed_at_ms
                };
                let remaining_days = if reference_now_ms < expires_at_ms {
                    expires_at_ms
                        .saturating_sub(reference_now_ms)
                        .div_ceil(86_400_000)
                        .clamp(1, 30)
                } else {
                    0
                };
                let preview = record
                    .aggregate
                    .spine
                    .segments()
                    .first()
                    .map(|s| s.text.chars().take(100).collect::<String>())
                    .unwrap_or_default();
                Some(json!({
                    "id": record.aggregate.recording_id,
                    "title": record.title,
                    "createdAtEpochSec": record.aggregate.created_at_epoch_sec,
                    "durationMs": record.aggregate.duration_ms,
                    "source": origin(record.origin),
                    "segmentCount": record.aggregate.spine.len(),
                    "preview": preview,
                    "trashedAtMs": trashed_at_ms,
                    "expiresAtMs": expires_at_ms,
                    "remainingDays": remaining_days,
                }))
            })
            .collect();
        let undo_trash = self
            .undo_trash
            .as_ref()
            .map(|b| json!({"recordId": b.record_id, "title": b.title}));
        let detail = self
            .selection
            .location
            .record
            .as_deref()
            .and_then(|id| self.workspace().record(id))
            .filter(|r| r.is_live())
            .map(|r| self.detail(r, live_record_id, live_duration_ms));
        let (tasks, memories) = self.tasks_and_memories_json();
        let ask_json = self.ask_json();
        let device_json = self.device_json_with_live(live_record_id, live_duration_ms);
        let microphone = self.microphone_status();
        let capture_selection = self.capture_selection();
        let workspaces = self.mode_workspaces_json(
            now,
            &records,
            live_record_id,
            live_duration_ms,
            microphone.as_ref(),
            &capture_selection,
        );
        json!({"speech":self.speech_json(),"allDay":self.all_day_json(microphone.as_ref()),"dictation":{"active":self.any_dictation_active()},"lifecycle": self.lifecycle_json(),
            "captureModes":self.capture_modes_json(&capture_selection),"activeCapture":self.active_capture_json(microphone.as_ref(), live_duration_ms),
            "microphone": self.microphone_json(microphone.as_ref()), "capture": self.capture_studio_json(&capture_selection), "version":KOE_HOST_SNAPSHOT_VERSION,"generation":self.generation,"section":self.selection.location.page,
            "canGoBack":!self.selection.back.is_empty(),"selectedRecordId":self.selection.location.record,"focusSegmentId":self.selection.location.segment,
            "records":rows,"trashRecords":trash_rows,"undoTrash":undo_trash,"detail":detail,"tasks":tasks,"memories":memories,
            "workspaces":workspaces,
            "ask":ask_json,
            "device":device_json,
            "localAsr":{"state":self.local_asr.state,"message":self.local_asr.message},
            "liveCaption":self.live_caption_json(),"liveMinutes":self.live_minutes_view(),
            "provider":self.provider_json(),
            "playback":self.playback_json(),
            "migrationReports": self.workspace().migrations().iter().map(|m|json!({"fingerprint":m.fingerprint,"archivePath":self.root.join(&m.archive).to_string_lossy(),"pending":m.pending,"recordCount":m.record_ids.len()})).collect::<Vec<_>>(),
            "error":self.error,"notice":self.notice})
    }

    fn detail(
        &self,
        record: &ProductRecord,
        live_record_id: Option<&str>,
        live_duration_ms: u64,
    ) -> Value {
        let aggregate = &record.aggregate;
        let duration_ms = if Some(aggregate.recording_id.as_str()) == live_record_id {
            aggregate.duration_ms.max(live_duration_ms)
        } else {
            aggregate.duration_ms
        };
        let segments: Vec<_> = aggregate
            .spine
            .segments()
            .iter()
            .map(crate::live_minutes::TranscriptLine::from)
            .collect();
        let speakers: Vec<_> = record
            .distinct_speakers()
            .into_iter()
            .map(|sp| {
                json!({
                    "name": sp.name,
                    "segmentCount": sp.segment_count,
                    "firstSegmentId": sp.first_segment_id.to_string(),
                })
            })
            .collect();
        let mut summary = Vec::new();
        for imported in self
            .workspace()
            .migrations()
            .iter()
            .flat_map(|m| &m.summaries)
            .filter(|s| s.record_id == aggregate.recording_id)
        {
            summary.push(json!({"title":format!("旧版纪要（未验证来源） {}", imported.slot),"text":imported.text,"sources":[]}));
        }
        summary.extend(self.minutes_sections(record).iter().map(|section| json!(section)));
        let mut highlighted = record.highlighted_segments.clone();
        for mark in &aggregate.bookmarks {
            if let Some(segment) = aggregate
                .spine
                .segments()
                .iter()
                .find(|s| s.start_ms <= *mark && *mark <= s.end_ms)
            {
                highlighted.insert(segment.id);
            }
        }
        let highlights: Vec<_> = highlighted
            .iter()
            .filter_map(|s| {
                self.source_json(&SourceRef {
                    record_id: aggregate.recording_id.clone(),
                    segment_id: *s,
                })
            })
            .collect();
        let audio = recording_assets::audio_path(&self.root, &aggregate.recording_id)
            .ok()
            .filter(|p| p.exists());
        let capture_lanes: Vec<_> = record.capture_lanes.iter().map(|l| {
            let path = l.asset_id.as_ref().and_then(|id| recording_assets::audio_path(&self.root, id).ok()).filter(|p| p.is_file());
            json!({"lane":l.lane,"audioPath":path.map(|p|p.to_string_lossy().into_owned()),"sampleRate":l.sample_rate,"durationMs":l.duration_ms,"interruption":l.interruption,"timeline":l.timeline.iter().map(|s| json!({"epoch":s.epoch,"startNs":s.start_ns,"sampleOffset":s.sample_offset,"sampleCount":s.sample_count})).collect::<Vec<_>>()})
        }).collect();
        let can_retranscribe = audio.is_some()
            && matches!(
                record.analysis,
                AnalysisState::Failed { .. } | AnalysisState::Interrupted { .. }
            );
        json!({"id":aggregate.recording_id,"title":record.title,"createdAtEpochSec":aggregate.created_at_epoch_sec,
            "durationMs":duration_ms,"source":origin(record.origin),"mode":record.mode.as_str(),"project":record.project,"runId":record.all_day.as_ref().map(|s|&s.run_id),"ordinal":record.all_day.as_ref().map(|s|s.ordinal),"status":status(record),"archived":record.is_archived(),"segments":segments,"speakers":speakers,
            "minutesStale":record.is_minutes_stale(),"canEditTranscript":self.can_edit_record(&aggregate.recording_id),
            "captureLanes":capture_lanes,"summary":summary,"highlights":highlights,"audioPath":audio.map(|p|p.to_string_lossy().to_string()),
            "canRetranscribe":can_retranscribe,"isProcessing":matches!(record.analysis,AnalysisState::Pending {..})})
    }

    pub(super) fn live_bean_capture_progress(&self) -> (Option<&str>, u64) {
        let device = &self.device.session;
        let live_record_id = device
            .active_file_id
            .and_then(|fid| self.captures.active.get(&fid))
            .or_else(|| self.captures.active.values().next())
            .map(String::as_str);
        let live_duration_ms = if !self.companion.standby_stream_owned
            && (device.device_recording_active
                || matches!(device.transfer.phase, TransferPhaseTag::StreamingRealtime))
        {
            let opus_ms = ((device.opus_buffer.len() / OPUS_FRAME_BYTES) as u64) * 20;
            let pcm_ms = live_record_id
                .and_then(|id| self.captures.sessions.get(id))
                .map_or(0, |c| c.captured_pcm_bytes / 32);
            let record_ms = live_record_id
                .and_then(|id| self.workspace().record(id))
                .map_or(0, |r| r.aggregate.duration_ms);
            opus_ms.max(pcm_ms).max(record_ms)
        } else {
            0
        };
        (live_record_id, live_duration_ms)
    }

    pub(crate) fn record_detail_json(&self, id: &str) -> Result<Value, String> {
        let record = self.workspace().record(id).ok_or("记录不存在")?;
        record.ensure_live().map_err(|e| e.to_string())?;
        let (live_record_id, live_duration_ms) = self.live_bean_capture_progress();
        Ok(self.detail(record, live_record_id, live_duration_ms))
    }

    pub(crate) fn source_json(&self, source: &SourceRef) -> Option<Value> {
        self.source_view(&source.record_id, source.segment_id)
            .map(|source| json!(source))
    }
}

pub(super) fn local_date(epoch: u64) -> Option<chrono::NaiveDate> {
    i64::try_from(epoch)
        .ok()
        .and_then(|n| DateTime::from_timestamp(n, 0))
        .map(|d| d.with_timezone(&Local).date_naive())
}

pub(crate) fn origin_slug(source: RecordOrigin) -> &'static str {
    match source {
        RecordOrigin::Microphone => "microphone",
        RecordOrigin::Bean => "bean",
        RecordOrigin::ImportedAudio => "imported_audio",
        RecordOrigin::ImportedText => "imported_text",
        RecordOrigin::Note => "note",
    }
}

pub(crate) fn origin(source: RecordOrigin) -> &'static str {
    match source {
        RecordOrigin::Microphone => "Mac 麦克风",
        RecordOrigin::Bean => "录音豆",
        RecordOrigin::ImportedAudio => "导入音频",
        RecordOrigin::ImportedText => "导入文字",
        RecordOrigin::Note => "随手记",
    }
}

pub(crate) fn status(record: &ProductRecord) -> &'static str {
    match &record.analysis {
        AnalysisState::Pending {
            stage: AnalysisStage::Transcribing,
            ..
        } => "转写中",
        AnalysisState::Pending {
            stage: AnalysisStage::Summarizing,
            ..
        } => "整理中",
        AnalysisState::Failed { .. } => "处理失败",
        AnalysisState::Interrupted { .. } => "处理已中断",
        _ if record
            .capture_lanes
            .iter()
            .any(|l| l.interruption.is_some()) =>
        {
            "采集不完整"
        }
        _ if record.aggregate.spine.is_empty() => "等待转写",
        _ if record.is_minutes_stale() => "原文已变更待重算",
        _ if record.aggregate.minutes.is_some() => "已整理",
        _ => "已有文字",
    }
}
