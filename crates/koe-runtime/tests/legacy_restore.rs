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
    assert!(runtime.snapshot(1_800_000_000)["notice"]
        .as_str()
        .unwrap()
        .contains("无法解码"));
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

fn flutter_fixture(source: &Sandbox) {
    for (name, raw) in [
        (
            "recording_library.json",
            include_str!("fixtures/flutter/recording_library.json"),
        ),
        (
            "transcripts.json",
            include_str!("fixtures/flutter/transcripts.json"),
        ),
        (
            "analysis.json",
            include_str!("fixtures/flutter/analysis.json"),
        ),
        ("topics.json", include_str!("fixtures/flutter/topics.json")),
    ] {
        fs::write(source.0.join(name), raw).unwrap();
    }
    let pcm = vec![0u8; 32_000];
    let mut wav =
        koe_engine::wav::OpusWave::wav_header_with_rate(pcm.len() as u32, 16_000).to_vec();
    wav.extend(pcm);
    fs::create_dir(source.0.join("exports")).unwrap();
    fs::create_dir(source.0.join("imports")).unwrap();
    fs::write(source.0.join("exports/42_meeting.wav"), &wav).unwrap();
    fs::write(source.0.join("imports/note.wav"), &wav).unwrap();
}

fn import_flutter(runtime: &mut KoeRuntime, source: &Sandbox) -> serde_json::Value {
    serde_json::from_str(&runtime.dispatch_json(
        &json!({"type":"import_flutter_library", "path":source.0}).to_string(),
        1,
    ))
    .unwrap()
}

#[test]
fn flutter_library_migrates_visible_content_preserves_history_and_reopens_idempotently() {
    let source = Sandbox::new();
    let target = Sandbox::new();
    flutter_fixture(&source);
    let before: Vec<_> = [
        "recording_library.json",
        "transcripts.json",
        "analysis.json",
        "topics.json",
        "exports/42_meeting.wav",
        "imports/note.wav",
    ]
    .iter()
    .map(|name| {
        let path = source.0.join(name);
        (path.clone(), fs::read(path).unwrap())
    })
    .collect();
    let mut runtime = KoeRuntime::open(&target.0).unwrap();
    let snapshot = import_flutter(&mut runtime, &source);
    assert!(snapshot["error"].is_null(), "{snapshot}");
    assert_eq!(runtime.workspace().records().len(), 2);
    let meeting = runtime
        .workspace()
        .records()
        .values()
        .find(|r| r.title == "Fixture meeting")
        .unwrap();
    assert_eq!(meeting.aggregate.created_at_epoch_sec, 1704164645);
    assert_eq!(
        meeting.aggregate.spine.segments()[1].speaker.as_deref(),
        Some("Ada")
    );
    let id = meeting.aggregate.recording_id.clone();
    let detail: serde_json::Value = serde_json::from_str(&runtime.dispatch_json(
        &json!({"type":"select_record","recordId":id}).to_string(),
        1,
    ))
    .unwrap();
    assert!(detail.to_string().contains("Decision summary"));
    assert!(detail.to_string().contains("Meeting minutes"));
    let note = runtime
        .workspace()
        .records()
        .values()
        .find(|r| r.title == "Edited note")
        .unwrap();
    assert_eq!(note.aggregate.spine.segments()[0].text, "Human correction");
    assert_eq!(note.aggregate.spine.segments()[0].end_ms, 0);
    assert!(snapshot["migrationReports"]
        .to_string()
        .contains("topics.json"));
    assert!(snapshot["migrationReports"]
        .to_string()
        .contains("incomingByKey"));
    let state = runtime.workspace().clone();
    assert!(import_flutter(&mut runtime, &source)["error"].is_null());
    assert_eq!(&state, runtime.workspace());
    drop(runtime);
    let mut reopened = KoeRuntime::open(&target.0).unwrap();
    assert_eq!(&state, reopened.workspace());
    assert!(import_flutter(&mut reopened, &source)["error"].is_null());
    assert_eq!(&state, reopened.workspace());
    for (path, bytes) in before {
        assert_eq!(fs::read(path).unwrap(), bytes);
    }
    let reports = serde_json::from_str::<serde_json::Value>(&reopened.snapshot_json(1)).unwrap();
    let archive = reports["migrationReports"][0]["archivePath"]
        .as_str()
        .unwrap();
    assert_eq!(
        fs::read(std::path::Path::new(archive).join("analysis.json")).unwrap(),
        fs::read(source.0.join("analysis.json")).unwrap()
    );
    assert!(target.0.join("audio").join(format!("{id}.wav")).is_file());
}

