use crate::{Library, Recording};
use anyhow::{Context, Result, bail};
use chrono::{DateTime, Duration, SecondsFormat, Utc};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    fs,
    io::{self, BufRead, Write},
    path::{Path, PathBuf},
};

const PROTOCOL: &str = "2025-11-25";

#[derive(Debug, Clone)]
pub struct LivePublicationReceipt {
    pub path: PathBuf,
    pub generation: u64,
    pub expires_at: String,
    pub shared_count: usize,
}

#[derive(Debug, Default)]
pub struct McpPublisher {
    granted: BTreeSet<String>,
    generation: u64,
}

impl McpPublisher {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn grant(&mut self, recording_id: &str) {
        self.granted.insert(recording_id.to_owned());
    }

    pub fn revoke(&mut self, recording_id: &str) {
        self.granted.remove(recording_id);
    }

    pub fn revoke_all(&mut self) {
        self.granted.clear();
    }

    pub fn is_granted(&self, recording_id: &str) -> bool {
        self.granted.contains(recording_id)
    }

    pub fn granted_count(&self) -> usize {
        self.granted.len()
    }

    pub fn publish_live(
        &mut self,
        library: &Library,
        live_dir: &Path,
        lease_seconds: i64,
    ) -> Result<LivePublicationReceipt> {
        if !(1..=20).contains(&lease_seconds) {
            bail!("MCP 租约秒数必须在 1..=20 之间");
        }
        fs::create_dir_all(live_dir)?;
        self.generation += 1;
        let now = Utc::now();
        let expires_at =
            (now + Duration::seconds(lease_seconds)).to_rfc3339_opts(SecondsFormat::Millis, true);
        let exported_at = now.to_rfc3339_opts(SecondsFormat::Millis, true);

        let mut records = Map::new();
        let mut active_packs = BTreeSet::new();
        for recording in &library.recordings {
            let Ok(id) = recording.recording_id() else {
                continue;
            };
            if !self.granted.contains(&id) {
                continue;
            }
            let manifest = build_manifest(recording, &id, &exported_at);
            let manifest_bytes = serde_json::to_vec(&manifest)?;
            let pack_name = format!("{:x}.koepack", Sha256::digest(&manifest_bytes));
            let pack_path = live_dir.join(&pack_name);
            let pack_tmp = live_dir.join(format!(".{pack_name}.tmp-{}", std::process::id()));
            let mut framed = format!("KOEPACK1\n{}\n", manifest_bytes.len()).into_bytes();
            framed.extend_from_slice(&manifest_bytes);
            fs::write(&pack_tmp, framed)?;
            fs::rename(&pack_tmp, &pack_path)?;
            active_packs.insert(pack_name);
            records.insert(id, manifest);
        }
        if let Ok(entries) = fs::read_dir(live_dir) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if name.ends_with(".koepack") && !active_packs.contains(&name) {
                    let _ = fs::remove_file(entry.path());
                }
            }
        }

        let payload = json!({
            "version": 1,
            "generation": self.generation,
            "expiresAt": expires_at,
            "records": records,
        });
        let live_path = live_dir.join("live.json");
        let tmp_path = live_dir.join(format!(".live.json.tmp-{}", std::process::id()));
        fs::write(&tmp_path, serde_json::to_vec(&payload)?)?;
        fs::rename(&tmp_path, &live_path)?;

        Ok(LivePublicationReceipt {
            path: live_path,
            generation: self.generation,
            expires_at,
            shared_count: records.len(),
        })
    }

    pub fn clear_live(&mut self, live_dir: &Path) -> Result<()> {
        self.granted.clear();
        let live_path = live_dir.join("live.json");
        if live_path.exists() {
            let _ = fs::remove_file(live_path);
        }
        if let Ok(entries) = fs::read_dir(live_dir) {
            for entry in entries.flatten() {
                if entry.file_name().to_string_lossy().ends_with(".koepack") {
                    let _ = fs::remove_file(entry.path());
                }
            }
        }
        Ok(())
    }
}

