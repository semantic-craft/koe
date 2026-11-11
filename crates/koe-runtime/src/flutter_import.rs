use super::*;
use chrono::{DateTime, Local, NaiveDateTime, TimeZone};
use koe_client_base::{hash::sha256_hex, write_atomic};
use koe_engine::wav::parse_pcm_wave;
use serde::Deserialize;
use std::{collections::BTreeSet, fs};

const MAX_FILE: u64 = 256 * 1024 * 1024;
const DOMAIN_FILES: &[&str] = &[
    "recording_library.json",
    "transcripts.json",
    "analysis.json",
    "metadata.json",
    "topics.json",
    "projects.json",
    "diary.json",
    "context_items.json",
    "todos.json",
    "ask.json",
    "playback_history.json",
    "bookmarks.json",
];

#[derive(Deserialize)]
struct Library {
    version: u32,
    assets: Vec<Asset>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Asset {
    path: String,
    display_name: String,
    source: String,
    imported_at: String,
    recorded_at: Option<String>,
    #[serde(default)]
    archived: bool,
    deleted_at: Option<String>,
    #[serde(default)]
    permanently_deleted: bool,
    #[serde(default = "yes")]
    original_complete: bool,
}
fn yes() -> bool {
    true
}
#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Transcripts {
    version: u32,
    #[serde(default)]
    by_path: BTreeMap<String, String>,
    #[serde(default)]
    by_file_id: BTreeMap<String, String>,
    #[serde(default)]
    segments: BTreeMap<String, Vec<Segment>>,
    #[serde(default)]
    manual_by_key: BTreeMap<String, String>,
    #[serde(default)]
    aliases_by_path: BTreeMap<String, BTreeMap<String, String>>,
    #[serde(default)]
    aliases_by_file_id: BTreeMap<String, BTreeMap<String, String>>,
    #[serde(default)]
    segment_speakers_by_key: BTreeMap<String, BTreeMap<String, String>>,
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Segment {
    text: String,
    start_ms: u64,
    end_ms: Option<u64>,
    speaker: Option<String>,
}
struct PreparedRecord {
    id: String,
    title: String,
    origin: RecordOrigin,
    file_id: u32,
    created: u64,
    duration: u64,
    segments: Vec<Segment>,
    audio: Option<Vec<u8>>,
}
struct ImportPlan {
    receipt: MigrationReceipt,
    records: Vec<PreparedRecord>,
    originals: BTreeMap<String, Vec<u8>>,
}

impl KoeRuntime {
    pub(super) fn import_flutter_library(&mut self, source: &Path) -> Result<(), String> {
        let source = fs::canonicalize(source).map_err(|e| format!("旧库目录无法读取：{e}"))?;
        let target = fs::canonicalize(&self.root).map_err(|e| e.to_string())?;
        if source.starts_with(&target) || target.starts_with(&source) {
            return Err("旧库与当前工作区不能相同或互相包含，原库未修改".into());
        }
        let plan = ImportPlan::read(&source)?;
        if self
            .workspace()
            .migrations()
            .iter()
            .any(|m| m.fingerprint == plan.receipt.fingerprint)
        {
            self.notice = Some("此旧库快照已迁入；原文件与未迁清单均已保留。".into());
            return Ok(());
        }
        if plan
            .records
            .iter()
            .any(|r| self.workspace().record(&r.id).is_some())
        {
            return Err(
                "旧库内容已变化或记录已迁入，未覆盖现有记录。请保留旧库等待增量迁移支持。".into(),
            );
        }
        let archive = self.root.join(&plan.receipt.archive);
        for path in [
            target.join("audio"),
            target.join(&plan.receipt.archive),
            target.join(&plan.receipt.archive).join("audio"),
        ] {
            reject_symlink_ancestors(&target, &path)?;
        }
        for (name, bytes) in &plan.originals {
            preserve(&archive.join(name), bytes)?;
        }
        for record in &plan.records {
            if let Some(bytes) = &record.audio {
                recording_assets::save_audio(&self.root, &record.id, bytes)?;
            }
        }
        let count = plan.records.len();
        self.commit(move |workspace| {
            for record in plan.records {
                workspace.insert_record(
                    record.id.clone(),
                    record.title,
                    record.origin,
                    record.file_id,
                    record.created,
                    record.duration,
                )?;
                for segment in record.segments {
                    let id = workspace.append_transcript(
                        &record.id,
                        &segment.text,
                        segment.start_ms,
                        segment.end_ms.unwrap_or(segment.start_ms),
                        "flutter-import",
                    )?;
                    workspace.import_segment_speaker(
                        &SourceRef {
                            record_id: record.id.clone(),
                            segment_id: id,
                        },
                        segment.speaker.as_deref(),
                    )?;
                }
            }
            workspace.finish_migration(plan.receipt)
        })?;
        self.notice = Some(format!(
            "已迁入 {count} 条基础记录；旧库原件已保全。部分资料尚未迁入，请查看设置中的未迁清单。"
        ));
        Ok(())
    }
}

impl ImportPlan {
    fn read(source: &Path) -> Result<Self, String> {
        let mut originals = BTreeMap::new();
        let mut remaining = MAX_FILE;
        let mut audio_manifest = BTreeMap::new();
        let mut pending = BTreeSet::new();
        for entry in fs::read_dir(source).map_err(|e| e.to_string())? {
            let entry = entry.map_err(|e| e.to_string())?;
            let name = entry.file_name().to_string_lossy().to_string();
            if DOMAIN_FILES.contains(&name.as_str()) {
                let bytes = read_source(source, &entry.path(), &mut remaining)?;
                let value: Value = serde_json::from_slice(&bytes)
                    .map_err(|e| format!("旧库 {name} 损坏：{e}；原文件未修改"))?;
                if !value.is_object() {
                    return Err(format!("旧库 {name} 必须是 JSON 对象"));
                }
                originals.insert(name.clone(), bytes);
                if !matches!(
                    name.as_str(),
                    "recording_library.json" | "transcripts.json" | "analysis.json"
                ) {
                    pending.insert(format!("{name}：已保全原件，领域资料尚未迁入"));
                }
            } else if !matches!(name.as_str(), "exports" | "imports") && !is_audio_name(&name) {
                pending.insert(format!(
                    "{name}：未读取，仍保留在原目录 {}",
                    source.display()
                ));
            }
        }
        let library: Library = decode(&originals, "recording_library.json")?;
        if library.version != 1 {
            return Err("不支持的 Flutter 录音库版本，原库未修改".into());
        }
        let transcripts: Transcripts = if originals.contains_key("transcripts.json") {
            decode(&originals, "transcripts.json")?
        } else {
            Transcripts::default()
        };
        if originals.contains_key("transcripts.json") && !matches!(transcripts.version, 1..=4) {
            return Err("不支持的 Flutter 原文版本，原库未修改".into());
        }
        for name in [
            "recording_library.json",
            "transcripts.json",
            "analysis.json",
        ] {
            if originals.contains_key(name) {
                pending.insert(format!(
                    "{name}：未映射字段、原始版本与历史已保全；仅迁入基础可见内容"
                ));
            }
        }
        if let Some(bytes) = originals.get("transcripts.json") {
            let json: Value = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
            for field in [
                "incomingByKey",
                "manualByKey",
                "translations",
                "speakerUndoByKey",
                "expectedSpeakersByKey",
                "diarizationQualityByKey",
            ] {
                if json.get(field).is_some_and(nonempty_value) {
                    pending.insert(format!(
                        "transcripts.json/{field}：原件已保全，版本或扩展语义尚未迁入"
                    ));
                }
            }
        }
        let analysis: Value = originals
            .get("analysis.json")
            .map(|b| serde_json::from_slice(b))
            .transpose()
            .map_err(|e| e.to_string())?
            .unwrap_or(Value::Null);
        if !analysis.is_null() && analysis["version"] != 1 {
            return Err("不支持的 Flutter 纪要版本".into());
        }
        let results = analysis
            .get("results")
            .map(|v| v.as_object().ok_or("analysis.json/results 格式损坏"))
            .transpose()?;
        let mut records = Vec::new();
        let mut summaries = Vec::new();
        let mut seen = BTreeSet::new();
        let mut mapped_keys = BTreeSet::new();
        for asset in library.assets {
            if asset.path.trim().is_empty() || asset.display_name.trim().is_empty() {
                return Err("旧库录音身份或名称缺失".into());
            }
            let basename = Path::new(&asset.path)
                .file_name()
                .and_then(|n| n.to_str())
                .ok_or("旧库音频路径无效")?;
            let file_id = basename
                .chars()
                .take_while(char::is_ascii_digit)
                .collect::<String>()
                .parse::<u64>()
                .unwrap_or(0);
            let key = if file_id > 0 {
                format!("file:{file_id}")
            } else {
                format!("path:{}", asset.path)
            };
            if !seen.insert(key.clone()) {
                return Err(format!("旧库重复录音身份 {key}，未导入"));
            }
            if asset.archived || asset.deleted_at.is_some() || asset.permanently_deleted {
                pending.insert(format!(
                    "{key}：归档或回收站记录保持隐藏，音频仅保留在原目录，尚未迁入"
                ));
                continue;
            }
            if !asset.original_complete {
                return Err(format!("{key}：原始音频尚未完成，未导入"));
            }
            let audio_path = resolve_audio(source, &asset.path)?;
            let bytes = read_source(source, &audio_path, &mut remaining)?;
            let id = format!("flutter-{}", sha256_hex(key.as_bytes()));
            let extension = audio_path
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            if !is_audio_name(basename) {
                return Err("旧库引用了不支持的音频文件类型".into());
            }
            let original_name = format!("audio/{}.{}", sha256_hex(&bytes), extension);
            audio_manifest.insert(asset.path.clone(), original_name.clone());
            originals.insert(original_name, bytes.clone());
            let audio = match extension.as_str() {
                "wav" => {
                    parse_pcm_wave(&bytes).map_err(|e| format!("{key}：WAV 损坏：{e}"))?;
                    Some(bytes)
                }
                "opus" => Some(
                    if bytes.starts_with(b"OggS") {
                        super::legacy::decode_ogg_opus(&bytes)
                    } else {
                        decode_bare_opus(&bytes)
                    }
                    .map_err(|e| format!("{key}：Opus 损坏：{e}"))?,
                ),
                _ => {
                    pending.insert(format!("{key}：{extension} 音频原件已保全，暂不可播放"));
                    None
                }
            };
            let duration = audio
                .as_ref()
                .map(|b| parse_pcm_wave(b).map(|w| w.duration_ms()))
                .transpose()?
                .unwrap_or(0);
            let manual = transcripts.manual_by_key.get(&key);
            let visible = manual
                .or_else(|| transcripts.by_path.get(&asset.path))
                .or_else(|| transcripts.by_file_id.get(&file_id.to_string()));
            let aliases = transcripts
                .aliases_by_path
                .get(&asset.path)
                .or_else(|| transcripts.aliases_by_file_id.get(&file_id.to_string()));
            let timed = transcripts.segments.get(&key);
            if timed.is_some_and(|segments| {
                segments.iter().any(|s| {
                    s.text.trim().is_empty() || s.end_ms.is_some_and(|end| end < s.start_ms)
                })
            }) {
                return Err(format!("{key}：原文片段损坏"));
            }
            let use_timed = manual.is_none()
                && timed.is_some_and(|segments| {
                    visible.is_some_and(|text| {
                        normalize_text(text, aliases)
                            == normalize_text(
                                &segments.iter().map(|s| s.text.as_str()).collect::<String>(),
                                aliases,
                            )
                    }) && segments.len() >= 2
                        && segments
                            .windows(2)
                            .all(|pair| pair[0].start_ms < pair[1].start_ms)
                        && segments.iter().all(|s| {
                            s.end_ms.is_some_and(|end| end <= duration) && s.start_ms <= duration
                        })
                });
            let mut segments = if use_timed {
                timed.cloned().unwrap_or_default()
            } else {
                text_segments(visible.map(String::as_str).unwrap_or(""), aliases)
            };
            if timed.is_some() && !use_timed {
                pending.insert(format!(
                    "{key}：旧分段版本或时码不可用，已保全；可见全文以无时码文字迁入"
                ));
            }
            let overrides = transcripts.segment_speakers_by_key.get(&key);
            for (index, segment) in segments.iter_mut().enumerate() {
                if segment.text.trim().is_empty()
                    || segment.end_ms.is_some_and(|end| end < segment.start_ms)
                {
                    return Err(format!("{key}：原文片段损坏"));
                }
                if use_timed {
                    if let Some(speaker) = overrides.and_then(|m| m.get(&index.to_string())) {
                        segment.speaker = Some(speaker.clone());
                    }
                    if let Some(alias) = segment
                        .speaker
                        .as_ref()
                        .and_then(|s| aliases.and_then(|m| m.get(s)))
                    {
                        segment.speaker = Some(alias.clone());
                    }
                }
            }
            if manual.is_some() {
                pending.insert(format!(
                    "{key}：人工原文已迁入，无可靠时码；旧分段和候选保存在 transcripts.json"
                ));
            }
            if let Some(results) = results {
                for (slot, result) in results {
                    if let Some(suffix) = slot.strip_prefix(&format!("{key}/")) {
                        let text = result
                            .get("text")
                            .and_then(Value::as_str)
                            .filter(|t| !t.trim().is_empty())
                            .ok_or_else(|| format!("analysis.json/{slot} 纪要文本损坏"))?;
                        summaries.push(ImportedSummary {
                            record_id: id.clone(),
                            slot: suffix.into(),
                            text: text.into(),
                        });
                        mapped_keys.insert(slot.clone());
                    }
                }
            }
            let origin = match asset.source.as_str() {
                "device" => RecordOrigin::ImportedAudio,
                "localImport" | "phone" => RecordOrigin::ImportedAudio,
                _ => return Err("旧库录音来源无效".into()),
            };
            records.push(PreparedRecord {
                id,
                title: asset.display_name,
                origin,
                file_id: u32::try_from(file_id).unwrap_or(0),
                created: timestamp(asset.recorded_at.as_deref().unwrap_or(&asset.imported_at))?,
                duration,
                segments,
                audio,
            });
        }
        if let Some(results) = results {
            for key in results.keys().filter(|key| !mapped_keys.contains(*key)) {
                pending.insert(format!("analysis.json/{key}：未匹配活跃录音，原件已保全"));
            }
        }
        for directory in [
            source.to_path_buf(),
            source.join("exports"),
            source.join("imports"),
        ] {
            if !directory.exists() {
                continue;
            }
            let resolved = fs::canonicalize(&directory).map_err(|e| e.to_string())?;
            if !resolved.starts_with(source) {
                return Err("旧库音频目录越出所选目录，未读取".into());
            }
            for entry in fs::read_dir(&directory).map_err(|e| e.to_string())? {
                let entry = entry.map_err(|e| e.to_string())?;
                let path = entry.path();
                if is_audio_name(&entry.file_name().to_string_lossy())
                    && !audio_manifest.keys().any(|stored| {
                        resolve_audio(source, stored).is_ok_and(|selected| selected == path)
                    })
                {
                    pending.insert(format!("{}：未迁入的音频仅保留在原目录", path.display()));
                }
            }
        }
        originals.insert(
            "audio-manifest.json".into(),
            serde_json::to_vec(&audio_manifest).map_err(|e| e.to_string())?,
        );
        let mut fingerprint_bytes = Vec::new();
        for (name, bytes) in &originals {
            fingerprint_bytes.extend_from_slice(name.as_bytes());
            fingerprint_bytes.push(0);
            fingerprint_bytes.extend_from_slice(sha256_hex(bytes).as_bytes());
        }
        let fingerprint = sha256_hex(&fingerprint_bytes);
        Ok(Self {
            receipt: MigrationReceipt {
                archive: format!("legacy-imports/{fingerprint}"),
                fingerprint,
                record_ids: records.iter().map(|r| r.id.clone()).collect(),
                pending: pending.into_iter().collect(),
                summaries,
            },
            records,
            originals,
        })
    }
}
fn normalize_text(text: &str, aliases: Option<&BTreeMap<String, String>>) -> String {
    text.lines()
        .map(|line| {
            let line = line.trim();
            let content = if let Some((label, body)) = line.split_once('：') {
                if label.trim_start().starts_with("说话人 ")
                    || aliases.is_some_and(|m| m.values().any(|a| a == label))
                {
                    body
                } else {
                    line
                }
            } else {
                line
            };
            content
                .chars()
                .filter(|c| !c.is_whitespace())
                .collect::<String>()
        })
        .collect()
}
fn nonempty_value(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Object(m) => !m.is_empty(),
        Value::Array(v) => !v.is_empty(),
        _ => true,
    }
}
fn apply_speaker_alias(text: &str, aliases: Option<&BTreeMap<String, String>>) -> String {
    if let Some((label, body)) = text.split_once('：') {
        if let Some(id) = label.strip_prefix("说话人") {
            if id.starts_with(char::is_whitespace) {
                if let Some(alias) = aliases
                    .and_then(|m| m.get(id.trim()))
                    .filter(|a| !a.trim().is_empty())
                {
                    return format!("{}：{body}", alias.trim());
                }
            }
        }
    }
    text.into()
}
fn text_segments(text: &str, aliases: Option<&BTreeMap<String, String>>) -> Vec<Segment> {
    text.lines()
        .filter(|s| !s.trim().is_empty())
        .map(|text| Segment {
            text: apply_speaker_alias(text, aliases),
            start_ms: 0,
            end_ms: Some(0),
            speaker: None,
        })
        .collect()
}
fn decode<T: serde::de::DeserializeOwned>(
    files: &BTreeMap<String, Vec<u8>>,
    name: &str,
) -> Result<T, String> {
    serde_json::from_slice(
        files
            .get(name)
            .ok_or_else(|| format!("未找到 {name}，请选择 Flutter AnkerRecorder 目录"))?,
    )
    .map_err(|e| format!("旧库 {name} 格式损坏：{e}"))
}
fn is_audio_name(name: &str) -> bool {
    if name.to_ascii_lowercase().ends_with(".opus.bin") {
        return true;
    }
    Path::new(name)
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| {
            matches!(
                e.to_ascii_lowercase().as_str(),
                "wav" | "opus" | "ogg" | "mp3" | "m4a" | "aac" | "flac"
            )
        })
}
fn read_source(root: &Path, path: &Path, remaining: &mut u64) -> Result<Vec<u8>, String> {
    let resolved = fs::canonicalize(path)
        .map_err(|e| format!("旧库文件缺失或不可读 {}：{e}", path.display()))?;
    if !resolved.starts_with(root) {
        return Err("旧库文件越出所选目录，未读取".into());
    }
    let metadata = fs::metadata(&resolved).map_err(|e| e.to_string())?;
    if !metadata.is_file() || metadata.len() > MAX_FILE {
        return Err("旧库文件不是普通文件或超过 256 MB".into());
    }
    if metadata.len() > *remaining {
        return Err("旧库整批文件超过 256 MB，本轮未迁入；请保留原库等待分批迁移支持".into());
    }
    *remaining -= metadata.len();
    fs::read(resolved).map_err(|e| format!("旧库文件无法读取：{e}"))
}
fn resolve_audio(root: &Path, stored: &str) -> Result<PathBuf, String> {
    let stored = Path::new(stored);
    if stored.starts_with(root) {
        return Ok(stored.to_path_buf());
    }
    let basename = stored.file_name().ok_or("旧库音频文件名无效")?;
    let mut candidates = Vec::new();
    for dir in [
        root.to_path_buf(),
        root.join("exports"),
        root.join("imports"),
    ] {
        let candidate = dir.join(basename);
        if candidate.exists() {
            candidates.push(candidate);
        }
    }
    match candidates.as_slice() {
        [path] => Ok(path.clone()),
        [] => Err(format!("旧库音频缺失：{}", basename.to_string_lossy())),
        _ => Err(format!(
            "旧库存在同名音频，无法安全匹配：{}",
            basename.to_string_lossy()
        )),
    }
}
fn timestamp(value: &str) -> Result<u64, String> {
    let seconds = if let Ok(time) = DateTime::parse_from_rfc3339(value) {
        time.timestamp()
    } else {
        let time = NaiveDateTime::parse_from_str(value, "%Y-%m-%dT%H:%M:%S%.f")
            .map_err(|_| "旧库日期格式无效")?;
        Local
            .from_local_datetime(&time)
            .single()
            .ok_or("旧库本地时间存在时区歧义")?
            .timestamp()
    };
    u64::try_from(seconds).map_err(|_| "旧库日期早于支持范围".into())
}
fn preserve(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if path.exists() {
        if fs::read(path).map_err(|e| e.to_string())? == bytes {
            return Ok(());
        }
        return Err("旧库保全副本冲突，未覆盖".into());
    }
    write_atomic(path, bytes).map_err(|e| format!("旧库保全失败：{e}"))?;
    fs::File::open(path.parent().ok_or("保全路径无父目录")?)
        .and_then(|f| f.sync_all())
        .map_err(|e| format!("旧库保全落盘失败：{e}"))
}

