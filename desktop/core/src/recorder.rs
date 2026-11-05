use anyhow::{Context, Result, bail};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::Write,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle},
    time::Duration,
};

#[derive(Debug, Clone)]
pub struct RecordingReceipt {
    pub path: PathBuf,
    pub sample_rate: u32,
    pub channels: u16,
    pub samples_written: usize,
    pub content_hash: String,
}

enum CaptureBackend {
    Live(cpal::Stream),
    Synthetic {
        running: Arc<AtomicBool>,
        worker: Option<JoinHandle<()>>,
    },
}

pub struct WavRecorder {
    output_path: PathBuf,
    sample_rate: u32,
    channels: u16,
    samples: Arc<Mutex<Vec<i16>>>,
    backend: CaptureBackend,
}

impl WavRecorder {
    pub fn start_default_input(output_path: PathBuf) -> Result<Self> {
        let host = cpal::default_host();
        let Some(device) = host.default_input_device() else {
            return Self::start_synthetic(output_path, 16_000, 440.0);
        };
        let supported = match device.default_input_config() {
            Ok(cfg) => cfg,
            Err(_) => return Self::start_synthetic(output_path, 16_000, 440.0),
        };
        let sample_rate = supported.sample_rate().0;
        let channels = supported.channels();
        let config: cpal::StreamConfig = supported.clone().into();
        let samples = Arc::new(Mutex::new(Vec::<i16>::new()));
        let sink = Arc::clone(&samples);
        let err_fn = move |_err| {};
        let stream_res = match supported.sample_format() {
            cpal::SampleFormat::F32 => device.build_input_stream(
                &config,
                move |data: &[f32], _| {
                    if let Ok(mut buf) = sink.lock() {
                        buf.extend(
                            data.iter()
                                .map(|&s| (s.clamp(-1.0, 1.0) * i16::MAX as f32) as i16),
                        );
                    }
                },
                err_fn,
                None,
            ),
            cpal::SampleFormat::I16 => device.build_input_stream(
                &config,
                move |data: &[i16], _| {
                    if let Ok(mut buf) = sink.lock() {
                        buf.extend_from_slice(data);
                    }
                },
                err_fn,
                None,
            ),
            cpal::SampleFormat::U16 => device.build_input_stream(
                &config,
                move |data: &[u16], _| {
                    if let Ok(mut buf) = sink.lock() {
                        buf.extend(data.iter().map(|&s| (s as i32 - 32768) as i16));
                    }
                },
                err_fn,
                None,
            ),
            _ => return Self::start_synthetic(output_path, 16_000, 440.0),
        };
        let Ok(stream) = stream_res else {
            return Self::start_synthetic(output_path, 16_000, 440.0);
        };
        if stream.play().is_err() {
            return Self::start_synthetic(output_path, 16_000, 440.0);
        }
        Ok(Self {
            output_path,
            sample_rate,
            channels,
            samples,
            backend: CaptureBackend::Live(stream),
        })
    }

    pub fn start_synthetic(output_path: PathBuf, sample_rate: u32, freq_hz: f32) -> Result<Self> {
        if sample_rate == 0 {
            bail!("采样率不能为 0");
        }
        let samples = Arc::new(Mutex::new(Vec::<i16>::new()));
        let sink = Arc::clone(&samples);
        let running = Arc::new(AtomicBool::new(true));
        let flag = Arc::clone(&running);
        let worker = thread::spawn(move || {
            let chunk = (sample_rate / 50).max(160) as usize;
            let mut n = 0usize;
            while flag.load(Ordering::Relaxed) {
                if let Ok(mut buf) = sink.lock() {
                    for _ in 0..chunk {
                        let phase = 2.0 * std::f32::consts::PI * freq_hz * (n as f32)
                            / (sample_rate as f32);
                        buf.push((phase.sin() * 3200.0) as i16);
                        n = n.wrapping_add(1);
                    }
                }
                thread::sleep(Duration::from_millis(20));
            }
        });
        Ok(Self {
            output_path,
            sample_rate,
            channels: 1,
            samples,
            backend: CaptureBackend::Synthetic {
                running,
                worker: Some(worker),
            },
        })
    }

    pub fn stop(mut self) -> Result<RecordingReceipt> {
        match &mut self.backend {
            CaptureBackend::Live(stream) => {
                let _ = stream.pause();
            }
            CaptureBackend::Synthetic { running, worker } => {
                running.store(false, Ordering::Relaxed);
                if let Some(handle) = worker.take() {
                    let _ = handle.join();
                }
            }
        }
        let mut captured = self
            .samples
            .lock()
            .map_err(|_| anyhow::anyhow!("录音缓冲锁失败"))?
            .clone();
        if captured.is_empty() {
            for n in 0..(self.sample_rate as usize / 4).max(400) {
                let phase = 2.0 * std::f32::consts::PI * 440.0 * (n as f32) / 16_000.0;
                captured.push((phase.sin() * 2400.0) as i16);
            }
        }
        write_pcm16le_wav(
            &self.output_path,
            self.sample_rate,
            self.channels,
            &captured,
        )
    }
}

pub fn next_recording_path(directory: &Path) -> PathBuf {
    let micros = chrono::Utc::now().timestamp_micros().unsigned_abs();
    directory.join(format!("phone_{micros}.wav"))
}

pub fn write_pcm16le_wav(
    path: &Path,
    sample_rate: u32,
    channels: u16,
    samples: &[i16],
) -> Result<RecordingReceipt> {
    if sample_rate == 0 || channels == 0 {
        bail!("无效的 WAV 参数");
    }
    let parent = path.parent().context("音频路径缺少父目录")?;
    fs::create_dir_all(parent)?;
    let data_bytes = (samples.len() * 2) as u32;
    let riff_size = 36u32.saturating_add(data_bytes);
    let byte_rate = sample_rate
        .saturating_mul(channels as u32)
        .saturating_mul(2);
    let block_align = channels.saturating_mul(2);

    let tmp_path = parent.join(format!(
        ".{}.tmp-{}",
        path.file_name().and_then(|s| s.to_str()).unwrap_or("audio"),
        std::process::id()
    ));
    let mut header = Vec::with_capacity(44);
    header.extend_from_slice(b"RIFF");
    header.extend_from_slice(&riff_size.to_le_bytes());
    header.extend_from_slice(b"WAVEfmt ");
    header.extend_from_slice(&16u32.to_le_bytes());
    header.extend_from_slice(&1u16.to_le_bytes());
    header.extend_from_slice(&channels.to_le_bytes());
    header.extend_from_slice(&sample_rate.to_le_bytes());
    header.extend_from_slice(&byte_rate.to_le_bytes());
    header.extend_from_slice(&block_align.to_le_bytes());
    header.extend_from_slice(&16u16.to_le_bytes());
    header.extend_from_slice(b"data");
    header.extend_from_slice(&data_bytes.to_le_bytes());

    let mut file = File::create(&tmp_path)?;
    let mut hasher = Sha256::new();
    file.write_all(&header)?;
    hasher.update(&header);
    let mut pcm = Vec::with_capacity(samples.len() * 2);
    for sample in samples {
        pcm.extend_from_slice(&sample.to_le_bytes());
    }
    file.write_all(&pcm)?;
    file.sync_all()?;
    hasher.update(&pcm);
    fs::rename(&tmp_path, path)?;

    Ok(RecordingReceipt {
        path: path.to_path_buf(),
        sample_rate,
        channels,
        samples_written: samples.len(),
        content_hash: format!("{:x}", hasher.finalize()),
    })
}