fn build_manifest(recording: &Recording, content_hash: &str, exported_at: &str) -> Value {
    let source = match recording.source.as_str() {
        "device" | "localImport" | "phone" => recording.source.as_str(),
        _ => "phone",
    };
    let mut manifest = json!({
        "format": "koe-material-pack",
        "version": if recording.minutes.is_some() { 2 } else { 1 },
        "exportedAt": exported_at,
        "material": {
            "contentHash": content_hash,
            "title": recording.display_name,
            "source": source,
        },
        "audio": {
            "included": false,
        }
    });
    if !recording.transcript.trim().is_empty() {
        let segments: Vec<Value> = recording
            .transcript
            .lines()
            .filter(|l| !l.trim().is_empty())
            .enumerate()
            .map(|(idx, line)| {
                json!({
                    "text": line.trim(),
                    "startMs": (idx as u64) * 1000,
                })
            })
            .collect();
        manifest["transcript"] = json!({
            "text": recording.transcript,
            "revision": 1,
            "segments": segments,
        });
    }
    if let Some(minutes) = &recording.minutes {
        manifest["minutes"] = minutes.clone();
    }
    manifest
}

pub fn serve_live_stdio(live_dir: &Path) -> Result<()> {
    if !live_dir.is_dir() {
        bail!("Live directory unavailable.");
    }
    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();
    let mut initialized = false;
    let mut ready = false;

    for line in stdin.lock().lines() {
        let raw = line?;
        if raw.trim().is_empty() {
            continue;
        }
        let Ok(req) = serde_json::from_str::<Value>(&raw) else {
            writeln!(
                stdout,
                "{}",
                json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}})
            )?;
            stdout.flush()?;
            continue;
        };
        let Some(method) = req.get("method").and_then(Value::as_str) else {
            writeln!(
                stdout,
                "{}",
                json!({"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid request"}})
            )?;
            stdout.flush()?;
            continue;
        };
        if req.get("id").is_none() {
            if method == "notifications/initialized" && initialized {
                ready = true;
            }
            continue;
        }
        let id = req["id"].clone();
        let params = req.get("params").cloned().unwrap_or_else(|| json!({}));
        let response = if method == "ping" {
            json!({"jsonrpc": "2.0", "id": id, "result": {}})
        } else if method == "initialize" && !initialized {
            initialized = true;
            json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": {
                    "protocolVersion": PROTOCOL,
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "koe-live-mcp", "version": "0.2.0"},
                    "instructions": "Read-only explicitly shared publisher records, refreshed on every call."
                }
            })
        } else if !ready {
            json!({"jsonrpc":"2.0","id":id,"error":{"code":-32002,"message":"Initialize first"}})
        } else if method == "tools/list" {
            json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": {"tools": live_tools()}
            })
        } else if method == "tools/call" {
            json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": handle_tool_call(live_dir, &params)
            })
        } else {
            json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"Method not found"}})
        };
        writeln!(stdout, "{}", serde_json::to_string(&response)?)?;
        stdout.flush()?;
    }
    Ok(())
}

fn live_tools() -> Value {
    let id_prop = json!({
        "recording_id": {"type": "string", "pattern": "^[a-f0-9]{64}$"},
        "expected_revision": {"type": "string", "pattern": "^[0-9]+$"}
    });
    json!([
        {
            "name": "list_recordings",
            "description": "List records explicitly shared by the running Koe publisher.",
            "inputSchema": {"type": "object", "properties": {}, "required": [], "additionalProperties": false}
        },
        {
            "name": "get_transcript",
            "description": "Read current published text.",
            "inputSchema": {"type": "object", "properties": id_prop, "required": ["recording_id"], "additionalProperties": false}
        },
        {
            "name": "get_minutes",
            "description": "Read published minutes.",
            "inputSchema": {"type": "object", "properties": id_prop, "required": ["recording_id"], "additionalProperties": false}
        }
    ])
}

fn tool_result(payload: Value, is_error: bool) -> Value {
    json!({
        "content": [{"type": "text", "text": serde_json::to_string(&payload).unwrap_or_default()}],
        "isError": is_error,
    })
}

fn handle_tool_call(live_dir: &Path, params: &Value) -> Value {
    match call_inner(live_dir, params) {
        Ok(payload) => tool_result(payload, false),
        Err(code) => tool_result(json!({"error": code}), true),
    }
}

