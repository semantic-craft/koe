use super::*;
use chrono::{DateTime, Local};
use koe_engine::{
    context::{AskRole, AskStatus},
    session::{ConnectionPhaseTag, TransferPhaseTag},
    transport::OPUS_FRAME_BYTES,
};
use serde_json::json;

impl KoeRuntime {
    pub(super) fn project(&self, now: u64) -> Value {
        let mut records: Vec<_> = self.workspace().records().values().collect();
        records.sort_by_key(|r| {
            std::cmp::Reverse((
                r.aggregate.created_at_epoch_sec,
                r.aggregate.recording_id.clone(),
            ))
        });
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
        let today = local_date(now);
        let rows: Vec<_> = records.iter().filter(|r| r.is_live()).map(|record| {
            let is_live = Some(record.aggregate.recording_id.as_str()) == live_record_id;
            let duration_ms = if is_live {
                record.aggregate.duration_ms.max(live_duration_ms)
            } else {
                record.aggregate.duration_ms
            };
            let preview = if is_live {
                record.aggregate.spine.segments().last().map(|s| s.text.chars().take(100).collect::<String>()).unwrap_or_default()
            } else {
                record.aggregate.spine.segments().first().map(|s| s.text.chars().take(100).collect::<String>()).unwrap_or_default()
            };
            json!({"id":record.aggregate.recording_id,"title":record.title,
                "createdAtEpochSec":record.aggregate.created_at_epoch_sec,"durationMs":duration_ms,
                "source":origin(record.origin),"status":status(record),"segmentCount":record.aggregate.spine.len(),
                "preview":preview,"archived":record.is_archived()})
        }).collect();
        let today_ids: Vec<_> = records
            .iter()
            .filter(|r| r.is_live() && local_date(r.aggregate.created_at_epoch_sec) == today)
            .map(|r| &r.aggregate.recording_id)
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
        let effective_now_sec = if now > 0 { now } else { self.last_now_sec };
        let trash_rows: Vec<_> = trashed_records
            .iter()
            .filter_map(|record| {
                let trashed_at_ms = record.retention().trashed_at_ms()?;
                let expires_at_ms = record.retention().expires_at_ms()?;
                let reference_now_ms = if effective_now_sec > 0 {
                    effective_now_sec.saturating_mul(1000)
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
            .location
            .record
            .as_deref()
            .and_then(|id| self.workspace().record(id))
            .filter(|r| r.is_live())
            .map(|r| self.detail(r, live_record_id, live_duration_ms));
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
            let row = json!({"id":item.id,"text":item.text,"state":state,"completed":item.completed,"due":item.due,"sources":sources});
            if item.kind == ItemKind::Task {
                tasks.push(row);
            } else {
                memories.push(row);
            }
        }
        let ask = self.workspace().ask_session();
        let messages: Vec<_> = ask.messages.iter().map(|m| {
            let sources: Vec<_> = m.sources.iter().filter_map(|line| {
                let id = SegmentId::from_zero_based(line.source.line?)?;
                self.source_json(&SourceRef { record_id: line.source.recording_key.clone(), segment_id: id })
            }).collect();
            json!({"id":m.id,"role":if m.role == AskRole::User {"user"} else {"assistant"},"text":m.text,
                "mode":if m.notice {"retrieval"} else {"answer"},"sources":sources})
        }).collect();
        let (scope, ask_record) = match self.workspace().ask_scope() {
            SearchScope::All => ("all", None),
            SearchScope::Record(id) => ("record", Some(id)),
        };
        let phase = if ask.in_flight {
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
        };
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
            .filter(|f| !self.is_standby_file(f.file_id))
            .map(|f| json!({"id":f.file_id,"title":format!("录音 {}", f.file_id),"durationMs":f.duration_ms}))
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
        let device_json = json!({
            "phase": device_phase,
            "state": device_state,
            "statusDetail": status_detail,
            "connected": connected,
            "busy": device_busy,
            "stopping": self.device.awaiting_stop,
            "recording": device_recording,
            "transferPhase": transfer_phase,
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
            "guide": self.device.guide_json()
        });
        json!({"lifecycle": self.lifecycle_json(),
            "microphone": self.microphone_json(), "version":KOE_HOST_SNAPSHOT_VERSION,"generation":self.generation,"section":self.location.page,
            "canGoBack":!self.back.is_empty(),"selectedRecordId":self.location.record,"focusSegmentId":self.location.segment,
            "records":rows,"todayRecordIds":today_ids,"trashRecords":trash_rows,"undoTrash":undo_trash,"detail":detail,"tasks":tasks,"memories":memories,
            "ask":{"scope":scope,"recordId":ask_record,"phase":phase,"messages":messages},
            "device":device_json,
            "provider":{"meetingAudioPolicy":self.workspace().provider_configuration().meeting_audio_policy.as_str(),"meetingAudioPolicyError":self.audio_policy_error,"meetingAudioStatus":self.ensure_meeting_audio_upload().err(),"configured":!self.settings.key.is_empty(),"model":self.workspace().provider_configuration().model,"asrEndpoint":self.workspace().provider_configuration().asr_endpoint,"chatEndpoint":self.workspace().provider_configuration().chat_endpoint,"credentialState":self.credential_state(),"isolated":self.credentials.isolated()},
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
            .map(|s| {
                json!({
                    "id": s.id.to_string(),
                    "text": s.text,
                    "originalText": s.original_text,
                    "isEdited": s.is_edited(),
                    "startMs": s.start_ms,
                    "endMs": s.end_ms,
                    "timed": s.end_ms > s.start_ms,
                    "speaker": s.speaker,
                })
            })
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
            summary.push(json!({"title":format!("旧版纪要（未验证来源） · {}", imported.slot),"text":imported.text,"sources":[]}));
        }
        let source_values = |ids: &[SegmentId]| -> Vec<Value> {
            ids.iter()
                .filter_map(|s| {
                    self.source_json(&SourceRef {
                        record_id: aggregate.recording_id.clone(),
                        segment_id: *s,
                    })
                })
                .collect()
        };
        if let Some(minutes) = &aggregate.minutes {
            if !minutes.overview.is_empty() {
                summary.push(json!({"title":"摘要","text":minutes.overview,"sources":[]}));
            }
            for topic in &minutes.topics {
                summary.push(json!({"title":topic.title,"text":topic.summary,"sources":source_values(&topic.citations)}));
            }
            for decision in &minutes.decisions {
                summary.push(json!({"title":"决定","text":decision.claim,"sources":source_values(&decision.citations)}));
            }
        }
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
            "durationMs":duration_ms,"source":origin(record.origin),"status":status(record),"archived":record.is_archived(),"segments":segments,"speakers":speakers,
            "minutesStale":record.is_minutes_stale(),"canEditTranscript":self.can_edit_record(&aggregate.recording_id),
            "captureLanes":capture_lanes,"summary":summary,"highlights":highlights,"audioPath":audio.map(|p|p.to_string_lossy().to_string()),
            "canRetranscribe":can_retranscribe,"isProcessing":matches!(record.analysis,AnalysisState::Pending {..})})
    }

    pub(crate) fn record_detail_json(&self, id: &str) -> Result<Value, String> {
        let record = self.workspace().record(id).ok_or("记录不存在")?;
        record.ensure_live().map_err(|e| e.to_string())?;
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
                .and_then(|rid| self.captures.sessions.get(rid))
                .map_or(0, |c| c.captured_pcm_bytes / 32);
            let record_ms = live_record_id
                .and_then(|rid| self.workspace().record(rid))
                .map_or(0, |r| r.aggregate.duration_ms);
            opus_ms.max(pcm_ms).max(record_ms)
        } else {
            0
        };
        Ok(self.detail(record, live_record_id, live_duration_ms))
    }

    pub(crate) fn source_json(&self, source: &SourceRef) -> Option<Value> {
        let evidence = self.workspace().resolve_live_source(source).ok()?;
        Some(
            json!({"recordId":source.record_id,"segmentId":source.segment_id.to_string(),"title":evidence.title,"quote":evidence.quote,"startMs":evidence.start_ms}),
        )
    }
}

fn local_date(epoch: u64) -> Option<chrono::NaiveDate> {
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
