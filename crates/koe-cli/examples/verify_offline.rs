use koe_engine::product::AnalysisState;
use koe_runtime::KoeRuntime;
use serde_json::{json, Value};
use std::{
    path::PathBuf,
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

fn dispatch(runtime: &mut KoeRuntime, command: Value) -> Result<Value, String> {
    let result: Value = serde_json::from_str(&runtime.dispatch_json(&command.to_string(), now()))
        .map_err(|e| e.to_string())?;
    if let Some(error) = result["error"].as_str() {
        return Err(format!("{}: {error}", command["type"]));
    }
    Ok(result)
}

fn wait(
    runtime: &mut KoeRuntime,
    seconds: u64,
    done: impl Fn(&KoeRuntime) -> Result<bool, String>,
) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs(seconds);
    loop {
        runtime.poll_timers(25, now());
        if done(runtime)? {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err("timed out waiting for persisted completion".into());
        }
        thread::sleep(Duration::from_millis(25));
    }
}

fn verify_all_day(runtime: &mut KoeRuntime, audio: &std::path::Path) -> Result<Value, String> {
    let bytes = std::fs::read(audio).map_err(|e| e.to_string())?;
    let wave = koe_engine::wav::parse_pcm_wave(&bytes)?;
    let pcm = wave.mono_16khz();
    let samples: Vec<i16> = pcm
        .chunks_exact(2)
        .map(|b| i16::from_le_bytes([b[0], b[1]]))
        .collect();
    if samples.is_empty() {
        return Err("the speech fixture is empty".into());
    }
    let start = dispatch(
        runtime,
        json!({"type":"start_all_day","source":"microphone","inputId":"public-audio-fixture"}),
    )?;
    let capture = start["microphone"].clone();
    dispatch(
        runtime,
        json!({"type":"microphone_started","recordId":capture["recordId"],"sessionId":capture["sessionId"],"lane":"microphone","sampleRate":16000}),
    )?;
    let count = |r: &KoeRuntime| {
        r.workspace()
            .records()
            .values()
            .map(|record| record.aggregate.spine.segments().len())
            .sum::<usize>()
    };
    let mut offset = 0;
    let mut sequence = 0;
    for window in 0..21 {
        let previous = count(runtime);
        let length = if window == 20 { 3 * 16000 } else { 15 * 16000 };
        let mut remaining = length;
        while remaining > 0 {
            let n = remaining.min(8000);
            let chunk: Vec<_> = (offset..offset + n)
                .map(|i| samples[i % samples.len()])
                .collect();
            let receipt = runtime.ingest_microphone_pcm(
                capture["recordId"].as_str().ok_or("missing recordId")?,
                capture["sessionId"].as_str().ok_or("missing sessionId")?,
                "microphone",
                sequence,
                &chunk,
                None,
                now(),
            );
            if receipt.status != koe_runtime::PcmIngestStatus::Accepted {
                return Err(format!("ingest_microphone_pcm rejected at seq {sequence}"));
            }
            offset += n;
            sequence += 1;
            remaining -= n;
            runtime.poll_timers(25, now());
        }
        if window < 20 {
            wait(runtime, 120, |r| Ok(count(r) > previous))?;
        }
    }
    dispatch(runtime, json!({"type":"stop_all_day"}))?;
    dispatch(
        runtime,
        json!({"type":"microphone_stopped","recordId":capture["recordId"],"sessionId":capture["sessionId"],"lane":"microphone","sequence":sequence}),
    )?;
    wait(runtime, 120, |r| {
        Ok(r.snapshot(now())["allDay"]["state"] == "idle")
    })?;
    let ids: Vec<_> = runtime.workspace().records().keys().cloned().collect();
    let mut records = Vec::new();
    for id in ids {
        let snapshot = dispatch(runtime, json!({"type":"select_record","recordId":id}))?;
        records.push(json!({"recordId":id,"segments":snapshot["detail"]["segments"]}));
    }
    if records.len() != 2
        || records
            .iter()
            .any(|r| r["segments"].as_array().is_none_or(|s| s.is_empty()))
    {
        return Err(format!(
            "303 seconds did not produce two transcribed records: {records:?}"
        ));
    }
    Ok(json!({"records":records,"fixtureDurationSeconds":303}))
}

