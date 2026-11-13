use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use koe_engine::{ogg_opus::OggOpus, wav::parse_pcm_wave};
use koe_runtime::KoeRuntime;
use serde_json::json;

struct Sandbox(PathBuf);
impl Sandbox {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "koe-legacy-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn legacy_speakers_and_bookmarks_survive_migration_and_reopen() {
    let dir = Sandbox::new();
    let original = json!({
        "activeFileId":77,"durationMs":2000,
        "segments":[
            {"text":"First speaker's decision.","startMs":0,"endMs":1000,"sourceLanguage":"en","provider":"legacy","speaker":"Ada"},
            {"text":"Second speaker's action.","startMs":1000,"endMs":2000,"sourceLanguage":"en","provider":"legacy","speaker":"Lin"}
        ],"bookmarks":[250,1500],"dismissedReviews":[],"appliedProposals":[]
    }).to_string();
    fs::write(dir.0.join("workspace_session.json"), &original).unwrap();
    let runtime = KoeRuntime::open(&dir.0).unwrap();
    let record = runtime.workspace().record("bean-77").unwrap();
    let speakers: Vec<_> = record
        .aggregate
        .spine
        .segments()
        .iter()
        .map(|s| s.speaker.as_deref())
        .collect();
    assert_eq!(speakers, vec![Some("Ada"), Some("Lin")]);
    assert_eq!(record.aggregate.bookmarks, vec![250, 1500]);
    drop(runtime);
    let reopened = KoeRuntime::open(&dir.0).unwrap();
    assert_eq!(
        reopened
            .workspace()
            .record("bean-77")
            .unwrap()
            .aggregate
            .bookmarks,
        vec![250, 1500]
    );
    assert_eq!(
        reopened
            .workspace()
            .record("bean-77")
            .unwrap()
            .aggregate
            .spine
            .segments()[1]
            .speaker
            .as_deref(),
        Some("Lin")
    );
    assert_eq!(
        fs::read_to_string(dir.0.join("workspace_session.json")).unwrap(),
        original
    );
}

#[test]
fn legacy_session_clamps_out_of_range_bookmarks_on_restore() {
    let dir = Sandbox::new();
    let original = json!({
        "activeFileId": 88,
        "durationMs": 2000,
        "segments": [
            {"text": "Recorded discussion.", "startMs": 0, "endMs": 2000, "sourceLanguage": "zh", "provider": "legacy", "speaker": "Alice"}
        ],
        "bookmarks": [250, 2020],
        "dismissedReviews": [],
        "appliedProposals": []
    })
    .to_string();
    fs::write(dir.0.join("workspace_session.json"), &original).unwrap();
    let runtime =
        KoeRuntime::open(&dir.0).expect("legacy restore must heal out-of-range bookmarks");
    let record = runtime.workspace().record("bean-88").unwrap();
    assert_eq!(record.aggregate.duration_ms, 2000);
    assert_eq!(record.aggregate.bookmarks, vec![250, 2000]);
}

#[test]
fn opus_without_preview_is_recovered_from_real_decoder_output() {
    let dir = Sandbox::new();
    let mut frame = [0_u8; 160];
    frame[..3].copy_from_slice(&[0xf8, 0xff, 0xfe]);
    let opus = OggOpus::mux_raw_frames(&frame.repeat(10));
    fs::write(dir.0.join("42.opus"), &opus).unwrap();
    let runtime = KoeRuntime::open(&dir.0).unwrap();
    let record = runtime
        .workspace()
        .record("bean-42")
        .expect("an Opus-only recording was skipped");
    let wav = fs::read(dir.0.join("audio/bean-42.wav")).unwrap();
    let parsed = parse_pcm_wave(&wav).unwrap();
    assert!(parsed.duration_ms() > 0);
    assert_eq!(record.aggregate.duration_ms, parsed.duration_ms());
    let mut decoder = koe_opus::create_libopus_decoder(48000).unwrap();
    let mut decoded = Vec::new();
    for _ in 0..10 {
        assert!(decoder.decode_trimmed_packet(&frame[..3], &mut decoded));
    }
    // OggOpus writes an OpusHead pre-skip of 3840 samples at 48 kHz.
    assert_eq!(&wav[44..], &decoded[3840 * 2..]);
    assert_eq!(fs::read(dir.0.join("42.opus")).unwrap(), opus);
}

#[test]
fn undecodable_opus_keeps_transcript_metadata_and_original_bytes() {
    let dir = Sandbox::new();
    let original = b"not a decodable Opus recording";
    fs::write(dir.0.join("42.opus"), original).unwrap();
    fs::write(dir.0.join("workspace_session.json"), json!({
        "activeFileId":42,"durationMs":1500,"bookmarks":[300],
        "segments":[{"text":"Retain this original sentence.","startMs":0,"endMs":1500,"speaker":"Ada"}]
    }).to_string()).unwrap();
    let runtime = KoeRuntime::open(&dir.0).unwrap();
    let record = runtime.workspace().record("bean-42").unwrap();
    assert_eq!(
        record.aggregate.spine.segments()[0].text,
        "Retain this original sentence."
    );
    assert_eq!(
        record.aggregate.spine.segments()[0].speaker.as_deref(),
        Some("Ada")
    );
    assert_eq!(record.aggregate.bookmarks, vec![300]);
    assert!(
        !dir.0.join("audio/bean-42.wav").exists(),
        "unavailable audio must not be synthesized"
    );
    assert!(
        runtime.snapshot(1_800_000_000)["notice"]
            .as_str()
            .unwrap()
            .contains("无法解码")
    );
    assert_eq!(fs::read(dir.0.join("42.opus")).unwrap(), original);
}

#[test]
fn unreadable_legacy_metadata_fails_without_creating_an_empty_replacement() {
    let dir = Sandbox::new();
    fs::create_dir(dir.0.join("workspace_session.json")).unwrap();
    let error = KoeRuntime::open(&dir.0)
        .err()
        .expect("reading a directory as metadata must fail");
    assert!(error.contains("旧工作区无法读取"));
    assert!(dir.0.join("workspace_session.json").is_dir());
    assert!(!dir.0.join("product-workspace.json").exists());
}
