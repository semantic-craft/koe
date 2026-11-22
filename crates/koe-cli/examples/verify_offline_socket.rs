use koe_host_api::HostSessionGuard;
use koe_runtime::resolve_bridge_socket_path;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use std::{fs, thread};

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

fn snapshot(s: &HostSessionGuard) -> Result<Value, String> {
    serde_json::from_str(&s.snapshot_json(now()).ok_or("null snapshot")?).map_err(|e| e.to_string())
}

fn dispatch_raw(s: &HostSessionGuard, cmd: Value) -> Result<Value, String> {
    serde_json::from_str(&s.dispatch_json(&cmd.to_string(), now()).ok_or("null dispatch")?)
        .map_err(|e| e.to_string())
}

fn dispatch(s: &HostSessionGuard, cmd: Value) -> Result<Value, String> {
    let kind = cmd["type"].clone();
    let res = dispatch_raw(s, cmd)?;
    match res["error"].as_str() {
        Some(err) => Err(format!("{kind}: {err}")),
        None => Ok(res),
    }
}

fn wait(s: &HostSessionGuard, secs: u64, done: impl Fn(&Value) -> Result<bool, String>) -> Result<Value, String> {
    let deadline = Instant::now() + Duration::from_secs(secs);
    loop {
        let _ = s.poll_timers(25, now());
        let snap = snapshot(s)?;
        if done(&snap)? {
            return Ok(snap);
        }
        if Instant::now() >= deadline {
            return Err(format!("timed out; error={}", snap["error"]));
        }
        thread::sleep(Duration::from_millis(25));
    }
}

fn seg_total(snap: &Value) -> u64 {
    snap["records"].as_array().into_iter().flatten().filter_map(|r| r["segmentCount"].as_u64()).sum()
}

fn record_ready(snap: &Value, id: &str) -> bool {
    snap["records"].as_array().into_iter().flatten().any(|r| r["id"] == id && r["status"] == "已有文字" && r["segmentCount"].as_u64().unwrap_or(0) > 0)
}

fn rpc_call(sock_path: &Path, id: u64, method: &str, params: Value) -> Result<Value, String> {
    let mut stream = UnixStream::connect(sock_path).map_err(|e| format!("{}: {e}", sock_path.display()))?;
    writeln!(stream, "{}", json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}))
        .and_then(|()| stream.flush())
        .map_err(|e| e.to_string())?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).map_err(|e| e.to_string())?;
    let resp: Value = serde_json::from_str(&line).map_err(|e| e.to_string())?;
    if let Some(err) = resp.get("error").filter(|e| !e.is_null()) {
        return Err(format!("{method} rpc error: {err}"));
    }
    Ok(resp["result"].clone())
}

struct WorkspaceBlockGuard {
    ws_json: PathBuf,
    ws_bak: PathBuf,
    active: bool,
}

impl WorkspaceBlockGuard {
    fn inject(ws: &Path) -> Result<Self, String> {
        let ws_json = ws.join("product-workspace.json");
        let ws_bak = ws.join("product-workspace.json.bak");
        fs::rename(&ws_json, &ws_bak).map_err(|e| e.to_string())?;
        let guard = Self { ws_json, ws_bak, active: true };
        fs::create_dir(&guard.ws_json).map_err(|e| e.to_string())?;
        Ok(guard)
    }

    fn restore(mut self) -> Result<(), String> {
        self.active = false;
        fs::remove_dir(&self.ws_json).and_then(|()| fs::rename(&self.ws_bak, &self.ws_json)).map_err(|e| e.to_string())
    }
}

impl Drop for WorkspaceBlockGuard {
    fn drop(&mut self) {
        if self.active && self.ws_bak.exists() {
            let _ = fs::remove_dir(&self.ws_json);
            let _ = fs::rename(&self.ws_bak, &self.ws_json);
        }
    }
}

struct MicDriver { record_id: String, session_id: String, epoch: u64, clock_ns: u64, seq: u64, epoch_samples: u64, cursor: usize }

