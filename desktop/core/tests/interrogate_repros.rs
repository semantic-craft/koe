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
