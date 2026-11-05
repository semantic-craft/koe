use crate::{mcp::hash_file_sha256, organize};
use anyhow::{Context, Result, bail};
use chrono::SecondsFormat;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
};

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Recording {
    pub path: PathBuf,
    pub display_name: String,
    #[serde(default)]
    pub archived: bool,
    pub deleted_at: Option<String>,
    #[serde(default)]
    pub permanently_deleted: bool,
    #[serde(default = "default_source")]
    pub source: String,
    pub content_hash: Option<String>,
    pub imported_at: Option<String>,
    #[serde(skip)]
    pub transcript: String,
    #[serde(skip)]
    pub minutes: Option<Value>,
}

fn default_source() -> String {
    "phone".to_owned()
}

impl Recording {
    pub fn playable(&self) -> bool {
        self.path.is_file()
            && matches!(
                self.path.extension().and_then(|s| s.to_str()),
                Some("wav" | "mp3" | "m4a" | "flac" | "ogg")
            )
    }

    pub fn recording_key(&self) -> String {
        if let Some(id) = file_id(&self.path) {
            format!("file:{id}")
        } else {
            format!("path:{}", self.path.to_string_lossy())
        }
    }

    pub fn recording_id(&self) -> Result<String> {
        if let Some(hash) = &self.content_hash
            && hash.len() == 64
        {
            return Ok(hash.clone());
        }
        if self.path.is_file() {
            return hash_file_sha256(&self.path);
        }
        Ok(format!(
            "{:x}",
            Sha256::digest(self.recording_key().as_bytes())
        ))
    }

    pub fn formatted_minutes(&self) -> Option<String> {
        let text = self.minutes.as_ref()?["current"]["text"].as_str()?;
        Some(organize::format_minutes(text))
    }
}

#[derive(Debug, Default)]
pub struct Library {
    pub directory: PathBuf,
    pub recordings: Vec<Recording>,
}

#[derive(Deserialize)]
struct Catalog {
    version: u32,
    assets: Vec<Recording>,
}

fn text<'a>(doc: &'a Value, field: &str, key: &str) -> Option<&'a str> {
    doc.get(field)?.get(key)?.as_str()
}

