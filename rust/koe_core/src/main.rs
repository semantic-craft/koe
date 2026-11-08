//! CLI driver for `koe_core`: runs the 20-seed A/B differential parity suite
//! (`--parity`) and the benchmark staircase stages (`--bench-safe` and `--bench-soa`).

#![forbid(unsafe_code)]

use std::env;
use std::fs;
use std::io::{self, BufRead};
use std::path::{Path, PathBuf};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use koe_core::cicada::RollingMinutesScheduler;
use koe_core::context::{ContextSearchIndex, ContextState};
use koe_core::copilot_google::{
    encode_batchexecute_envelope, CopilotPresetChip, GoogleSuiteStore, KeepNoteColor,
    KeepNoteDraft, NotebookId, NotebookRpcOp,
};
use koe_core::crypto::{AesCtrStreamDecrypt, DeviceCrypto};
use koe_core::domain::UtteranceSpine;
use koe_core::frame::ProtocolFrame;
use koe_core::library::RecordingLibrary;
use koe_core::mcp_acp::{build_openai_tools_json, McpAcpState, McpAcpWorkspaceView};
use koe_core::minutes::{JsonValue, MinutesState};
use koe_core::ogg_opus::OggOpus;
use koe_core::prng::{fnv1a64_hex, to_hex_upper, SplitMix64};
use koe_core::wav::OpusWave;

fn run_parity_seed(seed: u64) -> String {
    let mut rng = SplitMix64::new(seed);
    let cmd_type = rng.next_byte();
    let cmd_id = rng.next_byte();
    let payload_len = (rng.next_byte() as usize % 48) + 1;
    let payload = rng.next_bytes(payload_len);
    let tx_frame = ProtocolFrame::encode(cmd_type, cmd_id, &payload);

    let mut rx_body1 = vec![
        0x09u8,
        0xFF,
        0x00,
        0x00,
        0x01,
        cmd_type,
        cmd_id,
        ((10 + payload.len()) & 0xFF) as u8,
        (((10 + payload.len()) >> 8) & 0xFF) as u8,
    ];
    rx_body1.extend_from_slice(&payload);
    let mut rx_pkt1 = rx_body1.clone();
    rx_pkt1.push(ProtocolFrame::checksum(&rx_body1));

    let rx_body2 = vec![
        0x09u8,
        0xFF,
        0x00,
        0x00,
        0x11,
        cmd_type.wrapping_add(1),
        cmd_id.wrapping_add(2),
        12,
        0,
        rng.next_byte(),
        rng.next_byte(),
    ];
    let mut rx_pkt2 = rx_body2.clone();
    rx_pkt2.push(ProtocolFrame::checksum(&rx_body2));

    let mut stream_buf = vec![0xAAu8, 0xBB];
    stream_buf.extend_from_slice(&rx_pkt1);
    stream_buf.push(0xCC);
    stream_buf.extend_from_slice(&rx_pkt2);
    stream_buf.extend_from_slice(&[0x09, 0xFF, 0x00]);
    let decoded = ProtocolFrame::process_buffer(&mut stream_buf);

    let ikm = rng.next_bytes(32);
    let salt = [1u8, 2, 3];
    let info = [1u8, 2, 3];
    let session_key = DeviceCrypto::hkdf_sha256(&ikm, &salt, &info, 32);
    let nonce = rng.next_bytes(16);
    let seq = (rng.next_u64() & 0xFFFF) as u32;
    let chunk_in = rng.next_bytes(160);
    let stream_dec = AesCtrStreamDecrypt::new(&session_key, &nonce).expect("valid 32B key");
    let chunk_dec = stream_dec.decrypt_chunk(&chunk_in, seq);

    let frame_count = (rng.next_byte() as usize % 110) + 5;
    let mut raw_opus = rng.next_bytes(frame_count * 160);
    let mut f = 0usize;
    while f < frame_count {
        let zero_count = (f % 7) + 1;
        for z in 0..zero_count {
            raw_opus[(f + 1) * 160 - 1 - z] = 0;
        }
        if raw_opus[f * 160] == 0 {
            raw_opus[f * 160] = 0x78;
        }
        f += 3;
    }
    let ogg_bytes = OggOpus::mux_raw_frames(&raw_opus);
    let wav_hdr = OpusWave::wav_header((frame_count * 960 * 2) as u32);

    format!(
        "{{\"seed\":{},\"tx_hex\":\"{}\",\"rx_count\":{},\"rx_rem\":{},\"rx0_payload\":\"{}\",\"rx1_payload\":\"{}\",\"hkdf_hex\":\"{}\",\"aes_fnv\":\"{}\",\"ogg_len\":{},\"ogg_fnv\":\"{}\",\"wav_hex\":\"{}\"}}",
        seed,
        to_hex_upper(&tx_frame),
        decoded.len(),
        stream_buf.len(),
        to_hex_upper(&decoded[0].payload),
        to_hex_upper(&decoded[1].payload),
        to_hex_upper(&session_key),
        fnv1a64_hex(&chunk_dec),
        ogg_bytes.len(),
        fnv1a64_hex(&ogg_bytes),
        to_hex_upper(&wav_hdr),
    )
}

