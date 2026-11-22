    use super::*;
    use crate::commands::DeviceCommands;
    use crate::crypto::{AesCtrStreamDecrypt, DeviceCrypto};
    use crate::frame::{ProtocolFrame, RX_MAGIC};
    use crate::ogg_opus::OggOpus;
    use crate::transport::{OPUS_FRAME_BYTES, SLICE_RECORD_BYTES, UNFINISHED_FILE_SIZE};
    use crate::wav::OpusWave;

    struct DeterministicTestDecoder {
        sample_rate: u32,
        frames_seen: i16,
    }

    impl OpusStreamDecoder for DeterministicTestDecoder {
        fn sample_rate(&self) -> u32 {
            self.sample_rate
        }

        fn decode_trimmed_packet(&mut self, packet: &[u8], out_pcm16_le: &mut Vec<u8>) -> bool {
            if packet != REAL_OPUS_20MS_440HZ_PACKET {
                return false;
            }
            self.frames_seen = self.frames_seen.saturating_add(1);
            let samples_20ms = (self.sample_rate as usize) / 50;
            out_pcm16_le.reserve(samples_20ms * 2);
            for i in 0..samples_20ms {
                let sample = self
                    .frames_seen
                    .saturating_mul(10)
                    .saturating_add((i % 64) as i16);
                out_pcm16_le.extend_from_slice(&sample.to_le_bytes());
            }
            true
        }

        fn reset(&mut self) {
            self.frames_seen = 0;
        }
    }

    fn test_decoder_factory(sample_rate: u32) -> Option<Box<dyn OpusStreamDecoder>> {
        if !OpusWave::is_valid_sample_rate(sample_rate) {
            return None;
        }
        Some(Box::new(DeterministicTestDecoder {
            sample_rate,
            frames_seen: 0,
        }))
    }

    fn feed_realtime_60_slice_capture(
        session: &mut TransportSession,
        now_epoch_sec: u64,
    ) -> FinalizedRecording {
        let sk_vec = DeviceCrypto::hkdf_sha256(&[0x42u8; 32], &[1, 2, 3], &[1, 2, 3], 32);
        let mut sk = [0u8; 32];
        sk.copy_from_slice(&sk_vec);
        session.set_session_key(sk);

        let mut tel_payload = Vec::new();
        tel_payload.push(1);
        tel_payload.push(8);
        tel_payload.push(1);
        tel_payload.extend_from_slice(b"1.4.8");
        tel_payload.extend_from_slice(b"D3200NATIVE639D0");
        tel_payload.extend_from_slice(&(64u32 * 1024 * 1024).to_le_bytes());
        tel_payload.extend_from_slice(&(58u32 * 1024 * 1024).to_le_bytes());
        tel_payload.push(0);
        tel_payload.extend_from_slice(b"2.1.0");
        tel_payload.push(9);
        tel_payload.extend_from_slice(&[0xAA, 0xBB, 0xCC, 0xDD, 0x63, 0x9D]);
        let tel_rx = TransportSession::build_rx_frame(0x01, 0x01, &tel_payload);
        let _ = session.ingest_ble_chunk(&tel_rx, now_epoch_sec);

        let fk = [0x55u8; 32];
        let fn_iv = [0x66u8; 16];
        let head_rx = build_test_head_frame(&sk, 20_261_107, u32::MAX, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&head_rx, now_epoch_sec);

        let seqs: Vec<(u32, u8)> = (0..60u32)
            .map(|seq| (seq, if seq == 15 || seq == 45 { 0x01 } else { 0x00 }))
            .collect();
        let slices_rx = build_test_slice_frame(&fk, &fn_iv, &seqs);
        let _ = session.ingest_ble_chunk(&slices_rx, now_epoch_sec);

        session
            .finalize_active_transfer(now_epoch_sec)
            .expect("60-slice stream must produce a FinalizedRecording")
    }

    #[test]
    fn realtime_capture_decodes_telemetry_head_and_60_slices() {
        let mut session = TransportSession::new();
        let fin = feed_realtime_60_slice_capture(&mut session, 1_700_000_000);
        assert_eq!(session.connection_phase, ConnectionPhaseTag::Connected);
        assert_eq!(session.telemetry.as_ref().unwrap().battery, Some(90));
        assert_eq!(fin.entry.id, 20_261_107);
        assert_eq!(fin.entry.duration_ms, 1200);
        assert_eq!(fin.entry.marks_ms, vec![300, 900]);
        assert!(fin.ogg_opus_bytes.starts_with(b"OggS"));
        assert!(fin.preview_wav_bytes.is_empty());
    }

    fn drain_audio_pcm(session: &mut TransportSession) -> Vec<u8> {
        session
            .take_capture_events()
            .into_iter()
            .filter_map(|event| match event {
                CaptureEvent::Audio { pcm16, .. } => Some(pcm16),
                _ => None,
            })
            .flatten()
            .collect()
    }

    #[test]
    fn session_with_decoder_factory_streams_16khz_pcm_and_finalizes_48khz_wav() {
        let mut session = TransportSession::with_decoder_factory(Some(test_decoder_factory));
        let fin = feed_realtime_60_slice_capture(&mut session, 1_700_000_000);
        assert_eq!(fin.preview_wav_bytes.len(), 44 + 60 * 960 * 2);
        let events: Vec<_> = session.take_capture_events().into_iter().collect();
        assert!(matches!(
            events.first(),
            Some(CaptureEvent::Started { file_id: 20_261_107 })
        ));
        assert!(matches!(
            events.last(),
            Some(CaptureEvent::Finished {
                file_id: 20_261_107,
                saved: true
            })
        ));
        let live_pcm: Vec<u8> = events
            .into_iter()
            .filter_map(|event| match event {
                CaptureEvent::Audio {
                    file_id: 20_261_107,
                    pcm16,
                } => Some(pcm16),
                _ => None,
            })
            .flatten()
            .collect();
        assert_eq!(live_pcm.len(), 60 * 320 * 2);
        assert!(session.take_capture_events().is_empty());
    }

    #[test]
    fn offline_pull_skips_16khz_decode_and_emits_no_audio_events() {
        let mut session = TransportSession::with_decoder_factory(Some(test_decoder_factory));
        let sk = [0x77u8; 32];
        let fk = [0x88u8; 32];
        let fn_iv = [0x99u8; 16];
        session.set_session_key(sk);

        let _ = session.begin_offline_pull(555, 40);
        let head = build_test_head_frame(&sk, 555, 2 * 166, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&head, 1_700_000_100);
        let slices = build_test_slice_frame(&fk, &fn_iv, &[(0, 0x00), (1, 0x01)]);
        let step = session.ingest_ble_chunk(&slices, 1_700_000_100);
        assert_eq!(step.slices_unpacked_count, 2);
        assert!(drain_audio_pcm(&mut session).is_empty());
        let fin = session.finalize_active_transfer(1_700_000_101).unwrap();
        assert!(!fin.preview_wav_bytes.is_empty());
        let events: Vec<_> = session.take_capture_events().into_iter().collect();
        assert!(!events
            .iter()
            .any(|event| matches!(event, CaptureEvent::Audio { .. })));
    }

    #[test]
    fn is_file_in_flight_reflects_active_suspended_and_failed_states() {
        let mut session = TransportSession::new();
        assert!(!session.is_file_in_flight(101));

        let _ = session.begin_offline_pull(101, 1_000);
        assert!(session.is_file_in_flight(101));
        assert!(!session.is_file_in_flight(202));

        session.on_transport_interrupted();
        assert!(matches!(
            session.runtime_state,
            TransferRuntimeState::Suspended { file_id: 101, .. }
        ));
        assert!(session.is_file_in_flight(101));

        session.active_file_id = None;
        session.runtime_state = TransferRuntimeState::Failed {
            file_id: 101,
            error_code: 0x01,
        };
        session.transfer.phase = TransferPhaseTag::Failed;
        assert!(!session.is_file_in_flight(101));

        session.start_realtime_recording(Some(303), 1_700_000_000_000);
        assert!(session.is_file_in_flight(303));
    }

    fn build_test_head_frame(
        session_key: &[u8; 32],
        file_id: u32,
        file_size: u32,
        file_key: &[u8; 32],
        file_nonce: &[u8; 16],
    ) -> Vec<u8> {
        let mut plain_key_mat = Vec::with_capacity(46);
        plain_key_mat.extend_from_slice(b"soundcored3200");
        plain_key_mat.extend_from_slice(file_key);
        let session_nonce = [0x33u8; 16];
        let enc_file_key =
            DeviceCrypto::aes_ctr_decrypt(&plain_key_mat, session_key, &session_nonce).unwrap();
        let mut head_payload = Vec::with_capacity(87);
        head_payload.extend_from_slice(&file_id.to_le_bytes());
        head_payload.extend_from_slice(&file_size.to_le_bytes());
        head_payload.extend_from_slice(file_nonce);
        head_payload.extend_from_slice(&enc_file_key);
        head_payload.extend_from_slice(&session_nonce);
        head_payload.push(0);
        TransportSession::build_rx_frame(0x1A, 0x07, &head_payload)
    }

    fn build_test_slice_frame(
        file_key: &[u8; 32],
        file_nonce: &[u8; 16],
        sequences: &[(u32, u8)],
    ) -> Vec<u8> {
        let decryptor = AesCtrStreamDecrypt::new(file_key, file_nonce).unwrap();
        let mut payload = Vec::with_capacity(sequences.len() * SLICE_RECORD_BYTES);
        for &(seq, flags) in sequences {
            payload.extend_from_slice(&seq.to_le_bytes());
            payload.push(flags);
            let mut chunk = [0u8; OPUS_FRAME_BYTES];
            chunk[..REAL_OPUS_20MS_440HZ_PACKET.len()]
                .copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
            decryptor.decrypt_contiguous_in_place(&mut chunk, seq);
            payload.extend_from_slice(&chunk);
            payload.push(0x00);
        }
        TransportSession::build_rx_frame(0x1A, 0x08, &payload)
    }

    #[test]
    fn repeated_realtime_capture_decrypts_without_fresh_file_key_wrapping() {
        for repeat_head_kind in 0..3 {
            let mut session = TransportSession::with_decoder_factory(Some(test_decoder_factory));
            let sk = [0x21; 32];
            let fk = [0x22; 32];
            let nonce = [0x23; 16];
            session.set_session_key(sk);
            session.start_realtime_recording(Some(4001), 1_700_000_000_000);
            session.ingest_ble_chunk(
                &build_test_head_frame(&sk, 4001, u32::MAX, &fk, &nonce),
                1_700_000_000,
            );
            let slices = build_test_slice_frame(&fk, &nonce, &[(0, 0), (1, 1)]);
            let _ = session.ingest_ble_chunk(&slices, 1_700_000_001);
            let first_pcm = drain_audio_pcm(&mut session);
            let mut expected_opus = [0; OPUS_FRAME_BYTES];
            expected_opus[..REAL_OPUS_20MS_440HZ_PACKET.len()]
                .copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
            assert_eq!(session.opus_buffer, expected_opus.repeat(2));
            assert_eq!(first_pcm.len(), 2 * 320 * 2);
            session.stop_realtime_recording();
            let first = session
                .poll_timers(REALTIME_QUIET_DRAIN_MS, 1_700_000_003)
                .finalized
                .unwrap();

            session.start_realtime_recording(Some(4001), 1_700_000_004_000);
            match repeat_head_kind {
                0 => {
                    let invalid_wrapping = build_test_head_frame(
                        &[0x99; 32],
                        4001,
                        u32::MAX,
                        &[0x88; 32],
                        &[0x77; 16],
                    );
                    session.ingest_ble_chunk(&invalid_wrapping, 1_700_000_004);
                }
                1 => {
                    let mut short_head = 4001u32.to_le_bytes().to_vec();
                    short_head.extend_from_slice(&u32::MAX.to_le_bytes());
                    short_head.push(0);
                    session.ingest_ble_chunk(
                        &TransportSession::build_rx_frame(0x1A, 0x07, &short_head),
                        1_700_000_004,
                    );
                }
                _ => {}
            }
            let _ = session.ingest_ble_chunk(&slices, 1_700_000_005);
            let second_pcm = drain_audio_pcm(&mut session);
            assert_eq!(
                session.opus_buffer,
                expected_opus.repeat(2),
                "repeat head kind {repeat_head_kind}"
            );
            assert_eq!(second_pcm, first_pcm);
            session.stop_realtime_recording();
            let second = session
                .poll_timers(REALTIME_QUIET_DRAIN_MS, 1_700_000_007)
                .finalized
                .unwrap();
            assert_eq!(second.ogg_opus_bytes, first.ogg_opus_bytes);
            assert_eq!(second.preview_wav_bytes, first.preview_wav_bytes);
        }
    }

    #[test]
    fn encrypted_head_without_valid_context_does_not_publish_ciphertext_as_audio() {
        let mut session = TransportSession::with_decoder_factory(Some(test_decoder_factory));
        let sk = [0x21; 32];
        let fk = [0x22; 32];
        let nonce = [0x23; 16];
        session.set_session_key(sk);
        session.start_realtime_recording(Some(4001), 1_700_000_000_000);
        session.ingest_ble_chunk(
            &build_test_head_frame(&[0x99; 32], 4001, u32::MAX, &fk, &nonce),
            1_700_000_000,
        );
        let slices = build_test_slice_frame(&fk, &nonce, &[(0, 0)]);
        let rejected = session.ingest_ble_chunk(&slices, 1_700_000_001);
        assert_eq!(rejected.slices_unpacked_count, 0);
        assert!(drain_audio_pcm(&mut session).is_empty());
        assert!(session.opus_buffer.is_empty());
        assert_ne!(session.transfer.error_code, 0);
        session.ingest_ble_chunk(
            &build_test_head_frame(&sk, 4001, u32::MAX, &fk, &nonce),
            1_700_000_002,
        );
        let _ = session.ingest_ble_chunk(&slices, 1_700_000_003);
        assert_eq!(drain_audio_pcm(&mut session).len(), 320 * 2);
        assert_eq!(session.transfer.error_code, 0);
        session.stop_realtime_recording();
        assert!(
            session
                .poll_timers(REALTIME_QUIET_DRAIN_MS, 1_700_000_005)
                .finalized
                .is_some()
        );
    }

    #[test]
    fn repeated_file_decrypt_context_is_isolated_by_file_and_connection() {
        for reset_kind in 0..5 {
            let mut session = TransportSession::with_decoder_factory(Some(test_decoder_factory));
            let sk = [0x21; 32];
            let fk = [0x22; 32];
            let nonce = [0x23; 16];
            session.set_session_key(sk);
            session.ingest_ble_chunk(
                &build_test_head_frame(&sk, 4001, u32::MAX, &fk, &nonce),
                1_700_000_000,
            );
            let slices = build_test_slice_frame(&fk, &nonce, &[(0, 0)]);
            let _ = session.ingest_ble_chunk(&slices, 1_700_000_001);
            let expected_pcm = drain_audio_pcm(&mut session);
            session.stop_realtime_recording();
            session.poll_timers(REALTIME_QUIET_DRAIN_MS, 1_700_000_003);
            session.start_realtime_recording(Some(4001), 1_700_000_004_000);
            let _ = session.ingest_ble_chunk(&slices, 1_700_000_004);
            assert_eq!(drain_audio_pcm(&mut session), expected_pcm);
            session.reset_active_transfer();

            let file_id = match reset_kind {
                0 => 4002,
                1 => {
                    session.on_disconnected();
                    4001
                }
                2 => {
                    session.on_transport_interrupted();
                    4001
                }
                3 => {
                    session.on_gatt_ready([0x31; 32]).unwrap();
                    4001
                }
                _ => {
                    session.set_session_key([0x32; 32]);
                    4001
                }
            };
            session.start_realtime_recording(Some(file_id), 1_700_000_005_000);
            session.ingest_ble_chunk(
                &build_test_head_frame(&[0x99; 32], file_id, u32::MAX, &fk, &nonce),
                1_700_000_005,
            );
            let rejected = session.ingest_ble_chunk(&slices, 1_700_000_006);
            assert_eq!(rejected.slices_unpacked_count, 0, "reset kind {reset_kind}");
            assert!(drain_audio_pcm(&mut session).is_empty());
            assert!(session.opus_buffer.is_empty());
        }
    }

    #[test]
    fn offline_pull_watchdog_retries_with_byte_offset_and_deduplicates_overlapping_slices() {
        let mut session = TransportSession::new();
        let sk = [0x77u8; 32];
        let fk = [0x88u8; 32];
        let fn_iv = [0x99u8; 16];
        session.set_session_key(sk);

        let start_tx = session.begin_offline_pull(555, 80);
        assert_eq!(&start_tx[9..13], &0u32.to_le_bytes());
        assert_eq!(&start_tx[13..17], &555u32.to_le_bytes());

        let head = build_test_head_frame(&sk, 555, 4 * 166, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&head, 1_700_000_100);

        let batch1 = build_test_slice_frame(&fk, &fn_iv, &[(0, 0x00), (1, 0x01)]);
        let step1 = session.ingest_ble_chunk(&batch1, 1_700_000_100);
        assert_eq!(step1.slices_unpacked_count, 2);
        assert_eq!(session.transfer.received_wire_bytes, 332);

        let w1 = session.poll_timers(4_999, 1_700_000_104);
        assert!(w1.outbound_tx_frames.is_empty());
        assert_eq!(session.transfer.retry_count, 0);

        let w2 = session.poll_timers(1, 1_700_000_105);
        assert_eq!(w2.outbound_tx_frames.len(), 1);
        assert_eq!(session.transfer.retry_count, 1);
        let retry_tx = &w2.outbound_tx_frames[0];
        assert_eq!(&retry_tx[9..13], &332u32.to_le_bytes());
        assert_eq!(&retry_tx[13..17], &555u32.to_le_bytes());

        let _ = session.ingest_ble_chunk(&head, 1_700_000_106);
        assert_eq!(session.received_slice_count(), 2);
        assert_eq!(session.transfer.retry_count, 1);

        let batch2 = build_test_slice_frame(&fk, &fn_iv, &[(1, 0x01), (2, 0x00), (3, 0x01)]);
        let step2 = session.ingest_ble_chunk(&batch2, 1_700_000_106);
        assert_eq!(step2.slices_unpacked_count, 2);
        assert_eq!(session.received_slice_count(), 4);
        assert_eq!(session.transfer.received_wire_bytes, 664);
        assert_eq!(session.transfer.retry_count, 0);

        let done = TransportSession::build_rx_frame(0x1A, 0x0A, &555u32.to_le_bytes());
        let fin_step = session.ingest_ble_chunk(&done, 1_700_000_107);
        let fin = fin_step
            .finalized
            .expect("offline pull must finalize on 1A/0A");
        assert_eq!(fin.entry.id, 555);
        assert_eq!(fin.entry.marks_ms, vec![20, 60]);
    }

    #[test]
    fn offline_pull_watchdog_fails_after_two_retries() {
        let mut session = TransportSession::new();
        let _ = session.begin_offline_pull(777, 1_000);

        let r1 = session.poll_timers(OFFLINE_WATCHDOG_TIMEOUT_MS, 10);
        assert_eq!(r1.outbound_tx_frames.len(), 1);
        assert_eq!(session.transfer.phase, TransferPhaseTag::PullingOffline);
        assert_eq!(session.transfer.retry_count, 1);

        let r2 = session.poll_timers(OFFLINE_WATCHDOG_TIMEOUT_MS, 15);
        assert_eq!(r2.outbound_tx_frames.len(), 1);
        assert_eq!(session.transfer.phase, TransferPhaseTag::PullingOffline);
        assert_eq!(session.transfer.retry_count, 2);

        let r3 = session.poll_timers(OFFLINE_WATCHDOG_TIMEOUT_MS, 20);
        assert!(r3.outbound_tx_frames.is_empty());
        assert_eq!(session.transfer.phase, TransferPhaseTag::Failed);
        assert_eq!(session.transfer.error_code, TRANSFER_ERR_WATCHDOG_TIMEOUT);
        assert_eq!(session.transfer.retry_count, 2);
    }

    #[test]
    fn realtime_stop_enters_2s_quiet_drain_and_late_slices_extend_deadline() {
        let mut session = TransportSession::new();
        let sk = [0x12u8; 32];
        let fk = [0x34u8; 32];
        let fn_iv = [0x56u8; 16];
        session.set_session_key(sk);

        let head = build_test_head_frame(&sk, 9001, u32::MAX, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&head, 1_700_000_200);
        let slice0 = build_test_slice_frame(&fk, &fn_iv, &[(0, 0x00), (1, 0x01)]);
        let _ = session.ingest_ble_chunk(&slice0, 1_700_000_200);

        let stop_out = session.stop_realtime_recording();
        assert_eq!(
            stop_out.outbound_tx_frames,
            vec![DeviceCommands::pause_record()]
        );
        assert!(session.is_realtime_quiet_draining());
        assert!(session.transfer.quiet_draining);

        let t1 = session.poll_timers(1_500, 1_700_000_201);
        assert!(t1.finalized.is_none());

        let late_slice = build_test_slice_frame(&fk, &fn_iv, &[(2, 0x01)]);
        let _ = session.ingest_ble_chunk(&late_slice, 1_700_000_201);
        assert!(session.is_realtime_quiet_draining());

        let t2 = session.poll_timers(1_500, 1_700_000_203);
        assert!(t2.finalized.is_none());

        let t3 = session.poll_timers(500, 1_700_000_204);
        let fin = t3
            .finalized
            .expect("2,000 ms quiet drain after late slice must finalize");
        assert_eq!(fin.entry.id, 9001);
        assert_eq!(fin.entry.marks_ms, vec![20, 40]);
        assert!(!session.is_realtime_quiet_draining());
    }

    #[test]
    fn transport_interrupted_suspends_offline_pull_and_resumes_on_reconnect() {
        let mut session = TransportSession::new();
        let sk = [0x44u8; 32];
        let fk = [0x55u8; 32];
        let fn_iv = [0x66u8; 16];
        session.set_session_key(sk);

        let _ = session.begin_offline_pull(321, 100);
        let head = build_test_head_frame(&sk, 321, 5 * 166, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&head, 1_700_000_300);
        let first_three = build_test_slice_frame(&fk, &fn_iv, &[(0, 0x00), (1, 0x01), (2, 0x00)]);
        let _ = session.ingest_ble_chunk(&first_three, 1_700_000_300);
        assert_eq!(session.received_slice_count(), 3);

        session.on_transport_interrupted();
        assert!(session.is_offline_pull_suspended());
        assert_eq!(session.connection_phase, ConnectionPhaseTag::Disconnected);
        assert_eq!(session.received_slice_count(), 3);

        let idle_poll = session.poll_timers(10_000, 1_700_000_310);
        assert!(idle_poll.outbound_tx_frames.is_empty());
        assert!(session.is_offline_pull_suspended());

        session.set_session_key(sk);
        let mut tel_pkt = Vec::from(RX_MAGIC);
        tel_pkt.extend_from_slice(&[0x01, 0x01, 0x01, 0x00, 0x00, 1, 7, 0]);
        tel_pkt.extend_from_slice(b"1.4.8");
        tel_pkt.extend_from_slice(b"D3200NATIVE639D0");
        tel_pkt.extend_from_slice(&1024u32.to_le_bytes());
        tel_pkt.extend_from_slice(&512u32.to_le_bytes());
        let tel_len = (tel_pkt.len() + 1) as u16;
        tel_pkt[7] = (tel_len & 0xFF) as u8;
        tel_pkt[8] = ((tel_len >> 8) & 0xFF) as u8;
        let csum = ProtocolFrame::checksum(&tel_pkt);
        tel_pkt.push(csum);

        let reconn_out = session.ingest_ble_chunk(&tel_pkt, 1_700_000_311);
        assert_eq!(reconn_out.outbound_tx_frames.len(), 2);
        let resume_tx = &reconn_out.outbound_tx_frames[1];
        assert_eq!(&resume_tx[9..13], &(3u32 * 166).to_le_bytes());
        assert_eq!(&resume_tx[13..17], &321u32.to_le_bytes());
        assert!(!session.is_offline_pull_suspended());
    }

    fn build_test_head_frame_with_err(
        session_key: &[u8; 32],
        file_id: u32,
        file_size: u32,
        file_key: &[u8; 32],
        file_nonce: &[u8; 16],
        error_code: u8,
    ) -> Vec<u8> {
        let mut plain_key_mat = Vec::with_capacity(46);
        plain_key_mat.extend_from_slice(b"soundcored3200");
        plain_key_mat.extend_from_slice(file_key);
        let session_nonce = [0x33u8; 16];
        let enc_file_key =
            DeviceCrypto::aes_ctr_decrypt(&plain_key_mat, session_key, &session_nonce).unwrap();
        let mut head_payload = Vec::with_capacity(87);
        head_payload.extend_from_slice(&file_id.to_le_bytes());
        head_payload.extend_from_slice(&file_size.to_le_bytes());
        head_payload.extend_from_slice(file_nonce);
        head_payload.extend_from_slice(&enc_file_key);
        head_payload.extend_from_slice(&session_nonce);
        head_payload.push(error_code);
        TransportSession::build_rx_frame(0x1A, 0x07, &head_payload)
    }

    fn build_telemetry_frame_with_recording_status(recording_status: u8) -> Vec<u8> {
        let mut payload = Vec::with_capacity(56);
        payload.push(1);
        payload.push(8);
        payload.push(0);
        payload.extend_from_slice(b"1.4.8");
        payload.extend_from_slice(b"D3200NATIVE639D0");
        payload.extend_from_slice(&(64u32 * 1024 * 1024).to_le_bytes());
        payload.extend_from_slice(&(58u32 * 1024 * 1024).to_le_bytes());
        payload.push(0);
        payload.extend_from_slice(b"2.1.0");
        payload.push(9);
        payload.extend_from_slice(&[0xAA, 0xBB, 0xCC, 0xDD, 0x63, 0x9D]);
        payload.extend_from_slice(&[0u8; 5]);
        payload.push(recording_status);
        payload.extend_from_slice(b"1.0.0");
        TransportSession::build_rx_frame(0x01, 0x01, &payload)
    }

    #[test]
    fn telemetry_recording_active_auto_subscribes_latest_catalog_file_on_1b_0e() {
        let mut session = TransportSession::new();
        let tel = build_telemetry_frame_with_recording_status(1);
        let tel_out = session.ingest_ble_chunk(&tel, 1_700_000_700);
        assert!(tel_out.telemetry_updated);
        assert_eq!(
            session.telemetry.as_ref().map(|t| t.recording_status),
            Some(1)
        );
        assert_eq!(
            tel_out.outbound_tx_frames,
            vec![DeviceCommands::list_files_with_end_time(0)]
        );

        let mut list_payload = Vec::new();
        list_payload.extend_from_slice(&2u16.to_le_bytes());
        list_payload.extend_from_slice(&1000u32.to_le_bytes());
        list_payload.extend_from_slice(&1010u32.to_le_bytes());
        list_payload.extend_from_slice(&10_000u32.to_le_bytes());
        list_payload.extend_from_slice(&2050u32.to_le_bytes());
        list_payload.extend_from_slice(&0u32.to_le_bytes());
        list_payload.extend_from_slice(&4_000u32.to_le_bytes());
        let list_rx = TransportSession::build_rx_frame(0x1B, 0x0E, &list_payload);

        let cat_out = session.ingest_ble_chunk(&list_rx, 1_700_000_701);
        assert!(cat_out.catalog_updated);
        assert_eq!(
            cat_out.outbound_tx_frames,
            vec![DeviceCommands::start_transport_audio_file(2050, 0, 1)]
        );
        assert_eq!(session.active_file_id, Some(2050));
        assert!(session.active_is_realtime);
        assert_eq!(session.transfer.phase, TransferPhaseTag::StreamingRealtime);
    }

    #[test]
    fn record_status_1a_06_starts_realtime_transport_for_5byte_and_4byte_payloads() {
        let mut session = TransportSession::new();
        let mut payload_5b = Vec::with_capacity(5);
        payload_5b.extend_from_slice(&3001u32.to_le_bytes());
        payload_5b.push(1);
        let rx_5b = TransportSession::build_rx_frame(0x1A, 0x06, &payload_5b);

        let out_5b = session.ingest_ble_chunk(&rx_5b, 1_700_000_710);
        assert!(out_5b.transfer_updated);
        assert_eq!(
            out_5b.outbound_tx_frames,
            vec![DeviceCommands::start_transport_audio_file(3001, 0, 1)]
        );
        assert_eq!(session.active_file_id, Some(3001));
        assert!(session.active_is_realtime);
        assert_eq!(session.transfer.phase, TransferPhaseTag::StreamingRealtime);

        let mut session_4b = TransportSession::new();
        let rx_4b = TransportSession::build_rx_frame(0x1A, 0x06, &3002u32.to_le_bytes());
        let out_4b = session_4b.ingest_ble_chunk(&rx_4b, 1_700_000_711);
        assert!(out_4b.transfer_updated);
        assert_eq!(
            out_4b.outbound_tx_frames,
            vec![DeviceCommands::start_transport_audio_file(3002, 0, 1)]
        );
        assert_eq!(session_4b.active_file_id, Some(3002));
        assert!(session_4b.active_is_realtime);
        assert_eq!(
            session_4b.transfer.phase,
            TransferPhaseTag::StreamingRealtime
        );
    }

    #[test]
    fn realtime_1a_07_head_for_same_file_preserves_buffered_slices_marks_and_live_pcm() {
        let mut session = TransportSession::with_decoder_factory(Some(test_decoder_factory));
        let sk = [0x21u8; 32];
        let fk = [0x22u8; 32];
        let fn_iv = [0x23u8; 16];
        session.set_session_key(sk);

        let head = build_test_head_frame(&sk, 4001, u32::MAX, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&head, 1_700_000_720);
        let slices = build_test_slice_frame(&fk, &fn_iv, &[(0, 0x00), (1, 0x01)]);
        let _ = session.ingest_ble_chunk(&slices, 1_700_000_721);
        assert_eq!(session.received_slice_count(), 2);
        assert_eq!(session.marks_ms, vec![20]);
        assert_eq!(drain_audio_pcm(&mut session).len(), 2 * 320 * 2);

        let repeated_head = build_test_head_frame(&sk, 4001, u32::MAX, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&repeated_head, 1_700_000_722);
        assert_eq!(session.received_slice_count(), 2);
        assert_eq!(session.marks_ms, vec![20]);
        assert!(session.take_capture_events().is_empty());
        assert_eq!(session.transfer.received_wire_bytes, 2 * 166);
        let next_slice = build_test_slice_frame(&fk, &fn_iv, &[(2, 0x00)]);
        let _ = session.ingest_ble_chunk(&next_slice, 1_700_000_723);
        assert_eq!(drain_audio_pcm(&mut session).len(), 320 * 2);
    }

    #[test]
    fn realtime_error_head_before_stop_preserves_audio_until_finished() {
        for error_code in [1, 3, 2] {
            assert_realtime_error_head_preserves_capture(error_code, false);
        }
    }

    #[test]
    fn realtime_error_head_during_quiet_drain_preserves_audio_and_deadline() {
        for error_code in [1, 3, 2] {
            assert_realtime_error_head_preserves_capture(error_code, true);
        }
    }

    fn assert_realtime_error_head_preserves_capture(error_code: u8, after_stop: bool) {
        let mut session = TransportSession::with_decoder_factory(Some(test_decoder_factory));
        let sk = [0x21; 32];
        let fk = [0x22; 32];
        let nonce = [0x23; 16];
        session.set_session_key(sk);
        session.ingest_ble_chunk(
            &build_test_head_frame(&sk, 4001, u32::MAX, &fk, &nonce),
            1_700_000_720,
        );
        session.ingest_ble_chunk(
            &build_test_slice_frame(&fk, &nonce, &[(0, 0), (1, 1)]),
            1_700_000_720,
        );
        session.take_capture_events();
        if after_stop {
            session.stop_realtime_recording();
            assert!(
                session
                    .poll_timers(1_500, 1_700_000_721)
                    .finalized
                    .is_none()
            );
        }
        session.ingest_ble_chunk(
            &build_test_head_frame_with_err(&sk, 4001, u32::MAX, &fk, &nonce, error_code),
            1_700_000_721,
        );
        assert_eq!(session.transfer.error_code, error_code);
        assert_eq!(session.transfer.phase, TransferPhaseTag::StreamingRealtime);
        assert!(session.take_capture_events().is_empty());
        if !after_stop {
            session.ingest_ble_chunk(
                &build_test_slice_frame(&fk, &nonce, &[(2, 0)]),
                1_700_000_721,
            );
            assert!(matches!(
                session.take_capture_events().back(),
                Some(CaptureEvent::Audio { file_id: 4001, .. })
            ));
            session.stop_realtime_recording();
        }
        let remaining = if after_stop { 500 } else { 2_000 };
        let finalized = session
            .poll_timers(remaining, 1_700_000_723)
            .finalized
            .expect("a transfer error must not lose buffered audio or the stop deadline");
        assert_eq!(finalized.entry.id, 4001);
        assert_eq!(finalized.entry.marks_ms, vec![20]);
        assert_eq!(
            finalized.ogg_opus_bytes,
            OggOpus::mux_raw_frames(&{
                let mut expected = Vec::new();
                for _ in 0..if after_stop { 2 } else { 3 } {
                    let mut packet = [0; OPUS_FRAME_BYTES];
                    packet[..REAL_OPUS_20MS_440HZ_PACKET.len()]
                        .copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
                    expected.extend_from_slice(&packet);
                }
                expected
            })
        );
        assert_eq!(
            Vec::from(session.take_capture_events()),
            vec![CaptureEvent::Finished {
                file_id: 4001,
                saved: true,
            }]
        );
        assert_eq!(session.transfer.phase, TransferPhaseTag::Idle);
    }

    #[test]
    fn start_realtime_recording_queues_81_82_and_subscribes_known_or_pending_file() {
        let mut session = TransportSession::new();
        let out_pending = session.start_realtime_recording(None, 1_700_000_800_000);
        assert!(session.device_recording_active);
        assert!(session.pending_realtime_subscribe);
        assert_eq!(
            out_pending.outbound_tx_frames,
            vec![
                DeviceCommands::start_realtime_record_81(),
                DeviceCommands::start_app_recording(),
                DeviceCommands::list_files_with_end_time(0),
            ]
        );

        let mut session_known = TransportSession::new();
        let out_known = session_known.start_realtime_recording(Some(8801), 1_700_000_800_000);
        assert!(session_known.device_recording_active);
        assert!(!session_known.pending_realtime_subscribe);
        assert_eq!(session_known.active_file_id, Some(8801));
        assert!(session_known.active_is_realtime);
        assert_eq!(
            out_known.outbound_tx_frames,
            vec![
                DeviceCommands::start_realtime_record_81(),
                DeviceCommands::start_app_recording(),
                DeviceCommands::start_transport_audio_file(8801, 0, 1),
            ]
        );
    }

    #[test]
    fn repro_1a_06_stop_while_pending_realtime_subscribe_leaves_session_recording_active() {
        let mut session = TransportSession::new();
        let rx_start = TransportSession::build_rx_frame(0x1A, 0x06, &[0x01]);
        let _ = session.ingest_ble_chunk(&rx_start, 1_700_000_900);
        assert!(session.device_recording_active);
        assert!(session.pending_realtime_subscribe);
        assert!(!session.active_is_realtime);

        let rx_stop = TransportSession::build_rx_frame(0x1A, 0x06, &[0x00]);
        let _ = session.ingest_ble_chunk(&rx_stop, 1_700_000_901);

        assert!(
            !session.device_recording_active,
            "1A/06 stop (state=0) failed to clear device_recording_active because active_is_realtime was false"
        );
        assert!(
            !session.pending_realtime_subscribe,
            "1A/06 stop (state=0) failed to clear pending_realtime_subscribe because active_is_realtime was false"
        );
    }

    #[test]
    fn repro_1a_06_start_during_offline_pull_hijacks_offline_file_id_for_realtime() {
        let mut session = TransportSession::new();
        let _ = session.begin_offline_pull(5001, 10_000);
        assert_eq!(session.active_file_id, Some(5001));
        assert!(!session.active_is_realtime);

        let rx_start = TransportSession::build_rx_frame(0x1A, 0x06, &[0x01]);
        let outcome = session.ingest_ble_chunk(&rx_start, 1_700_000_910);

        assert_ne!(
            outcome.outbound_tx_frames,
            vec![DeviceCommands::start_transport_audio_file(5001, 0, 1)],
            "1A/06 start erroneously hijacked active offline file_id 5001 for realtime stream instead of querying catalog"
        );
        assert_eq!(
            outcome.outbound_tx_frames,
            vec![DeviceCommands::list_files_with_end_time(0)]
        );
    }

    #[test]
    fn omi_pendant_custody_blocks_hardware_file_deletion_until_disk_fsync_receipt() {
        let mut session = TransportSession::new();
        assert!(!session.has_disk_custody(20_261_109));
        assert!(session.request_reclaim_bean_file(20_261_109).is_err());

        assert!(!session.confirm_disk_custody(CustodyReceipt {
            file_id: 20_261_109,
            byte_count: 0,
            sha256_hex: "a".repeat(64),
            fsynced_at_epoch_sec: 1_775_000_000,
        }));
        assert!(!session.confirm_disk_custody(CustodyReceipt {
            file_id: 20_261_109,
            byte_count: 9818,
            sha256_hex: "not-a-sha".to_string(),
            fsynced_at_epoch_sec: 1_775_000_000,
        }));

        assert!(session.confirm_disk_custody(CustodyReceipt {
            file_id: 20_261_109,
            byte_count: 9818,
            sha256_hex:
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".to_string(),
            fsynced_at_epoch_sec: 1_775_000_000,
        }));
        assert!(session.has_disk_custody(20_261_109));
        let delete_cmd = session
            .request_reclaim_bean_file(20_261_109)
            .expect("custody verified must permit 0x1A/0x10 delete command");
        assert_eq!(delete_cmd, DeviceCommands::delete_file(20_261_109));
    }

    #[test]
    fn realtime_lifecycle_emits_started_finished_preserves_stream_on_head_and_refreshes_catalog_on_stop()
     {
        let mut session = TransportSession::new();
        let sk = [0x51u8; 32];
        let fk = [0x52u8; 32];
        let fn_iv = [0x53u8; 16];
        session.set_session_key(sk);

        let start_rx = TransportSession::build_rx_frame(0x1A, 0x06, &7001u32.to_le_bytes());
        let _ = session.ingest_ble_chunk(&start_rx, 1_700_001_000);
        assert_eq!(
            Vec::from(session.take_capture_events()),
            vec![CaptureEvent::Started { file_id: 7001 }]
        );

        let head_finite = build_test_head_frame(&sk, 7001, 10 * 166, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&head_finite, 1_700_001_001);
        assert!(session.active_is_realtime);
        assert_eq!(session.transfer.phase, TransferPhaseTag::StreamingRealtime);
        assert!(session.take_capture_events().is_empty());

        let stop_rx = TransportSession::build_rx_frame(0x18, 0x82, &[0x00]);
        let stop_out = session.ingest_ble_chunk(&stop_rx, 1_700_001_002);
        assert!(stop_out.transfer_updated);
        assert_eq!(
            stop_out.outbound_tx_frames,
            vec![DeviceCommands::list_files_with_end_time(0)]
        );
        assert!(session.is_realtime_quiet_draining());

        let drain_out = session.poll_timers(REALTIME_QUIET_DRAIN_MS, 1_700_001_004);
        assert!(drain_out.transfer_updated);
        assert_eq!(
            drain_out.outbound_tx_frames,
            vec![DeviceCommands::list_files_with_end_time(0)]
        );
        assert_eq!(
            Vec::from(session.take_capture_events()),
            vec![CaptureEvent::Finished {
                file_id: 7001,
                saved: false,
            }]
        );
    }

    #[test]
    fn realtime_transfer_clamps_out_of_range_marks_to_duration() {
        let mut session = TransportSession::with_decoder_factory(Some(test_decoder_factory));
        let sk = [0x71u8; 32];
        let fk = [0x72u8; 32];
        let fn_iv = [0x73u8; 16];
        session.set_session_key(sk);

        let _ = session.start_realtime_recording(Some(9901), 1_775_000_000_000);
        let head = build_test_head_frame(&sk, 9901, UNFINISHED_FILE_SIZE, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&head, 1_775_000_000);

        let dec = AesCtrStreamDecrypt::new(&fk, &fn_iv).unwrap();
        let mut payload = Vec::with_capacity(3 * SLICE_RECORD_BYTES);
        for i in 0..3u32 {
            let seq = if i == 2 { 50 } else { i };
            payload.extend_from_slice(&seq.to_le_bytes());
            payload.push(if i == 2 { 0x01 } else { 0x00 });
            let mut opus = [0u8; OPUS_FRAME_BYTES];
            opus[..REAL_OPUS_20MS_440HZ_PACKET.len()].copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
            dec.decrypt_contiguous_in_place(&mut opus, seq);
            payload.extend_from_slice(&opus);
            payload.push(0);
        }
        let slices_rx = TransportSession::build_rx_frame(0x1A, 0x08, &payload);
        let outcome = session.ingest_ble_chunk(&slices_rx, 1_775_000_001);
        assert_eq!(outcome.new_marks_ms, vec![1000]);

        let finalized = session
            .finalize_active_transfer(1_775_000_002)
            .expect("must produce finalized recording");
        assert_eq!(finalized.entry.duration_ms, 400);
        assert_eq!(finalized.entry.marks_ms, vec![60]);
    }

    fn build_1b0e_page(count: u16, files: &[(u32, u32, Option<u32>)]) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&count.to_le_bytes());
        for &(fid, dur, et) in files {
            payload.extend_from_slice(&fid.to_le_bytes());
            payload.extend_from_slice(&et.unwrap_or(0).to_le_bytes());
            payload.extend_from_slice(&dur.to_le_bytes());
        }
        TransportSession::build_rx_frame(0x1B, 0x0E, &payload)
    }

    #[test]
    fn multipage_catalog_pagination_selects_new_open_file_on_second_page() {
        let mut session = TransportSession::new();
        let sk = [0x41u8; 32];
        session.set_session_key(sk);

        let initial_files: Vec<(u32, u32, Option<u32>)> = (101..=110)
            .map(|id| {
                if id == 105 {
                    (id, 0, Some(0))
                } else {
                    (id, 2_000, Some(1_700_000_000 + id))
                }
            })
            .collect();

        let initial_page = build_1b0e_page(10, &initial_files);
        let _ = session.ingest_ble_chunk(&initial_page, 1_700_000_100);
        let initial_end = build_1b0e_page(0, &[]);
        let _ = session.ingest_ble_chunk(&initial_end, 1_700_000_100);
        assert_eq!(session.raw_catalog.len(), 10);

        let start_out = session.start_realtime_recording(None, 1_700_000_100_000);
        assert!(
            start_out
                .outbound_tx_frames
                .iter()
                .any(|f| f.len() >= 7 && f[5] == 0x18 && f[6] == 0x81)
        );
        assert!(
            start_out
                .outbound_tx_frames
                .iter()
                .any(|f| f.len() >= 7 && f[5] == 0x1B && f[6] == 0x0E)
        );

        let page0_files = initial_files.clone();
        let page0_rx = build_1b0e_page(10, &page0_files);
        let p0_out = session.ingest_ble_chunk(&page0_rx, 1_700_000_101);
        assert!(session.is_catalog_loading());
        assert_eq!(
            session.catalog_load_phase,
            CatalogLoadPhase::Paginating { next_page: 2 }
        );
        assert_eq!(
            p0_out.outbound_tx_frames,
            vec![DeviceCommands::list_files_with_end_time(1)]
        );
        assert_eq!(session.active_file_id, None);

        let page1_files = vec![(111, 0, Some(0))];
        let page1_rx = build_1b0e_page(1, &page1_files);
        let p1_out = session.ingest_ble_chunk(&page1_rx, 1_700_000_102);
        assert!(!session.is_catalog_loading());
        assert_eq!(session.active_file_id, Some(111));
        assert_eq!(session.stream_base_slices, 0);
        assert_eq!(
            p1_out.outbound_tx_frames,
            vec![DeviceCommands::start_transport_audio_file(111, 0, 1)]
        );
    }

    #[test]
    fn resumed_open_file_computes_slice_offset_and_relative_marks() {
        let mut session = TransportSession::with_decoder_factory(Some(test_decoder_factory));
        let sk = [0x51u8; 32];
        let fk = [0x52u8; 32];
        let fn_iv = [0x53u8; 16];
        session.set_session_key(sk);

        let files = vec![(201, 1_000, Some(0))];
        let initial_page = build_1b0e_page(1, &files);
        let _ = session.ingest_ble_chunk(&initial_page, 1_700_000_200);

        let _ = session.start_realtime_recording(None, 1_700_000_200_000);
        let start_page = build_1b0e_page(1, &files);
        let start_out = session.ingest_ble_chunk(&start_page, 1_700_000_201);

        assert_eq!(session.active_file_id, Some(201));
        assert_eq!(session.stream_base_slices, 0);
        assert_eq!(
            start_out.outbound_tx_frames,
            vec![DeviceCommands::start_transport_audio_file(201, 0, 1)]
        );

        let resume_tx = session
            .enter_or_resume_realtime_stream_at(201, 50, 1_700_000_201)
            .unwrap();
        assert_eq!(session.stream_base_slices, 50);
        let expected_wire_offset = 50 * SLICE_RECORD_BYTES as u32;
        assert_eq!(
            resume_tx,
            DeviceCommands::start_transport_audio_file(201, expected_wire_offset, 1)
        );

        let head = build_test_head_frame(&sk, 201, UNFINISHED_FILE_SIZE, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&head, 1_700_000_202);

        let dec = AesCtrStreamDecrypt::new(&fk, &fn_iv).unwrap();
        let mut slice_payload = Vec::with_capacity(SLICE_RECORD_BYTES);
        let seq = 51u32;
        slice_payload.extend_from_slice(&seq.to_le_bytes());
        slice_payload.push(0x01);
        let mut opus = [0u8; OPUS_FRAME_BYTES];
        opus[..REAL_OPUS_20MS_440HZ_PACKET.len()].copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
        dec.decrypt_contiguous_in_place(&mut opus, seq);
        slice_payload.extend_from_slice(&opus);
        slice_payload.push(0);

        let slice_rx = TransportSession::build_rx_frame(0x1A, 0x08, &slice_payload);
        let outcome = session.ingest_ble_chunk(&slice_rx, 1_700_000_203);
        assert_eq!(outcome.new_marks_ms, vec![20]);
        assert_eq!(session.marks_ms, vec![20]);
    }

    #[test]
    fn offline_pull_error_code_clears_active_file_id_and_sets_failed_phase() {
        let mut session = TransportSession::new();
        let sk = [0x61u8; 32];
        let fk = [0x62u8; 32];
        let fn_iv = [0x63u8; 16];
        session.set_session_key(sk);

        let _ = session.begin_offline_pull(301, 2_000);
        assert_eq!(session.active_file_id, Some(301));
        assert_eq!(session.transfer.phase, TransferPhaseTag::PullingOffline);

        let err_head = build_test_head_frame_with_err(&sk, 301, 2_000, &fk, &fn_iv, 1);

        let outcome = session.ingest_ble_chunk(&err_head, 1_700_000_300);
        assert!(outcome.transfer_updated);
        assert_eq!(session.active_file_id, None);
        assert!(!session.active_is_realtime);
        assert_eq!(session.transfer.phase, TransferPhaseTag::Failed);
        assert_eq!(session.transfer.file_id, 301);
        assert_eq!(session.transfer.error_code, 1);
    }

    #[test]
    fn offline_pull_unfinished_head_aborts_to_idle_without_flipping_to_realtime() {
        let mut session = TransportSession::new();
        let sk = [0x71u8; 32];
        let fk = [0x72u8; 32];
        let fn_iv = [0x73u8; 16];
        session.set_session_key(sk);

        let _ = session.begin_offline_pull(401, 2_000);
        assert_eq!(session.active_file_id, Some(401));
        assert_eq!(session.transfer.phase, TransferPhaseTag::PullingOffline);

        let head = build_test_head_frame(&sk, 401, UNFINISHED_FILE_SIZE, &fk, &fn_iv);
        let outcome = session.ingest_ble_chunk(&head, 1_700_000_400);

        assert!(outcome.transfer_updated);
        assert_eq!(session.active_file_id, None);
        assert!(!session.active_is_realtime);
        assert_eq!(session.transfer.phase, TransferPhaseTag::Idle);
    }

    fn build_1b0e_page_with_tail(
        count: u16,
        files: &[(u32, u32, Option<u32>)],
        transport_timestamp: Option<u32>,
        transport_duration: Option<u32>,
    ) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&count.to_le_bytes());
        for &(fid, dur, et) in files {
            payload.extend_from_slice(&fid.to_le_bytes());
            payload.extend_from_slice(&et.unwrap_or(0).to_le_bytes());
            payload.extend_from_slice(&dur.to_le_bytes());
        }
        if let (Some(ts), Some(dur)) = (transport_timestamp, transport_duration) {
            payload.extend_from_slice(&ts.to_le_bytes());
            payload.extend_from_slice(&dur.to_le_bytes());
        }
        TransportSession::build_rx_frame(0x1B, 0x0E, &payload)
    }

    #[test]
    fn duplicate_page0_and_1882_ack_do_not_abort_multi_page_pagination() {
        let mut session = TransportSession::new();
        let sk = [0x42u8; 32];
        session.set_session_key(sk);

        let page0_files: Vec<(u32, u32, Option<u32>)> = (1001..=1010)
            .map(|id| (id, 60_000, Some(1_700_000_000 + id)))
            .collect();

        let start_out = session.start_realtime_recording(None, 1_700_000_100_000);
        assert!(
            start_out
                .outbound_tx_frames
                .iter()
                .any(|f| f.len() >= 7 && f[5] == 0x1B && f[6] == 0x0E)
        );
        assert!(session.is_catalog_loading());

        let page0_rx = build_1b0e_page_with_tail(10, &page0_files, Some(1793860020), Some(60_000));
        let p0_out = session.ingest_ble_chunk(&page0_rx, 1_700_000_101);
        assert_eq!(
            p0_out.outbound_tx_frames,
            vec![DeviceCommands::list_files_with_end_time(1)]
        );
        assert!(session.is_catalog_loading());

        let ack_rx = TransportSession::build_rx_frame(0x18, 0x82, &[0x01]);
        let _ = session.ingest_ble_chunk(&ack_rx, 1_700_000_102);
        assert!(session.is_catalog_loading());

        let _ = session.ingest_ble_chunk(&page0_rx, 1_700_000_103);
        assert!(session.is_catalog_loading());

        let page1_files = vec![(1794015297, 9_480, Some(0))];
        let page1_rx = build_1b0e_page_with_tail(1, &page1_files, Some(1794015297), Some(9_480));
        let p1_out = session.ingest_ble_chunk(&page1_rx, 1_700_000_104);

        assert!(!session.is_catalog_loading());
        assert!(session.has_complete_catalog());
        assert_eq!(session.raw_catalog.len(), 11);
        assert_eq!(session.active_file_id, Some(1794015297));
        assert!(
            p1_out
                .outbound_tx_frames
                .iter()
                .any(|f| f == &DeviceCommands::start_transport_audio_file(1794015297, 0, 1))
        );
    }

    #[test]
    fn orphan_slice_without_active_file_id_is_ignored_and_never_creates_phantom_file() {
        let mut session = TransportSession::new();
        let sk = [0x42u8; 32];
        session.set_session_key(sk);

        assert_eq!(session.active_file_id, None);
        assert_eq!(session.transfer.phase, TransferPhaseTag::Idle);

        let mut slice_payload = Vec::new();
        slice_payload.extend_from_slice(&0u32.to_le_bytes());
        slice_payload.push(0);
        slice_payload.extend_from_slice(&[0xAA; 160]);
        slice_payload.push(0);
        let slice_rx = TransportSession::build_rx_frame(0x1A, 0x08, &slice_payload);

        let outcome = session.ingest_ble_chunk(&slice_rx, 1_700_000_100);
        assert!(!outcome.transfer_updated);
        assert_eq!(session.active_file_id, None);
        assert_eq!(session.transfer.phase, TransferPhaseTag::Idle);
        assert_eq!(session.transfer.received_wire_bytes, 0);
        assert!(session.opus_buffer.is_empty());
    }

    #[test]
    fn one_byte_1a06_during_catalog_loading_never_emits_empty_tx_frame() {
        let mut session = TransportSession::new();
        assert!(!session.request_full_catalog().is_empty());
        assert!(session.is_catalog_loading());

        let start_rx = TransportSession::build_rx_frame(0x1A, 0x06, &[0x01]);
        let start_out = session.ingest_ble_chunk(&start_rx, 1_700_000_200);
        assert!(
            start_out.outbound_tx_frames.iter().all(|f| !f.is_empty()),
            "1A/06 state=1 during catalog loading emitted empty BLE TX frame: {:?}",
            start_out.outbound_tx_frames
        );

        let stop_rx = TransportSession::build_rx_frame(0x1A, 0x06, &[0x00]);
        let stop_out = session.ingest_ble_chunk(&stop_rx, 1_700_000_201);
        assert!(
            stop_out.outbound_tx_frames.iter().all(|f| !f.is_empty()),
            "1A/06 state=0 during catalog loading emitted empty BLE TX frame: {:?}",
            stop_out.outbound_tx_frames
        );
    }

    #[test]
    fn duplicate_one_byte_1a06_start_does_not_queue_spurious_catalog_refresh() {
        let mut session = TransportSession::new();
        let start_rx = TransportSession::build_rx_frame(0x1A, 0x06, &[0x01]);

        let first = session.ingest_ble_chunk(&start_rx, 1_700_000_300);
        assert_eq!(
            first.outbound_tx_frames,
            vec![DeviceCommands::list_files_with_end_time(0)]
        );
        assert!(session.is_catalog_loading());

        let dup = session.ingest_ble_chunk(&start_rx, 1_700_000_301);
        assert!(dup.outbound_tx_frames.is_empty());

        let empty_page = build_1b0e_page(0, &[]);
        let completed = session.ingest_ble_chunk(&empty_page, 1_700_000_302);
        assert!(
            completed.outbound_tx_frames.is_empty(),
            "duplicate 1A/06 state=1 spuriously queued a second catalog refresh: {:?}",
            completed.outbound_tx_frames
        );
        assert!(!session.is_catalog_loading());
    }