#[test]
fn flutter_corruption_and_missing_audio_do_not_publish_partial_records() {
    for file in ["transcripts.json", "42_meeting.wav"] {
        let source = Sandbox::new();
        let target = Sandbox::new();
        flutter_fixture(&source);
        if file.ends_with("json") {
            fs::write(source.0.join(file), b"{broken").unwrap();
        } else {
            fs::remove_file(source.0.join("exports").join(file)).unwrap();
        }
        let mut runtime = KoeRuntime::open(&target.0).unwrap();
        let result = import_flutter(&mut runtime, &source);
        assert!(
            result["error"]
                .as_str()
                .is_some_and(|e| if file.ends_with("json") {
                    e.contains("损坏")
                } else {
                    e.contains("缺失")
                }),
            "{result}"
        );
        assert!(runtime.workspace().records().is_empty());
        assert!(!target.0.join("product-workspace.json").exists());
    }
}

#[test]
fn flutter_import_rejects_workspace_asset_symlinks_before_touching_source() {
    let source = Sandbox::new();
    let target = Sandbox::new();
    flutter_fixture(&source);
    std::os::unix::fs::symlink(source.0.join("exports"), target.0.join("legacy-imports")).unwrap();
    let mut runtime = KoeRuntime::open(&target.0).unwrap();
    let result = import_flutter(&mut runtime, &source);
    assert!(
        result["error"]
            .as_str()
            .is_some_and(|e| e.contains("符号链接")),
        "{result}"
    );
    assert!(runtime.workspace().records().is_empty());
    assert_eq!(fs::read_dir(source.0.join("exports")).unwrap().count(), 1);
}

