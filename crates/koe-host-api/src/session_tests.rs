use super::*;
use koe_runtime::PcmIngestStatus;
use serde_json::{Value, json};
use std::{
    ffi::CStr,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};

struct TempWorkspace(PathBuf);

impl TempWorkspace {
    fn new(label: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let dir = std::env::temp_dir().join(format!(
            "koe-ffi-{label}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }
}

impl Drop for TempWorkspace {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn parse_snapshot(session: &HostSessionGuard, now: u64) -> Value {
    serde_json::from_str(&session.snapshot_json(now).unwrap()).unwrap()
}

fn send_json(session: &HostSessionGuard, payload: Value, now: u64) -> Value {
    serde_json::from_str(&session.dispatch_json(&payload.to_string(), now).unwrap()).unwrap()
}

#[test]
fn session_lifecycle_has_no_seed_data_and_rejects_duplicate_writer() {
    let root = TempWorkspace::new("v2");
    let path = CString::new(root.0.to_str().unwrap()).unwrap();
    unsafe {
        let handle = koe_host_session_create(path.as_ptr());
        assert_ne!(handle, 0);
        assert_eq!(koe_host_session_create(path.as_ptr()), 0);
        let snapshot = koe_host_session_snapshot_json(handle, 1000);
        let text = CStr::from_ptr(snapshot).to_str().unwrap();
        assert!(text.contains("\"records\":[]"));
        assert!(text.contains("\"version\":2"));
        koe_host_string_free(snapshot);
        let effects = koe_host_session_drain_local_asr_json(handle);
        assert_eq!(CStr::from_ptr(effects).to_str().unwrap(), "[]");
        koe_host_string_free(effects);
        assert!(koe_host_session_destroy(handle));
        assert!(koe_host_session_drain_local_asr_json(handle).is_null());
        assert_eq!(koe_host_session_generation(handle), 0);
        assert!(!koe_host_session_destroy(handle));
    }
}

#[test]
fn receipt_abi_layouts_and_invalid_pointer_boundaries_reject_without_accepting() {
    assert_eq!(std::mem::size_of::<KoePcmReceipt>(), 24);
    assert_eq!(std::mem::align_of::<KoePcmReceipt>(), 8);
    assert_eq!(std::mem::size_of::<KoePlaybackReceipt>(), 40);
    assert_eq!(std::mem::align_of::<KoePlaybackReceipt>(), 8);
    assert_eq!(
        KoePcmReceipt::default().status,
        PcmIngestStatus::Rejected as u32
    );
    assert!(!KoePlaybackReceipt::default().applied);

    let ws = TempWorkspace::new("bounds");
    let session = HostSessionGuard::open(&ws.0).unwrap();
    let now = 1_800_000_000;
    let started = send_json(
        &session,
        json!({"type": "start_microphone", "inputId": ""}),
        now,
    );
    let rec_id = started["microphone"]["recordId"].as_str().unwrap();
    let ses_id = started["microphone"]["sessionId"].as_str().unwrap();
    let ready = send_json(
        &session,
        json!({
            "type": "microphone_started",
            "recordId": rec_id,
            "sessionId": ses_id,
            "lane": "microphone",
            "sampleRate": 16_000
        }),
        now,
    );
    assert!(ready["error"].is_null());

    let c_rec = CString::new(rec_id).unwrap();
    let c_ses = CString::new(ses_id).unwrap();
    let c_lane = CString::new("microphone").unwrap();
    let valid_samples = [42i16; 16];

    unsafe {
        let bad_handle = koe_host_session_ingest_pcm(
            999_999,
            c_rec.as_ptr(),
            c_ses.as_ptr(),
            c_lane.as_ptr(),
            0,
            0,
            0,
            false,
            valid_samples.as_ptr(),
            valid_samples.len(),
            now,
        );
        assert_eq!(bad_handle.status, PcmIngestStatus::Rejected as u32);
        assert_eq!(bad_handle.generation, 0);

        let null_str = koe_host_session_ingest_pcm(
            session.handle(),
            std::ptr::null(),
            c_ses.as_ptr(),
            c_lane.as_ptr(),
            0,
            0,
            0,
            false,
            valid_samples.as_ptr(),
            valid_samples.len(),
            now,
        );
        assert_eq!(null_str.status, PcmIngestStatus::Rejected as u32);

        let null_samples_nonzero = koe_host_session_ingest_pcm(
            session.handle(),
            c_rec.as_ptr(),
            c_ses.as_ptr(),
            c_lane.as_ptr(),
            0,
            0,
            0,
            false,
            std::ptr::null(),
            16,
            now,
        );
        assert_eq!(
            null_samples_nonzero.status,
            PcmIngestStatus::Rejected as u32
        );
        assert_eq!(null_samples_nonzero.generation, 0);

        let empty_chunk = koe_host_session_ingest_pcm(
            session.handle(),
            c_rec.as_ptr(),
            c_ses.as_ptr(),
            c_lane.as_ptr(),
            0,
            0,
            0,
            false,
            std::ptr::null(),
            0,
            now,
        );
        assert_eq!(empty_chunk.status, PcmIngestStatus::Rejected as u32);
        assert_eq!(empty_chunk.next_sequence, 0);
        assert_eq!(empty_chunk.generation, 0);
        assert!(parse_snapshot(&session, now)["error"].is_null());

        let oversized_chunk = koe_host_session_ingest_pcm(
            session.handle(),
            c_rec.as_ptr(),
            c_ses.as_ptr(),
            c_lane.as_ptr(),
            0,
            0,
            0,
            false,
            valid_samples.as_ptr(),
            usize::MAX,
            now,
        );
        assert_eq!(oversized_chunk.status, PcmIngestStatus::Rejected as u32);
        assert_eq!(oversized_chunk.next_sequence, 0);
        assert_eq!(oversized_chunk.generation, 0);
        assert!(parse_snapshot(&session, now)["error"].is_null());

        let null_playback = koe_host_session_report_playback_progress(
            session.handle(),
            std::ptr::null(),
            1,
            100,
            true,
            now,
            now,
        );
        assert!(!null_playback.applied);
        assert_eq!(null_playback.generation, 0);
    }
}

#[test]
fn ingest_pcm_matches_microphone_chunk_json_across_chunk0_dual_lanes_rejection_and_stale_session() {
    let ws_fast = TempWorkspace::new("pcm-fast");
    let ws_json = TempWorkspace::new("pcm-json");
    let fast = HostSessionGuard::open(&ws_fast.0).unwrap();
    let baseline = HostSessionGuard::open(&ws_json.0).unwrap();
    let now = 1_800_000_000u64;
    let base_clock_ns = 1_000_000_000u64;

    let start_cmd =
        json!({"type": "start_microphone", "inputId": "", "includeSystem": true, "clockNs": base_clock_ns});
    let s_fast = send_json(&fast, start_cmd.clone(), now);
    let s_json = send_json(&baseline, start_cmd, now);

    let fast_rec = s_fast["microphone"]["recordId"]
        .as_str()
        .unwrap()
        .to_string();
    let fast_ses = s_fast["microphone"]["sessionId"]
        .as_str()
        .unwrap()
        .to_string();
    let json_rec = s_json["microphone"]["recordId"]
        .as_str()
        .unwrap()
        .to_string();
    let json_ses = s_json["microphone"]["sessionId"]
        .as_str()
        .unwrap()
        .to_string();

    for (lane, rate) in [("microphone", 16_000u32), ("system", 48_000u32)] {
        let f_snap = send_json(
            &fast,
            json!({"type": "microphone_started", "recordId": fast_rec, "sessionId": fast_ses, "lane": lane, "sampleRate": rate}),
            now,
        );
        let j_snap = send_json(
            &baseline,
            json!({"type": "microphone_started", "recordId": json_rec, "sessionId": json_ses, "lane": lane, "sampleRate": rate}),
            now,
        );
        assert!(f_snap["error"].is_null());
        assert!(j_snap["error"].is_null());
    }

    let mic_chunk_0: Vec<i16> = (0..320).map(|i| (i * 37 - 2000) as i16).collect();
    let mic_chunk_1: Vec<i16> = (0..320).map(|i| (1500 - i * 19) as i16).collect();
    let sys_chunk_0: Vec<i16> = (0..960).map(|i| ((i % 97) * 113 - 4000) as i16).collect();
    let sys_chunk_1: Vec<i16> = (0..960).map(|i| ((i % 53) * 211 - 5000) as i16).collect();

    let r0 = fast.ingest_pcm(
        &fast_rec,
        &fast_ses,
        "microphone",
        0,
        Some((0, base_clock_ns)),
        &mic_chunk_0,
        now + 1,
    );
    let j0 = send_json(
        &baseline,
        json!({
            "type": "microphone_chunk",
            "recordId": json_rec,
            "sessionId": json_ses,
            "lane": "microphone",
            "sequence": 0,
            "samples": mic_chunk_0,
            "timing": {"epoch": 0, "capturedStartNs": base_clock_ns}
        }),
        now + 1,
    );
    assert_eq!(r0.status, PcmIngestStatus::Accepted as u32);
    assert_eq!(r0.next_sequence, 1);
    assert_eq!(r0.generation, j0["generation"].as_u64().unwrap());
    assert_eq!(
        parse_snapshot(&fast, now + 1)["records"]
            .as_array()
            .unwrap()
            .len(),
        1
    );

    let steps: &[(&str, u64, u64, &[i16])] = &[
        ("system", 0, base_clock_ns + 5_000_000, &sys_chunk_0),
        ("microphone", 1, base_clock_ns + 20_000_000, &mic_chunk_1),
        ("system", 1, base_clock_ns + 25_000_000, &sys_chunk_1),
    ];
    for &(lane, seq, ts_ns, samples) in steps {
        let receipt = fast.ingest_pcm(
            &fast_rec,
            &fast_ses,
            lane,
            seq,
            Some((0, ts_ns)),
            samples,
            now + 2,
        );
        let j_snap = send_json(
            &baseline,
            json!({
                "type": "microphone_chunk",
                "recordId": json_rec,
                "sessionId": json_ses,
                "lane": lane,
                "sequence": seq,
                "samples": samples,
                "timing": {"epoch": 0, "capturedStartNs": ts_ns}
            }),
            now + 2,
        );
        assert_eq!(receipt.status, PcmIngestStatus::Accepted as u32);
        assert_eq!(receipt.next_sequence, seq + 1);
        assert_eq!(receipt.generation, j_snap["generation"].as_u64().unwrap());
    }

    let rejected = fast.ingest_pcm(
        &fast_rec,
        &fast_ses,
        "microphone",
        9,
        Some((0, base_clock_ns + 40_000_000)),
        &mic_chunk_0,
        now + 3,
    );
    let j_rejected = send_json(
        &baseline,
        json!({
            "type": "microphone_chunk",
            "recordId": json_rec,
            "sessionId": json_ses,
            "lane": "microphone",
            "sequence": 9,
            "samples": mic_chunk_0,
            "timing": {"epoch": 0, "capturedStartNs": base_clock_ns + 40_000_000}
        }),
        now + 3,
    );
    assert_eq!(rejected.status, PcmIngestStatus::Rejected as u32);
    assert_eq!(rejected.next_sequence, 2);
    assert_eq!(
        parse_snapshot(&fast, now + 3)["error"],
        j_rejected["error"],
        "rejection error message must match Command::MicrophoneChunk"
    );

    for (stale_rec, stale_lane) in [("mic-stale", "microphone"), (fast_rec.as_str(), "unknown")] {
        let stale = fast.ingest_pcm(
            stale_rec,
            &fast_ses,
            stale_lane,
            0,
            Some((0, base_clock_ns)),
            &mic_chunk_0,
            now + 4,
        );
        let j_stale_rec = if stale_rec == fast_rec {
            json_rec.as_str()
        } else {
            stale_rec
        };
        let j_stale = send_json(
            &baseline,
            json!({
                "type": "microphone_chunk",
                "recordId": j_stale_rec,
                "sessionId": json_ses,
                "lane": stale_lane,
                "sequence": 0,
                "samples": mic_chunk_0,
                "timing": {"epoch": 0, "capturedStartNs": base_clock_ns}
            }),
            now + 4,
        );
        assert_eq!(stale.status, PcmIngestStatus::StaleSession as u32);
        assert_eq!(stale.next_sequence, 0);
        assert_eq!(stale.generation, j_stale["generation"].as_u64().unwrap());
        assert!(parse_snapshot(&fast, now + 4)["error"].is_null());
        assert!(j_stale["error"].is_null());
    }

    send_json(&fast, json!({"type": "stop_microphone"}), now + 5);
    send_json(&baseline, json!({"type": "stop_microphone"}), now + 5);
    for lane in ["microphone", "system"] {
        let f_stop = send_json(
            &fast,
            json!({"type": "microphone_stopped", "recordId": fast_rec, "sessionId": fast_ses, "lane": lane, "sequence": 2, "epoch": 0}),
            now + 5,
        );
        let j_stop = send_json(
            &baseline,
            json!({"type": "microphone_stopped", "recordId": json_rec, "sessionId": json_ses, "lane": lane, "sequence": 2, "epoch": 0}),
            now + 5,
        );
        assert!(f_stop["error"].is_null(), "fast stop failed: {f_stop}");
        assert!(j_stop["error"].is_null(), "json stop failed: {j_stop}");
    }

    let final_fast_raw = fast.snapshot_json(now + 5).unwrap();
    let final_json_normalized = baseline
        .snapshot_json(now + 5)
        .unwrap()
        .replace(&json_rec, &fast_rec)
        .replace(ws_json.0.to_str().unwrap(), ws_fast.0.to_str().unwrap());
    let final_fast: Value = serde_json::from_str(&final_fast_raw).unwrap();
    let mut final_json: Value = serde_json::from_str(&final_json_normalized).unwrap();
    assert!(
        final_fast["workspaces"]["voiceInput"]["companionEpoch"]
            .as_str()
            .is_some_and(|s| !s.is_empty())
    );
    final_json["workspaces"]["voiceInput"]["companionEpoch"] =
        final_fast["workspaces"]["voiceInput"]["companionEpoch"].clone();
    assert_eq!(final_fast, final_json);

    let audio_dir_fast = ws_fast.0.join("audio");
    let audio_dir_json = ws_json.0.join("audio");
    assert_eq!(
        std::fs::read(audio_dir_fast.join(format!("{fast_rec}.wav"))).unwrap(),
        std::fs::read(audio_dir_json.join(format!("{json_rec}.wav"))).unwrap(),
    );
    assert_eq!(
        std::fs::read(audio_dir_fast.join(format!("{fast_rec}-system.wav"))).unwrap(),
        std::fs::read(audio_dir_json.join(format!("{json_rec}-system.wav"))).unwrap(),
    );

    let post_stop = fast.ingest_pcm(
        &fast_rec,
        &fast_ses,
        "microphone",
        2,
        Some((0, base_clock_ns + 60_000_000)),
        &mic_chunk_0,
        now + 6,
    );
    assert_eq!(post_stop.status, PcmIngestStatus::StaleSession as u32);
    assert_eq!(post_stop.next_sequence, 0);
}

#[test]
fn report_playback_progress_clamps_elides_duplicates_and_tracks_day_and_trash_watermarks() {
    let ws = TempWorkspace::new("playback-fast");
    let session = HostSessionGuard::open(&ws.0).unwrap();
    let day1 = 1_800_000_000u64;

    let s = send_json(
        &session,
        json!({"type": "start_microphone", "inputId": "", "clockNs": 1_000_000_000u64}),
        day1,
    );
    let rec_id = s["microphone"]["recordId"].as_str().unwrap().to_string();
    let ses_id = s["microphone"]["sessionId"].as_str().unwrap().to_string();
    send_json(
        &session,
        json!({"type": "microphone_started", "recordId": rec_id, "sessionId": ses_id, "lane": "microphone", "sampleRate": 16_000}),
        day1,
    );
    let samples = vec![500i16; 1_600];
    let pcm = session.ingest_pcm(
        &rec_id,
        &ses_id,
        "microphone",
        0,
        Some((0, 1_000_000_000)),
        &samples,
        day1,
    );
    assert_eq!(pcm.status, PcmIngestStatus::Accepted as u32);
    send_json(&session, json!({"type": "stop_microphone"}), day1);
    let saved = send_json(
        &session,
        json!({"type": "microphone_stopped", "recordId": rec_id, "sessionId": ses_id, "lane": "microphone", "sequence": 1, "epoch": 0}),
        day1,
    );
    assert!(saved["error"].is_null());
    assert_eq!(saved["notice"].as_str(), Some("录音已保存到本机"));
    let duration_ms = saved["detail"]["durationMs"].as_u64().unwrap();
    assert_eq!(duration_ms, 100);

    let playing = send_json(&session, json!({"type": "playback", "isPlaying": true}), day1);
    let req_id = playing["playback"]["requestId"].as_u64().unwrap();
    let with_err = send_json(&session, json!({"type": "unknown_command"}), day1);
    assert!(with_err["error"].is_string());
    let base_gen = with_err["generation"].as_u64().unwrap();

    let clamped = session.report_playback_progress(&rec_id, req_id, 999, true, day1, day1);
    assert!(clamped.applied);
    assert!(!clamped.needs_full_snapshot);
    assert_eq!(clamped.prev_generation, base_gen);
    assert_eq!(clamped.generation, base_gen + 1);
    assert_eq!(clamped.position_ms, 100);
    assert_eq!(clamped.now_epoch_sec, day1);
    assert!(clamped.is_playing);

    let snap_after_clamp = parse_snapshot(&session, day1);
    assert_eq!(snap_after_clamp["generation"].as_u64(), Some(clamped.generation));
    assert_eq!(snap_after_clamp["playback"]["positionMs"].as_u64(), Some(100));
    assert_eq!(snap_after_clamp["playback"]["isPlaying"].as_bool(), Some(true));
    assert_eq!(snap_after_clamp["error"], with_err["error"]);

    let dup = session.report_playback_progress(&rec_id, req_id, 999, true, day1, day1 + 5);
    assert!(!dup.applied);
    assert!(!dup.needs_full_snapshot);
    assert_eq!(dup.prev_generation, clamped.generation);
    assert_eq!(dup.generation, clamped.generation);
    assert_eq!(dup.position_ms, 100);
    assert_eq!(dup.now_epoch_sec, day1 + 5);
    assert!(dup.is_playing);
    assert_eq!(koe_host_session_generation(session.handle()), clamped.generation);

    let stale_req = session.report_playback_progress(&rec_id, req_id + 77, 40, false, day1 + 5, day1 + 6);
    assert!(!stale_req.applied);
    assert!(!stale_req.needs_full_snapshot);
    assert_eq!(stale_req.generation, clamped.generation);
    assert_eq!(stale_req.position_ms, 0);
    assert_eq!(stale_req.now_epoch_sec, day1 + 6);
    assert!(!stale_req.is_playing);

    let unknown_rec = session.report_playback_progress("missing-rec", req_id, 40, false, day1 + 5, day1 + 6);
    assert!(!unknown_rec.applied);
    assert!(!unknown_rec.needs_full_snapshot);
    assert_eq!(unknown_rec.generation, clamped.generation);

    let uninitialized_caller = session.report_playback_progress(&rec_id, req_id, 30, true, 0, day1 + 6);
    assert!(uninitialized_caller.applied);
    assert!(uninitialized_caller.needs_full_snapshot);

    let day2 = day1 + 86_400;
    let day3 = day2 + 86_400;
    let _external_bridge_read_day2 = parse_snapshot(&session, day2);
    let _external_bridge_read_day3 = parse_snapshot(&session, day3);

    let stale_rollover = session.report_playback_progress(&rec_id, req_id + 77, 40, true, day1 + 6, day2);
    assert!(!stale_rollover.applied);
    assert!(stale_rollover.needs_full_snapshot);
    assert_eq!(stale_rollover.prev_generation, uninitialized_caller.generation);
    assert_eq!(stale_rollover.generation, uninitialized_caller.generation + 1);

    let active_rollover = session.report_playback_progress(&rec_id, req_id, 45, true, day1 + 6, day2);
    assert!(active_rollover.applied);
    assert!(active_rollover.needs_full_snapshot);
    assert_eq!(active_rollover.prev_generation, stale_rollover.generation);
    assert_eq!(active_rollover.generation, stale_rollover.generation + 1);
    assert_eq!(active_rollover.position_ms, 45);
    assert_eq!(active_rollover.now_epoch_sec, day2);

    let clean_day2 = session.report_playback_progress(&rec_id, req_id, 55, true, day2, day2 + 10);
    assert!(clean_day2.applied);
    assert!(!clean_day2.needs_full_snapshot);
    assert_eq!(clean_day2.position_ms, 55);

    let note_snap = send_json(
        &session,
        json!({"type": "create_note", "title": "To Trash", "text": "ephemeral", "stayOnPage": true}),
        day2 + 20,
    );
    let note_id = note_snap["records"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["title"] == "To Trash")
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let trashed_snap = send_json(
        &session,
        json!({"type": "trash_record", "recordId": note_id}),
        day2 + 20,
    );
    assert_eq!(trashed_snap["trashRecords"].as_array().unwrap().len(), 1);
    assert_eq!(trashed_snap["trashRecords"][0]["remainingDays"].as_u64(), Some(30));

    let mut host_watermark = day2 + 20;
    for offset in 1..=60u64 {
        let tick_now = day2 + 20 + offset;
        let pos = 10 + offset;
        let tick = session.report_playback_progress(&rec_id, req_id, pos, true, host_watermark, tick_now);
        assert!(tick.applied);
        assert!(!tick.needs_full_snapshot);
        assert_eq!(tick.now_epoch_sec, tick_now);
        host_watermark = tick.now_epoch_sec;
    }

    let day3_early = day2 + 86_400 + 5;
    let day3_snap = parse_snapshot(&session, day3_early);
    assert_eq!(day3_snap["trashRecords"][0]["remainingDays"].as_u64(), Some(30));
    host_watermark = day3_early;

    let trash_step_sec = day2 + 20 + 86_400;
    let trash_step_tick = session.report_playback_progress(
        &rec_id,
        req_id,
        75,
        true,
        host_watermark,
        trash_step_sec,
    );
    assert!(trash_step_tick.applied);
    assert!(trash_step_tick.needs_full_snapshot);
    let after_step = parse_snapshot(&session, trash_step_sec);
    assert_eq!(after_step["trashRecords"][0]["remainingDays"].as_u64(), Some(29));
    host_watermark = trash_step_sec;

    let expired_sec = day2 + 31 * 86_400;
    let purged_tick = session.report_playback_progress(
        &rec_id,
        req_id,
        70,
        false,
        host_watermark,
        expired_sec,
    );
    assert!(purged_tick.applied);
    assert!(purged_tick.needs_full_snapshot);
    assert_eq!(purged_tick.position_ms, 70);
    assert!(!purged_tick.is_playing);
    let after_purge = parse_snapshot(&session, expired_sec);
    assert!(after_purge["trashRecords"].as_array().unwrap().is_empty());
}

#[test]
fn ingest_pcm_rejects_sample_count_8193_without_advancing_sequence_or_generation() {
    let ws = TempWorkspace::new("pcm-8193");
    let session = HostSessionGuard::open(&ws.0).unwrap();
    let now = 1_800_000_000u64;
    let started = send_json(&session, json!({"type": "start_microphone", "inputId": ""}), now);
    let rec_id = started["microphone"]["recordId"].as_str().unwrap().to_string();
    let ses_id = started["microphone"]["sessionId"].as_str().unwrap().to_string();
    let ready = send_json(
        &session,
        json!({
            "type": "microphone_started",
            "recordId": rec_id,
            "sessionId": ses_id,
            "lane": "microphone",
            "sampleRate": 16_000
        }),
        now,
    );
    assert!(ready["error"].is_null());

    let gen_before = koe_host_session_generation(session.handle());
    let oversized = vec![7i16; 8193];
    let receipt = session.ingest_pcm(&rec_id, &ses_id, "microphone", 0, None, &oversized, now);
    assert_eq!(receipt.status, PcmIngestStatus::Rejected as u32);
    assert_eq!(receipt.next_sequence, 0);
    assert_eq!(receipt.generation, 0);
    assert_eq!(koe_host_session_generation(session.handle()), gen_before);
    assert!(parse_snapshot(&session, now)["error"].is_null());
}
