use koe_core::Library;
use serde_json::json;
use std::fs;

#[test]
fn keeps_manual_text_and_deleted_recordings_out_of_live_list_without_writing() {
    let dir = tempfile::tempdir().unwrap();
    let audio = dir.path().join("123_meeting.wav");
    let hidden = dir.path().join("124_hidden.wav");
    fs::write(&audio, b"audio").unwrap();
    fs::create_dir(dir.path().join("exports")).unwrap();
    fs::write(dir.path().join("exports/124_hidden.wav"), b"audio").unwrap();
    let catalog = json!({"version":1,"futureField":"preserve","assets":[
        {"path":audio,"displayName":"会议","source":"device","importedAt":"2026-11-05T08:00:00Z","future":{"nested":true}},
        {"path":hidden,"displayName":"已删除","deletedAt":"2026-11-05"}
    ]}).to_string();
    let transcripts = json!({"manualByKey":{"file:123":"说话人 1：校订内容"},"byPath":{audio.to_str().unwrap():"旧转写"},"aliasesByFileId":{"123":{"1":"小王"}}}).to_string();
    fs::write(dir.path().join("recording_library.json"), &catalog).unwrap();
    fs::write(dir.path().join("transcripts.json"), &transcripts).unwrap();
    let library = Library::open(dir.path()).unwrap();
    assert_eq!(library.recordings.len(), 1);
    assert_eq!(library.recordings[0].transcript, "小王：校订内容");
    assert_eq!(
        fs::read_to_string(dir.path().join("recording_library.json")).unwrap(),
        catalog
    );
    assert_eq!(
        fs::read_to_string(dir.path().join("transcripts.json")).unwrap(),
        transcripts
    );
    assert_eq!(fs::read(audio).unwrap(), b"audio");
}

#[test]
fn recovers_export_only_library_and_prefers_wav_over_raw_device_audio() {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir(dir.path().join("exports")).unwrap();
    fs::write(dir.path().join("exports/42.opus.bin"), b"raw").unwrap();
    fs::write(dir.path().join("exports/42.wav"), b"wave").unwrap();
    fs::write(dir.path().join("exports/43.opus"), b"raw").unwrap();
    fs::write(
        dir.path().join("transcripts.json"),
        r#"{"byFileId":{"42":"取回内容"}}"#,
    )
    .unwrap();
    let library = Library::open(dir.path()).unwrap();
    assert_eq!(library.recordings.len(), 2);
    let recording = library
        .recordings
        .iter()
        .find(|r| r.path.ends_with("42.wav"))
        .unwrap();
    assert_eq!(recording.transcript, "取回内容");
    assert!(recording.playable());
    assert!(
        !library
            .recordings
            .iter()
            .find(|r| r.path.ends_with("43.opus"))
            .unwrap()
            .playable()
    );
}

#[test]
fn corrupt_index_is_reported_without_repair_or_replacement() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("recording_library.json");
    fs::write(&path, b"broken").unwrap();
    assert!(Library::open(dir.path()).is_err());
    assert_eq!(fs::read(&path).unwrap(), b"broken");
    assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1);
}

#[test]
fn existing_copy_wins_over_missing_wav_in_either_catalog_order() {
    let dir = tempfile::tempdir().unwrap();
    let missing = dir.path().join("123.wav");
    let present = dir.path().join("123.m4a");
    fs::write(&present, b"audio").unwrap();
    for paths in [[&missing, &present], [&present, &missing]] {
        let assets: Vec<_> = paths
            .iter()
            .map(|path| json!({"path":path,"displayName":"录音"}))
            .collect();
        fs::write(
            dir.path().join("recording_library.json"),
            json!({"version":1,"assets":assets}).to_string(),
        )
        .unwrap();
        let library = Library::open(dir.path()).unwrap();
        assert_eq!(library.recordings.len(), 1);
        assert_eq!(library.recordings[0].path, present);
    }
}

#[test]
fn missing_copies_keep_a_stable_row_and_saved_text() {
    let dir = tempfile::tempdir().unwrap();
    let a = dir.path().join("123_a.wav");
    let z = dir.path().join("123_z.wav");
    fs::write(
        dir.path().join("transcripts.json"),
        r#"{"byFileId":{"123":"原声暂失，文字仍在"}}"#,
    )
    .unwrap();
    for paths in [[&z, &a], [&a, &z]] {
        let assets: Vec<_> = paths
            .iter()
            .map(|path| json!({"path":path,"displayName":"录音"}))
            .collect();
        fs::write(
            dir.path().join("recording_library.json"),
            json!({"version":1,"assets":assets}).to_string(),
        )
        .unwrap();
        let library = Library::open(dir.path()).unwrap();
        assert_eq!(library.recordings.len(), 1);
        assert_eq!(library.recordings[0].path, z);
        assert_eq!(library.recordings[0].transcript, "原声暂失，文字仍在");
    }
}

#[test]
fn orders_by_normalized_filename_time_across_directories_and_phone_prefix() {
    let dir = tempfile::tempdir().unwrap();
    let names = [
        "z/1700000000000000.wav",
        "y/1700000001000.wav",
        "x/1700000002.wav",
        "a/phone_1700000003000000.wav",
        "zz/unknown.wav",
    ];
    let assets: Vec<_> = names
        .iter()
        .map(|name| json!({"path":dir.path().join(name),"displayName":name}))
        .collect();
    fs::write(
        dir.path().join("recording_library.json"),
        json!({"version":1,"assets":assets}).to_string(),
    )
    .unwrap();
    let library = Library::open(dir.path()).unwrap();
    let ordered: Vec<_> = library
        .recordings
        .iter()
        .map(|r| r.display_name.as_str())
        .collect();
    assert_eq!(ordered, [names[3], names[2], names[1], names[0], names[4]]);
}
