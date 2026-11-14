use std::{
    fs,
    io::{BufRead, BufReader, ErrorKind, Write},
    os::unix::net::UnixStream,
    path::Path,
    time::{Duration, Instant},
};

use koe_engine::{
    crypto::{AesCtrStreamDecrypt, DeviceCrypto},
    frame::{ProtocolFrame, RX_MAGIC},
    session::REAL_OPUS_20MS_440HZ_PACKET,
    transport::{OPUS_FRAME_BYTES, SLICE_RECORD_BYTES, UNFINISHED_FILE_SIZE},
};
use koe_runtime::{CompanionStreamEvent, resolve_bridge_socket_path};
use serde_json::{Value, json};

use crate::{
    HostSessionGuard, koe_host_session_generation, local_bridge::tests::temp_workspace, sessions,
};

fn rx_frame(cmd_type: u8, cmd_id: u8, payload: &[u8]) -> Vec<u8> {
    let mut frame = Vec::from(RX_MAGIC);
    frame.extend_from_slice(&[0x01, cmd_type, cmd_id]);
    frame.extend_from_slice(&u16::try_from(payload.len() + 10).unwrap().to_le_bytes());
    frame.extend_from_slice(payload);
    frame.push(ProtocolFrame::checksum(&frame));
    frame
}

