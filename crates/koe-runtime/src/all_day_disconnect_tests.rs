use super::*;
use koe_engine::{
    ogg_opus::OggOpus,
    session::{FinalizedRecording, RecordingEntry},
    wav::{OpusWave, WAV_SAMPLE_RATE},
};

fn telemetry_rx_with_recording_status(recording_status: u8) -> Vec<u8> {
    let mut pkt = RX_MAGIC.to_vec();
    pkt.extend_from_slice(&[0x01, 0x01, 0x01, 0x00, 0x00]);
    pkt.push(1);
    pkt.push(8);
    pkt.push(recording_status);
    pkt.extend_from_slice(b"04.92");
    pkt.extend_from_slice(b"D3200ALLDAY00001");
    pkt.extend_from_slice(&(64u32 * 1024 * 1024).to_le_bytes());
    pkt.extend_from_slice(&(60u32 * 1024 * 1024).to_le_bytes());
    pkt.push(0);
    pkt.extend_from_slice(b"2.1.0");
    pkt.push(9);
    pkt.extend_from_slice(&[0xAA, 0xBB, 0xCC, 0xDD, 0x63, 0x9D]);
    pkt.extend_from_slice(&[0, 0, 0, 0, 0]);
    pkt.push(0);
    pkt.extend_from_slice(b"1.0.0");
    let total_len = u16::try_from(pkt.len() + 1).unwrap().to_le_bytes();
    pkt[7] = total_len[0];
    pkt[8] = total_len[1];
    let csum = ProtocolFrame::checksum(&pkt);
    pkt.push(csum);
    pkt
}

fn connect_bean_session(
    runtime: &mut KoeRuntime,
    connection_id: &str,
    with_initial_telemetry: bool,
    now: u64,
) -> [u8; 32] {
    let connecting: Value = serde_json::from_str(
        &runtime.dispatch_json(
            &json!({
                "type": "device_event",
                "event": "connecting",
                "connectionId": connection_id,
                "deviceName": "Soundcore Work"
            })
            .to_string(),
            now,
        ),
    )
    .unwrap();
    assert!(connecting["error"].is_null(), "{connecting}");
    let ready: Value = serde_json::from_str(
        &runtime.dispatch_json(
            &json!({
                "type": "device_event",
                "event": "ready",
                "connectionId": connection_id,
                "deviceName": "Soundcore Work"
            })
            .to_string(),
            now,
        ),
    )
    .unwrap();
    assert!(ready["error"].is_null(), "{ready}");

    let outbound = runtime.drain_outbound_ble_frames();
    let ecdh_tx = outbound
        .iter()
        .find(|f| f.len() >= 75 && f[5] == 0x2E && f[6] == 0x01)
        .expect("ready event must emit 2E/01 public key frame");
    let client_pub = &ecdh_tx[9..74];
    let bean_priv = [0x24u8; 32];
    let bean_pub = DeviceCrypto::p256_public_key(&bean_priv).unwrap();
    let shared = DeviceCrypto::p256_ecdh_shared_secret(&bean_priv, client_pub).unwrap();
    let mut ecdh_payload = Vec::with_capacity(97);
    ecdh_payload.extend_from_slice(&bean_pub);
    ecdh_payload.extend_from_slice(&shared);
    runtime.ingest_ble_chunk(&rx_cmd(0x2E, 0x01, &ecdh_payload), now);
    if with_initial_telemetry {
        runtime.ingest_ble_chunk(&telemetry_rx_with_recording_status(0), now);
        runtime.ingest_ble_chunk(&rx_cmd(0x1B, 0x0E, &[0, 0]), now);
    }
    runtime.drain_outbound_ble_frames();

    let derived = DeviceCrypto::hkdf_sha256(&shared, &[1, 2, 3], &[1, 2, 3], 32);
    let mut session_key = [0u8; 32];
    session_key.copy_from_slice(&derived);
    session_key
}

