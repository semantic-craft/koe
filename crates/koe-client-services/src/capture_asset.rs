//! Bounded streaming PCM assets, published before product metadata references them.
use crate::recording_assets::audio_path;
use std::{
    fs::{self, File, OpenOptions},
    io::{Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};

/// The result of admitting one block to a finite WAV container.
#[derive(Debug, PartialEq, Eq)]
pub enum AppendOutcome {
    /// The entire block was written.
    Written,
    /// The accepted prefix is intact; stop instead of retrying this block.
    CapacityReached,
}

/// One native mono PCM16 stream. Its unpublished file is never a successful record.
pub struct CaptureAsset {
    file: File,
    staging: PathBuf,
    target: PathBuf,
    sample_rate: u32,
    samples: u64,
    published: bool,
}
impl CaptureAsset {
    /// Creates a uniquely named stream without replacing any existing asset.
    pub fn create(root: &Path, id: &str, sample_rate: u32) -> Result<Self, String> {
        if !(8_000..=96_000).contains(&sample_rate) {
            return Err("麦克风采样率不受支持".into());
        }
        let target = audio_path(root, id)?;
        fs::create_dir_all(target.parent().ok_or("无效音频目录")?).map_err(io_error)?;
        let staging = target.with_extension("capture");
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&staging)
            .map_err(io_error)?;
        Ok(Self {
            file,
            staging,
            target,
            sample_rate,
            samples: 0,
            published: false,
        })
    }
    /// Appends one bounded block. Retrying rewinds any incomplete previous write.
    pub fn append(&mut self, samples: &[i16]) -> Result<AppendOutcome, String> {
        if self.published || samples.is_empty() || samples.len() > 8192 {
            return Err("麦克风音频块无效或过大".into());
        }
        let next = self.samples + samples.len() as u64;
        if next * 2 > u32::MAX as u64 - 36 {
            return Ok(AppendOutcome::CapacityReached);
        }
        let offset = 44 + self.samples * 2;
        self.file.set_len(offset).map_err(io_error)?;
        self.file.seek(SeekFrom::Start(offset)).map_err(io_error)?;
        let bytes: Vec<u8> = samples.iter().flat_map(|v| v.to_le_bytes()).collect();
        self.file.write_all(&bytes).map_err(io_error)?;
        let header =
            koe_engine::wav::OpusWave::wav_header_with_rate((next * 2) as u32, self.sample_rate);
        self.file.seek(SeekFrom::Start(0)).map_err(io_error)?;
        self.file.write_all(&header).map_err(io_error)?;
        self.file.sync_data().map_err(io_error)?;
        self.samples = next;
        Ok(AppendOutcome::Written)
    }
    /// Recovers a validated, durably checkpointed stream after its producer has exited.
    pub fn recover(root: &Path, id: &str) -> Result<Option<u64>, String> {
        let target = audio_path(root, id)?;
        let staging = target.with_extension("capture");
        let bytes = match fs::read(&staging) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(io_error(e)),
        };
        let wave = koe_engine::wav::parse_pcm_wave(&bytes)
            .map_err(|e| format!("未完成录音格式无效：{e:?}"))?;
        let duration = wave.duration_ms();
        if !target.exists() {
            fs::hard_link(&staging, &target).map_err(io_error)?;
        }
        File::open(&target)
            .and_then(|f| f.sync_all())
            .map_err(io_error)?;
        File::open(target.parent().ok_or("无效音频目录")?)
            .and_then(|f| f.sync_all())
            .map_err(io_error)?;
        Ok(Some(duration))
    }
    /// Releases a recovered staging name only after its recording metadata commits.
    pub fn release_recovered(root: &Path, id: &str) -> Result<(), String> {
        let staging = audio_path(root, id)?.with_extension("capture");
        match fs::remove_file(staging) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(io_error(e)),
        }
    }
    /// Duration derived from accepted frames, never from host timers.
    pub fn duration_ms(&self) -> u64 {
        self.samples * 1000 / u64::from(self.sample_rate)
    }
    /// Whether the stream contains audio.
    pub fn is_empty(&self) -> bool {
        self.samples == 0
    }
    /// Seals and durably publishes the file. Every retry repeats durability barriers.
    pub fn publish(&mut self) -> Result<(), String> {
        let size = (self.samples * 2) as u32;
        if !self.published {
            let mut header = Vec::with_capacity(44);
            header.extend_from_slice(b"RIFF");
            header.extend_from_slice(&(size + 36).to_le_bytes());
            header.extend_from_slice(b"WAVEfmt ");
            header.extend_from_slice(&16u32.to_le_bytes());
            header.extend_from_slice(&1u16.to_le_bytes());
            header.extend_from_slice(&1u16.to_le_bytes());
            header.extend_from_slice(&self.sample_rate.to_le_bytes());
            header.extend_from_slice(&(self.sample_rate * 2).to_le_bytes());
            header.extend_from_slice(&2u16.to_le_bytes());
            header.extend_from_slice(&16u16.to_le_bytes());
            header.extend_from_slice(b"data");
            header.extend_from_slice(&size.to_le_bytes());
            self.file.seek(SeekFrom::Start(0)).map_err(io_error)?;
            self.file.write_all(&header).map_err(io_error)?;
            self.file.set_len(44 + u64::from(size)).map_err(io_error)?;
            self.file.sync_all().map_err(io_error)?;
            // A hard link publishes atomically without replacing another recording.
            fs::hard_link(&self.staging, &self.target).map_err(io_error)?;
            self.published = true;
        }
        self.file.sync_all().map_err(io_error)?;
        File::open(self.target.parent().ok_or("无效音频目录")?)
            .and_then(|f| f.sync_all())
            .map_err(io_error)?;
        Ok(())
    }
    /// Removes only this session's unpublished spool after producer termination.
    pub fn discard(&mut self) -> Result<(), String> {
        if self.published {
            return Err("音频已提交，不能丢弃待保存的记录".into());
        }
        match fs::remove_file(&self.staging) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(io_error(e)),
        }
    }
    /// Removes the redundant staging name only after metadata has committed.
    pub fn release_staging(&self) {
        let _ = fs::remove_file(&self.staging);
    }
}
fn io_error(e: std::io::Error) -> String {
    format!("麦克风录音保存失败：{e}")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn wav_capacity_stops_without_overwriting_the_accepted_prefix() {
        let root = std::env::temp_dir().join(format!("koe-wav-limit-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let mut asset = CaptureAsset::create(&root, "mic-capacity", 16000).unwrap();
        asset.append(&[7, 8]).unwrap();
        let original = fs::read(&asset.staging).unwrap();
        asset.samples = (u32::MAX as u64 - 36) / 2 - 1;
        let result = asset.append(&[9, 10]);
        let after = fs::read(&asset.staging).unwrap();
        asset.discard().unwrap();
        fs::remove_dir_all(&root).unwrap();
        assert_eq!(after, original);
        assert_eq!(result.unwrap(), AppendOutcome::CapacityReached);
    }
}