fn run_benchmark(soa_fast_path: bool) {
    const NUM_CHUNKS: usize = 90_000;
    const NUM_BLE_PACKETS: usize = 10_000;

    let mut rng = SplitMix64::new(42);
    let ikm = rng.next_bytes(32);
    let nonce = rng.next_bytes(16);
    let mut raw_encrypted = rng.next_bytes(NUM_CHUNKS * 160);
    for f in 0..NUM_CHUNKS {
        if raw_encrypted[f * 160] == 0 {
            raw_encrypted[f * 160] = 0x78;
        }
    }
    let ble_payload = rng.next_bytes(32);

    let start = Instant::now();

    let mut rx_checksum_acc: u64 = 0;
    let mut rx_stream = Vec::with_capacity(NUM_BLE_PACKETS * 42);
    for _ in 0..NUM_BLE_PACKETS {
        let tx = ProtocolFrame::encode(0x1A, 0x07, &ble_payload);
        rx_checksum_acc = (rx_checksum_acc + u64::from(*tx.last().unwrap_or(&0))) & 0xFFFF_FFFF;
        let start_idx = rx_stream.len();
        rx_stream.extend_from_slice(&[
            0x09,
            0xFF,
            0x00,
            0x00,
            0x01,
            0x1A,
            0x07,
            ((10 + ble_payload.len()) & 0xFF) as u8,
            0,
        ]);
        rx_stream.extend_from_slice(&ble_payload);
        let csum = ProtocolFrame::checksum(&rx_stream[start_idx..]);
        rx_stream.push(csum);
    }
    let decoded_pkts = ProtocolFrame::process_buffer(&mut rx_stream);

    let session_key = DeviceCrypto::hkdf_sha256(&ikm, &[1, 2, 3], &[1, 2, 3], 32);
    let (decrypted_len, ogg_bytes) = if soa_fast_path {
        let stream_dec = AesCtrStreamDecrypt::new(&session_key, &nonce).expect("valid key");
        let mut decrypted = raw_encrypted;
        stream_dec.decrypt_contiguous_in_place(&mut decrypted, 0);
        let ogg = OggOpus::mux_raw_frames(&decrypted);
        (decrypted.len(), ogg)
    } else {
        let mut decrypted = Vec::with_capacity(NUM_CHUNKS * 160);
        for seq in 0..NUM_CHUNKS {
            let stream_dec = AesCtrStreamDecrypt::new(&session_key, &nonce).expect("valid key");
            let slice = &raw_encrypted[seq * 160..(seq + 1) * 160];
            decrypted.extend_from_slice(&stream_dec.decrypt_chunk(slice, seq as u32));
        }
        let ogg = OggOpus::mux_raw_frames_naive(&decrypted);
        (decrypted.len(), ogg)
    };
    let wav_hdr = OpusWave::wav_header((NUM_CHUNKS * 960 * 2) as u32);

    let elapsed_ms = start.elapsed().as_secs_f64() * 1000.0;
    let digest = fnv1a64_hex(&ogg_bytes);
    println!(
        "{{\"wall_time_ms\":{:.3},\"decoded_packets\":{},\"tx_csum_acc\":{},\"decrypted_bytes\":{},\"ogg_bytes\":{},\"ogg_fnv\":\"{}\",\"wav_hdr_len\":{}}}",
        elapsed_ms,
        decoded_pkts.len(),
        rx_checksum_acc,
        decrypted_len,
        ogg_bytes.len(),
        digest,
        wav_hdr.len()
    );
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.iter().any(|a| a == "--parity") {
        let items: Vec<String> = (0..20).map(run_parity_seed).collect();
        println!("[{}]", items.join(","));
        return;
    }
    if args.iter().any(|a| a == "--bench-safe") {
        run_benchmark(false);
        return;
    }
    if args.iter().any(|a| a == "--bench-soa") {
        run_benchmark(true);
        return;
    }

    let export_dir = args
        .iter()
        .position(|a| a == "--export-dir")
        .and_then(|idx| args.get(idx + 1))
        .map(PathBuf::from)
        .unwrap_or_else(|| env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));

    let now_epoch_sec = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let mut spine = UtteranceSpine::new("cli-session");
    let library = RecordingLibrary::new();
    let mut minutes = MinutesState::default();
    let mut rolling_scheduler = RollingMinutesScheduler::new("cli-session");
    let mut context = ContextState::default();
    let mut search_index = ContextSearchIndex::new();
    let mut mcp_state = McpAcpState::default();

    let suite_file = export_dir.join("google_suite.json");
    if suite_file.exists() {
        if let Ok(content) = fs::read_to_string(&suite_file) {
            if let Ok(json_val) = JsonValue::parse(&content) {
                if let Ok(store) = GoogleSuiteStore::from_json_value(&json_val) {
                    mcp_state.google_suite = store;
                }
            }
        }
    }

    let save_suite = |suite: &GoogleSuiteStore, target: &Path| {
        if let Some(parent) = target.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let tmp = target.with_extension("json.tmp");
        let payload = suite.to_json_value().to_json_string();
        if fs::write(&tmp, payload.as_bytes()).is_ok() {
            let _ = fs::rename(&tmp, target);
        }
    };

    if args.iter().any(|a| a == "--mcp-stdio") {
        let stdin = io::stdin();
        let handle = stdin.lock();
        for line_res in handle.lines() {
            let Ok(line) = line_res else {
                break;
            };
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let mut ws = McpAcpWorkspaceView {
                spine: &mut spine,
                library: &library,
                minutes: &mut minutes,
                rolling_scheduler: &mut rolling_scheduler,
                context: &mut context,
                search_index: &mut search_index,
            };
            if let Some(resp) = mcp_state.dispatch_jsonrpc(&mut ws, trimmed, now_epoch_sec) {
                println!("{resp}");
            }
        }
        save_suite(&mcp_state.google_suite, &suite_file);
        return;
    }

    if let Some(pos) = args.iter().position(|a| a == "--copilot-preset") {
        if let Some(slug) = args.get(pos + 1) {
            let mut ws = McpAcpWorkspaceView {
                spine: &mut spine,
                library: &library,
                minutes: &mut minutes,
                rolling_scheduler: &mut rolling_scheduler,
                context: &mut context,
                search_index: &mut search_index,
            };
            if let Some(chip) = CopilotPresetChip::parse(slug) {
                match mcp_state.run_copilot_preset(&mut ws, chip, now_epoch_sec) {
                    Ok(reply) => {
                        save_suite(&mcp_state.google_suite, &suite_file);
                        println!("{reply}");
                    }
                    Err(err) => eprintln!("Error running copilot preset: {err}"),
                }
            } else {
                eprintln!("Unknown copilot preset slug: {slug}");
            }
            return;
        }
    }

    if let Some(pos) = args.iter().position(|a| a == "--copilot-prompt") {
        if let Some(prompt) = args.get(pos + 1) {
            mcp_state.submit_copilot_prompt(prompt, now_epoch_sec);
            if args.iter().any(|a| a == "--emit-openai-request") {
                let tools = build_openai_tools_json();
                let req = mcp_state.copilot.build_openai_chat_request_json(tools);
                println!("{}", req.to_json_string());
            } else {
                println!(
                    "Prompt submitted to Copilot. Phase: {}",
                    mcp_state.copilot.phase.as_str()
                );
            }
            save_suite(&mcp_state.google_suite, &suite_file);
            return;
        }
    }

    if args.iter().any(|a| a == "--emit-openai-request") {
        let tools = build_openai_tools_json();
        let req = mcp_state.copilot.build_openai_chat_request_json(tools);
        println!("{}", req.to_json_string());
        return;
    }

    if args.iter().any(|a| a == "--google-tasks-sync") {
        let report =
            mcp_state
                .google_suite
                .sync_google_tasks_with_context(&mut context, "@default", now_epoch_sec);
        save_suite(&mcp_state.google_suite, &suite_file);
        println!(
            "{{\"created_remote\":{},\"pushed_to_remote\":{},\"applied_from_remote\":{},\"conflicts\":{},\"unchanged\":{}}}",
            report.created_remote,
            report.pushed_to_remote,
            report.applied_from_remote,
            report.conflicts,
            report.unchanged
        );
        return;
    }

    if let Some(pos) = args.iter().position(|a| a == "--google-notebook") {
        if let Some(op) = args.get(pos + 1) {
            match op.as_str() {
                "list" => {
                    println!("Notebooks: {}", mcp_state.google_suite.notebooks.len());
                }
                "create" => {
                    let title = args
                        .get(pos + 2)
                        .map(|s| s.as_str())
                        .unwrap_or("Untitled Notebook");
                    let id = mcp_state.google_suite.create_notebook(title, now_epoch_sec);
                    save_suite(&mcp_state.google_suite, &suite_file);
                    println!("Created notebook: {}", id.0);
                }
                "ask" => {
                    let nb_id = args.get(pos + 2).map(|s| s.as_str()).unwrap_or("");
                    let query = args
                        .get(pos + 3)
                        .map(|s| s.as_str())
                        .unwrap_or("What are the key takeaways?");
                    match mcp_state.google_suite.query_notebook_grounded(
                        &NotebookId(nb_id.to_string()),
                        query,
                        &search_index,
                        &spine,
                        now_epoch_sec,
                    ) {
                        Ok(turn) => {
                            save_suite(&mcp_state.google_suite, &suite_file);
                            println!("{}", turn.to_json_value().to_json_string());
                        }
                        Err(e) => eprintln!("Error querying notebook: {e}"),
                    }
                }
                "audio-overview" => {
                    let nb_id = args.get(pos + 2).map(|s| s.as_str()).unwrap_or("");
                    let focus = args.get(pos + 3).map(|s| s.as_str()).unwrap_or("");
                    match mcp_state.google_suite.generate_notebook_audio_overview(
                        &NotebookId(nb_id.to_string()),
                        focus,
                        Some(&spine),
                        now_epoch_sec,
                    ) {
                        Ok(overview) => {
                            save_suite(&mcp_state.google_suite, &suite_file);
                            println!("{}", overview.to_json_value().to_json_string());
                        }
                        Err(e) => eprintln!("Error generating audio overview: {e}"),
                    }
                }
                "encode-rpc" => {
                    let env = encode_batchexecute_envelope(
                        NotebookRpcOp::CreateNotebook,
                        &JsonValue::Array(vec![JsonValue::String("Koe Notebook".to_string())]),
                    );
                    println!("{env}");
                }
                _ => eprintln!("Unsupported notebook operation: {op}"),
            }
            return;
        }
    }

    if let Some(pos) = args.iter().position(|a| a == "--google-keep") {
        if let Some(op) = args.get(pos + 1) {
            match op.as_str() {
                "list" => {
                    println!("Keep notes: {}", mcp_state.google_suite.keep_notes.len());
                }
                "create" => {
                    let title = args
                        .get(pos + 2)
                        .map(|s| s.as_str())
                        .unwrap_or("Untitled Keep Note");
                    let body = args.get(pos + 3).map(|s| s.as_str()).unwrap_or("");
                    let note = mcp_state.google_suite.create_keep_note(
                        KeepNoteDraft {
                            id: None,
                            title: title.to_string(),
                            body_text: body.to_string(),
                            checklist: Vec::new(),
                            color: KeepNoteColor::Default,
                            pinned: false,
                            labels: vec!["koe".to_string()],
                        },
                        now_epoch_sec,
                    );
                    save_suite(&mcp_state.google_suite, &suite_file);
                    println!("Created keep note: {}", note.id.0);
                }
                "sync" | "sync-context" => {
                    let synced = mcp_state
                        .google_suite
                        .sync_keep_with_context(&mut context, now_epoch_sec);
                    save_suite(&mcp_state.google_suite, &suite_file);
                    println!("Synced {synced} keep notes with context");
                }
                _ => eprintln!("Unsupported keep operation: {op}"),
            }
            return;
        }
    }

    run_benchmark(true);
}