fn reject_symlink_ancestors(root: &Path, path: &Path) -> Result<(), String> {
    let relative = path
        .strip_prefix(root)
        .map_err(|_| "迁移目标不在工作区内")?;
    let mut current = root.to_path_buf();
    for component in relative.components() {
        current.push(component);
        match fs::symlink_metadata(&current) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err("迁移目标含符号链接，未写入旧库或工作区".into())
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.to_string()),
        }
    }
    Ok(())
}

fn decode_bare_opus(bytes: &[u8]) -> Result<Vec<u8>, String> {
    use koe_engine::{
        ogg_opus::{OggOpus, FRAME_SIZE},
        wav::OpusWave,
    };
    if bytes.is_empty() {
        return Err("裸 Opus 录音为空".into());
    }
    let mut decoder = koe_opus::create_libopus_decoder(48_000).ok_or("Opus 解码器不可用")?;
    let mut pcm = Vec::new();
    for (index, frame) in bytes.chunks(FRAME_SIZE).enumerate() {
        if !decoder.decode_trimmed_packet(OggOpus::trim_trailing_zeros(frame), &mut pcm) {
            return Err(format!("裸 Opus 第 {} 帧无法解码", index + 1));
        }
        if pcm.len() > 512 * 1024 * 1024 {
            return Err("Opus 音频超出单次恢复大小".into());
        }
    }
    let mut wav = OpusWave::wav_header_with_rate(pcm.len() as u32, 48_000).to_vec();
    wav.extend_from_slice(&pcm);
    Ok(wav)
}
