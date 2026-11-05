pub mod library;
pub mod mcp;
mod minutes;
pub mod organize;
pub mod recorder;
pub use library::{Library, Recording};
use serde::Serialize;
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::io::{BufReader, Read};

pub const MAX_MANIFEST_BYTES: usize = 32 * 1024 * 1024;
type Result<T> = std::result::Result<T, String>;

#[derive(Debug, Serialize)]
pub struct ReadingPack {
    pub title: String,
    pub text: Option<String>,
    pub segments: Vec<Value>,
    pub minutes: Option<Value>,
    /// The unmodified manifest preserves fields not projected by this reader.
    pub manifest: Value,
}

/// Reads one pack, validates its attached audio, and never writes any bytes.
pub fn read_pack(reader: impl Read) -> Result<ReadingPack> {
    let mut reader = BufReader::with_capacity(65536, reader);
    if line(&mut reader)? != b"KOEPACK1" {
        return Err("invalid pack magic".into());
    }
    let size = line(&mut reader)?;
    if size.is_empty() || !size.iter().all(u8::is_ascii_digit) {
        return Err("invalid manifest length".into());
    }
    let size: usize = std::str::from_utf8(&size)
        .map_err(|_| "invalid length")?
        .parse()
        .map_err(|_| "invalid length")?;
    if size == 0 || size > MAX_MANIFEST_BYTES {
        return Err("manifest exceeds 32 MiB or is empty".into());
    }
    let mut bytes = Vec::new();
    reader
        .by_ref()
        .take(size as u64)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("cannot read manifest: {e}"))?;
    if bytes.len() != size {
        return Err("truncated manifest".into());
    }
    let manifest: Value =
        serde_json::from_slice(&bytes).map_err(|e| format!("invalid manifest JSON: {e}"))?;
    let pack = validate(manifest)?;
    let audio = &pack.manifest["audio"];
    if audio["included"] == true {
        let count = integer(&audio["bytes"])?;
        if count == 0 {
            return Err("audio must not be empty".into());
        }
        let hash = string(&audio["sha256"])?;
        if !is_hash(hash) || hash != pack.manifest["material"]["contentHash"] {
            return Err("audio identity mismatch".into());
        }
        let ext = string(&audio["extension"])?;
        if !valid_extension(ext) {
            return Err("invalid audio extension".into());
        }
        let mut remaining = count;
        let mut digest = Sha256::new();
        let mut buffer = [0; 65536];
        while remaining > 0 {
            let n = (remaining.min(buffer.len() as u64)) as usize;
            let n = reader
                .read(&mut buffer[..n])
                .map_err(|e| format!("cannot read audio: {e}"))?;
            if n == 0 {
                return Err("truncated audio".into());
            }
            digest.update(&buffer[..n]);
            remaining -= n as u64;
        }
        if format!("{:x}", digest.finalize()) != hash {
            return Err("audio SHA-256 mismatch".into());
        }
    }
    let mut extra = [0];
    if reader
        .read(&mut extra)
        .map_err(|e| format!("cannot finish pack: {e}"))?
        != 0
    {
        return Err("unexpected trailing bytes".into());
    }
    Ok(pack)
}
fn line(reader: &mut impl Read) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    for _ in 0..=16 {
        let mut byte = [0];
        reader
            .read_exact(&mut byte)
            .map_err(|_| "truncated header")?;
        if byte[0] == b'\n' {
            return Ok(out);
        }
        out.push(byte[0]);
    }
    Err("header line too long".into())
}
fn validate(manifest: Value) -> Result<ReadingPack> {
    let root = object(&manifest)?;
    if manifest["format"] != "koe-material-pack" {
        return Err("unsupported pack format".into());
    }
    let version = integer(&manifest["version"])?;
    if ![1, 2].contains(&version) {
        return Err("unsupported pack version".into());
    }
    if version == 1 && root.contains_key("minutes") {
        return Err("version 1 cannot carry minutes".into());
    }
    date(&manifest["exportedAt"])?;
    let material = &manifest["material"];
    object(material)?;
    if !is_hash(string(&material["contentHash"])?) {
        return Err("invalid material identity".into());
    }
    let title = nonempty(&material["title"])?.to_owned();
    nonempty(&material["source"])?;
    if present(&material["recordedAt"]) {
        date(&material["recordedAt"])?;
    }
    if present(&material["deviceFileId"]) {
        integer(&material["deviceFileId"])?;
    }
    if present(&material["audioExtension"])
        && !valid_extension(string(&material["audioExtension"])?)
    {
        return Err("invalid original extension".into());
    }
    object(&manifest["audio"])?;
    manifest["audio"]["included"]
        .as_bool()
        .ok_or("audio.included must be boolean")?;
    let mut text = None;
    let mut segments = Vec::new();
    let transcript = &manifest["transcript"];
    if present(transcript) {
        object(transcript)?;
        for key in ["text", "manual", "provider", "sourceLanguage"] {
            if present(&transcript[key]) {
                string(&transcript[key])?;
            }
        }
        text = transcript["manual"]
            .as_str()
            .or(transcript["text"].as_str())
            .map(str::to_owned);
        if present(&transcript["revision"]) {
            integer(&transcript["revision"])?;
        }
        if present(&transcript["segments"]) {
            for segment in array(&transcript["segments"])? {
                object(segment)?;
                nonempty(&segment["text"])?;
                let start = integer(&segment["startMs"])?;
                if present(&segment["endMs"]) && integer(&segment["endMs"])? < start {
                    return Err("segment ends before start".into());
                }
                if present(&segment["speaker"]) {
                    string(&segment["speaker"])?;
                }
                if present(&segment["speakerChanged"]) {
                    segment["speakerChanged"]
                        .as_bool()
                        .ok_or("invalid speakerChanged")?;
                }
                segments.push(segment.clone());
            }
        }
        let mut corrections = std::collections::BTreeMap::new();
        if present(&transcript["segmentSpeakers"]) {
            for (key, value) in object(&transcript["segmentSpeakers"])? {
                let index: usize = key
                    .parse()
                    .map_err(|_| "invalid speaker correction index")?;
                if index >= segments.len()
                    || corrections.insert(index, string(value)?.trim()).is_some()
                {
                    return Err("invalid or duplicate speaker correction index".into());
                }
            }
        }
        let aliases = if present(&transcript["speakerAliases"]) {
            Some(object(&transcript["speakerAliases"])?)
        } else {
            None
        };
        if let Some(aliases) = aliases {
            for value in aliases.values() {
                string(value)?;
            }
        }
        let mut previous_speaker: Option<String> = None;
        for (i, segment) in segments.iter_mut().enumerate() {
            let speaker = corrections
                .get(&i)
                .copied()
                .or(segment["speaker"].as_str())
                .map(str::trim)
                .filter(|s| !s.is_empty());
            let speaker_changed = speaker.is_some() && speaker != previous_speaker.as_deref();
            previous_speaker = speaker.map(str::to_owned);
            let speaker = speaker.map(|s| {
                aliases
                    .and_then(|a| a.get(s))
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .unwrap_or(s)
                    .to_owned()
            });
            segment["speaker"] = speaker.map(Value::String).unwrap_or(Value::Null);
            segment["speakerChanged"] = Value::Bool(speaker_changed);
            if segment.get("endMs").is_none() {
                segment["endMs"] = Value::Null;
            }
        }
    }
    if present(&manifest["bookmarks"]) {
        for bookmark in array(&manifest["bookmarks"])? {
            object(bookmark)?;
            nonempty(&bookmark["id"])?;
            integer(&bookmark["positionMs"])?;
            date(&bookmark["createdAt"])?;
            date(&bookmark["updatedAt"])?;
        }
    }
    let minutes = if present(&manifest["minutes"]) {
        minutes::validate(&manifest["minutes"])?;
        Some(manifest["minutes"].clone())
    } else {
        None
    };
    Ok(ReadingPack {
        title,
        text,
        segments,
        minutes,
        manifest,
    })
}
fn present(v: &Value) -> bool {
    !v.is_null()
}
fn object(v: &Value) -> Result<&Map<String, Value>> {
    v.as_object().ok_or_else(|| "expected object".into())
}
fn array(v: &Value) -> Result<&Vec<Value>> {
    v.as_array().ok_or_else(|| "expected array".into())
}
fn string(v: &Value) -> Result<&str> {
    v.as_str().ok_or_else(|| "expected string".into())
}
fn nonempty(v: &Value) -> Result<&str> {
    let s = string(v)?;
    if s.trim().is_empty() {
        Err("expected nonempty string".into())
    } else {
        Ok(s)
    }
}
fn integer(v: &Value) -> Result<u64> {
    v.as_u64()
        .filter(|n| *n <= i64::MAX as u64)
        .ok_or_else(|| "expected nonnegative integer".into())
}
fn is_hash(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn valid_extension(s: &str) -> bool {
    s.starts_with('.')
        && (2..=9).contains(&s.len())
        && s.as_bytes()[1..].iter().all(u8::is_ascii_alphanumeric)
}
fn date(v: &Value) -> Result<()> {
    let s = string(v)?;
    if chrono::DateTime::parse_from_rfc3339(s).is_ok()
        || chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S%.f").is_ok()
    {
        Ok(())
    } else {
        Err("invalid ISO date".into())
    }
}
