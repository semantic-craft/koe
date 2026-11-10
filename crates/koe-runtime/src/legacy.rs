use super::*;
use koe_client_base::hash::sha256_hex;
use koe_engine::wav::{parse_pcm_wave, OpusWave};
use ogg::reading::PacketReader;
use serde::Deserialize;
use std::fs;
use std::io::Cursor;
use std::time::UNIX_EPOCH;

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacySession {
    #[serde(default)]
    active_file_id: u32,
    #[serde(default)]
    duration_ms: u64,
    #[serde(default)]
    segments: Vec<LegacySegment>,
    #[serde(default)]
    bookmarks: Vec<u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacySegment {
    text: String,
    #[serde(default)]
    start_ms: u64,
    #[serde(default)]
    end_ms: u64,
    speaker: Option<String>,
    provider: Option<String>,
}

#[derive(Default)]
struct AudioFiles {
    wav: Option<PathBuf>,
    opus: Option<PathBuf>,
}

struct RestoredAudio {
    id: String,
    file_id: u32,
    created: u64,
    duration: u64,
}

impl KoeRuntime {
    pub(super) fn restore_legacy(&mut self) -> Result<(), String> {
        let path = self.root.join("workspace_session.json");
        let legacy = match fs::read(&path) {
            Ok(bytes) => Some(
                serde_json::from_slice::<LegacySession>(&bytes)
                    .map_err(|_| "旧工作区损坏，已保留原文件".to_string())?,
            ),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => return Err(format!("旧工作区无法读取：{error}")),
        };
        let mut files: BTreeMap<String, AudioFiles> = BTreeMap::new();
        for entry in fs::read_dir(&self.root).map_err(|e| format!("旧录音目录无法读取：{e}"))?
        {
            let entry = entry.map_err(|e| format!("旧录音目录无法读取：{e}"))?;
            if !entry.file_type().map_err(|e| e.to_string())?.is_file() {
                continue;
            }
            let path = entry.path();
            let Some(stem) = path.file_stem().and_then(|name| name.to_str()) else {
                continue;
            };
            let stem = stem.to_string();
            let extension = path
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            if extension == "wav" {
                files.entry(stem).or_default().wav = Some(path);
            } else if extension == "opus" {
                files.entry(stem).or_default().opus = Some(path);
            }
        }
        let mut audio = Vec::new();
        let mut unavailable = 0;
        for (stem, paths) in files {
            let (record, playable) = restore_audio(&self.root, &stem, paths)?;
            if !playable {
                unavailable += 1;
            }
            audio.push(record);
        }
        if audio.is_empty() && legacy.is_none() {
            return Ok(());
        }
        let legacy_created = modified_epoch(&path);
        self.commit(|workspace| {
            for record in audio {
                let title = if record.file_id > 0 {
                    format!("录音 {}", record.file_id)
                } else {
                    "恢复的录音".to_string()
                };
                workspace.insert_record(
                    record.id,
                    title,
                    RecordOrigin::Bean,
                    record.file_id,
                    record.created,
                    record.duration,
                )?;
            }
            if let Some(legacy) = legacy {
                let id = if legacy.active_file_id > 0 {
                    format!("bean-{}", legacy.active_file_id)
                } else {
                    "legacy-workspace".to_string()
                };
                workspace.insert_record(
                    id.clone(),
                    "恢复的记录".into(),
                    RecordOrigin::ImportedText,
                    legacy.active_file_id,
                    legacy_created,
                    legacy.duration_ms,
                )?;
                for segment in legacy.segments {
                    if segment.text.trim().is_empty() {
                        continue;
                    }
                    let segment_id = workspace.append_transcript(
                        &id,
                        &segment.text,
                        segment.start_ms,
                        segment.end_ms,
                        segment.provider.as_deref().unwrap_or("recovered"),
                    )?;
                    workspace.name_speaker(
                        &SourceRef {
                            record_id: id.clone(),
                            segment_id,
                        },
                        segment.speaker,
                    )?;
                }
                let duration = workspace
                    .record(&id)
                    .ok_or(ProductError::UnknownRecord)?
                    .aggregate
                    .duration_ms
                    .max(legacy.duration_ms);
                if legacy.bookmarks.iter().any(|mark| *mark > duration) {
                    return Err(ProductError::InvalidInput(
                        "旧记录标记超出录音长度，已保留原文件".to_string(),
                    ));
                }
                workspace.finish_capture(&id, duration, &legacy.bookmarks)?;
            }
            Ok(())
        })?;
        self.notice = Some(if unavailable > 0 {
            format!("已恢复旧记录；{unavailable} 条原始音频无法解码，暂不能播放。原文件均已保留。")
        } else {
            "已恢复旧记录，原文件均已保留。".to_string()
        });
        Ok(())
    }
}

fn restore_audio(
    root: &Path,
    stem: &str,
    paths: AudioFiles,
) -> Result<(RestoredAudio, bool), String> {
    let source = paths
        .wav
        .as_ref()
        .or(paths.opus.as_ref())
        .ok_or("旧录音缺少文件")?;
    let primary =
        fs::read(source).map_err(|e| format!("旧录音 {} 无法读取：{e}", source.display()))?;
    let file_id = stem.parse::<u32>().ok();
    let id = file_id.map_or_else(
        || format!("import-{}", sha256_hex(&primary)),
        |id| format!("bean-{id}"),
    );
    let mut decoded = if paths.wav.is_some() && parse_pcm_wave(&primary).is_ok() {
        Some(primary.clone())
    } else {
        None
    };
    if decoded.is_none() {
        if let Some(path) = &paths.opus {
            let bytes = if paths.wav.is_none() {
                primary
            } else {
                fs::read(path).map_err(|e| format!("旧录音 {} 无法读取：{e}", path.display()))?
            };
            decoded = decode_ogg_opus(&bytes).ok();
        }
    }
    let mut duration = 0;
    if let Some(bytes) = &decoded {
        duration = parse_pcm_wave(bytes)?.duration_ms();
        recording_assets::save_audio(root, &id, bytes)?;
    }
    Ok((
        RestoredAudio {
            id,
            file_id: file_id.unwrap_or(0),
            created: modified_epoch(source),
            duration,
        },
        decoded.is_some(),
    ))
}

fn modified_epoch(path: &Path) -> u64 {
    fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |duration| duration.as_secs())
}