impl Library {
    pub fn open(directory: &Path) -> Result<Self> {
        if !directory.is_dir() {
            bail!("资料目录不存在");
        }
        let catalog: Catalog = match fs::read(directory.join("recording_library.json")) {
            Ok(bytes) => {
                serde_json::from_slice(&bytes).context("资料索引格式无法读取，未改动原文件")?
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Catalog {
                version: 1,
                assets: Vec::new(),
            },
            Err(error) => return Err(error.into()),
        };
        if catalog.version != 1 {
            bail!("不支持的资料索引版本 {}", catalog.version);
        }
        let transcript_file = directory.join("transcripts.json");
        let transcripts: Value = match fs::read(&transcript_file) {
            Ok(bytes) => {
                serde_json::from_slice(&bytes).context("转写格式无法读取，未改动原文件")?
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Value::Null,
            Err(error) => return Err(error.into()),
        };
        if !transcripts.is_null() && !transcripts.is_object() {
            bail!("转写文件必须是 JSON 对象，未改动原文件");
        }
        let analysis_file = directory.join("analysis.json");
        let analysis: Value = match fs::read(&analysis_file) {
            Ok(bytes) => {
                serde_json::from_slice(&bytes).context("纪要分析格式无法读取，未改动原文件")?
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Value::Null,
            Err(error) => return Err(error.into()),
        };
        if !analysis.is_null() && !analysis.is_object() {
            bail!("纪要分析文件必须是 JSON 对象，未改动原文件");
        }
        let mut assets = catalog.assets;
        let exports = directory.join("exports");
        if exports.is_dir() {
            for entry in fs::read_dir(exports)? {
                let entry = entry?;
                if !entry.file_type()?.is_file() {
                    continue;
                }
                let path = entry.path();
                let name = entry.file_name().to_string_lossy().into_owned();
                let id = file_id(&path);
                if id.is_none()
                    || !(name.ends_with(".wav")
                        || name.ends_with(".opus")
                        || name.ends_with(".opus.bin"))
                {
                    continue;
                }
                if assets.iter().any(|r| {
                    r.path == path
                        || (file_id(&r.path) == id
                            && (r.archived || r.deleted_at.is_some() || r.permanently_deleted))
                }) {
                    continue;
                }
                assets.push(Recording {
                    path,
                    display_name: name,
                    archived: false,
                    deleted_at: None,
                    permanently_deleted: false,
                    source: "device".to_owned(),
                    content_hash: None,
                    imported_at: None,
                    transcript: String::new(),
                    minutes: None,
                });
            }
        }
        let mut recordings: Vec<Recording> = Vec::new();
        for mut recording in assets {
            if recording.archived || recording.deleted_at.is_some() || recording.permanently_deleted
            {
                continue;
            }
            let path = recording.path.to_str().context("音频路径不是 UTF-8")?;
            let id = file_id(&recording.path);
            let key = id
                .as_ref()
                .map(|id| format!("file:{id}"))
                .unwrap_or_else(|| format!("path:{path}"));
            recording.transcript = text(&transcripts, "manualByKey", &key)
                .or_else(|| text(&transcripts, "byPath", path).filter(|s| !s.is_empty()))
                .or_else(|| {
                    id.as_ref()
                        .and_then(|id| text(&transcripts, "byFileId", id))
                })
                .unwrap_or("")
                .to_owned();
            let aliases = transcripts
                .get("aliasesByPath")
                .and_then(|v| v.get(path))
                .or_else(|| {
                    id.as_ref()
                        .and_then(|id| transcripts.get("aliasesByFileId")?.get(id))
                });
            recording.transcript = apply_speaker_aliases(&recording.transcript, aliases);
            let minutes_key = format!("{key}/minutes");
            if let Some(current) = analysis.get("results").and_then(|r| r.get(&minutes_key)) {
                let history = analysis
                    .get("versionHistory")
                    .and_then(|h| h.get(&minutes_key))
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                recording.minutes = Some(json!({
                    "current": current,
                    "history": history,
                }));
            }
            if recording.path.is_relative() {
                recording.path = directory.join(&recording.path);
            }
            if let Some(index) = id.as_ref().and_then(|id| {
                recordings
                    .iter()
                    .position(|r| file_id(&r.path).as_ref() == Some(id))
            }) {
                if !prefer(&recording.path, &recordings[index].path) {
                    continue;
                }
                recordings.remove(index);
            }
            recordings.push(recording);
        }
        recordings.sort_by(|left, right| {
            filename_seconds(&right.path)
                .cmp(&filename_seconds(&left.path))
                .then_with(|| right.path.cmp(&left.path))
        });
        Ok(Self {
            directory: directory.to_path_buf(),
            recordings,
        })
    }

    pub fn save_manual_transcript(&mut self, index: usize, manual_text: &str) -> Result<()> {
        let recording = self
            .recordings
            .get(index)
            .context("未找到指定索引的录音")?
            .clone();
        if self.directory.as_os_str().is_empty() {
            bail!("尚未绑定资料目录");
        }
        let transcript_file = self.directory.join("transcripts.json");
        let mut root: Map<String, Value> = match fs::read(&transcript_file) {
            Ok(bytes) => serde_json::from_slice(&bytes).context("转写格式无法读取")?,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                let mut m = Map::new();
                m.insert("version".into(), json!(4));
                m
            }
            Err(err) => return Err(err.into()),
        };
        let key = recording.recording_key();
        let manual_map = root
            .entry("manualByKey")
            .or_insert_with(|| json!({}))
            .as_object_mut()
            .context("manualByKey 必须是 JSON 对象")?;
        manual_map.insert(key.clone(), Value::String(manual_text.to_owned()));

        let meta_map = root
            .entry("metadata")
            .or_insert_with(|| json!({}))
            .as_object_mut()
            .context("metadata 必须是 JSON 对象")?;
        let next_rev = meta_map
            .get(&key)
            .and_then(|v| v.get("revision"))
            .and_then(Value::as_u64)
            .unwrap_or(0)
            + 1;
        meta_map.insert(
            key,
            json!({
                "revision": next_rev,
                "updatedAt": chrono::Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
            }),
        );
        atomic_write_json(&transcript_file, &Value::Object(root.clone()))?;

        let path_str = recording.path.to_string_lossy();
        let id = file_id(&recording.path);
        let root_val = Value::Object(root);
        let aliases = root_val
            .get("aliasesByPath")
            .and_then(|v| v.get(path_str.as_ref()))
            .or_else(|| {
                id.as_ref()
                    .and_then(|id| root_val.get("aliasesByFileId")?.get(id))
            });
        self.recordings[index].transcript = apply_speaker_aliases(manual_text, aliases);
        Ok(())
    }

    pub fn register_recording(
        &mut self,
        audio_path: &Path,
        display_name: &str,
        source: &str,
    ) -> Result<usize> {
        if !audio_path.is_file() {
            bail!("录音文件不存在：{}", audio_path.display());
        }
        if self.directory.as_os_str().is_empty() {
            bail!("尚未绑定资料目录");
        }
        let content_hash = hash_file_sha256(audio_path)?;
        let byte_size = fs::metadata(audio_path)?.len();
        let catalog_file = self.directory.join("recording_library.json");
        let mut root: Map<String, Value> = match fs::read(&catalog_file) {
            Ok(bytes) => serde_json::from_slice(&bytes).context("资料索引格式无法读取")?,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                let mut m = Map::new();
                m.insert("version".into(), json!(1));
                m.insert("assets".into(), json!([]));
                m
            }
            Err(err) => return Err(err.into()),
        };
        let assets = root
            .entry("assets")
            .or_insert_with(|| json!([]))
            .as_array_mut()
            .context("assets 必须是数组")?;
        let now = chrono::Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
        let entry = json!({
            "path": audio_path,
            "displayName": display_name,
            "source": source,
            "importedAt": now,
            "contentHash": content_hash,
            "originalByteSize": byte_size,
            "originalComplete": true,
        });
        if let Some(pos) = assets
            .iter()
            .position(|a| a.get("path").and_then(Value::as_str) == audio_path.to_str())
        {
            assets[pos] = entry;
        } else {
            assets.push(entry);
        }
        atomic_write_json(&catalog_file, &Value::Object(root))?;
        *self = Self::open(&self.directory)?;
        self.recordings
            .iter()
            .position(|r| r.path == audio_path)
            .context("新注册的录音未出现在资料列表中")
    }

    pub fn generate_minutes(&mut self, index: usize, instruction: &str) -> Result<Value> {
        let recording = self
            .recordings
            .get(index)
            .context("未找到指定索引的录音")?
            .clone();
        if self.directory.as_os_str().is_empty() {
            bail!("尚未绑定资料目录");
        }
        let wrapped = organize::generate_minutes_for_recording(
            &recording,
            instruction,
            recording.minutes.as_ref(),
        )?;
        let analysis_file = self.directory.join("analysis.json");
        let mut root: Map<String, Value> = match fs::read(&analysis_file) {
            Ok(bytes) => serde_json::from_slice(&bytes).context("纪要文件格式无法读取")?,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                let mut m = Map::new();
                m.insert("model".into(), json!("koe-desktop-organizer"));
                m
            }
            Err(err) => return Err(err.into()),
        };
        let minutes_key = format!("{}/minutes", recording.recording_key());
        root.entry("results")
            .or_insert_with(|| json!({}))
            .as_object_mut()
            .context("results 必须是对象")?
            .insert(minutes_key.clone(), wrapped["current"].clone());
        root.entry("versionHistory")
            .or_insert_with(|| json!({}))
            .as_object_mut()
            .context("versionHistory 必须是对象")?
            .insert(minutes_key, wrapped["history"].clone());
        atomic_write_json(&analysis_file, &Value::Object(root))?;
        self.recordings[index].minutes = Some(wrapped.clone());
        Ok(wrapped)
    }
}

