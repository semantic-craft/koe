use super::*;
use koe_client_providers::OfflineSpeechEvent;

    #[test]
    fn preparation_is_single_owner_and_cancelled_ready_never_reenables_a_model() {
        let root = std::env::temp_dir().join(format!("koe-model-lifecycle-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let mut runtime = KoeRuntime::open(&root).unwrap();
        runtime.speech.preparation = Some(ModelPreparation {
            id: "sensevoice-small".into(),
            cancelled: false,
        });
        runtime.speech.models.insert(
            "sensevoice-small".into(),
            ModelState {
                state: "preparing".into(),
                bytes: 1,
                message: None,
            },
        );
        let busy: Value = serde_json::from_str(&runtime.dispatch_json(
            r#"{"type":"prepare_speech_model","modelId":"qwen3-asr-0.6b"}"#,
            100,
        ))
        .unwrap();
        assert!(busy["error"].as_str().unwrap().contains("等待当前模型"));
        runtime.cancel_speech_model();
        let cancelled_busy: Value = serde_json::from_str(&runtime.dispatch_json(
            r#"{"type":"prepare_speech_model","modelId":"qwen3-asr-0.6b"}"#,
            100,
        ))
        .unwrap();
        assert!(cancelled_busy["error"].is_string());
        runtime.accept_offline_speech_event(OfflineSpeechEvent::Ready {
            model_id: "sensevoice-small".into(),
        });
        let snapshot = runtime.snapshot(100);
        assert!(!snapshot["speech"]["models"]
            .as_array()
            .unwrap()
            .iter()
            .any(|model| model["state"] == "ready"));
        assert!(!runtime.speech_ready(&SpeechEngine::Downloaded("sensevoice-small".into())));
        assert!(runtime.speech.preparation.is_none());
        runtime.accept_offline_speech_event(OfflineSpeechEvent::Ready {
            model_id: "qwen3-asr-0.6b".into(),
        });
        assert!(!runtime.speech_ready(&SpeechEngine::Downloaded("qwen3-asr-0.6b".into())));
        drop(runtime);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cancelled_deferred_cloud_session_stays_cancelled_after_finish_speech() {
        let root = std::env::temp_dir().join(format!("koe-speech-phase-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let mut runtime = KoeRuntime::open(&root).unwrap();
        runtime
            .commit(|w| {
                w.insert_record(
                    "rec-deferred".into(),
                    "Deferred".into(),
                    RecordOrigin::Microphone,
                    0,
                    1_800_000_000,
                    1_000,
                )
            })
            .unwrap();
        let wav = koe_engine::wav::OpusWave::wav_header_with_rate(320, 16_000)
            .into_iter()
            .chain(vec![0u8; 320])
            .collect::<Vec<_>>();
        recording_assets::save_audio(&root, "rec-deferred", &wav).unwrap();

        runtime.captures.sessions.insert(
            "rec-deferred".into(),
            SpeechSession {
                key: RequestKey {
                    record_id: "rec-deferred".into(),
                    attempt: 0,
                    input_revision: 0,
                },
                backend: SpeechBackend::CloudDeferredBatch,
                phase: SpeechPhase::Accepting,
                source: Some(CaptureOrigin::Microphone),
                file_audio: None,
                results: VecDeque::new(),
                minutes_schedule: Default::default(),
                saved: false,
                captured_pcm_bytes: 0,
            },
        );

        runtime.cancel_cloud_captures();
        assert_eq!(
            runtime.captures.sessions["rec-deferred"].phase,
            SpeechPhase::Cancelled
        );

        runtime.finish_speech("rec-deferred");
        runtime.capture_saved("rec-deferred");
        runtime.poll_captures();

        assert!(runtime.captures.sessions.is_empty());
        assert!(!runtime.auto_transcribe.contains("rec-deferred"));
        drop(runtime);
        let _ = std::fs::remove_dir_all(root);
    }