fn setup_standby_host_session(ws: &Path) -> (HostSessionGuard, [u8; 32], [u8; 16]) {
    let _ = fs::remove_dir_all(ws);
    let session = HostSessionGuard::open(ws).expect("host session should open");
    let file_key = [0x5Au8; 32];
    let file_nonce = [0x6Bu8; 16];

    let mut table = sessions().lock().unwrap();
    let entry = table.entries.get_mut(&session.handle()).unwrap();
    entry
        .runtime
        .dispatch_json(r#"{"type":"set_companion_mode","mode":"collar_standby"}"#, 0);
    entry
        .runtime
        .dispatch_json(r#"{"type":"set_ble_auto_connect","enabled":false}"#, 0);
    entry.runtime.dispatch_json(
        r#"{"type":"device_event","event":"connecting","connectionId":"sock-bean","deviceName":"Soundcore Work"}"#,
        0,
    );
    entry.runtime.dispatch_json(
        r#"{"type":"device_event","event":"ready","connectionId":"sock-bean","deviceName":"Soundcore Work"}"#,
        0,
    );
    let outbound = entry.runtime.drain_outbound_ble_frames();
    let ecdh_tx = outbound
        .iter()
        .find(|f| f.len() >= 75 && f[5] == 0x2E && f[6] == 0x01)
        .unwrap();
    let bean_priv = [0x24u8; 32];
    let bean_pub = DeviceCrypto::p256_public_key(&bean_priv).unwrap();
    let shared = DeviceCrypto::p256_ecdh_shared_secret(&bean_priv, &ecdh_tx[9..74]).unwrap();
    let mut ecdh_payload = Vec::with_capacity(97);
    ecdh_payload.extend_from_slice(&bean_pub);
    ecdh_payload.extend_from_slice(&shared);
    entry
        .runtime
        .ingest_ble_chunk(&rx_frame(0x2E, 0x01, &ecdh_payload), 0);

    let mut tel = Vec::from(RX_MAGIC);
    tel.extend_from_slice(&[0x01, 0x01, 0x01, 0x00, 0x00, 1, 8, 0]);
    tel.extend_from_slice(b"04.92D3200COLLAR00001");
    tel.extend_from_slice(&(64u32 * 1024 * 1024).to_le_bytes());
    tel.extend_from_slice(&(60u32 * 1024 * 1024).to_le_bytes());
    tel.push(0);
    tel.extend_from_slice(b"2.1.0");
    tel.push(9);
    tel.extend_from_slice(&[0xAA, 0xBB, 0xCC, 0xDD, 0x63, 0x9D, 0, 0, 0, 0, 0, 0]);
    tel.extend_from_slice(b"1.0.0");
    let total_len = u16::try_from(tel.len() + 1).unwrap().to_le_bytes();
    tel[7] = total_len[0];
    tel[8] = total_len[1];
    let csum = ProtocolFrame::checksum(&tel);
    tel.push(csum);
    entry.runtime.ingest_ble_chunk(&tel, 0);
    entry
        .runtime
        .ingest_ble_chunk(&rx_frame(0x1B, 0x0E, &[0, 0]), 0);
    entry.runtime.drain_outbound_ble_frames();

    let mut list_payload = Vec::with_capacity(14);
    list_payload.extend_from_slice(&1u16.to_le_bytes());
    list_payload.extend_from_slice(&777u32.to_le_bytes());
    list_payload.extend_from_slice(&0u32.to_le_bytes());
    list_payload.extend_from_slice(&1_000u32.to_le_bytes());
    entry
        .runtime
        .ingest_ble_chunk(&rx_frame(0x1B, 0x0E, &list_payload), 0);
    entry.runtime.drain_outbound_ble_frames();

    let derived = DeviceCrypto::hkdf_sha256(&shared, &[1, 2, 3], &[1, 2, 3], 32);
    let mut session_key = [0u8; 32];
    session_key.copy_from_slice(&derived);
    let mut plain_key_mat = b"soundcored3200".to_vec();
    plain_key_mat.extend_from_slice(&file_key);
    let session_nonce = [0x33u8; 16];
    let enc_file_key =
        DeviceCrypto::aes_ctr_decrypt(&plain_key_mat, &session_key, &session_nonce).unwrap();
    let mut head_payload = Vec::with_capacity(87);
    head_payload.extend_from_slice(&777u32.to_le_bytes());
    head_payload.extend_from_slice(&UNFINISHED_FILE_SIZE.to_le_bytes());
    head_payload.extend_from_slice(&file_nonce);
    head_payload.extend_from_slice(&enc_file_key);
    head_payload.extend_from_slice(&session_nonce);
    head_payload.push(0);
    entry
        .runtime
        .ingest_ble_chunk(&rx_frame(0x1A, 0x07, &head_payload), 0);
    let _ = entry.runtime.drain_companion_events();
    assert!(entry.runtime.is_standby_ready());
    drop(table);
    (session, file_key, file_nonce)
}

fn ingest_standby_slices(
    session: &HostSessionGuard,
    file_key: &[u8; 32],
    file_nonce: &[u8; 16],
    range: std::ops::Range<u32>,
) {
    let decryptor = AesCtrStreamDecrypt::new(file_key, file_nonce).unwrap();
    let mut payload = Vec::with_capacity(range.len() * SLICE_RECORD_BYTES);
    for seq in range {
        payload.extend_from_slice(&seq.to_le_bytes());
        payload.push(0);
        let mut opus = [0u8; OPUS_FRAME_BYTES];
        opus[..REAL_OPUS_20MS_440HZ_PACKET.len()].copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
        decryptor.decrypt_contiguous_in_place(&mut opus, seq);
        payload.extend_from_slice(&opus);
        payload.push(0);
    }
    let mut table = sessions().lock().unwrap();
    let entry = table.entries.get_mut(&session.handle()).unwrap();
    entry
        .runtime
        .ingest_ble_chunk(&rx_frame(0x1A, 0x08, &payload), 0);
    let early = entry.runtime.drain_companion_events();
    assert!(
        !early
            .iter()
            .any(|e| matches!(e, CompanionStreamEvent::AudioPcm16 { .. })),
        "slices must stay in standby holdback until stop gate"
    );
    entry.subscribers.broadcast(&early);
}

fn read_until_deadline(
    reader: &mut BufReader<UnixStream>,
    deadline: Instant,
    mut accept: impl FnMut(Value) -> bool,
) {
    loop {
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {
                if line.trim().is_empty() {
                    continue;
                }
                let val: Value = serde_json::from_str(&line).unwrap();
                if accept(val) {
                    return;
                }
            }
            Err(err)
                if matches!(
                    err.kind(),
                    ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted
                ) =>
            {
                if Instant::now() >= deadline {
                    break;
                }
            }
            Err(_) => break,
        }
        if Instant::now() >= deadline {
            break;
        }
    }
}

fn assert_socket_gate_stamps_clock_bumps_generation_and_flushes(method: &str, use_subscribed_command: bool) {
    let ws = temp_workspace();
    let sock_path = resolve_bridge_socket_path(&ws).unwrap();
    let (session, file_key, file_nonce) = setup_standby_host_session(&ws);

    let mut sub = UnixStream::connect(&sock_path).unwrap();
    sub.set_read_timeout(Some(Duration::from_millis(100)))
        .unwrap();
    writeln!(sub, "{}", json!({"method": "companion/subscribe", "params": {"autoGate": false}}))
        .unwrap();
    sub.flush().unwrap();
    let mut reader = BufReader::new(sub.try_clone().unwrap());
    let mut greeted = false;
    read_until_deadline(&mut reader, Instant::now() + Duration::from_secs(2), |val| {
        if val["event"] == "hello" {
            greeted = true;
            true
        } else {
            false
        }
    });
    if !greeted {
        drop(reader);
        drop(sub);
        drop(session);
        let _ = fs::remove_dir_all(&ws);
        panic!("subscriber must receive hello");
    }

    let gen_before_start = koe_host_session_generation(session.handle());
    if use_subscribed_command {
        writeln!(
            sub,
            "{}",
            json!({"jsonrpc": "2.0", "id": 11, "method": method, "active": true})
        )
        .unwrap();
        sub.flush().unwrap();
        let mut acked = false;
        read_until_deadline(&mut reader, Instant::now() + Duration::from_secs(2), |val| {
            if val["id"] == 11 && val["result"]["ok"] == true {
                acked = true;
                true
            } else {
                false
            }
        });
        if !acked {
            drop(reader);
            drop(sub);
            drop(session);
            let _ = fs::remove_dir_all(&ws);
            panic!("subscribed {method}(true) with jsonrpc id must receive ok ack");
        }
    } else {
        let mut rpc = UnixStream::connect(&sock_path).unwrap();
        rpc.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        writeln!(
            rpc,
            "{}",
            json!({"jsonrpc": "2.0", "id": 21, "method": method, "params": {"active": true, "reason": "shortcut_dictate"}})
        )
        .unwrap();
        rpc.flush().unwrap();
        let mut rpc_reader = BufReader::new(rpc);
        let mut resp_line = String::new();
        rpc_reader.read_line(&mut resp_line).unwrap();
        let resp: Value = serde_json::from_str(&resp_line).unwrap();
        assert_eq!(resp["result"]["ok"], true);
    }

    let gen_after_start = koe_host_session_generation(session.handle());

    ingest_standby_slices(&session, &file_key, &file_nonce, 0..3);

    let gen_before_stop = koe_host_session_generation(session.handle());
    if use_subscribed_command {
        writeln!(
            sub,
            "{}",
            json!({"jsonrpc": "2.0", "id": 12, "method": method, "active": false})
        )
        .unwrap();
        sub.flush().unwrap();
    } else {
        let mut rpc = UnixStream::connect(&sock_path).unwrap();
        rpc.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        writeln!(
            rpc,
            "{}",
            json!({"jsonrpc": "2.0", "id": 22, "method": method, "params": {"active": false, "reason": "shortcut_dictate"}})
        )
        .unwrap();
        rpc.flush().unwrap();
        let mut rpc_reader = BufReader::new(rpc);
        let mut resp_line = String::new();
        rpc_reader.read_line(&mut resp_line).unwrap();
        let resp: Value = serde_json::from_str(&resp_line).unwrap();
        assert_eq!(resp["result"]["ok"], true);
    }

    let mut flushed_pcm_events = Vec::new();
    let mut stop_acked = !use_subscribed_command;
    read_until_deadline(&mut reader, Instant::now() + Duration::from_secs(2), |val| {
        if val["id"] == 12 && val["result"]["ok"] == true {
            stop_acked = true;
        }
        if val["event"] == "audio_pcm16" {
            flushed_pcm_events.push(val);
        }
        stop_acked && flushed_pcm_events.len() == 3
    });
    let gen_after_stop = koe_host_session_generation(session.handle());

    let (record_id, created_at) = {
        let table = sessions().lock().unwrap();
        let entry = table.entries.get(&session.handle()).unwrap();
        let snap = entry.runtime.snapshot(0);
        let rec = &snap["records"][0];
        (
            rec["id"].as_str().unwrap_or_default().to_owned(),
            rec["createdAtEpochSec"].as_u64().unwrap_or(0),
        )
    };

    drop(reader);
    drop(sub);
    drop(session);
    let _ = fs::remove_dir_all(&ws);

    assert!(stop_acked, "subscribed {method}(false) with jsonrpc id must receive ok ack");
    assert!(
        gen_after_start > gen_before_start
            && gen_after_stop > gen_before_stop
            && flushed_pcm_events.len() == 3
            && created_at > 0
            && !record_id.starts_with("dictation-0-"),
        "{method} (subscribed={use_subscribed_command}) failed: gen_start={gen_before_start}->{gen_after_start}, gen_stop={gen_before_stop}->{gen_after_stop}, events={}, createdAtEpochSec={created_at}, record_id={record_id}",
        flushed_pcm_events.len()
    );
}

#[test]
fn set_dictation_active_over_socket_stamps_clock_bumps_generation_and_flushes() {
    assert_socket_gate_stamps_clock_bumps_generation_and_flushes("set_dictation_active", true);
}

#[test]
fn set_capture_active_over_socket_stamps_clock_bumps_generation_and_flushes() {
    assert_socket_gate_stamps_clock_bumps_generation_and_flushes("set_capture_active", false);
    assert_socket_gate_stamps_clock_bumps_generation_and_flushes("set_capture_active", true);
}