fn file_head_rx_with_key(session_key: &[u8; 32], file_id: u32, file_size: u32) -> Vec<u8> {
    let session_nonce = [0x33; 16];
    let mut key_material = b"soundcored3200".to_vec();
    key_material.extend_from_slice(&FILE_KEY);
    let wrapped_key =
        DeviceCrypto::aes_ctr_decrypt(&key_material, session_key, &session_nonce).unwrap();
    let mut payload = Vec::with_capacity(87);
    payload.extend_from_slice(&file_id.to_le_bytes());
    payload.extend_from_slice(&file_size.to_le_bytes());
    payload.extend_from_slice(&FILE_NONCE);
    payload.extend_from_slice(&wrapped_key);
    payload.extend_from_slice(&session_nonce);
    payload.push(0);
    rx_cmd(0x1a, 0x07, &payload)
}

fn catalog_entries_1b0e_rx(entries: &[OfflineFileEntry]) -> Vec<u8> {
    let mut payload = Vec::with_capacity(2 + entries.len() * 12);
    payload.extend_from_slice(&u16::try_from(entries.len()).unwrap().to_le_bytes());
    for entry in entries {
        payload.extend_from_slice(&entry.file_id.to_le_bytes());
        payload.extend_from_slice(&entry.end_time.unwrap_or(0).to_le_bytes());
        payload.extend_from_slice(&entry.duration_ms.to_le_bytes());
    }
    rx_cmd(0x1b, 0x0e, &payload)
}

fn settle_local_speech(runtime: &mut KoeRuntime, now: u64) {
    loop {
        let finishes: Vec<u64> = local_effects(runtime)
            .into_iter()
            .filter(|e| e["kind"] == "finish")
            .filter_map(|e| e["operationId"].as_u64())
            .collect();
        if finishes.is_empty() {
            break;
        }
        for op in finishes {
            runtime.dispatch_json(
                &json!({
                    "type": "local_asr_result",
                    "operationId": op,
                    "text": "本地分段识别完成。",
                    "startMs": 0,
                    "endMs": 20,
                    "isFinal": true
                })
                .to_string(),
                now,
            );
            runtime.dispatch_json(
                &json!({"type": "local_asr_finished", "operationId": op}).to_string(),
                now,
            );
        }
        runtime.poll_timers(0, now);
    }
}

#[test]
fn coalesced_empty_and_non_empty_transfers() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    command(
        &mut runtime,
        json!({"type":"set_ble_auto_connect","enabled":false}),
    );
    let sk = connect_bean_session(&mut runtime, "conn-coal", true, NOW);
    command(&mut runtime, json!({"type":"start_all_day","source":"bean"}));
    runtime.drain_outbound_ble_frames();

    let mut coalesced = Vec::new();
    coalesced.extend_from_slice(&rx(0x06, &951u32.to_le_bytes()));
    coalesced.extend_from_slice(&rx(0x0a, &951u32.to_le_bytes()));
    coalesced.extend_from_slice(&rx(0x06, &952u32.to_le_bytes()));
    coalesced.extend_from_slice(&file_head_rx_with_key(&sk, 952, u32::MAX));
    coalesced.extend_from_slice(&encrypted_slices(0..3));
    coalesced.extend_from_slice(&rx(0x0a, &952u32.to_le_bytes()));
    runtime.ingest_ble_chunk(&coalesced, NOW + 1);

    let ids: Vec<String> = runtime.workspace().records().keys().cloned().collect();
    assert!(
        !ids.iter().any(|id| id.starts_with("live-951-")),
        "empty 951 shell must not steal 952 audio or remain in workspace: {ids:?}"
    );
    let rec_952 = runtime
        .workspace()
        .records()
        .values()
        .find(|r| r.aggregate.recording_id.starts_with("live-952-"))
        .expect("record for 952 must exist");
    assert_eq!(rec_952.aggregate.file_id, 952);
    assert_eq!(rec_952.aggregate.duration_ms, 400);
    assert!(
        recording_assets::audio_path(&dir.0, &rec_952.aggregate.recording_id)
            .unwrap()
            .exists(),
        "952 audio must be saved under live-952, not hijacked onto live-951"
    );
    assert_eq!(rec_952.all_day.as_ref().unwrap().ordinal, 1);
    assert!(runtime.captures.targets.is_empty());
}

