//! Validated import and immutable audio assets. Product decisions stay in the engine.

use koe_client_base::{hash::sha256_hex, write_atomic};
use koe_engine::{
    cicada::decode_koepack, domain::MeetingMinutes, domain::UtteranceSpine,
    minutes::parse_meeting_minutes_json, wav::parse_pcm_wave,
};
use std::{
    collections::BTreeSet,
    fs,
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

/// Content prepared for one atomic product transaction.
pub struct ImportedRecording {
    /// Content-derived stable identity makes repeated imports idempotent.
    pub id: String,
    /// Original title or filename without an extension.
    pub title: String,
    /// Existing file timestamp, when available.
    pub created_at: u64,
    /// Duration from actual PCM, zero for untimed text.
    pub duration_ms: u64,
    /// Text sources, without invented time offsets.
    pub paragraphs: Vec<String>,
    /// Validated portable minutes, if present.
    pub minutes: Option<MeetingMinutes>,
    /// Whether an audio asset was successfully saved.
    pub has_audio: bool,
}

const MAX_IMPORT_BYTES: u64 = 256 * 1024 * 1024;

/// Imports WAV, UTF-8 text, Markdown, or an audio-less Koe pack.
pub fn import_recording(root: &Path, path: &Path, now: u64) -> Result<ImportedRecording, String> {
    let metadata = fs::metadata(path).map_err(|e| format!("无法读取所选文件：{e}"))?;
    if !metadata.is_file() || metadata.len() > MAX_IMPORT_BYTES {
        return Err("请选择不超过 256 MB 的文件".into());
    }
    let bytes = fs::read(path).map_err(|e| format!("无法读取所选文件：{e}"))?;
    let id = format!("import-{}", sha256_hex(&bytes));
    let extension = path
        .extension()
        .and_then(|v| v.to_str())
        .unwrap_or("")
        .to_lowercase();
    let mut imported = ImportedRecording {
        id,
        title: path
            .file_stem()
            .and_then(|v| v.to_str())
            .unwrap_or("导入记录")
            .to_string(),
        created_at: metadata
            .modified()
            .ok()
            .and_then(|v| v.duration_since(UNIX_EPOCH).ok())
            .map_or(now, |v| v.as_secs()),
        duration_ms: 0,
        paragraphs: Vec::new(),
        minutes: None,
        has_audio: false,
    };
    match extension.as_str() {
        "wav" => {
            let wav = parse_pcm_wave(&bytes)?;
            imported.duration_ms = wav.duration_ms();
            save_audio(root, &imported.id, &bytes)?;
            imported.has_audio = true;
        }
        "txt" | "md" => {
            let text = std::str::from_utf8(&bytes).map_err(|_| "文件不是 UTF-8 文本")?;
            imported.paragraphs = text
                .lines()
                .map(str::trim)
                .filter(|v| !v.is_empty())
                .map(str::to_string)
                .collect();
            if imported.paragraphs.is_empty() {
                return Err("文件没有可导入的文字".into());
            }
        }
        "koepack" => {
            let pack = decode_koepack(&bytes).map_err(|e| e.to_string())?;
            imported.title = pack.material.title;
            if let Some(minutes) = pack.minutes {
                imported.paragraphs = minutes.current.sources;
                let mut spine = UtteranceSpine::new(&imported.id);
                for text in &imported.paragraphs {
                    spine.append_segment(text, 0, 0, "zh", "import");
                }
                imported.minutes = Some(
                    parse_meeting_minutes_json(&minutes.current.text, &spine)
                        .map_err(|e| format!("资料包纪要无效：{e:?}"))?,
                );
            }
            if imported.paragraphs.is_empty() {
                return Err("资料包没有可用的文字内容".into());
            }
        }
        _ => return Err("支持 WAV、TXT、Markdown 和 Koe 资料包".into()),
    }
    Ok(imported)
}

/// Resolves only generated asset names, never arbitrary relative paths.
pub fn audio_path(root: &Path, id: &str) -> Result<PathBuf, String> {
    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
        return Err("无效的录音标识".into());
    }
    Ok(root.join("audio").join(format!("{id}.wav")))
}

/// Resolves only generated Ogg Opus asset names, never arbitrary relative paths.
pub fn opus_path(root: &Path, id: &str) -> Result<PathBuf, String> {
    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
        return Err("无效的录音标识".into());
    }
    Ok(root.join("audio").join(format!("{id}.opus")))
}

/// Persists complete validated audio before a record is allowed to reference it.
pub fn save_audio(root: &Path, id: &str, bytes: &[u8]) -> Result<PathBuf, String> {
    parse_pcm_wave(bytes)?;
    let path = audio_path(root, id)?;
    if path.exists() {
        let existing = fs::read(&path).map_err(|e| format!("无法核对原录音：{e}"))?;
        if existing == bytes {
            return Ok(path);
        }
        return Err("录音内容已存在，不能覆盖原文所引用的音频".into());
    }
    write_atomic(&path, bytes).map_err(|e| format!("录音保存失败：{e}"))?;
    if let Some(parent) = path.parent() {
        fs::File::open(parent)
            .and_then(|f| f.sync_all())
            .map_err(|e| format!("录音落盘未完成：{e}"))?;
    }
    Ok(path)
}

/// Reads an owned audio asset and converts it to the provider's PCM format.
pub fn transcription_pcm(root: &Path, id: &str) -> Result<Vec<u8>, String> {
    let path = audio_path(root, id)?;
    let bytes = fs::read(path).map_err(|e| format!("无法读取录音：{e}"))?;
    Ok(parse_pcm_wave(&bytes)?.mono_16khz())
}

/// Convergently removes unreferenced `.wav` and `.opus` regular files in `<root>/audio/`.
pub fn reconcile_audio_directory(
    root: &Path,
    retained_filenames: &BTreeSet<String>,
) -> Result<usize, String> {
    let audio_dir = root.join("audio");
    let dir_meta = match fs::symlink_metadata(&audio_dir) {
        Ok(meta) => meta,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(e) => return Err(format!("无法读取音频目录：{e}")),
    };
    if dir_meta.file_type().is_symlink() || !dir_meta.file_type().is_dir() {
        return Err("音频目录路径无效或为符号链接".into());
    }
    let entries = fs::read_dir(&audio_dir).map_err(|e| format!("无法读取音频目录：{e}"))?;
    let mut removed = 0usize;
    for entry in entries {
        let entry = entry.map_err(|e| format!("无法遍历音频目录：{e}"))?;
        let path = entry.path();
        let meta = match fs::symlink_metadata(&path) {
            Ok(meta) => meta,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(format!("无法读取音频文件属性：{e}")),
        };
        if meta.file_type().is_symlink() || !meta.file_type().is_file() {
            continue;
        }
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        if !(name.ends_with(".wav") || name.ends_with(".opus")) {
            continue;
        }
        if retained_filenames.contains(&name)
            || retained_filenames
                .iter()
                .any(|retained| retained.eq_ignore_ascii_case(&name))
        {
            continue;
        }
        match fs::remove_file(&path) {
            Ok(()) => removed += 1,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(format!("无法删除已清除录音文件：{e}")),
        }
    }
    if removed > 0 {
        fs::File::open(&audio_dir)
            .and_then(|f| f.sync_all())
            .map_err(|e| format!("音频目录落盘失败：{e}"))?;
    }
    Ok(removed)
}