impl MicDriver {
    fn start(s: &HostSessionGuard, all_day: bool) -> Result<Self, String> {
        let cmd = if all_day {
            json!({"type":"start_all_day","source":"microphone","inputId":"public-audio-fixture"})
        } else {
            json!({"type":"start_microphone","inputId":"public-audio-fixture"})
        };
        let snap = dispatch(s, cmd)?;
        let record_id = snap["microphone"]["recordId"].as_str().ok_or("missing recordId")?.to_owned();
        let session_id = snap["microphone"]["sessionId"].as_str().ok_or("missing sessionId")?.to_owned();
        let clock_ns = 1_000_000_000u64;
        dispatch(s, json!({"type":"microphone_prepared","recordId":record_id,"sessionId":session_id,"epoch":0,"clockNs":clock_ns}))?;
        dispatch(s, json!({"type":"microphone_started","recordId":record_id,"sessionId":session_id,"lane":"microphone","sampleRate":16000}))?;
        Ok(Self { record_id, session_id, epoch: 0, clock_ns, seq: 0, epoch_samples: 0, cursor: 0 })
    }

    fn feed(&mut self, s: &HostSessionGuard, samples: &[i16], secs: usize) -> Result<(), String> {
        let mut rem = secs * 16_000;
        while rem > 0 {
            let n = rem.min(8_000);
            let chunk: Vec<i16> = (self.cursor..self.cursor + n).map(|i| samples[i % samples.len()]).collect();
            let start_ns = self.clock_ns + self.epoch_samples * 1_000_000_000 / 16_000;
            let receipt = s.ingest_pcm(koe_host_api::PcmIngestInput {
                record_id: &self.record_id,
                session_id: &self.session_id,
                lane: "microphone",
                sequence: self.seq,
                timing: Some((self.epoch, start_ns)),
                samples: &chunk,
                now: now(),
            });
            if receipt.status != 0 {
                return Err(format!("ingest_pcm failed with status {}", receipt.status));
            }
            self.cursor += n;
            self.epoch_samples += n as u64;
            self.seq += 1;
            rem -= n;
            let _ = s.poll_timers(25, now());
        }
        Ok(())
    }

    fn pause_resume(&mut self, s: &HostSessionGuard) -> Result<(), String> {
        dispatch(s, json!({"type":"pause_microphone"}))?;
        dispatch(s, json!({"type":"microphone_paused","recordId":self.record_id,"sessionId":self.session_id,"lane":"microphone","sequence":self.seq,"epoch":self.epoch}))?;
        let resume_ns = self.clock_ns + self.epoch_samples * 1_000_000_000 / 16_000 + 2_000_000_000;
        let snap = dispatch(s, json!({"type":"resume_microphone","clockNs":resume_ns}))?;
        self.epoch += 1;
        self.clock_ns = resume_ns;
        self.epoch_samples = 0;
        if snap["microphone"]["epoch"] != self.epoch || snap["microphone"]["phase"] != "recording" {
            return Err(format!("bad resume state: {}", snap["microphone"]));
        }
        Ok(())
    }

    fn stopped(&self) -> Value {
        json!({"type":"microphone_stopped","recordId":self.record_id,"sessionId":self.session_id,"lane":"microphone","sequence":self.seq,"epoch":self.epoch})
    }
}

fn check_record(s: &HostSessionGuard, id: &str, expected_duration_ms: Option<u64>, require_multi_epoch: bool) -> Result<Value, String> {
    let detail = dispatch(s, json!({"type":"select_record","recordId":id}))?["detail"].clone();
    let segs = detail["segments"].as_array().filter(|a| !a.is_empty()).ok_or("empty segments")?;
    let wav = detail["audioPath"].as_str().ok_or("missing audioPath")?;
    if detail["isProcessing"] != false || detail["status"] != "已有文字" || fs::metadata(wav).map_or(0, |m| m.len()) <= 44 {
        return Err(format!("record {id} invalid: {detail}"));
    }
    if let Some(exp_ms) = expected_duration_ms {
        if detail["durationMs"].as_u64() != Some(exp_ms) {
            return Err(format!("record {id} duration mismatch: expected {exp_ms}, got {}", detail["durationMs"]));
        }
    }
    if require_multi_epoch && !detail["captureLanes"][0]["timeline"].as_array().is_some_and(|t| t.len() >= 2) {
        return Err(format!("record {id} expected multi-epoch timeline: {}", detail["captureLanes"]));
    }
    Ok(json!({"recordId":id,"ordinal":detail["ordinal"],"durationMs":detail["durationMs"],"audioPath":wav,"segmentCount":segs.len(),"segments":segs}))
}

