#![forbid(unsafe_code)]

use koe_engine::ogg_opus::OggOpus;
use koe_engine::session::REAL_OPUS_20MS_440HZ_PACKET;
use koe_engine::wav::{OpusStreamDecoder, OpusWave, ASR_SAMPLE_RATE, WAV_SAMPLE_RATE};
use koe_opus::{create_libopus_decoder, LibOpusDecoder};

const SILENCE_20MS_MONO: [u8; 3] = [0xF8, 0xFF, 0xFE];
const SILENCE_20MS_STEREO_TOC: [u8; 3] = [0xFC, 0xFF, 0xFE];

fn assert_send<T: Send>() {}

#[test]
fn constructs_all_valid_sample_rates_and_rejects_invalid_rates() {
    assert_send::<LibOpusDecoder>();
    assert_send::<Box<dyn OpusStreamDecoder>>();

    for sr in [8_000u32, 12_000, 16_000, 24_000, 48_000] {
        let direct = LibOpusDecoder::new(sr).expect("valid Opus sample rate must construct");
        assert_eq!(direct.sample_rate(), sr);

        let boxed = create_libopus_decoder(sr).expect("factory must construct valid rate");
        assert_eq!(boxed.sample_rate(), sr);
    }

    for invalid in [0u32, 1, 7_999, 11_025, 22_050, 32_000, 44_100, 96_000, u32::MAX] {
        assert!(
            LibOpusDecoder::new(invalid).is_none(),
            "rate {invalid} must be rejected"
        );
        assert!(
            create_libopus_decoder(invalid).is_none(),
            "factory must reject rate {invalid}"
        );
    }
}

#[test]
fn decodes_real_440hz_and_silence_frames_deterministically_across_rates() {
    for (sr, expected_bytes) in [
        (8_000u32, 320usize),
        (12_000, 480),
        (16_000, 640),
        (24_000, 960),
        (48_000, 1920),
    ] {
        let mut dec_a = LibOpusDecoder::new(sr).unwrap();
        let mut dec_b = LibOpusDecoder::new(sr).unwrap();
        let mut pcm_a = Vec::new();
        let mut pcm_b = Vec::new();
        assert!(dec_a.decode_trimmed_packet(&REAL_OPUS_20MS_440HZ_PACKET, &mut pcm_a));
        assert!(dec_b.decode_trimmed_packet(&REAL_OPUS_20MS_440HZ_PACKET, &mut pcm_b));
        assert_eq!(pcm_a.len(), expected_bytes);
        assert_eq!(pcm_a, pcm_b);

        let peak = pcm_a
            .as_chunks::<2>()
            .0
            .iter()
            .map(|b| i16::from_le_bytes(*b).unsigned_abs())
            .max()
            .unwrap_or(0);
        assert!(peak > 1_000, "decoded 440 Hz tone at {sr} Hz should be non-silent");

        if sr == ASR_SAMPLE_RATE {
            let sample_130 = i16::from_le_bytes([pcm_a[130 * 2], pcm_a[130 * 2 + 1]]);
            assert!(
                (sample_130 - (-4130)).abs() <= 16,
                "unexpected 16 kHz sample 130: {sample_130}"
            );
        }
    }

    for (sr, expected_bytes) in [(ASR_SAMPLE_RATE, 640usize), (WAV_SAMPLE_RATE, 1920)] {
        let mut dec = create_libopus_decoder(sr).unwrap();
        let mut pcm = Vec::new();
        assert!(dec.decode_trimmed_packet(&SILENCE_20MS_MONO, &mut pcm));
        assert_eq!(pcm.len(), expected_bytes);

        let mut stereo_pcm = Vec::new();
        assert!(dec.decode_trimmed_packet(&SILENCE_20MS_STEREO_TOC, &mut stereo_pcm));
        assert_eq!(stereo_pcm.len(), expected_bytes);
    }
}

#[test]
fn rejects_empty_truncated_corrupted_and_oversized_payloads_safely() {
    let mut dec = LibOpusDecoder::new(ASR_SAMPLE_RATE).unwrap();
    let mut out = vec![0xAA, 0xBB];

    assert!(!dec.decode_trimmed_packet(&[], &mut out));
    assert_eq!(out, vec![0xAA, 0xBB]);

    let malformed_packets: [&[u8]; 5] = [
        &[0x03],
        &[0x03, 0x00],
        &[0x03, 0x41],
        &[0x02, 0xFF],
        &[0x03, 0xC1, 0xFF],
    ];
    for pkt in malformed_packets {
        let before = out.len();
        assert!(
            !dec.decode_trimmed_packet(pkt, &mut out),
            "malformed packet {pkt:02X?} must be rejected"
        );
        assert_eq!(out.len(), before);
    }

    let oversized_code3 = vec![0x03u8; 65_536];
    let before = out.len();
    assert!(!dec.decode_trimmed_packet(&oversized_code3, &mut out));
    assert_eq!(out.len(), before);

    let oversized_garbage = vec![0xFFu8; 65_536];
    let mut scratch = Vec::new();
    let _ = dec.decode_trimmed_packet(&oversized_garbage, &mut scratch);

    let mut recovered = Vec::new();
    assert!(dec.decode_trimmed_packet(&REAL_OPUS_20MS_440HZ_PACKET, &mut recovered));
    assert_eq!(recovered.len(), 640);
}

#[test]
fn repeated_decode_advances_state_and_reset_restores_initial_output() {
    let mut dec = LibOpusDecoder::new(ASR_SAMPLE_RATE).unwrap();
    let mut stream = Vec::new();
    for _ in 0..10 {
        assert!(dec.decode_trimmed_packet(&REAL_OPUS_20MS_440HZ_PACKET, &mut stream));
    }
    assert_eq!(stream.len(), 10 * 640);

    let frame0 = &stream[..640];
    let frame1 = &stream[640..1280];
    assert_ne!(frame0, frame1, "stateful Opus decoding should advance across consecutive frames");

    dec.reset();
    let mut after_reset = Vec::new();
    assert!(dec.decode_trimmed_packet(&REAL_OPUS_20MS_440HZ_PACKET, &mut after_reset));
    assert_eq!(after_reset.as_slice(), frame0);

    let mut fresh = LibOpusDecoder::new(ASR_SAMPLE_RATE).unwrap();
    let mut fresh_out = Vec::new();
    assert!(fresh.decode_trimmed_packet(&REAL_OPUS_20MS_440HZ_PACKET, &mut fresh_out));
    assert_eq!(after_reset, fresh_out);
}

#[test]
fn end_to_end_opus_wave_decodes_zero_padded_d3200_frames() {
    let mut raw = vec![0u8; 4 * 160];
    for frame_idx in 0..4 {
        let start = frame_idx * 160;
        raw[start..start + REAL_OPUS_20MS_440HZ_PACKET.len()]
            .copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
    }

    let pcm16 =
        OpusWave::decode_raw_frames_to_pcm16(&raw, ASR_SAMPLE_RATE, Some(create_libopus_decoder))
            .expect("padded D3200 Opus frames must decode to 16 kHz PCM");
    assert_eq!(pcm16.len(), 4 * 640);

    let wav = OpusWave::decode_raw_frames_to_wav(
        &raw,
        WAV_SAMPLE_RATE,
        &[40],
        Some(create_libopus_decoder),
    )
    .expect("padded D3200 Opus frames must decode to 48 kHz WAV");
    assert!(OggOpus::is_wav(&wav));
    assert_eq!(wav.len(), 44 + 4 * 1920);
}