#[test]
fn queued_offline_pull_not_hijacked_by_aborted_live_capture() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    command(
        &mut runtime,
        json!({"type":"set_ble_auto_connect","enabled":false}),
    );
    connect_bean_session(&mut runtime, "conn-queued", true, NOW);

    let mut raw_opus = [0u8; OPUS_FRAME_BYTES];
    raw_opus[..REAL_OPUS_20MS_440HZ_PACKET.len()].copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
    let ogg_opus_bytes = OggOpus::mux_raw_frames(&raw_opus);
    let preview_wav_bytes = OpusWave::decode_raw_frames_to_wav(
        &raw_opus,
        WAV_SAMPLE_RATE,
        &[],
        Some(koe_opus::create_libopus_decoder),
    )
    .unwrap();
    runtime.device.finalized.push(FinalizedRecording {
        entry: RecordingEntry {
            id: 100,
            bean_file_id: 100,
            created_at_epoch_sec: NOW,
            duration_ms: 400,
            byte_count: ogg_opus_bytes.len() as u32,
            marks_ms: vec![],
        },
        ogg_opus_bytes,
        preview_wav_bytes,
        is_realtime: false,
        base_slice_offset: 0,
    });

    let mut aborted_live = rx(0x06, &200u32.to_le_bytes());
    aborted_live.extend_from_slice(&rx(0x0a, &200u32.to_le_bytes()));
    runtime.ingest_ble_chunk(&aborted_live, NOW + 1);

    let ids: Vec<String> = runtime.workspace().records().keys().cloned().collect();
    assert!(
        ids.iter().any(|id| id.starts_with("bean-100-")),
        "queued offline pull 100 must save as standalone bean-100-*, got {ids:?}"
    );
    assert!(
        !ids.iter().any(|id| id.starts_with("live-200-")),
        "aborted empty live capture 200 must not hijack offline pull 100 or leave shell: {ids:?}"
    );
    assert!(runtime.is_device_file_synced(100));
    assert!(runtime.captures.targets.is_empty());
}

#[test]
fn standby_open_file_disconnect_does_not_leak_target() {
    for explicit_disconnect in [false, true] {
        let dir = Sandbox::new();
        let mut runtime = KoeRuntime::open(&dir.0).unwrap();
        command(
            &mut runtime,
            json!({"type":"set_ble_auto_connect","enabled":false}),
        );
        command(
            &mut runtime,
            json!({"type":"set_companion_mode","mode":"collar_standby"}),
        );
        let sk = connect_bean_session(&mut runtime, "conn-sb", false, NOW);
        runtime.ingest_ble_chunk(&telemetry_rx_with_recording_status(1), NOW);
        runtime.ingest_ble_chunk(
            &catalog_entries_1b0e_rx(&[OfflineFileEntry {
                file_id: 7601,
                duration_ms: 2_000,
                end_time: Some(0),
            }]),
            NOW,
        );
        runtime.poll_timers(0, NOW);
        runtime.drain_outbound_ble_frames();
        assert!(runtime.companion.standby_stream_owned);

        runtime.ingest_ble_chunk(&rx(0x06, &7601u32.to_le_bytes()), NOW + 1);
        runtime.ingest_ble_chunk(&file_head_rx_with_key(&sk, 7601, u32::MAX), NOW + 1);
        runtime.ingest_ble_chunk(&encrypted_slices(0..3), NOW + 1);
        assert!(!runtime.is_standby_file(7601));
        assert!(runtime.treats_file_as_standby(7601));

        if explicit_disconnect {
            command(&mut runtime, json!({"type":"device_disconnect"}));
        } else {
            command(
                &mut runtime,
                json!({
                    "type": "device_event",
                    "event": "disconnected",
                    "connectionId": "conn-sb"
                }),
            );
        }

        assert!(
            runtime.captures.targets.is_empty(),
            "disconnecting standby on open pre-existing file must not leak targets (explicit={explicit_disconnect}): {:?}",
            runtime.captures.targets
        );
        assert!(
            runtime.workspace().records().is_empty(),
            "standby tail must not be saved as user record (explicit={explicit_disconnect})"
        );
        assert!(!runtime.is_device_file_synced(7601));
    }
}