fn call_inner(live_dir: &Path, params: &Value) -> std::result::Result<Value, &'static str> {
    let name = params
        .get("name")
        .and_then(Value::as_str)
        .ok_or("invalid_arguments")?;
    let args = params
        .get("arguments")
        .and_then(Value::as_object)
        .ok_or("invalid_arguments")?;
    let raw =
        fs::read_to_string(live_dir.join("live.json")).map_err(|_| "publication_unavailable")?;
    let live: Value = serde_json::from_str(&raw).map_err(|_| "invalid_publication")?;
    if live["version"].as_u64() != Some(1) {
        return Err("invalid_publication");
    }
    let generation = live["generation"].as_u64().ok_or("invalid_publication")?;
    let actual_revision = generation.to_string();
    let expires_str = live["expiresAt"].as_str().ok_or("invalid_publication")?;
    let expiry = DateTime::parse_from_rfc3339(expires_str)
        .map_err(|_| "invalid_publication")?
        .with_timezone(&Utc);
    let remaining = (expiry - Utc::now()).num_milliseconds() as f64 / 1000.0;
    if remaining <= 0.0 {
        return Err("publication_expired");
    }
    if remaining > 20.0 {
        return Err("invalid_publication");
    }
    if let Some(expected_rev) = args.get("expected_revision").and_then(Value::as_str)
        && expected_rev != actual_revision
    {
        return Err("snapshot_changed");
    }
    let records = live["records"].as_object().ok_or("invalid_publication")?;
    if name == "list_recordings" {
        let mut list = Vec::new();
        for (id, manifest) in records {
            list.push(json!({
                "recording_id": id,
                "title": manifest["material"]["title"],
                "exportedAt": manifest["exportedAt"],
                "hasTranscript": manifest.get("transcript").is_some(),
                "hasMinutes": manifest.get("minutes").is_some(),
                "materialContentHash": manifest["material"]["contentHash"],
            }));
        }
        return Ok(json!({
            "recordings": list,
            "rejectedCount": 0,
            "snapshotOnly": false,
            "snapshotRevision": actual_revision,
        }));
    }
    let rec_id = args
        .get("recording_id")
        .and_then(Value::as_str)
        .ok_or("recording_unavailable")?;
    let manifest = records.get(rec_id).ok_or("recording_unavailable")?;
    let content_hash = manifest["material"]["contentHash"].clone();
    if name == "get_transcript" {
        let text = manifest["transcript"]["manual"]
            .as_str()
            .filter(|s| !s.trim().is_empty())
            .or_else(|| manifest["transcript"]["text"].as_str())
            .unwrap_or("");
        let sources: Vec<Value> = text
            .lines()
            .filter(|l| !l.trim().is_empty())
            .enumerate()
            .map(|(i, line)| json!({"ref": format!("T{}", i + 1), "text": line, "startMs": (i as u64) * 1000}))
            .collect();
        return Ok(json!({
            "recording_id": rec_id,
            "exportedAt": manifest["exportedAt"],
            "hasTranscript": !text.is_empty(),
            "snapshotRevision": actual_revision,
            "materialContentHash": content_hash,
            "text": text,
            "revision": manifest["transcript"]["revision"].as_u64().unwrap_or(1),
            "manuallyEdited": false,
            "timingReliable": true,
            "sources": sources,
            "sourceBasis": "exported provider segments; text may differ"
        }));
    }
    if name == "get_minutes" {
        let Some(minutes) = manifest.get("minutes") else {
            return Ok(json!({
                "recording_id": rec_id,
                "exportedAt": manifest["exportedAt"],
                "hasMinutes": false,
                "snapshotRevision": actual_revision,
                "materialContentHash": content_hash,
            }));
        };
        let text = manifest["transcript"]["manual"]
            .as_str()
            .filter(|s| !s.trim().is_empty())
            .or_else(|| manifest["transcript"]["text"].as_str());
        let freshness = match text {
            None => "unverified",
            Some(t) => {
                let hash = format!("{:x}", Sha256::digest(t.as_bytes()));
                if Some(hash.as_str()) == minutes["current"]["sourceHash"].as_str() {
                    "current"
                } else {
                    "stale"
                }
            }
        };
        return Ok(json!({
            "recording_id": rec_id,
            "exportedAt": manifest["exportedAt"],
            "hasMinutes": true,
            "snapshotRevision": actual_revision,
            "materialContentHash": content_hash,
            "current": minutes["current"],
            "historyCount": minutes["history"].as_array().map(|a| a.len()).unwrap_or(0),
            "freshness": freshness,
            "freshnessScope": "published_text_consistency",
            "sourceNamespace": "minutes snapshot; separate from transcript T/P references"
        }));
    }
    Err("unknown_tool")
}

pub fn hash_file_sha256(path: &Path) -> Result<String> {
    let bytes = fs::read(path).with_context(|| format!("无法读取文件：{}", path.display()))?;
    Ok(format!("{:x}", Sha256::digest(&bytes)))
}