fn wait_model(s: &HostSessionGuard, model: &str) -> Result<(), String> {
    wait(s, 1800, |snap| {
        match snap["speech"]["models"].as_array().and_then(|m| m.iter().find(|e| e["id"] == model)) {
            Some(e) if e["state"] == "ready" => Ok(true),
            Some(e) if e["state"] == "failed" => Err(format!("model failed: {}", e["message"])),
            _ => Ok(false),
        }
    })
    .map(|_| ())
}

fn run_capture(s: &HostSessionGuard, ws: &Path, samples: &[i16], all_day: bool) -> Result<Vec<String>, String> {
    let mut mic = MicDriver::start(s, all_day)?;
    mic.feed(s, samples, 15)?;
    wait(s, 600, |v| Ok(seg_total(v) > 0))?;
    let seg1 = mic.record_id.clone();
    if !all_day {
        dispatch(s, json!({"type":"stop_microphone"}))?;
        dispatch(s, mic.stopped())?;
        wait(s, 600, |v| Ok(record_ready(v, &seg1)))?;
        return Ok(vec![seg1]);
    }
    mic.pause_resume(s)?;
    for _ in 1..20 {
        let prev = seg_total(&snapshot(s)?);
        mic.feed(s, samples, 15)?;
        wait(s, 300, |v| Ok(seg_total(v) > prev))?;
    }
    wait(s, 300, |v| Ok(record_ready(v, &seg1)))?;
    mic.feed(s, samples, 1)?;
    let seg2 = snapshot(s)?["records"].as_array().into_iter().flatten()
        .find(|r| r["ordinal"] == 2)
        .and_then(|r| r["id"].as_str().map(str::to_owned))
        .ok_or("missing rotated ordinal 2")?;
    mic.pause_resume(s)?;
    mic.feed(s, samples, 2)?;

    dispatch(s, json!({"type":"stop_all_day"}))?;
    let block_guard = WorkspaceBlockGuard::inject(ws)?;
    let failed = dispatch_raw(s, mic.stopped());
    block_guard.restore()?;
    let failed = failed?;
    if failed["microphone"]["phase"] != "saving" || failed["microphone"]["error"].as_str().is_none_or(str::is_empty) {
        return Err(format!("expected saving error, got {}", failed["microphone"]));
    }
    dispatch(s, json!({"type":"retry_microphone_save"}))?;
    wait(s, 300, |v| {
        Ok(v["workspaces"]["allDay"]["isActive"] == false
            && record_ready(v, &seg1)
            && record_ready(v, &seg2))
    })?;
    Ok(vec![mic.record_id, seg2])
}

