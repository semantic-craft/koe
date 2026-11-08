use koe_desktop_core::{
    crypto::{AesCtrStreamDecrypt, DeviceCrypto},
    domain::{
        EditorialCardRole, MeetingMinutesV2, MinutePoint, RecordingAggregate,
        RecordingLifecyclePhase, SegmentId, UtteranceSpine,
    },
    frame::{ProtocolFrame, RX_MAGIC},
    session::{ConnectionPhaseTag, TransportSession, REAL_OPUS_20MS_440HZ_PACKET},
    transport::{OPUS_FRAME_BYTES, SLICE_RECORD_BYTES},
    DesktopBeanHost, OutboundAsrWsFrame,
};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

static COUNTER: AtomicU64 = AtomicU64::new(1);

fn temp_dir(label: &str) -> PathBuf {
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!(
        "koe-interrogate-2-{label}-{}-{n}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn build_rx_frame(cmd_type: u8, cmd_id: u8, payload: &[u8]) -> Vec<u8> {
    let total_len = (9 + payload.len() + 1) as u16;
    let mut frame = Vec::with_capacity(total_len as usize);
    frame.extend_from_slice(&RX_MAGIC);
    frame.push(0x01);
    frame.push(cmd_type);
    frame.push(cmd_id);
    frame.push((total_len & 0xFF) as u8);
    frame.push(((total_len >> 8) & 0xFF) as u8);
    frame.extend_from_slice(payload);
    let csum = ProtocolFrame::checksum(&frame);
    frame.push(csum);
    frame
}

fn build_encrypted_head_and_slices(
    sk: &[u8; 32],
    file_id: u32,
    sequences: &[(u32, u8)],
) -> (Vec<u8>, Vec<u8>) {
    let mut plain_key_mat = Vec::with_capacity(46);
    plain_key_mat.extend_from_slice(b"soundcored3200");
    let file_key = [0x5Au8; 32];
    plain_key_mat.extend_from_slice(&file_key);
    let session_nonce = [0x11u8; 16];
    let enc_file_key =
        DeviceCrypto::aes_ctr_decrypt(&plain_key_mat, sk, &session_nonce).unwrap();
    let file_nonce = [0x22u8; 16];

    let mut head_payload = Vec::with_capacity(87);
    head_payload.extend_from_slice(&file_id.to_le_bytes());
    head_payload.extend_from_slice(&u32::MAX.to_le_bytes());
    head_payload.extend_from_slice(&file_nonce);
    head_payload.extend_from_slice(&enc_file_key);
    head_payload.extend_from_slice(&session_nonce);
    head_payload.push(0);
    let head_rx = build_rx_frame(0x1A, 0x07, &head_payload);

    let decryptor = AesCtrStreamDecrypt::new(&file_key, &file_nonce).unwrap();
    let mut slice_payload = Vec::with_capacity(sequences.len() * SLICE_RECORD_BYTES);
    for &(seq, flags) in sequences {
        slice_payload.extend_from_slice(&seq.to_le_bytes());
        slice_payload.push(flags);
        let mut chunk = [0u8; OPUS_FRAME_BYTES];
        chunk[..REAL_OPUS_20MS_440HZ_PACKET.len()].copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
        decryptor.decrypt_contiguous_in_place(&mut chunk, seq);
        slice_payload.extend_from_slice(&chunk);
        slice_payload.push(0x00);
    }
    let slices_rx = build_rx_frame(0x1A, 0x08, &slice_payload);
    (head_rx, slices_rx)
}

#[test]
fn repro_1_catalog_1b_0e_subscribes_completed_offline_file_when_new_recording_starts() {
    let mut session = TransportSession::new();
    let _ = session.start_realtime_recording(None, 1_762_600_000_000);
    assert!(session.pending_realtime_subscribe);

    let mut list_payload = Vec::new();
    list_payload.extend_from_slice(&2u16.to_le_bytes());
    list_payload.extend_from_slice(&1000u32.to_le_bytes());
    list_payload.extend_from_slice(&1010u32.to_le_bytes());
    list_payload.extend_from_slice(&10_000u32.to_le_bytes());
    list_payload.extend_from_slice(&2050u32.to_le_bytes());
    list_payload.extend_from_slice(&0u32.to_le_bytes());
    list_payload.extend_from_slice(&0u32.to_le_bytes());
    let list_rx = build_rx_frame(0x1B, 0x0E, &list_payload);

    let _ = session.ingest_ble_chunk(&list_rx, 1_762_600_001);

    assert_ne!(
        session.active_file_id,
        Some(1000),
        "subscribed to completed historical file 1000 (end_time=1010) in realtime mode!"
    );
    assert_eq!(session.active_file_id, Some(2050));
}

#[test]
fn repro_2_switching_realtime_file_on_1a_06_wipes_unfinalized_previous_recording() {
    let mut session = TransportSession::new();
    let sk = [0x42u8; 32];
    session.set_session_key(sk);

    let (head_3001, slices_3001) =
        build_encrypted_head_and_slices(&sk, 3001, &[(0, 0x00), (1, 0x01), (2, 0x00)]);
    let _ = session.ingest_ble_chunk(&head_3001, 1_762_600_010);
    let _ = session.ingest_ble_chunk(&slices_3001, 1_762_600_011);
    let _ = session.stop_realtime_recording();
    assert!(session.is_realtime_quiet_draining());
    assert_eq!(session.received_slice_count(), 3);

    let mut status_3002 = Vec::with_capacity(5);
    status_3002.extend_from_slice(&3002u32.to_le_bytes());
    status_3002.push(1);
    let rx_3002 = build_rx_frame(0x1A, 0x06, &status_3002);
    let _ = session.ingest_ble_chunk(&rx_3002, 1_762_600_012);

    let saved = session.take_next_finalized();
    assert!(
        saved.is_some(),
        "Take 1 (file_id=3001, 3 slices, mark at 20ms) was wiped without finalization when 1A/06 switched to 3002!"
    );
    let fin = saved.unwrap();
    assert_eq!(fin.entry.id, 3001);
    assert_eq!(fin.entry.marks_ms, vec![20]);
}

#[test]
fn repro_3_audio_control_18_82_5byte_payload_and_01_01_stop_telemetry_mishandled() {
    let mut session = TransportSession::new();
    let sk = [0x42u8; 32];
    session.set_session_key(sk);

    let (head_5001, slices_5001) =
        build_encrypted_head_and_slices(&sk, 5001, &[(0, 0x00), (1, 0x00)]);
    let _ = session.ingest_ble_chunk(&head_5001, 1_762_600_020);
    let _ = session.ingest_ble_chunk(&slices_5001, 1_762_600_021);
    assert!(session.active_is_realtime);
    assert!(!session.is_realtime_quiet_draining());

    let rx_18_82_resume = build_rx_frame(0x18, 0x82, &[0x01, 0x00, 0x00, 0x00, 0x00]);
    let _ = session.ingest_ble_chunk(&rx_18_82_resume, 1_762_600_022);

    let mut session_b = TransportSession::new();
    session_b.set_session_key(sk);
    let _ = session_b.ingest_ble_chunk(&head_5001, 1_762_600_030);
    let _ = session_b.ingest_ble_chunk(&slices_5001, 1_762_600_031);

    let mut tel_payload = Vec::with_capacity(56);
    tel_payload.extend_from_slice(&[1, 8, 0]);
    tel_payload.extend_from_slice(b"1.4.8");
    tel_payload.extend_from_slice(b"D3200NATIVE639D0");
    tel_payload.extend_from_slice(&(64u32 * 1024 * 1024).to_le_bytes());
    tel_payload.extend_from_slice(&(58u32 * 1024 * 1024).to_le_bytes());
    tel_payload.push(0);
    tel_payload.extend_from_slice(b"2.1.0");
    tel_payload.push(9);
    tel_payload.extend_from_slice(&[0xAA, 0xBB, 0xCC, 0xDD, 0x63, 0x9D]);
    tel_payload.extend_from_slice(&[0u8; 5]);
    tel_payload.push(0);
    tel_payload.extend_from_slice(b"1.0.0");
    let tel_rx = build_rx_frame(0x01, 0x01, &tel_payload);
    let _ = session_b.ingest_ble_chunk(&tel_rx, 1_762_600_032);
    let poll_out = session_b.poll_timers(2_000, 1_762_600_035);

    assert!(
        session.device_recording_active && !session.is_realtime_quiet_draining(),
        "0x18/0x82 [01, 0, 0, 0, 0] was misparsed as state=0 (stop) and forced active stream into quiet drain!"
    );
    assert!(
        poll_out.finalized.is_some(),
        "0x01/0x01 with recording_status=0 did not enter quiet drain and never finalized after 2000ms!"
    );
}

#[test]
fn repro_4_aggregate_visual_cards_freeze_on_s1_clobber_copying_phase_and_launder_bad_citations() {
    let dir = temp_dir("repro-4");
    let mut host = DesktopBeanHost::new(&dir);
    let _ = host.start_realtime_recording(Some(77), 1_762_600_100_000);
    assert_eq!(host.active_aggregate().phase, RecordingLifecyclePhase::Copying);

    let _ = host.ingest_utterance_with_context(
        "第一句：今天启动录音豆测试。",
        0,
        1_000,
        "zh",
        "qwen",
        1_762_600_101,
    );
    let phase_during_live_stream = host.active_aggregate().phase;

    let s2 = host
        .ingest_utterance_with_context(
            "第二句：张工周五前提交实时流压测报告。",
            1_000,
            2_500,
            "zh",
            "qwen",
            1_762_600_102,
        )
        .unwrap();

    let cards = &host.active_aggregate().visual_cards;
    let cites_s2 = cards.iter().any(|c| c.citations.contains(&s2));
    let flow_card = cards
        .iter()
        .find(|c| c.role == EditorialCardRole::FlowEmerald)
        .unwrap();

    let mut spine = UtteranceSpine::new("rec-cite-check");
    let _s1 = spine.append_segment("仅有一句原话。", 0, 1_000, "zh", "qwen").unwrap();
    let bad_s99 = SegmentId::new(99).unwrap();
    let ungrounded_mins = MeetingMinutesV2 {
        version: 2,
        spine_revision: spine.revision(),
        title: "测试纪要".to_string(),
        overview: "概览".to_string(),
        topics: Vec::new(),
        decisions: Vec::new(),
        actions: vec![MinutePoint {
            claim: "越界引用的待办".to_string(),
            speaker: None,
            owner: None,
            due: None,
            citations: vec![bad_s99],
        }],
        questions: Vec::new(),
        fishbones: Vec::new(),
        terms: Vec::new(),
        custom_sections: Vec::new(),
        review_items: Vec::new(),
    };
    let agg = RecordingAggregate::from_spine_and_minutes(
        "rec-cite-check",
        1,
        1_762_600_100,
        1_000,
        spine,
        Some(ungrounded_mins),
    );
    let action_card = agg
        .visual_cards
        .iter()
        .find(|c| c.role == EditorialCardRole::ActionsBlue);

    let _ = fs::remove_dir_all(&dir);

    assert_eq!(
        phase_during_live_stream,
        RecordingLifecyclePhase::Copying,
        "live streaming utterance prematurely overwrote Copying phase with Ready!"
    );
    assert!(
        cites_s2 && flow_card.body.contains("第二句"),
        "active_aggregate visual_cards froze on S1 and ignored S2!"
    );
    assert!(
        action_card.is_none(),
        "ungrounded action card with [S99] had its citation laundered into S1!"
    );
}

#[test]
fn repro_5_host_short_speech_dropped_on_stop_and_second_recording_leaks_bookmarks_and_asr_state() {
    let dir = temp_dir("repro-5");
    let mut host = DesktopBeanHost::new(&dir);
    let sk = [0x42u8; 32];
    host.session_mut().set_session_key(sk);
    host.session_mut().connection_phase = ConnectionPhaseTag::Connected;

    let (head_77, slices_77) = build_encrypted_head_and_slices(
        &sk,
        77,
        &[(0, 0x00), (1, 0x00), (2, 0x01), (3, 0x00)],
    );
    let _ = host.ingest_ble_chunk(&head_77, 1_762_600_200);
    let _ = host.ingest_ble_chunk(&slices_77, 1_762_600_201);
    let _ = host.stop_realtime_recording();
    let _ = host.poll_timers(2_000, 1_762_600_204);

    let take1_spine_len = host.spine().len();
    let take1_doctor = host.pipeline_doctor_snapshot();
    let mut take1_ws = Vec::new();
    while let Some(f) = host.asr_pump_mut().pop_outbound_ws_frame() {
        take1_ws.push(f);
    }

    let _ = host.start_realtime_recording(Some(88), 1_762_600_210_000);
    let (head_88, slices_88) = build_encrypted_head_and_slices(
        &sk,
        88,
        &[(0, 0x00), (1, 0x00), (2, 0x00), (3, 0x00), (4, 0x00), (5, 0x00)],
    );
    let _ = host.ingest_ble_chunk(&head_88, 1_762_600_211);
    let _ = host.ingest_ble_chunk(&slices_88, 1_762_600_212);

    let mut take2_ws = Vec::new();
    while let Some(f) = host.asr_pump_mut().pop_outbound_ws_frame() {
        take2_ws.push(f);
    }
    let take2_has_run_task = take2_ws
        .iter()
        .any(|f| matches!(f, OutboundAsrWsFrame::TextJson(s) if s.contains("\"run-task\"")));
    let take2_bookmarks = host.active_aggregate().bookmarks.clone();

    let _ = fs::remove_dir_all(&dir);

    assert!(
        take1_spine_len > 0 && take1_doctor.all_stages_healthy(),
        "Take 1 (4 slices = 2,560B PCM) dropped buffered speech on stop/finalize, leaving spine empty!"
    );
    assert!(
        take2_has_run_task,
        "Take 2 queued BinaryPcm16 frames after Take 1's finish-task without queuing a new run-task!"
    );
    assert!(
        take2_bookmarks.is_empty(),
        "Take 2 (file_id=88, 0 marks) leaked Take 1's bookmark {:?}!",
        take2_bookmarks
    );
}

#[test]
fn repro_6_slice_r_coarse_place_trash_sync_dynamic_date_speaker_and_1a07_tx() {
    use koe_desktop_core::WorkspaceCommand;

    let dir = temp_dir("repro-6");
    let mut host = DesktopBeanHost::new(&dir);

    let proj_place = host.dispatch(
        WorkspaceCommand::SetCoarsePlace(Some(
            "浙江省 杭州市 西湖区 文三路 478 号".to_string(),
        )),
        1_796_256_000,
    );
    let sanitized_place = proj_place.active_aggregate.coarse_place.clone();

    let proj_date = host.workspace_projection(1_796_256_000);
    let brief_date = proj_date.morning_brief.key.clone();
    let diary_key = proj_date.diary_entry.key.clone();

    let _ = host.dispatch(WorkspaceCommand::SimulateRealtimePipeline, 1_796_256_010);
    let sim_id = host.projection().library.selected_id.unwrap();
    let proj_after_trash = host.dispatch(WorkspaceCommand::MoveToTrash(sim_id), 1_796_256_011);

    let mut host_spk = DesktopBeanHost::new(&dir);
    let s1 = host_spk
        .ingest_utterance_with_context("Alice 的第一句话", 0, 1_000, "zh", "qwen", 1_796_256_020)
        .unwrap();
    let _ = host_spk.spine_mut().set_speaker(s1, Some("Alice".to_string()));
    let proj_spk = host_spk.dispatch(
        WorkspaceCommand::ReplaceSpeaker {
            old_speaker: "Ghost".to_string(),
            new_speaker: "Bob".to_string(),
        },
        1_796_256_021,
    );
    let s1_speaker_after_unmatched = proj_spk.active_aggregate.spine.segments()[0]
        .speaker
        .clone();

    let mut host_rpc = DesktopBeanHost::new(&dir);
    let _ = host_rpc.dispatch(
        WorkspaceCommand::AppendUtterance {
            text: "测试免手动 initialize 直接调 get_minutes".to_string(),
            start_ms: 0,
            end_ms: 1_200,
            source_language: "zh".to_string(),
            provider: "qwen".to_string(),
            now_epoch_sec: 1_796_256_030,
        },
        1_796_256_030,
    );
    let proj_rpc = host_rpc.dispatch(
        WorkspaceCommand::DispatchJsonRpc {
            request_json:
                r#"{"jsonrpc":"2.0","id":77,"method":"tools/call","params":{"name":"get_minutes","arguments":{}}}"#
                    .to_string(),
        },
        1_796_256_031,
    );

    let mut host_tx = DesktopBeanHost::new(&dir);
    let _ = host_tx.dispatch(
        WorkspaceCommand::RetriggerRealtimeStream {
            now_ms: 1_796_256_040_000,
        },
        1_796_256_040,
    );
    let tx_frames = host_tx.drain_outbound_ble_frames();

    let _ = fs::remove_dir_all(&dir);

    assert_eq!(
        sanitized_place.as_deref(),
        Some("杭州市 西湖区"),
        "SetCoarsePlace stored raw street-level PII {:?} instead of sanitizing via format_coarse_place!",
        sanitized_place
    );
    assert_eq!(
        brief_date, "brief:2026-12-03",
        "workspace_projection hardcoded 2026-11-08 instead of deriving calendar date from now_epoch_sec!"
    );
    assert_eq!(diary_key, "day:2026-12-03");
    assert_eq!(
        proj_after_trash.recordings.len(),
        0,
        "WorkspaceProjection.recordings still contained trashed recording after MoveToTrash!"
    );
    assert_eq!(
        proj_after_trash.active_aggregate.file_id,
        0,
        "active_aggregate.file_id remained pointing to trashed recording {}!",
        proj_after_trash.active_aggregate.file_id
    );
    assert_eq!(
        s1_speaker_after_unmatched.as_deref(),
        Some("Alice"),
        "ReplaceSpeaker with unmatched old_speaker clobbered Alice on S1 with {:?}!",
        s1_speaker_after_unmatched
    );
    assert!(
        !proj_rpc.last_jsonrpc_response.contains("ServerNotInitialized"),
        "DispatchJsonRpc failed with ServerNotInitialized when called directly from UI command: {}",
        proj_rpc.last_jsonrpc_response
    );
    assert_eq!(
        tx_frames.len(),
        1,
        "RetriggerRealtimeStream did not queue the 1A/07 outbound BLE frame!"
    );
}

#[test]
fn repro_7_slice_s_wifi_resume_from_transferring_cancel_cleanup_builtin_section_remove_empty_spine_and_settings_merge(
) {
    use koe_desktop_core::{
        BuiltinTemplateId, WifiBatchPhase, WifiSoftApAction, WorkspaceCommand,
    };

    let dir = temp_dir("repro-7");
    let mut host_empty = DesktopBeanHost::new(&dir);
    let proj_fresh = host_empty.workspace_projection(1_796_260_000);
    let fresh_custom_citations_valid = proj_fresh
        .formats
        .custom_sections
        .iter()
        .flat_map(|s| s.points.iter())
        .flat_map(|p| p.citations.iter())
        .all(|&c| proj_fresh.active_aggregate.spine.validate_citation(c));

    let proj_after_tpl = host_empty.dispatch(
        WorkspaceCommand::SelectMinuteTemplate(BuiltinTemplateId::Fishbone),
        1_796_260_001,
    );
    let host_spine_synced = !host_empty.spine().is_empty()
        && proj_after_tpl
            .active_aggregate
            .visual_cards
            .iter()
            .all(|c| c.validate_citations(host_empty.spine()))
        && host_empty.minutes().latest_minutes.is_some();

    let proj_after_rm_builtin = host_empty.dispatch(
        WorkspaceCommand::RemoveCustomMinuteSection {
            heading: "根因假设".to_string(),
        },
        1_796_260_002,
    );
    let still_has_removed_builtin = proj_after_rm_builtin
        .formats
        .custom_sections
        .iter()
        .any(|s| s.heading == "根因假设");

    let mut host_wifi = DesktopBeanHost::new(&dir);
    let _ = host_wifi.dispatch(WorkspaceCommand::AddSliceMark(5_000), 1_796_260_010);
    let _ = host_wifi.dispatch(
        WorkspaceCommand::ControlWifiSoftApBatch {
            action: WifiSoftApAction::StartDefaultSoftAp,
            now_epoch_sec: 1_796_260_011,
        },
        1_796_260_011,
    );
    let proj_direct_complete = host_wifi.dispatch(
        WorkspaceCommand::ControlWifiSoftApBatch {
            action: WifiSoftApAction::ResumeAndComplete,
            now_epoch_sec: 1_796_260_012,
        },
        1_796_260_012,
    );
    let stale_bookmark_leaked = proj_direct_complete
        .active_aggregate
        .bookmarks
        .contains(&5_000);

    let proj_cancelled = host_wifi.dispatch(
        WorkspaceCommand::ControlWifiSoftApBatch {
            action: WifiSoftApAction::Cancel,
            now_epoch_sec: 1_796_260_013,
        },
        1_796_260_013,
    );

    let settings_dir = temp_dir("repro-7-settings");
    fs::write(
        settings_dir.join("settings.json"),
        r#"{"auto_launch_enabled":"true","keep_alive_enabled":false,"custom_theme":"warm_paper"}"#,
    )
    .unwrap();
    let mut host_cfg = DesktopBeanHost::new(&settings_dir);
    let loaded_string_bool = host_cfg.projection().settings.auto_launch_enabled;
    let _ = host_cfg.dispatch(WorkspaceCommand::SetKeepAlive(true), 1_796_260_020);
    let saved_raw = fs::read_to_string(settings_dir.join("settings.json")).unwrap();

    let _ = fs::remove_dir_all(&dir);
    let _ = fs::remove_dir_all(&settings_dir);

    assert!(
        fresh_custom_citations_valid,
        "workspace_projection on fresh empty host fabricated [S1] citations against an empty spine!"
    );
    assert!(
        host_spine_synced,
        "SelectMinuteTemplate on empty host left host.spine() empty or minutes.latest_minutes None!"
    );
    assert!(
        !still_has_removed_builtin,
        "RemoveCustomMinuteSection on built-in heading '客户需求' was a silent no-op!"
    );
    assert_eq!(
        proj_direct_complete.wifi_batch.phase,
        WifiBatchPhase::Completed,
        "StartDefaultSoftAp -> ResumeAndComplete (without Interrupt) got stuck in {:?}!",
        proj_direct_complete.wifi_batch.phase
    );
    assert_eq!(
        proj_direct_complete.wifi_batch.finalized_count, 2,
        "Direct ResumeAndComplete finalized {} files instead of 2!",
        proj_direct_complete.wifi_batch.finalized_count
    );
    assert!(
        !stale_bookmark_leaked,
        "persist_finalized leaked bookmark 5000ms from previous aggregate into finalized file {:?}!",
        proj_direct_complete.active_aggregate.bookmarks
    );
    assert_eq!(
        proj_cancelled.wifi_batch.finalized_count, 0,
        "Cancel left stale finalized_count={}!",
        proj_cancelled.wifi_batch.finalized_count
    );
    assert_eq!(
        proj_cancelled.wifi_batch.salvaged_count, 0,
        "Cancel left stale salvaged_count={}!",
        proj_cancelled.wifi_batch.salvaged_count
    );
    assert!(
        proj_cancelled.wifi_endpoint.is_none(),
        "Cancel left stale wifi_endpoint={:?}!",
        proj_cancelled.wifi_endpoint
    );
    assert!(
        loaded_string_bool,
        "load_desktop_settings ignored string boolean \"true\"!"
    );
    assert!(
        saved_raw.contains("warm_paper"),
        "save_desktop_settings clobbered extra key custom_theme in settings.json: {saved_raw}"
    );
}

#[test]
fn repro_8_slice_t_fishbone_roundtrip_multi_take_reset_card_live_update_simulate_sync_trash_clear_search_doc_index_and_wifi_catalog() {
    use koe_desktop_core::{
        domain::{MinuteCause, MinuteFishbone, MinuteTopic},
        minutes::{encode_meeting_minutes_json, parse_meeting_minutes_json, MinutesEvent},
        models::OfflineFileEntry,
        WifiBatchPhase, WifiSoftApAction, WorkspaceCommand,
    };

    let dir = temp_dir("repro-8");

    let mut spine_fb = UtteranceSpine::new("rec-fb");
    let s1_fb = spine_fb
        .append_segment("海外渠道固件认证排期顺延两周，导致交付存在延迟风险。", 0, 2_000, "zh", "qwen")
        .unwrap();
    let mins_fb = MeetingMinutesV2 {
        version: 2,
        spine_revision: spine_fb.revision(),
        title: "Q4 供应链风险评审".to_string(),
        overview: "海外渠道固件认证排期顺延两周，导致交付存在延迟风险。".to_string(),
        topics: vec![MinuteTopic {
            title: "海外交付排期".to_string(),
            summary: "海外渠道固件认证排期顺延两周。".to_string(),
            citations: vec![s1_fb],
            points: Vec::new(),
            fishbone: None,
        }],
        decisions: vec![MinutePoint {
            claim: "海外渠道固件认证排期顺延两周。".to_string(),
            speaker: None,
            owner: None,
            due: None,
            citations: vec![s1_fb],
        }],
        actions: Vec::new(),
        questions: Vec::new(),
        fishbones: vec![MinuteFishbone {
            issue: "海外渠道固件认证延期".to_string(),
            causes: vec![MinuteCause {
                category: "合规与认证".to_string(),
                description: "海外渠道固件认证排期顺延两周，导致交付存在延迟风险。".to_string(),
                citations: vec![s1_fb],
            }],
        }],
        terms: Vec::new(),
        custom_sections: Vec::new(),
        review_items: Vec::new(),
    };
    let encoded_fb = encode_meeting_minutes_json(&mins_fb);
    let reparsed_fb = parse_meeting_minutes_json(&encoded_fb, &spine_fb).unwrap();

    let mut host_takes = DesktopBeanHost::new(&dir);
    let _ = host_takes.start_realtime_recording(Some(1001), 1_796_270_000_000);
    let _ = host_takes.ingest_dashscope_asr_event(
        r#"{"header":{"event":"task-started"}}"#,
        1_796_270_000_100,
    );
    let _ = host_takes.ingest_dashscope_asr_event(
        r#"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"sentence_id":1,"sentence_end":true,"text":"第一段录音第一句：确认明日上午十点召开评审会。"}}}}"#,
        1_796_270_000_500,
    );
    let _ = host_takes.ingest_dashscope_asr_event(
        r#"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"sentence_id":2,"sentence_end":true,"text":"第一段录音第二句：上一段录音遗留的旧内容。"}}}}"#,
        1_796_270_001_000,
    );
    let _ = host_takes.ingest_dashscope_asr_event(
        r#"{"header":{"event":"task-finished"}}"#,
        1_796_270_001_200,
    );
    let _ = host_takes.start_realtime_recording(Some(1002), 1_796_270_010_000);
    let _ = host_takes.ingest_dashscope_asr_event(
        r#"{"header":{"event":"task-started"}}"#,
        1_796_270_010_100,
    );
    let _ = host_takes.ingest_dashscope_asr_event(
        r#"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"sentence_id":1,"sentence_end":true,"text":"第二段全新录音：下午三点去机场接客户。"}}}}"#,
        1_796_270_010_500,
    );
    let take2_texts: Vec<String> = host_takes
        .projection()
        .active_aggregate
        .spine
        .segments()
        .iter()
        .map(|s| s.text.clone())
        .collect();

    let mut host_cards = DesktopBeanHost::new(&dir);
    let s1_card = host_cards
        .ingest_utterance_with_context(
            "第一句：确定由张总负责硬件试产。",
            0,
            1_000,
            "zh",
            "qwen",
            1_796_270_020,
        )
        .unwrap();
    let mcp_init = host_cards.dispatch(
        WorkspaceCommand::DispatchJsonRpc {
            request_json: r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_minutes","arguments":{}}}"#.to_string(),
        },
        1_796_270_021,
    );
    let mcp_initial_resp = mcp_init.last_jsonrpc_response.clone();
    let cand_mins = MeetingMinutesV2 {
        version: 2,
        spine_revision: host_cards.spine().revision(),
        title: "硬件试产周会".to_string(),
        overview: "第一句：确定由张总负责硬件试产。".to_string(),
        topics: vec![MinuteTopic {
            title: "试产分工".to_string(),
            summary: "第一句：确定由张总负责硬件试产。".to_string(),
            citations: vec![s1_card],
            points: Vec::new(),
            fishbone: None,
        }],
        decisions: vec![MinutePoint {
            claim: "第一句：确定由张总负责硬件试产。".to_string(),
            speaker: None,
            owner: None,
            due: None,
            citations: vec![s1_card],
        }],
        actions: vec![MinutePoint {
            claim: "第一句：确定由张总负责硬件试产。".to_string(),
            speaker: None,
            owner: None,
            due: None,
            citations: vec![s1_card],
        }],
        questions: Vec::new(),
        fishbones: Vec::new(),
        terms: Vec::new(),
        custom_sections: Vec::new(),
        review_items: Vec::new(),
    };
    let _ = host_cards.reduce_minutes(MinutesEvent::CandidateReceived(cand_mins));
    let s2_card = host_cards
        .ingest_utterance_with_context(
            "第二句：李工周五前提交电池低温放电曲线报告。",
            1_000,
            2_200,
            "zh",
            "qwen",
            1_796_270_022,
        )
        .unwrap();
    let any_card_cites_s2 = host_cards
        .projection()
        .visual_cards
        .iter()
        .any(|c| c.citations.contains(&s2_card));

    let sim_dir = temp_dir("repro-8-sim");
    let mut host_sim = DesktopBeanHost::new(&sim_dir);
    let _ = host_sim.simulate_realtime_pipeline(1_796_270_030);
    let sim_host_spine_len = host_sim.spine().len();
    let sim_pack_res = host_sim.export_koepack_v2_to_disk("实时自检包", "2026-11-08T15:00:00Z");

    let trash_dir = temp_dir("repro-8-trash");
    let mut host_trash = DesktopBeanHost::new(&trash_dir);
    let _ = host_trash.dispatch(WorkspaceCommand::SimulateRealtimePipeline, 1_796_270_040);
    let trash_id = host_trash.projection().library.selected_id.unwrap();
    let proj_after_trash_all =
        host_trash.dispatch(WorkspaceCommand::MoveToTrash(trash_id), 1_796_270_041);

    let search_dir = temp_dir("repro-8-search");
    let mut host_search = DesktopBeanHost::new(&search_dir);
    let _ = host_search.ingest_dashscope_asr_event(
        r#"{"header":{"event":"task-started"}}"#,
        1_796_270_050_000,
    );
    let _ = host_search.ingest_dashscope_asr_event(
        r#"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"sentence_id":1,"sentence_end":true,"text":"初步讨论量子加密模块"}}}}"#,
        1_796_270_050_200,
    );
    let _ = host_search.ingest_dashscope_asr_event(
        r#"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"sentence_id":1,"sentence_end":true,"text":"正式确认采购量子加密芯片并完成固件签名"}}}}"#,
        1_796_270_050_500,
    );
    let _ = host_search.ingest_dashscope_asr_event(
        r#"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"sentence_id":2,"sentence_end":true,"text":"午餐预订广东烧鹅便当"}}}}"#,
        1_796_270_050_900,
    );
    let proj_q1 = host_search.dispatch(
        WorkspaceCommand::SearchContext {
            query: "量子加密芯片".to_string(),
            limit: 5,
        },
        1_796_270_051,
    );
    let proj_q2 = host_search.dispatch(
        WorkspaceCommand::SearchContext {
            query: "广东烧鹅便当".to_string(),
            limit: 5,
        },
        1_796_270_052,
    );

    let wifi_dir = temp_dir("repro-8-wifi");
    let mut host_wifi = DesktopBeanHost::new(&wifi_dir);
    host_wifi.session_mut().catalog = (1..=10)
        .map(|i| OfflineFileEntry {
            file_id: 600 + i,
            end_time: Some(1_796_270_010 + i),
            duration_ms: 2_000,
        })
        .collect();
    let _ = host_wifi.dispatch(
        WorkspaceCommand::ControlWifiSoftApBatch {
            action: WifiSoftApAction::StartDefaultSoftAp,
            now_epoch_sec: 1_796_270_060,
        },
        1_796_270_060,
    );
    let _ = host_wifi.session_mut().begin_offline_pull(601, 2_000);
    let timer_out = host_wifi.poll_timers(5_000, 1_796_270_065);
    let proj_wifi_10 = host_wifi.dispatch(
        WorkspaceCommand::ControlWifiSoftApBatch {
            action: WifiSoftApAction::ResumeAndComplete,
            now_epoch_sec: 1_796_270_066,
        },
        1_796_270_066,
    );

    let _ = fs::remove_dir_all(&dir);
    let _ = fs::remove_dir_all(&sim_dir);
    let _ = fs::remove_dir_all(&trash_dir);
    let _ = fs::remove_dir_all(&search_dir);
    let _ = fs::remove_dir_all(&wifi_dir);

    assert_eq!(
        reparsed_fb.fishbones.len(),
        1,
        "encode_meeting_minutes_json dropped top-level fishbones: {encoded_fb}"
    );
    assert_eq!(
        take2_texts,
        vec!["第二段全新录音：下午三点去机场接客户。".to_string()],
        "Take 2 leaked Take 1 segments or failed to reset qwen_accumulator: {take2_texts:?}"
    );
    assert!(
        !mcp_initial_resp.contains(r#"\"isDraft\":false"#)
            && !mcp_initial_resp.contains(r#""isDraft":false"#),
        "MCP get_minutes returned auto-synthesized placeholder as formal non-draft minutes: {mcp_initial_resp}"
    );
    assert!(
        any_card_cites_s2,
        "VisualSummaryCards froze on [S1] after S2 was appended following CandidateReceived!"
    );
    assert!(
        sim_host_spine_len > 0 && sim_pack_res.is_ok(),
        "simulate_realtime_pipeline left host.spine empty (len={sim_host_spine_len}) or failed koepack export: {sim_pack_res:?}"
    );
    assert!(
        proj_after_trash_all.active_aggregate.spine.is_empty()
            && proj_after_trash_all.active_aggregate.duration_ms == 0,
        "Trashing the last recording left stale spine (len={}) or duration_ms={} on active_aggregate!",
        proj_after_trash_all.active_aggregate.spine.len(),
        proj_after_trash_all.active_aggregate.duration_ms
    );
    assert_eq!(
        proj_q1.search_hits.first().and_then(|h| h.citation),
        SegmentId::new(1),
        "SearchContext for revised S1 returned wrong citation: {:?}",
        proj_q1.search_hits.first()
    );
    assert_eq!(
        proj_q2.search_hits.first().and_then(|h| h.citation),
        SegmentId::new(2),
        "SearchContext for S2 after S1 revision returned wrong citation: {:?}",
        proj_q2.search_hits.first()
    );
    assert!(
        !timer_out.outbound_tx_frames.is_empty(),
        "poll_timers during WifiBatchPhase::Transferring starved the 5000ms BLE PullingOffline watchdog!"
    );
    assert_eq!(
        proj_wifi_10.wifi_batch.phase,
        WifiBatchPhase::Completed,
        "ResumeAndComplete truncated a 10-file catalog in {:?}",
        proj_wifi_10.wifi_batch
    );
}

#[test]
fn benchmark_slice_t_three_layer_zero_glue_end_to_end_pipeline() {
    use koe_desktop_core::WorkspaceCommand;
    use std::time::Instant;

    let profile = if cfg!(debug_assertions) {
        "debug"
    } else {
        "release"
    };
    let dir = temp_dir(&format!("bench-slice-t-{profile}"));
    let mut host = DesktopBeanHost::new(&dir);
    let now_sec = 1_796_280_000;

    let t0 = Instant::now();
    let exported = host.simulate_realtime_pipeline(now_sec);
    let opus_pipeline_us = t0.elapsed().as_micros();

    for idx in 0..800u64 {
        let _ = host.ingest_utterance_with_context(
            format!(
                "安克录音豆第 {idx} 段原话：下周三前完成海外渠道样品合同审阅并归档百炼实时流纪要。"
            ),
            idx * 1_000,
            (idx + 1) * 1_000,
            "zh",
            "qwen3-asr-flash-realtime",
            now_sec + 1,
        );
    }

    let t1 = Instant::now();
    let search_proj = host.dispatch(
        WorkspaceCommand::SearchContext {
            query: "海外渠道样品合同".to_string(),
            limit: 5,
        },
        now_sec + 10,
    );
    let search_projection_us = t1.elapsed().as_micros();

    let t2 = Instant::now();
    let (pack_summary, pack_path) = host
        .export_koepack_v2_to_disk("安克随心记终局基准测试", "2026-11-08T15:00:00Z")
        .expect("benchmark koepack v2 export must succeed");
    let koepack_export_us = t2.elapsed().as_micros();

    let t3 = Instant::now();
    let _ = host.dispatch_jsonrpc(
        r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#,
        now_sec + 11,
    );
    let _ = host.dispatch_jsonrpc(
        r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        now_sec + 11,
    );
    let mcp_resp = host
        .dispatch_jsonrpc(
            r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_context","arguments":{"query":"海外渠道","limit":5}}}"#,
            now_sec + 12,
        )
        .expect("MCP search_context must return JSON-RPC response");
    let mcp_jsonrpc_us = t3.elapsed().as_micros();
    let total_us = t0.elapsed().as_micros();

    let wav_len = fs::metadata(&exported.wav_path).map_or(0, |m| m.len());
    let pack_len = fs::metadata(&pack_path).map_or(0, |m| m.len());
    let _ = fs::remove_dir_all(&dir);

    assert_eq!(search_proj.visual_cards.len(), 6);
    assert!(!search_proj.search_hits.is_empty());
    assert!(wav_len > 44 && pack_len > 128);
    assert!(mcp_resp.contains(&pack_summary.id) || mcp_resp.contains("海外渠道"));
    assert!(
        total_us < 2_000_000,
        "end-to-end 3-layer pipeline exceeded 2s budget: {total_us} us"
    );

    println!(
        "BENCH_SLICE_T profile={profile} opus_60slices_us={opus_pipeline_us} bm25_and_projection_us={search_projection_us} koepack_v2_us={koepack_export_us} mcp_jsonrpc_us={mcp_jsonrpc_us} total_us={total_us} spine_segments={} cards={} wav_bytes={wav_len} pack_bytes={pack_len}",
        search_proj.active_aggregate.spine.len(),
        search_proj.visual_cards.len()
    );
}