#[test]
fn aborted_empty_bean_capture_purges_shell_and_device_release_finishes_all_day() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    command(
        &mut runtime,
        json!({"type":"set_ble_auto_connect","enabled":false}),
    );
    command(
        &mut runtime,
        json!({"type":"configure_speech","engine":"apple_speech"}),
    );
    command(
        &mut runtime,
        json!({"type":"local_asr_readiness","state":"ready","message":"本机识别已就绪"}),
    );

    let sk = connect_bean_session(&mut runtime, "conn-rel", true, NOW);
    command(&mut runtime, json!({"type":"start_all_day","source":"bean"}));
    runtime.drain_outbound_ble_frames();

    runtime.ingest_ble_chunk(&rx(0x06, &960u32.to_le_bytes()), NOW + 1);
    assert_eq!(runtime.workspace().records().len(), 1);
    runtime.ingest_ble_chunk(&rx(0x0a, &960u32.to_le_bytes()), NOW + 1);

    runtime.ingest_ble_chunk(&rx(0x06, &961u32.to_le_bytes()), NOW + 2);
    runtime.ingest_ble_chunk(&file_head_rx_with_key(&sk, 961, u32::MAX), NOW + 2);
    runtime.ingest_ble_chunk(&encrypted_slices(0..3), NOW + 2);

    let released = command(&mut runtime, json!({"type":"device_release"}));
    assert!(released["error"].is_null(), "{released}");
    settle_local_speech(&mut runtime, NOW + 3);
    runtime.poll_timers(0, NOW + 3);

    let snap = runtime.snapshot(NOW + 3);
    let quit = command(&mut runtime, json!({"type":"request_quit"}));
    assert!(
        snap["allDay"]["state"] == "idle" && quit["lifecycle"]["quitPhase"] == "ready",
        "device_release during active bean all_day must finish run and allow clean quit; got allDay.state={}, quitPhase={}",
        snap["allDay"]["state"],
        quit["lifecycle"]["quitPhase"]
    );
    assert!(
        !runtime
            .workspace()
            .records()
            .keys()
            .any(|id| id.starts_with("live-960-")),
        "0-second empty shell 960 must be purged"
    );
    assert!(
        !runtime.workspace().is_bean_file_purged(960),
        "purging 0-second empty shell 960 must not tombstone hardware file 960"
    );
    let salvaged = runtime
        .workspace()
        .records()
        .values()
        .find(|r| r.aggregate.file_id == 961)
        .expect("device_release must salvage buffered slices for active file 961");
    assert_eq!(salvaged.aggregate.duration_ms, 400);
    assert!(
        recording_assets::audio_path(&dir.0, &salvaged.aggregate.recording_id)
            .unwrap()
            .exists()
    );
}