fn decode_ogg_opus(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut reader = PacketReader::new(Cursor::new(bytes));
    let head = reader.read_packet_expected().map_err(|e| e.to_string())?;
    let header = &head.data;
    if header.len() < 19
        || &header[..8] != b"OpusHead"
        || header[8] != 1
        || header[9] != 1
        || header[18] != 0
    {
        return Err("不支持的 Opus 文件头".into());
    }
    if i16::from_le_bytes([header[16], header[17]]) != 0 {
        return Err("不支持的 Opus 输出增益".into());
    }
    let pre_skip = usize::from(u16::from_le_bytes([header[10], header[11]]));
    let serial = head.stream_serial();
    let tags = reader.read_packet_expected().map_err(|e| e.to_string())?;
    if tags.stream_serial() != serial || !tags.data.starts_with(b"OpusTags") {
        return Err("Opus 标签缺失".into());
    }
    let mut decoder = koe_opus::create_libopus_decoder(48_000).ok_or("Opus 解码器不可用")?;
    let mut pcm = Vec::new();
    let mut end = None;
    while let Some(packet) = reader.read_packet().map_err(|e| e.to_string())? {
        if packet.stream_serial() != serial || end.is_some() {
            return Err("不支持多个 Opus 流".into());
        }
        if !decoder.decode_trimmed_packet(&packet.data, &mut pcm) {
            return Err("Opus 音频包无法解码".into());
        }
        if pcm.len() > 512 * 1024 * 1024 {
            return Err("Opus 音频超出单次恢复大小".into());
        }
        if packet.last_in_stream() {
            end = Some(packet.absgp_page());
        }
    }
    let end = usize::try_from(end.ok_or("Opus 音频未完整结束")?).map_err(|_| "Opus 时间轴无效")?;
    if end > pcm.len() / 2 || end <= pre_skip {
        return Err("Opus 时间轴无效".into());
    }
    let pcm = &pcm[pre_skip * 2..end * 2];
    let mut wav = OpusWave::wav_header_with_rate(pcm.len() as u32, 48_000).to_vec();
    wav.extend_from_slice(pcm);
    Ok(wav)
}
