use koe_engine::prng::{fnv1a64_hex, to_hex_upper, SplitMix64};
use koe_engine::crypto::{AesCtrStreamDecrypt, DeviceCrypto};
use koe_engine::frame::ProtocolFrame;
use koe_engine::ogg_opus::OggOpus;
use koe_engine::wav::OpusWave;
use serde_json::{json, Value};
use std::time::Instant;

pub(crate) fn verify() -> Result<Value, String> {
    let mut left_key = [0u8; 32];
    left_key[31] = 1;
    let mut right_key = [0u8; 32];
    right_key[31] = 2;
    let left_public = DeviceCrypto::p256_public_key(&left_key).ok_or("ECDH public key failed")?;
    let right_public = DeviceCrypto::p256_public_key(&right_key).ok_or("ECDH public key failed")?;
    let left_shared = DeviceCrypto::p256_ecdh_shared_secret(&left_key, &right_public)
        .ok_or("ECDH left derivation failed")?;
    let right_shared = DeviceCrypto::p256_ecdh_shared_secret(&right_key, &left_public)
        .ok_or("ECDH right derivation failed")?;
    if left_shared != right_shared {
        return Err("ECDH shared secrets differ".into());
    }
    let encrypted =
        DeviceCrypto::aes_ctr_decrypt(&[0; 16], &[0; 16], &[0; 16]).ok_or("AES failed")?;
    if to_hex_upper(&encrypted) != "66E94BD4EF8A2C3B884CFA59CA342B2E" {
        return Err("AES known-answer vector differs".into());
    }
    for seed in 0..20 {
        let raw = run_parity_seed(seed)?;
        let vector: Value = serde_json::from_str(&raw).map_err(|e| e.to_string())?;
        if vector["rx_count"] != 2 {
            return Err("BLE frame decode differs".into());
        }
    }
    let mut decoder = koe_opus::create_libopus_decoder(16000).ok_or("libopus unavailable")?;
    let mut pcm = Vec::new();
    if !decoder.decode_trimmed_packet(&[0xf8, 0xff, 0xfe], &mut pcm) || pcm.len() != 640 {
        return Err("libopus silence vector differs".into());
    }
    Ok(json!({"status":"ok","scope":"in_memory_protocol_vectors",
        "checks":["p256_ecdh","aes_known_answer","ble_frames_20_seeds","libopus_16khz"],
        "hardwareVerified":false,"cloudVerified":false}))
}

pub(crate) fn run_parity_seed(seed: u64) -> Result<String, String> {
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
    let stream_dec =
        AesCtrStreamDecrypt::new(&session_key, &nonce).ok_or("invalid 32-byte AES-CTR key")?;
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

    Ok(format!(
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
    ))
}

pub(crate) fn run_benchmark(soa_fast_path: bool) -> Result<(), String> {
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
        let stream_dec =
            AesCtrStreamDecrypt::new(&session_key, &nonce).ok_or("invalid AES-CTR key")?;
        let mut decrypted = raw_encrypted;
        stream_dec.decrypt_contiguous_in_place(&mut decrypted, 0);
        let ogg = OggOpus::mux_raw_frames(&decrypted);
        (decrypted.len(), ogg)
    } else {
        let mut decrypted = Vec::with_capacity(NUM_CHUNKS * 160);
        for seq in 0..NUM_CHUNKS {
            let stream_dec =
                AesCtrStreamDecrypt::new(&session_key, &nonce).ok_or("invalid AES-CTR key")?;
            let slice = &raw_encrypted[seq * 160..(seq + 1) * 160];
            decrypted.extend_from_slice(&stream_dec.decrypt_chunk(slice, seq as u32));
        }
        let ogg = OggOpus::mux_raw_frames(&decrypted);
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
    Ok(())
}