fn apply_speaker_aliases(raw: &str, aliases: Option<&Value>) -> String {
    raw.lines()
        .map(|line| {
            if let Some((prefix, rest)) = line.split_once('：')
                && let Some(speaker) = prefix.strip_prefix("说话人 ")
                && let Some(alias) = aliases
                    .and_then(|a| a.get(speaker.trim()))
                    .and_then(Value::as_str)
                    .filter(|a| !a.trim().is_empty())
            {
                return format!("{}：{rest}", alias.trim());
            }
            line.to_owned()
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn atomic_write_json(target: &Path, value: &Value) -> Result<()> {
    let parent = target.parent().context("目标文件缺少父目录")?;
    fs::create_dir_all(parent)?;
    let tmp = parent.join(format!(
        ".{}.tmp-{}",
        target
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("data"),
        std::process::id()
    ));
    let bytes = serde_json::to_vec(value)?;
    fs::write(&tmp, bytes)?;
    fs::rename(&tmp, target)?;
    Ok(())
}

pub(crate) fn file_id(path: &Path) -> Option<String> {
    let digits: String = path
        .file_name()?
        .to_str()?
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    digits.parse::<u64>().ok().map(|id| id.to_string())
}

fn prefer(candidate: &Path, current: &Path) -> bool {
    let rank = |path: &Path| {
        (
            path.is_file(),
            path.extension().and_then(|s| s.to_str()) == Some("wav"),
            !path.to_string_lossy().ends_with(".opus.bin"),
        )
    };
    rank(candidate)
        .cmp(&rank(current))
        .then_with(|| candidate.cmp(current))
        .is_gt()
}

fn filename_seconds(path: &Path) -> Option<u64> {
    let name = path.file_name()?.to_str()?;
    let digits: String = name
        .strip_prefix("phone_")
        .unwrap_or(name)
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    let value = digits.parse::<u64>().ok()?;
    Some(if value >= 100_000_000_000_000 {
        value / 1_000_000
    } else if value >= 100_000_000_000 {
        value / 1_000
    } else {
        value
    })
}