fn run() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let usage = "usage: verify_offline_socket WORKSPACE AUDIO.wav MODEL [--all-day]";
    let ws = PathBuf::from(args.next().ok_or(usage)?);
    let audio = PathBuf::from(args.next().ok_or(usage)?).canonicalize().map_err(|e| e.to_string())?;
    let model = args.next().ok_or(usage)?;
    let all_day = match args.next().as_deref() {
        None => false,
        Some("--all-day") if args.next().is_none() => true,
        Some(_) => return Err(usage.into()),
    };
    if ws.join("product-workspace.json").exists() {
        return Err("refusing existing product-workspace.json".into());
    }
    fs::create_dir_all(&ws).map_err(|e| e.to_string())?;
    let sock_path = resolve_bridge_socket_path(&ws).ok_or("invalid socket path")?;
    let pcm = koe_engine::wav::parse_pcm_wave(&fs::read(&audio).map_err(|e| e.to_string())?)?.mono_16khz();
    let samples: Vec<i16> = pcm.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect();
    if samples.is_empty() {
        return Err("empty speech fixture".into());
    }

    let session = HostSessionGuard::open(&ws).ok_or("HostSessionGuard::open failed")?;
    dispatch(&session, json!({"type":"set_ble_auto_connect","enabled":false}))?;
    dispatch(&session, json!({"type":"set_meeting_audio_policy","policy":"local_only"}))?;
    dispatch(&session, json!({"type":"prepare_speech_model","modelId":model}))?;
    wait_model(&session, &model)?;
    dispatch(&session, json!({"type":"configure_speech","engine":"downloaded","modelId":model}))?;

    let mic_ids = run_capture(&session, &ws, &samples, all_day)?;

    let imp = dispatch(&session, json!({"type":"import_file","path":audio}))?;
    let imp_id = imp["selectedRecordId"].as_str().ok_or("no imported id")?.to_owned();
    dispatch(&session, json!({"type":"transcribe","recordId":imp_id}))?;
    wait(&session, 600, |v| {
        let st = v["records"].as_array().and_then(|a| a.iter().find(|r| r["id"] == imp_id)).and_then(|r| r["status"].as_str());
        match st {
            Some("已有文字") => Ok(true),
            Some("处理失败" | "处理已中断") => Err(format!("transcribe failed: {imp_id}")),
            _ => Ok(false),
        }
    })?;

    let mut persisted: Vec<Value> = mic_ids
        .iter()
        .enumerate()
        .map(|(idx, id)| {
            let exp_ms = all_day.then_some(if idx == 0 { 300_000 } else { 3_000 });
            check_record(&session, id, exp_ms, all_day)
        })
        .collect::<Result<Vec<_>, _>>()?;
    persisted.push(check_record(&session, &imp_id, None, false)?);

    let _ = session.poll_timers(25, now());
    let status_rpc = rpc_call(&sock_path, 1, "koe/status", json!({}))?;
    let doctor_rpc = rpc_call(&sock_path, 2, "koe/doctor", json!({}))?;
    let tools_rpc = rpc_call(&sock_path, 3, "koe/mcp_tools_list", json!({}))?;
    let get_rec_rpc = rpc_call(&sock_path, 4, "koe/mcp_tool_call", json!({"name":"get_record","arguments":{"record_id":imp_id}}))?;
    if status_rpc["records"].as_array().is_none() || doctor_rpc["workspaceReadable"] != true || tools_rpc["tools"].as_array().is_none_or(|t| t.len() != 16) || get_rec_rpc["isError"] != false {
        return Err("koe.sock JSON-RPC verification failed".into());
    }
    drop(session);
    if sock_path.exists() {
        return Err("socket not unlinked on drop".into());
    }

    let reopened = HostSessionGuard::open(&ws).ok_or("reopen failed")?;
    let after = dispatch(&reopened, json!({"type":"set_ble_auto_connect","enabled":false}))?;
    if after["provider"]["meetingAudioPolicy"] != "local_only" || after["speech"]["engine"] != "downloaded" || after["speech"]["modelId"] != model {
        return Err(format!("reopen config mismatch: {after}"));
    }
    wait_model(&reopened, &model)?;
    for (idx, exp) in persisted.iter().enumerate() {
        let is_all_day_mic = all_day && idx < mic_ids.len();
        let exp_ms = is_all_day_mic.then_some(if idx == 0 { 300_000 } else { 3_000 });
        let record_id = exp["recordId"]
            .as_str()
            .ok_or("persisted record missing recordId")?;
        let act = check_record(&reopened, record_id, exp_ms, is_all_day_mic)?;
        if act["segments"] != exp["segments"] {
            return Err("segments changed across reopen".into());
        }
    }
    drop(reopened);
    if sock_path.exists() {
        return Err("reopened socket not unlinked".into());
    }
    println!("{}", json!({"result":"PASS","model":model,"mode":if all_day{"all_day"}else{"single_segment"},"socketPath":sock_path,"meetingAudioPolicyAfterReopen":"local_only","reopenAutoReady":true,"saveRetryRecovered":all_day,"records":persisted}));
    Ok(())
}

fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
