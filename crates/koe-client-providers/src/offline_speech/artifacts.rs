use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use super::worker::Control;

pub(super) struct Artifact {
    pub(super) filename: &'static str,
    pub(super) url: String,
    pub(super) bytes: u64,
    pub(super) sha256: &'static str,
}

pub(super) fn artifact_for(model_id: &str) -> Result<Artifact, String> {
    let (filename, repository, revision, sha256) = match model_id {
        "sensevoice-small" => (
            "SenseVoiceSmall-Q8_0.gguf",
            "handy-computer/SenseVoiceSmall-gguf",
            "4a08b8e900b38a977e32eb08d5d0697d6e72ba04",
            "6c759ee4c9748c9b3f7a5a60ca74f0f7e685fb9d45d1378fce7cfd62f59adf29",
        ),
        "qwen3-asr-0.6b" => (
            "Qwen3-ASR-0.6B-Q8_0.gguf",
            "handy-computer/Qwen3-ASR-0.6B-gguf",
            "e4e16599b900eb0cb36e524514756bb92eb092b7",
            "f081b2d5e23bd669d92cc331d722a8a0681943b8e6f34b48996fd5c319b5acd8",
        ),
        _ => return Err(format!("unknown offline speech model: {model_id}")),
    };
    let bytes = super::offline_speech_models()
        .iter()
        .find(|model| model.id == model_id)
        .ok_or_else(|| format!("unknown offline speech model: {model_id}"))?
        .size_bytes;
    Ok(Artifact {
        filename,
        url: format!("https://huggingface.co/{repository}/resolve/{revision}/{filename}"),
        bytes,
        sha256,
    })
}

struct PartialArtifact(PathBuf);

impl Drop for PartialArtifact {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

fn verify(path: &Path, artifact: &Artifact, control: &Control, epoch: u64) -> Result<(), String> {
    let mut file = File::open(path).map_err(|error| format!("open model artifact: {error}"))?;
    let length = file
        .metadata()
        .map_err(|error| format!("inspect model artifact: {error}"))?
        .len();
    if length != artifact.bytes {
        return Err(format!(
            "model artifact length mismatch: expected {}, received {length}",
            artifact.bytes
        ));
    }
    let mut hash = Sha256::new();
    let mut buffer = [0; 64 * 1024];
    loop {
        control.check(epoch)?;
        let count = file
            .read(&mut buffer)
            .map_err(|error| format!("read model artifact: {error}"))?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    if hash
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>()
        != artifact.sha256
    {
        return Err("model artifact SHA-256 mismatch".into());
    }
    Ok(())
}

pub(super) async fn ensure_artifact(
    root: &Path,
    artifact: &Artifact,
    client: &reqwest::Client,
    control: &Control,
    epoch: u64,
    mut progress: impl FnMut(u64),
) -> Result<PathBuf, String> {
    control.check(epoch)?;
    let destination = root.join(artifact.filename);
    progress(0);
    if destination.exists() && verify(&destination, artifact, control, epoch).is_ok() {
        progress(artifact.bytes);
        return Ok(destination);
    }
    control.check(epoch)?;
    let partial = PartialArtifact(root.join(format!(
        "{}.{}.part",
        artifact.filename,
        uuid::Uuid::new_v4()
    )));
    let download = async {
        let mut response = client
            .get(&artifact.url)
            .send()
            .await
            .map_err(|error| format!("download model: {}", error.without_url()))?
            .error_for_status()
            .map_err(|error| format!("download model: {}", error.without_url()))?;
        if let Some(length) = response.content_length() {
            if length != artifact.bytes {
                return Err(format!(
                    "model download length mismatch: expected {}, received {length}",
                    artifact.bytes
                ));
            }
        }
        let mut file = File::create(&partial.0)
            .map_err(|error| format!("create partial model artifact: {error}"))?;
        let mut downloaded = 0;
        let mut hash = Sha256::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|error| format!("read model download: {}", error.without_url()))?
        {
            control.check(epoch)?;
            downloaded += chunk.len() as u64;
            if downloaded > artifact.bytes {
                return Err("model download exceeds expected artifact length".into());
            }
            file.write_all(&chunk)
                .map_err(|error| format!("write model artifact: {error}"))?;
            hash.update(&chunk);
            progress(downloaded);
        }
        if downloaded != artifact.bytes {
            return Err(format!(
                "model download is truncated: expected {}, received {downloaded}",
                artifact.bytes
            ));
        }
        if hash
            .finalize()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
            != artifact.sha256
        {
            return Err("model download SHA-256 mismatch".into());
        }
        file.sync_all()
            .map_err(|error| format!("sync model artifact: {error}"))?;
        drop(file);
        control.check(epoch)?;
        fs::rename(&partial.0, &destination)
            .map_err(|error| format!("publish verified model artifact: {error}"))?;
        File::open(root)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| format!("sync model directory: {error}"))?;
        Ok(destination)
    };
    tokio::select! {
        result = download => result,
        () = control.cancelled(epoch) => Err("offline model preparation cancelled".into()),
    }
}

#[cfg(test)]
mod tests;
