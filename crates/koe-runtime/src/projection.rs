use super::*;
use chrono::{DateTime, Local};
use koe_engine::{
    context::{AskRole, AskStatus},
    session::{ConnectionPhaseTag, TransferPhaseTag},
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
        let today = local_date(now);
        let rows: Vec<_> = records.iter().map(|record| {
            json!({"id":record.aggregate.recording_id,"title":record.title,
                "createdAtEpochSec":record.aggregate.created_at_epoch_sec,"durationMs":record.aggregate.duration_ms,
                "source":origin(record.origin),"status":status(record),"segmentCount":record.aggregate.spine.len(),
                "preview":record.aggregate.spine.segments().first().map(|s| s.text.chars().take(100).collect::<String>()).unwrap_or_default()})
        }).collect();
        let today_ids: Vec<_> = records
            .iter()
            .filter(|r| local_date(r.aggregate.created_at_epoch_sec) == today)
            .map(|r| &r.aggregate.recording_id)
            .collect();
        let detail = self
            .location
            .record
            .as_deref()
            .and_then(|id| self.workspace().record(id))
            .map(|r| self.detail(r));
        let mut tasks = Vec::new();
        let mut memories = Vec::new();
        for item in self.workspace().items().values() {
            let sources: Vec<_> = item
                .sources
                .iter()
                .filter_map(|s| self.source_json(s))
                .collect();
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
        let files: Vec<_> = device.catalog.iter().map(|f| json!({"id":f.file_id,"title":format!("录音 {}", f.file_id),"durationMs":f.duration_ms})).collect();
        let progress = if device.transfer.expected_wire_bytes > 0 {
            (f64::from(device.transfer.received_wire_bytes)
                / f64::from(device.transfer.expected_wire_bytes))
            .clamp(0.0, 1.0)
        } else {
            0.0
        };
        json!({"version":KOE_HOST_SNAPSHOT_VERSION,"generation":self.generation,"section":self.location.page,
            "canGoBack":!self.back.is_empty(),"selectedRecordId":self.location.record,"focusSegmentId":self.location.segment,
            "records":rows,"todayRecordIds":today_ids,"detail":detail,"tasks":tasks,"memories":memories,
            "ask":{"scope":scope,"recordId":ask_record,"phase":phase,"messages":messages},
            "device":{
                "phase":device_phase,
                "state":device_state,
                "statusDetail":status_detail,
                "connected":connected,
                "busy":matches!(device.transfer.phase,TransferPhaseTag::PullingOffline|TransferPhaseTag::StreamingRealtime) || device.device_recording_active,
                "recording":device.device_recording_active,
                "deviceName":device_name,
                "batteryPercent":battery_pct,
                "charging":telemetry.is_some_and(|t| t.charging),
                "boxBatteryPercent":box_battery_pct,
                "boxCharging":telemetry.is_some_and(|t| t.box_charging),
                "serialNumber":telemetry.map(|t| t.serial_number.clone()).unwrap_or_default(),
                "firmwareVersion":telemetry.map(|t| t.firmware_version.clone()).unwrap_or_default(),
                "storageLabel":telemetry.map(|t| t.storage_label()).unwrap_or_else(|| "—".to_string()),
                "files":files,
                "progress":progress,
                "guide":self.device.guide_json()
            },
            "provider":{"configured":!self.settings.key.is_empty(),"model":self.settings.model},
            "playback":{"recordId":self.playback.record,"positionMs":self.playback.position_ms,"isPlaying":self.playback.playing},
            "error":self.error,"notice":self.notice})
    }

    fn detail(&self, record: &ProductRecord) -> Value {
        let aggregate = &record.aggregate;
        let segments: Vec<_> = aggregate.spine.segments().iter().map(|s| json!({"id":s.id.to_string(),"text":s.text,"startMs":s.start_ms,"endMs":s.end_ms,"speaker":s.speaker})).collect();
        let mut summary = Vec::new();
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
        let can_retranscribe = audio.is_some()
            && matches!(
                record.analysis,
                AnalysisState::Failed { .. } | AnalysisState::Interrupted { .. }
            );
        json!({"id":aggregate.recording_id,"title":record.title,"createdAtEpochSec":aggregate.created_at_epoch_sec,
            "durationMs":aggregate.duration_ms,"source":origin(record.origin),"status":status(record),"segments":segments,
            "summary":summary,"highlights":highlights,"audioPath":audio.map(|p|p.to_string_lossy().to_string()),
            "canRetranscribe":can_retranscribe,"isProcessing":matches!(record.analysis,AnalysisState::Pending {..})})
    }

    pub(crate) fn source_json(&self, source: &SourceRef) -> Option<Value> {
        let evidence = self.workspace().resolve_source(source).ok()?;
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

fn origin(source: RecordOrigin) -> &'static str {
    match source {
        RecordOrigin::Bean => "录音豆",
        RecordOrigin::ImportedAudio => "导入音频",
        RecordOrigin::ImportedText => "导入文字",
        RecordOrigin::Note => "随手记",
    }
}

fn status(record: &ProductRecord) -> &'static str {
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
        _ if record.aggregate.spine.is_empty() => "等待转写",
        _ if record.aggregate.minutes.is_some() => "已整理",
        _ => "已有文字",
    }
}