#[test]
fn flutter_import_keeps_user_changes_and_rejects_changed_source_or_ambiguous_audio() {
    let source = Sandbox::new();
    let target = Sandbox::new();
    flutter_fixture(&source);
    let mut runtime = KoeRuntime::open(&target.0).unwrap();
    assert!(import_flutter(&mut runtime, &source)["error"].is_null());
    let id = runtime
        .workspace()
        .records()
        .values()
        .find(|r| r.title == "Fixture meeting")
        .unwrap()
        .aggregate
        .recording_id
        .clone();
    runtime.dispatch_json(
        &json!({"type":"rename_record","recordId":id,"title":"My edited title"}).to_string(),
        1,
    );
    let state = runtime.workspace().clone();
    assert!(import_flutter(&mut runtime, &source)["error"].is_null());
    assert_eq!(&state, runtime.workspace());
    fs::write(source.0.join("topics.json"), r#"{"version":1,"topics":[]}"#).unwrap();
    assert!(import_flutter(&mut runtime, &source)["error"]
        .as_str()
        .unwrap()
        .contains("已变化"));
    assert_eq!(&state, runtime.workspace());
    fs::copy(
        source.0.join("exports/42_meeting.wav"),
        source.0.join("imports/42_meeting.wav"),
    )
    .unwrap();
    assert!(import_flutter(&mut runtime, &source)["error"]
        .as_str()
        .unwrap()
        .contains("同名"));
}

#[test]
fn flutter_import_preserves_visible_text_over_stale_segments_and_does_not_revive_trash() {
    let source = Sandbox::new();
    let target = Sandbox::new();
    flutter_fixture(&source);
    let mut transcript: serde_json::Value =
        serde_json::from_slice(&fs::read(source.0.join("transcripts.json")).unwrap()).unwrap();
    transcript["byFileId"]["42"] = json!("New provider revision");
    fs::write(
        source.0.join("transcripts.json"),
        serde_json::to_vec(&transcript).unwrap(),
    )
    .unwrap();
    let mut library: serde_json::Value =
        serde_json::from_slice(&fs::read(source.0.join("recording_library.json")).unwrap())
            .unwrap();
    library["assets"][1]["archived"] = json!(true);
    fs::write(
        source.0.join("recording_library.json"),
        serde_json::to_vec(&library).unwrap(),
    )
    .unwrap();
    let mut runtime = KoeRuntime::open(&target.0).unwrap();
    let result = import_flutter(&mut runtime, &source);
    assert!(result["error"].is_null(), "{result}");
    assert_eq!(runtime.workspace().records().len(), 1);
    let record = runtime.workspace().records().values().next().unwrap();
    assert_eq!(
        record.aggregate.spine.segments()[0].text,
        "New provider revision"
    );
    assert_eq!(record.aggregate.spine.segments()[0].end_ms, 0);
    assert_eq!(
        record.origin,
        koe_engine::product::RecordOrigin::ImportedAudio
    );
    assert!(result["migrationReports"].to_string().contains("回收站"));
}

#[test]
fn flutter_import_storage_failure_does_not_publish_records_or_receipt() {
    let source = Sandbox::new();
    let target = Sandbox::new();
    flutter_fixture(&source);
    let mut runtime = KoeRuntime::open(&target.0).unwrap();
    fs::create_dir(target.0.join("product-workspace.json")).unwrap();
    let result = import_flutter(&mut runtime, &source);
    assert!(result["error"].as_str().unwrap().contains("保存"));
    assert!(runtime.workspace().records().is_empty());
    assert_eq!(result["migrationReports"], json!([]));
    assert!(result["notice"].is_null());
    fs::remove_dir(target.0.join("product-workspace.json")).unwrap();
    assert!(import_flutter(&mut runtime, &source)["error"].is_null());
    assert_eq!(runtime.workspace().records().len(), 2);
}

#[test]
fn flutter_microsecond_import_ids_keep_manual_text_and_minutes() {
    let source = Sandbox::new();
    let target = Sandbox::new();
    flutter_fixture(&source);
    let old_path = "/old/AnkerRecorder/note.wav";
    let new_path = "/old/AnkerRecorder/imports/1704251045000000_note.wav";
    let key = "file:1704251045000000";
    let mut library: serde_json::Value =
        serde_json::from_slice(&fs::read(source.0.join("recording_library.json")).unwrap())
            .unwrap();
    library["assets"][1]["path"] = json!(new_path);
    library["assets"][1]["source"] = json!("localImport");
    fs::write(
        source.0.join("recording_library.json"),
        serde_json::to_vec(&library).unwrap(),
    )
    .unwrap();
    fs::rename(
        source.0.join("imports/note.wav"),
        source.0.join("imports/1704251045000000_note.wav"),
    )
    .unwrap();
    let mut transcripts: serde_json::Value =
        serde_json::from_slice(&fs::read(source.0.join("transcripts.json")).unwrap()).unwrap();
    let raw = transcripts["byPath"]
        .as_object_mut()
        .unwrap()
        .remove(old_path)
        .unwrap();
    transcripts["byPath"][new_path] = raw;
    for field in ["manualByKey", "incomingByKey", "segments"] {
        let value = transcripts[field]
            .as_object_mut()
            .unwrap()
            .remove(&format!("path:{old_path}"))
            .unwrap();
        transcripts[field][key] = value;
    }
    fs::write(
        source.0.join("transcripts.json"),
        serde_json::to_vec(&transcripts).unwrap(),
    )
    .unwrap();
    let mut analysis: serde_json::Value =
        serde_json::from_slice(&fs::read(source.0.join("analysis.json")).unwrap()).unwrap();
    let mut summary = analysis["results"]["file:42/summary"].clone();
    summary["text"] = json!("Imported audio summary");
    analysis["results"][format!("{key}/summary")] = summary;
    fs::write(
        source.0.join("analysis.json"),
        serde_json::to_vec(&analysis).unwrap(),
    )
    .unwrap();
    let mut runtime = KoeRuntime::open(&target.0).unwrap();
    let result = import_flutter(&mut runtime, &source);
    assert!(result["error"].is_null(), "{result}");
    let note = runtime
        .workspace()
        .records()
        .values()
        .find(|r| r.title == "Edited note")
        .unwrap();
    assert_eq!(note.aggregate.spine.segments()[0].text, "Human correction");
    let id = note.aggregate.recording_id.clone();
    let detail = runtime.dispatch_json(
        &json!({"type":"select_record","recordId":id}).to_string(),
        1,
    );
    assert!(detail.contains("Imported audio summary"));
}

#[test]
fn flutter_device_bare_opus_frames_are_playable_after_migration() {
    assert_flutter_raw_opus(10, false);
}

#[test]
fn flutter_short_bare_opus_recording_keeps_its_only_frame() {
    assert_flutter_raw_opus(1, false);
}

#[test]
fn flutter_bare_opus_keeps_a_partial_final_packet() {
    assert_flutter_raw_opus(10, true);
}

fn assert_flutter_raw_opus(frame_count: usize, partial_tail: bool) {
    let source = Sandbox::new();
    let target = Sandbox::new();
    flutter_fixture(&source);
    let mut library: serde_json::Value =
        serde_json::from_slice(&fs::read(source.0.join("recording_library.json")).unwrap())
            .unwrap();
    library["assets"][0]["path"] = json!("/old/AnkerRecorder/exports/42_meeting.opus");
    fs::write(
        source.0.join("recording_library.json"),
        serde_json::to_vec(&library).unwrap(),
    )
    .unwrap();
    fs::remove_file(source.0.join("exports/42_meeting.wav")).unwrap();
    let mut frame = [0u8; 160];
    frame[..3].copy_from_slice(&[0xf8, 0xff, 0xfe]);
    let mut original = frame.repeat(frame_count);
    if partial_tail {
        original.truncate((frame_count - 1) * 160 + 3);
    }
    fs::write(source.0.join("exports/42_meeting.opus"), &original).unwrap();
    let mut runtime = KoeRuntime::open(&target.0).unwrap();
    let result = import_flutter(&mut runtime, &source);
    assert!(result["error"].is_null(), "{result}");
    let record = runtime
        .workspace()
        .records()
        .values()
        .find(|r| r.title == "Fixture meeting")
        .unwrap();
    let wav = fs::read(
        target
            .0
            .join("audio")
            .join(format!("{}.wav", record.aggregate.recording_id)),
    )
    .unwrap();
    assert_eq!(
        parse_pcm_wave(&wav).unwrap().duration_ms(),
        frame_count as u64 * 20
    );
    let mut decoder = koe_opus::create_libopus_decoder(48_000).unwrap();
    let mut expected = Vec::new();
    for _ in 0..frame_count {
        assert!(decoder.decode_trimmed_packet(&frame[..3], &mut expected));
    }
    assert_eq!(&wav[44..], &expected);
    assert_eq!(record.aggregate.duration_ms, frame_count as u64 * 20);
    assert_eq!(
        fs::read(source.0.join("exports/42_meeting.opus")).unwrap(),
        original
    );
}

#[test]
fn flutter_manual_transcript_applies_only_line_start_speaker_aliases() {
    let source = Sandbox::new();
    let target = Sandbox::new();
    flutter_fixture(&source);
    let mut transcripts: serde_json::Value =
        serde_json::from_slice(&fs::read(source.0.join("transcripts.json")).unwrap()).unwrap();
    transcripts["manualByKey"]["path:/old/AnkerRecorder/note.wav"] =
        json!("说话人 0：Human correction\nQuoted 说话人 0：is literal");
    transcripts["aliasesByPath"] = json!({"/old/AnkerRecorder/note.wav":{"0":"Ada"}});
    fs::write(
        source.0.join("transcripts.json"),
        serde_json::to_vec(&transcripts).unwrap(),
    )
    .unwrap();
    let mut runtime = KoeRuntime::open(&target.0).unwrap();
    assert!(import_flutter(&mut runtime, &source)["error"].is_null());
    let note = runtime
        .workspace()
        .records()
        .values()
        .find(|r| r.title == "Edited note")
        .unwrap();
    assert_eq!(
        note.aggregate.spine.segments()[0].text,
        "Ada：Human correction"
    );
    assert_eq!(
        note.aggregate.spine.segments()[1].text,
        "Quoted 说话人 0：is literal"
    );
}
