use super::*;
use koe_client_base::{hash::sha256_hex, write_atomic};
use koe_engine::session::CustodyReceipt;
use std::fs;

impl KoeRuntime {
    pub(super) fn save_device_recordings(&mut self, now: u64) -> Result<(), String> {
        while !self.device.finalized.is_empty() {
            let recording = &self.device.finalized[0];
            let entry = recording.entry.clone();
            let digest = sha256_hex(&recording.ogg_opus_bytes);
            let capture_id = self.captures.targets.front().cloned().flatten();
            let id = capture_id
                .clone()
                .unwrap_or_else(|| format!("bean-{}-{}", entry.id, &digest[..16]));
            let is_new = self.workspace().record(&id).is_none();
            let has_audio = !recording.preview_wav_bytes.is_empty();
            if has_audio {
                recording_assets::save_audio(&self.root, &id, &recording.preview_wav_bytes)?;
            }
            fs::create_dir_all(self.root.join("audio")).map_err(|e| e.to_string())?;
            let opus_path = self.root.join("audio").join(format!("{id}.opus"));
            write_atomic(&opus_path, &recording.ogg_opus_bytes)
                .map_err(|e| format!("原始录音保存失败：{e}"))?;
            fs::File::open(self.root.join("audio"))
                .and_then(|f| f.sync_all())
                .map_err(|e| format!("录音尚未完成落盘：{e}"))?;
            let receipt = CustodyReceipt {
                file_id: entry.id,
                byte_count: recording.ogg_opus_bytes.len() as u32,
                sha256_hex: sha256_hex(&recording.ogg_opus_bytes),
                fsynced_at_epoch_sec: now,
            };
            self.commit(|w| {
                w.insert_record(
                    id.clone(),
                    format!("录音 {}", entry.id),
                    RecordOrigin::Bean,
                    entry.id,
                    entry.created_at_epoch_sec,
                    entry.duration_ms,
                )?;
                w.finish_capture(&id, entry.duration_ms, &entry.marks_ms)
            })?;
            self.device.session.confirm_disk_custody(receipt);
            self.device.finalized.remove(0);
            self.captures.targets.pop_front();
            self.error = None;
            self.notice = Some(
                if has_audio {
                    "录音已取回并保存"
                } else {
                    "原始录音已保留，音频解码失败，暂时无法播放或转写"
                }
                .into(),
            );
            let had_live = self.capture_saved(&id);
            if has_audio && !had_live && (is_new || capture_id.is_some()) {
                self.auto_transcribe.insert(id);
            }
        }
        Ok(())
    }

    pub(super) fn export_record(&mut self, id: &str, path: &Path) -> Result<(), String> {
        let record = self.workspace().record(id).ok_or("记录不存在")?;
        let mut output = format!("# {}\n\n", record.title);
        if let Some(minutes) = &record.aggregate.minutes {
            output.push_str(&format!("{}\n\n", minutes.overview));
            for topic in &minutes.topics {
                output.push_str(&format!("## {}\n\n{}\n\n", topic.title, topic.summary));
            }
        }
        output.push_str("## 原文\n\n");
        for segment in record.aggregate.spine.segments() {
            output.push_str(&format!("[{}] {}\n\n", segment.id, segment.text));
        }
        write_atomic(path, output.as_bytes()).map_err(|e| format!("导出失败：{e}"))?;
        self.notice = Some("已导出 Markdown".into());
        Ok(())
    }
}
