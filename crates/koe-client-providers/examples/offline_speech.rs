use std::path::PathBuf;
use std::thread;
use std::time::{Duration, Instant};

use koe_client_providers::{OfflineSpeechEvent, OfflineSpeechWorker};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 4 {
        return Err("usage: offline_speech MODEL_DIRECTORY MODEL_ID AUDIO.wav".into());
    }
    let mut wav = hound::WavReader::open(&args[3])?;
    let spec = wav.spec();
    if spec.sample_rate != 16_000
        || spec.channels != 1
        || spec.bits_per_sample != 16
        || spec.sample_format != hound::SampleFormat::Int
    {
        return Err("input must be 16 kHz mono PCM16 WAV".into());
    }
    let samples = wav.samples::<i16>().collect::<Result<Vec<_>, _>>()?;
    println!("audio_samples={} sample_rate=16000", samples.len());
    let worker = OfflineSpeechWorker::new(PathBuf::from(&args[1]))?;
    worker.prepare(&args[2])?;
    let deadline = Instant::now() + Duration::from_secs(20 * 60);
    let mut submitted = false;
    let mut progress_percent = None;
    loop {
        for event in worker.poll() {
            match event {
                OfflineSpeechEvent::Preparing {
                    downloaded_bytes,
                    total_bytes,
                    ..
                } => {
                    let percent = downloaded_bytes * 100 / total_bytes;
                    if progress_percent != Some(percent) {
                        println!("model_download={downloaded_bytes}/{total_bytes} ({percent}%)");
                        progress_percent = Some(percent);
                    }
                }
                OfflineSpeechEvent::Ready { model_id } => {
                    println!("model_loaded={model_id}");
                    worker.transcribe(1, samples.clone())?;
                    submitted = true;
                }
                OfflineSpeechEvent::Transcribed {
                    operation_id,
                    text,
                    segments,
                } => {
                    println!("operation_id={operation_id} text={text:?}");
                    for segment in segments {
                        println!(
                            "{}..{} {:?}",
                            segment.start_ms, segment.end_ms, segment.text
                        );
                    }
                    if !submitted || text.trim().is_empty() {
                        return Err(
                            "recognition did not produce text for the supplied speech".into()
                        );
                    }
                    return Ok(());
                }
                OfflineSpeechEvent::PreparationFailed { error, .. }
                | OfflineSpeechEvent::TranscriptionFailed { error, .. } => return Err(error.into()),
            }
        }
        if Instant::now() >= deadline {
            worker.cancel();
            return Err("offline speech verification timed out".into());
        }
        thread::sleep(Duration::from_millis(20));
    }
}