#[test]
fn all_day_bean_disconnect_finishes_run_and_reconnect_pulls_full_hardware_file() {
    {
        let dir = Sandbox::new();
        let mut runtime = KoeRuntime::open(&dir.0).unwrap();
        command(
            &mut runtime,
            json!({"type":"set_ble_auto_connect","enabled":false}),
        );
        command(
            &mut runtime,
            json!({"type":"configure_speech","engine":"apple_speech"}),
        );
        command(
            &mut runtime,
            json!({"type":"local_asr_readiness","state":"ready","message":"本机识别已就绪"}),
        );

        let sk1 = connect_bean_session(&mut runtime, "conn-a1", true, NOW);
        command(&mut runtime, json!({"type":"start_all_day","source":"bean"}));
        runtime.drain_outbound_ble_frames();

        runtime.ingest_ble_chunk(&rx(0x06, &950u32.to_le_bytes()), NOW);
        runtime.drain_outbound_ble_frames();
        runtime.ingest_ble_chunk(&file_head_rx_with_key(&sk1, 950, u32::MAX), NOW);
        for start in (0..15_000).step_by(100) {
            runtime.ingest_ble_chunk(&encrypted_slices(start..start + 100), NOW);
        }
        settle_local_speech(&mut runtime, NOW);
        runtime.ingest_ble_chunk(&encrypted_slices(15_000..15_100), NOW + 1);

        let disconnected: Value = serde_json::from_str(
            &runtime.dispatch_json(
                &json!({
                    "type": "device_event",
                    "event": "disconnected",
                    "connectionId": "conn-a1"
                })
                .to_string(),
                NOW + 2,
            ),
        )
        .unwrap();
        assert!(disconnected["error"].is_null(), "{disconnected}");
        settle_local_speech(&mut runtime, NOW + 2);
        runtime.poll_timers(0, NOW + 2);

        let snap = runtime.snapshot(NOW + 2);
        assert_eq!(
            snap["allDay"]["state"], "idle",
            "BLE disconnect must finish bean all-day run once salvaged segments drain"
        );
        let seg1 = runtime
            .workspace()
            .records()
            .values()
            .find(|r| r.all_day.as_ref().map(|g| g.ordinal) == Some(1))
            .expect("segment 1 must be persisted");
        let seg2 = runtime
            .workspace()
            .records()
            .values()
            .find(|r| r.all_day.as_ref().map(|g| g.ordinal) == Some(2))
            .expect("segment 2 must be salvaged on disconnect");
        let seg1_id = seg1.aggregate.recording_id.clone();
        let seg2_id = seg2.aggregate.recording_id.clone();
        assert_eq!(seg2.aggregate.duration_ms, 2_000);
        assert_eq!(
            recording_assets::transcription_pcm(&dir.0, &seg2_id)
                .unwrap()
                .len(),
            2_000 * 32
        );
        assert!(!runtime.is_device_file_synced(950));

        let quit: Value = serde_json::from_str(
            &runtime.dispatch_json(r#"{"type":"request_quit"}"#, NOW + 2),
        )
        .unwrap();
        assert_eq!(
            quit["lifecycle"]["quitPhase"], "ready",
            "quitPhase must not stay blocked on stale device_recording_active: {quit}"
        );
        runtime.dispatch_json(r#"{"type":"cancel_quit"}"#, NOW + 2);

        let sk2 = connect_bean_session(&mut runtime, "conn-a2", false, NOW + 3);
        assert!(
            runtime.device.is_connected(),
            "reconnect ECDH reply must transition session back to Connected"
        );
        runtime.ingest_ble_chunk(
            &catalog_entries_1b0e_rx(&[OfflineFileEntry {
                file_id: 950,
                duration_ms: 420_000,
                end_time: Some(NOW as u32 + 420),
            }]),
            NOW + 3,
        );
        runtime.poll_timers(0, NOW + 3);
        let tx = runtime.drain_outbound_ble_frames();
        assert!(
            tx.iter().any(|f| {
                f.len() >= 17
                    && f[5] == 0x1a
                    && f[6] == 0x07
                    && f[9..13] == 0u32.to_le_bytes()
                    && f[13..17] == 950u32.to_le_bytes()
            }),
            "reconnect catalog must auto-start 1A/07 offline pull from offset 0 for file 950: {tx:?}"
        );

        let offline_slices = 200u32;
        runtime.ingest_ble_chunk(
            &file_head_rx_with_key(&sk2, 950, offline_slices * 166),
            NOW + 4,
        );
        runtime.ingest_ble_chunk(&encrypted_slices(0..offline_slices), NOW + 4);
        runtime.ingest_ble_chunk(&rx(0x0a, &950u32.to_le_bytes()), NOW + 4);

        assert!(
            runtime.is_device_file_synced(950),
            "full hardware file pull must confirm disk custody for file 950"
        );
        let full_record = runtime
            .workspace()
            .records()
            .values()
            .find(|r| {
                r.aggregate.recording_id.starts_with("bean-950-") && r.all_day.is_none()
            })
            .expect("reconnect pull must persist a standalone non-all_day bean-950 record");
        assert!(
            recording_assets::audio_path(&dir.0, &full_record.aggregate.recording_id)
                .unwrap()
                .exists()
        );
        assert!(runtime.workspace().record(&seg1_id).is_some());
        assert!(runtime.workspace().record(&seg2_id).is_some());
    }

    {
        let dir = Sandbox::new();
        let mut runtime = KoeRuntime::open(&dir.0).unwrap();
        command(
            &mut runtime,
            json!({"type":"set_ble_auto_connect","enabled":false}),
        );
        command(
            &mut runtime,
            json!({"type":"configure_speech","engine":"apple_speech"}),
        );
        command(
            &mut runtime,
            json!({"type":"local_asr_readiness","state":"ready","message":"本机识别已就绪"}),
        );

        let sk1 = connect_bean_session(&mut runtime, "conn-b1", true, NOW);
        command(&mut runtime, json!({"type":"start_all_day","source":"bean"}));
        runtime.drain_outbound_ble_frames();

        runtime.ingest_ble_chunk(&rx(0x06, &951u32.to_le_bytes()), NOW);
        runtime.drain_outbound_ble_frames();
        runtime.ingest_ble_chunk(&file_head_rx_with_key(&sk1, 951, u32::MAX), NOW);
        for start in (0..15_000).step_by(100) {
            runtime.ingest_ble_chunk(&encrypted_slices(start..start + 100), NOW);
        }
        assert!(runtime.device.session.opus_buffer.is_empty());
        let seg1_id = runtime
            .workspace()
            .records()
            .keys()
            .next()
            .unwrap()
            .clone();
        settle_local_speech(&mut runtime, NOW);

        runtime.dispatch_json(
            &json!({
                "type": "device_event",
                "event": "disconnected",
                "connectionId": "conn-b1"
            })
            .to_string(),
            NOW + 1,
        );
        settle_local_speech(&mut runtime, NOW + 1);
        runtime.poll_timers(0, NOW + 1);

        assert_eq!(runtime.snapshot(NOW + 1)["allDay"]["state"], "idle");
        assert!(runtime.captures.active.is_empty());
        assert!(runtime.captures.targets.is_empty());
        assert!(!runtime.is_device_file_synced(951));

        connect_bean_session(&mut runtime, "conn-b2", false, NOW + 2);
        command(&mut runtime, json!({"type":"start_all_day","source":"bean"}));
        runtime.drain_outbound_ble_frames();
        runtime.ingest_ble_chunk(&rx(0x06, &953u32.to_le_bytes()), NOW + 2);
        let shell_953_id = runtime
            .workspace()
            .records()
            .keys()
            .find(|id| *id != &seg1_id)
            .unwrap()
            .clone();
        assert!(runtime.device.session.opus_buffer.is_empty());

        runtime.dispatch_json(
            &json!({
                "type": "device_event",
                "event": "disconnected",
                "connectionId": "conn-b2"
            })
            .to_string(),
            NOW + 3,
        );
        settle_local_speech(&mut runtime, NOW + 3);
        runtime.poll_timers(0, NOW + 3);

        assert_eq!(runtime.snapshot(NOW + 3)["allDay"]["state"], "idle");
        assert!(runtime.captures.active.is_empty());
        assert!(runtime.captures.targets.is_empty());
        assert!(runtime.workspace().record(&shell_953_id).is_none());

        let sk3 = connect_bean_session(&mut runtime, "conn-b3", false, NOW + 4);
        runtime.ingest_ble_chunk(
            &catalog_entries_1b0e_rx(&[
                OfflineFileEntry {
                    file_id: 952,
                    duration_ms: 40,
                    end_time: Some(NOW as u32 + 10),
                },
                OfflineFileEntry {
                    file_id: 951,
                    duration_ms: 320_000,
                    end_time: Some(NOW as u32 + 20),
                },
                OfflineFileEntry {
                    file_id: 953,
                    duration_ms: 40,
                    end_time: Some(NOW as u32 + 30),
                },
            ]),
            NOW + 4,
        );

        for fid in [952u32, 951u32, 953u32] {
            runtime.poll_timers(0, NOW + 5);
            let tx = runtime.drain_outbound_ble_frames();
            assert!(
                tx.iter().any(|f| {
                    f.len() >= 17
                        && f[5] == 0x1a
                        && f[6] == 0x07
                        && f[9..13] == 0u32.to_le_bytes()
                        && f[13..17] == fid.to_le_bytes()
                }),
                "expected auto offline pull from offset 0 for file {fid}: {tx:?}"
            );
            runtime.ingest_ble_chunk(&file_head_rx_with_key(&sk3, fid, 2 * 166), NOW + 5);
            runtime.ingest_ble_chunk(&encrypted_slices(0..2), NOW + 5);
            runtime.ingest_ble_chunk(&rx(0x0a, &fid.to_le_bytes()), NOW + 5);
            assert!(
                runtime.is_device_file_synced(fid),
                "offline pull of file {fid} must confirm disk custody"
            );
            assert!(
                runtime.workspace().records().values().any(|r| {
                    r.aggregate
                        .recording_id
                        .starts_with(&format!("bean-{fid}-"))
                        && r.all_day.is_none()
                }),
                "offline pull of file {fid} must create standalone non-all_day record"
            );
        }
        assert!(runtime.workspace().record(&shell_953_id).is_none());
        assert!(
            !recording_assets::audio_path(&dir.0, &shell_953_id)
                .unwrap()
                .exists(),
            "unrelated offline pulls must not hijack empty all-day shell record {shell_953_id}"
        );
        assert!(
            recording_assets::audio_path(&dir.0, &seg1_id)
                .unwrap()
                .exists()
        );
    }
}

#[test]
fn all_day_microphone_cross_segment_pause_and_resume_preserves_valid_timelines() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    command(
        &mut runtime,
        json!({"type":"set_ble_auto_connect","enabled":false}),
    );

    let started = command(
        &mut runtime,
        json!({"type":"start_all_day","source":"microphone","inputId":"fixture-mic"}),
    );
    let ticket = started["microphone"].clone();
    let record_id = ticket["recordId"].as_str().unwrap().to_owned();
    let session_id = ticket["sessionId"].as_str().unwrap().to_owned();

    let mut epoch = 0u64;
    let mut clock_ns = 1_000_000_000u64;
    let mut epoch_samples = 0u64;
    let mut sequence = 0u64;
    let chunk_samples = vec![1200i16; 8_000];

    command(
        &mut runtime,
        json!({
            "type": "microphone_prepared",
            "recordId": record_id,
            "sessionId": session_id,
            "epoch": epoch,
            "clockNs": clock_ns
        }),
    );
    command(
        &mut runtime,
        json!({
            "type": "microphone_started",
            "recordId": record_id,
            "sessionId": session_id,
            "lane": "microphone",
            "sampleRate": 16_000
        }),
    );

    let feed_chunks = |runtime: &mut KoeRuntime,
                       count: usize,
                       epoch: u64,
                       clock_ns: u64,
                       epoch_samples: &mut u64,
                       sequence: &mut u64| {
        for _ in 0..count {
            let captured_start_ns = clock_ns + (*epoch_samples * 1_000_000_000) / 16_000;
            command(
                runtime,
                json!({
                    "type": "microphone_chunk",
                    "recordId": record_id,
                    "sessionId": session_id,
                    "lane": "microphone",
                    "sequence": *sequence,
                    "samples": chunk_samples,
                    "timing": {
                        "epoch": epoch,
                        "capturedStartNs": captured_start_ns
                    }
                }),
            );
            *epoch_samples += chunk_samples.len() as u64;
            *sequence += 1;
        }
    };

    let pause_and_resume = |runtime: &mut KoeRuntime,
                            pause_gap_ns: u64,
                            epoch: &mut u64,
                            clock_ns: &mut u64,
                            epoch_samples: &mut u64,
                            sequence: u64| {
        command(runtime, json!({"type":"pause_microphone"}));
        command(
            runtime,
            json!({
                "type": "microphone_paused",
                "recordId": record_id,
                "sessionId": session_id,
                "lane": "microphone",
                "sequence": sequence,
                "epoch": *epoch
            }),
        );
        let resumed_clock = *clock_ns + (*epoch_samples * 1_000_000_000) / 16_000 + pause_gap_ns;
        command(
            runtime,
            json!({"type":"resume_microphone","clockNs":resumed_clock}),
        );
        *epoch += 1;
        *clock_ns = resumed_clock;
        *epoch_samples = 0;
    };

    feed_chunks(
        &mut runtime,
        200,
        epoch,
        clock_ns,
        &mut epoch_samples,
        &mut sequence,
    );
    pause_and_resume(
        &mut runtime,
        4_000_000_000,
        &mut epoch,
        &mut clock_ns,
        &mut epoch_samples,
        sequence,
    );
    feed_chunks(
        &mut runtime,
        400,
        epoch,
        clock_ns,
        &mut epoch_samples,
        &mut sequence,
    );

    assert_eq!(
        runtime.workspace().records().len(),
        1,
        "reaching 300,000 ms must publish segment 1 while opening segment 2 staging"
    );

    pause_and_resume(
        &mut runtime,
        5_000_000_000,
        &mut epoch,
        &mut clock_ns,
        &mut epoch_samples,
        sequence,
    );
    feed_chunks(
        &mut runtime,
        4,
        epoch,
        clock_ns,
        &mut epoch_samples,
        &mut sequence,
    );
    pause_and_resume(
        &mut runtime,
        3_000_000_000,
        &mut epoch,
        &mut clock_ns,
        &mut epoch_samples,
        sequence,
    );
    feed_chunks(
        &mut runtime,
        2,
        epoch,
        clock_ns,
        &mut epoch_samples,
        &mut sequence,
    );

    command(&mut runtime, json!({"type":"stop_all_day"}));
    command(
        &mut runtime,
        json!({
            "type": "microphone_stopped",
            "recordId": record_id,
            "sessionId": session_id,
            "lane": "microphone",
            "sequence": sequence,
            "epoch": epoch
        }),
    );

    assert_eq!(runtime.snapshot(NOW)["allDay"]["state"], "idle");
    assert_eq!(runtime.workspace().records().len(), 2);

    drop(runtime);
    let reopened = KoeRuntime::open(&dir.0).unwrap();
    let mut segments: Vec<_> = reopened.workspace().records().values().collect();
    segments.sort_by_key(|r| r.all_day.as_ref().unwrap().ordinal);
    assert_eq!(segments.len(), 2);
    assert_eq!(segments[0].all_day.as_ref().unwrap().ordinal, 1);
    assert_eq!(segments[1].all_day.as_ref().unwrap().ordinal, 2);
    assert_eq!(
        segments[0].all_day.as_ref().unwrap().run_id,
        segments[1].all_day.as_ref().unwrap().run_id
    );
    assert_eq!(segments[0].aggregate.duration_ms, 300_000);
    assert_eq!(segments[1].aggregate.duration_ms, 3_000);

    let lane1 = &segments[0].capture_lanes[0];
    let lane2 = &segments[1].capture_lanes[0];
    assert_eq!(lane1.timeline.len(), 2);
    assert_eq!(lane2.timeline.len(), 2);
    assert_eq!(
        lane1.timeline.last().unwrap().end_ns(16_000),
        Some(300_000_000_000)
    );
    assert_eq!(
        lane2.timeline.last().unwrap().end_ns(16_000),
        Some(3_000_000_000)
    );

    let wav1 = recording_assets::audio_path(&dir.0, lane1.asset_id.as_deref().unwrap()).unwrap();
    let wav2 = recording_assets::audio_path(&dir.0, lane2.asset_id.as_deref().unwrap()).unwrap();
    assert_ne!(wav1, wav2);
    assert!(wav1.exists());
    assert!(wav2.exists());
}