fn run() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let workspace = PathBuf::from(
        args.next()
            .ok_or("usage: verify_offline WORKSPACE AUDIO.wav [MODEL]")?,
    );
    let audio = PathBuf::from(args.next().ok_or("missing WAV path")?)
        .canonicalize()
        .map_err(|e| e.to_string())?;
    let model = args.next().unwrap_or_else(|| "sensevoice-small".into());
    let all_day = args.next().as_deref() == Some("--all-day");
    if workspace.join("product-workspace.json").exists() {
        return Err(
            "use a fresh verification workspace; existing user data is not a test target".into(),
        );
    }
    let mut runtime = KoeRuntime::open(&workspace)?;
    dispatch(
        &mut runtime,
        json!({"type":"set_ble_auto_connect","enabled":false}),
    )?;
    dispatch(
        &mut runtime,
        json!({"type":"prepare_speech_model","modelId":model}),
    )?;
    wait(&mut runtime, 1800, |r| {
        let snapshot = r.snapshot(now());
        let entry = snapshot["speech"]["models"]
            .as_array()
            .and_then(|models| models.iter().find(|entry| entry["id"] == model));
        match entry {
            Some(entry) if entry["state"] == "ready" => Ok(true),
            Some(entry) if entry["state"] == "failed" => Err(entry["message"].to_string()),
            _ => Ok(false),
        }
    })?;
    dispatch(
        &mut runtime,
        json!({"type":"configure_speech","engine":"downloaded","modelId":model}),
    )?;
    if all_day {
        let result = verify_all_day(&mut runtime, &audio)?;
        drop(runtime);
        let mut reopened = KoeRuntime::open(&workspace)?;
        for record in result["records"].as_array().unwrap() {
            let id = record["recordId"].as_str().unwrap();
            let actual = dispatch(&mut reopened, json!({"type":"select_record","recordId":id}))?;
            if actual["detail"]["segments"] != record["segments"] {
                return Err("all-day transcript changed across reopen".into());
            }
        }
        println!(
            "{}",
            json!({"result":"PASS","model":model,"allDay":result,"reopened":true})
        );
        return Ok(());
    }
    dispatch(&mut runtime, json!({"type":"import_file","path":audio}))?;
    let id = runtime.snapshot(now())["selectedRecordId"]
        .as_str()
        .ok_or("import did not select a record")?
        .to_owned();
    dispatch(&mut runtime, json!({"type":"transcribe","recordId":id}))?;
    wait(&mut runtime, 300, |r| {
        let record = r.workspace().record(&id).ok_or("record disappeared")?;
        match &record.analysis {
            AnalysisState::Pending { .. } => Ok(false),
            AnalysisState::Failed { message, .. } => Err(message.clone()),
            AnalysisState::Interrupted { .. } => Err("recognition was interrupted".into()),
            _ => Ok(!record.aggregate.spine.is_empty()),
        }
    })?;
    let before = runtime.snapshot(now());
    let segments = before["detail"]["segments"].clone();
    if segments.as_array().is_none_or(|rows| rows.is_empty()) {
        return Err("recognition completed without persisted text".into());
    }
    drop(runtime);
    let mut reopened = KoeRuntime::open(&workspace)?;
    dispatch(&mut reopened, json!({"type":"select_record","recordId":id}))?;
    let after = reopened.snapshot(now());
    if after["detail"]["segments"] != segments {
        return Err("transcript changed across workspace reopen".into());
    }
    println!(
        "{}",
        json!({"result":"PASS","model":model,"recordId":id,"segments":segments,"reopened":true,"audioPolicy":after["provider"]["meetingAudioPolicy"]})
    );
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
