//! Portable `.koepack v1/v2` material pack decoder.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

use std::fmt;

use crate::domain::UtteranceSpine;
use crate::hash::{is_valid_sha256_hex, sha256_hex};
use crate::minutes::{parse_meeting_minutes_json, JsonValue};

/// First-line ASCII magic header for every `.koepack` archive (`"KOEPACK1"`).
pub const KOEPACK_MAGIC: &str = "KOEPACK1";

/// Required manifest `format` identifier for Koe material packs (`"koe-material-pack"`).
pub const KOEPACK_FORMAT_NAME: &str = "koe-material-pack";

/// Maximum manifest UTF-8 byte length permitted in a `.koepack` header (`32 MiB`).
pub const KOEPACK_MAX_MANIFEST_BYTES: usize = 32 * 1024 * 1024;

/// Maximum portable minutes history snapshots carried in a `.koepack v2` archive (`10`).
pub const KOEPACK_MAX_MINUTES_HISTORY: usize = 10;

/// Portable structured minutes snapshot carried inside a `.koepack v2` manifest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PortableMinutesEntry {
    /// Validated `MeetingMinutes` JSON string.
    pub text: String,
    /// Lowercase 64-hex SHA-256 of `sources.join("\n")`.
    pub source_hash: String,
    /// Model identifier used to generate the minutes.
    pub model: String,
    /// Prompt instruction used to generate the minutes.
    pub instruction: String,
    /// Source blocks (`S1..Sn`) backing the minutes citations.
    pub sources: Vec<String>,
    /// ISO-8601 creation timestamp.
    pub created_at_iso: String,
    /// Optional ISO-8601 manual edit timestamp.
    pub edited_at_iso: Option<String>,
    /// Optional template identifier.
    pub template_id: Option<String>,
    /// Template version (`>= 1`).
    pub template_version: u32,
    /// Whether this entry is a live/rolling draft (`true`) or formal post-meeting minutes (`false`).
    pub is_draft: bool,
}

impl PortableMinutesEntry {
    /// Validates `source_hash`, metadata fields, and `S1..Sn` grounding of `text` against `sources`.
    pub fn validate(&self) -> Result<(), MaterialPackError> {
        if !is_valid_sha256_hex(&self.source_hash) {
            return Err(MaterialPackError::InvalidMinutesEvidence(
                "invalid sourceHash hex".to_string(),
            ));
        }
        let expected_hash = sha256_hex(self.sources.join("\n").as_bytes());
        if self.source_hash != expected_hash {
            return Err(MaterialPackError::InvalidMinutesEvidence(
                "sourceHash does not match sources".to_string(),
            ));
        }
        if self.model.trim().is_empty()
            || self.created_at_iso.trim().is_empty()
            || self.template_version < 1
        {
            return Err(MaterialPackError::InvalidMinutesEvidence(
                "missing model, createdAt, or templateVersion".to_string(),
            ));
        }
        if let Some(ref edited) = self.edited_at_iso {
            if edited.trim().is_empty() {
                return Err(MaterialPackError::InvalidMinutesEvidence(
                    "empty editedAt".to_string(),
                ));
            }
        }
        let mut spine = UtteranceSpine::new("koepack-minutes-check");
        for (idx, src) in self.sources.iter().enumerate() {
            let clean = if src.trim().is_empty() {
                "（空）"
            } else {
                src.as_str()
            };
            let start_ms = (idx as u64) * 1_000;
            let _ = spine.append_segment(clean, start_ms, start_ms + 900, "zh", "qwen");
        }
        parse_meeting_minutes_json(&self.text, &spine)
            .map_err(|e| MaterialPackError::InvalidMinutesEvidence(format!("{e:?}")))?;
        Ok(())
    }

    /// Decodes and validates a [`PortableMinutesEntry`] from a JSON value.
    pub fn from_json_value(value: &JsonValue) -> Result<Self, MaterialPackError> {
        let obj = value.as_object().ok_or_else(|| {
            MaterialPackError::InvalidMinutesEvidence("entry is not an object".to_string())
        })?;
        let text = obj
            .get("text")
            .and_then(JsonValue::as_str)
            .filter(|s| !s.trim().is_empty())
            .ok_or_else(|| MaterialPackError::InvalidMinutesEvidence("missing text".to_string()))?
            .to_string();
        let source_hash = obj
            .get("sourceHash")
            .and_then(JsonValue::as_str)
            .ok_or_else(|| {
                MaterialPackError::InvalidMinutesEvidence("missing sourceHash".to_string())
            })?
            .to_string();
        let model = obj
            .get("model")
            .and_then(JsonValue::as_str)
            .filter(|s| !s.trim().is_empty())
            .ok_or_else(|| MaterialPackError::InvalidMinutesEvidence("missing model".to_string()))?
            .to_string();
        let instruction = obj
            .get("instruction")
            .and_then(JsonValue::as_str)
            .ok_or_else(|| {
                MaterialPackError::InvalidMinutesEvidence("missing instruction".to_string())
            })?
            .to_string();
        let raw_sources = obj
            .get("sources")
            .and_then(JsonValue::as_array)
            .ok_or_else(|| {
                MaterialPackError::InvalidMinutesEvidence("missing sources array".to_string())
            })?;
        let mut sources = Vec::with_capacity(raw_sources.len());
        for item in raw_sources {
            let s = item.as_str().ok_or_else(|| {
                MaterialPackError::InvalidMinutesEvidence("non-string source".to_string())
            })?;
            sources.push(s.to_string());
        }
        let created_at_iso = obj
            .get("createdAt")
            .and_then(JsonValue::as_str)
            .filter(|s| !s.trim().is_empty())
            .ok_or_else(|| {
                MaterialPackError::InvalidMinutesEvidence("missing createdAt".to_string())
            })?
            .to_string();
        let edited_at_iso = match obj.get("editedAt") {
            None | Some(JsonValue::Null) => None,
            Some(JsonValue::String(s)) if !s.trim().is_empty() => Some(s.clone()),
            _ => {
                return Err(MaterialPackError::InvalidMinutesEvidence(
                    "invalid editedAt".to_string(),
                ))
            }
        };
        let template_id = match obj.get("templateId") {
            None | Some(JsonValue::Null) => None,
            Some(JsonValue::String(s)) => Some(s.clone()),
            _ => {
                return Err(MaterialPackError::InvalidMinutesEvidence(
                    "invalid templateId".to_string(),
                ))
            }
        };
        let template_version_i64 = obj
            .get("templateVersion")
            .and_then(JsonValue::as_i64)
            .ok_or_else(|| {
                MaterialPackError::InvalidMinutesEvidence("missing templateVersion".to_string())
            })?;
        if template_version_i64 < 1 {
            return Err(MaterialPackError::InvalidMinutesEvidence(
                "templateVersion < 1".to_string(),
            ));
        }
        let is_draft = obj
            .get("isDraft")
            .and_then(JsonValue::as_bool)
            .ok_or_else(|| {
                MaterialPackError::InvalidMinutesEvidence("missing isDraft".to_string())
            })?;

        let entry = Self {
            text,
            source_hash,
            model,
            instruction,
            sources,
            created_at_iso,
            edited_at_iso,
            template_id,
            template_version: template_version_i64 as u32,
            is_draft,
        };
        entry.validate()?;
        Ok(entry)
    }
}

/// Material identity metadata inside a `.koepack` manifest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackMaterialMeta {
    /// Lowercase 64-hex SHA-256 digest of the original recording audio (`contentHash`).
    pub content_hash: String,
    /// Human-readable material title.
    pub title: String,
    /// Recording source kind (such as `"device"`, `"phone"`, or `"localImport"`).
    pub source: String,
    /// Optional recorder hardware file number.
    pub device_file_id: Option<u32>,
    /// Optional ISO-8601 recording timestamp.
    pub recorded_at_iso: Option<String>,
    /// Optional lowercase file extension (such as `".wav"` or `".m4a"`).
    pub audio_extension: Option<String>,
}

/// Structured minutes section of a `.koepack v2` manifest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackMinutes {
    /// Current active minutes entry.
    pub current: PortableMinutesEntry,
    /// Bounded history of previous or conflicting versions (`<= 10` entries).
    pub history: Vec<PortableMinutesEntry>,
}

/// Audio-less `.koepack` (`v1`/`v2`) manifest model.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MaterialPack {
    /// Pack schema version (`1` when `minutes.is_none()`, `2` when `minutes.is_some()`).
    pub version: u32,
    /// ISO-8601 export timestamp.
    pub exported_at_iso: String,
    /// Material identity metadata.
    pub material: PackMaterialMeta,
    /// Optional structured minutes and bounded version history (`v2`).
    pub minutes: Option<PackMinutes>,
}

/// Errors returned by [`decode_koepack`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MaterialPackError {
    /// First line is not `KOEPACK1` or `format != "koe-material-pack"`.
    NotAKoePack,
    /// Second line is not a valid positive byte length `<= 32 MiB`.
    CorruptHeader,
    /// File ends before the declared manifest byte length.
    TruncatedManifest,
    /// Extra bytes follow an audio-less (`audio.included == false`) manifest.
    TrailingBytes,
    /// Manifest is not valid UTF-8 or valid JSON.
    InvalidManifest,
    /// Manifest `version` is outside `1..=2`.
    UnsupportedVersion(i64),
    /// A `version: 1` manifest illegally contains a `minutes` field.
    MinutesInV1Pack,
    /// `exportedAt` or `material` (`contentHash` / `title`) is missing or invalid.
    MissingIdentity,
    /// `minutes.history` is missing or exceeds `10` entries.
    InvalidMinutesHistory,
    /// A `minutes` entry failed SHA-256 `sourceHash` or `MeetingMinutes` grounding checks.
    InvalidMinutesEvidence(String),
    /// Pack declares `audio.included == true`, which is unsupported by the pure audio-less codec.
    AudioCarrierUnsupported,
}

impl fmt::Display for MaterialPackError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotAKoePack => write!(f, "这不是 Koe 资料包"),
            Self::CorruptHeader => write!(f, "资料包已损坏：说明长度无法读取"),
            Self::TruncatedManifest => write!(f, "资料包不完整：说明被截断"),
            Self::TrailingBytes => write!(f, "资料包已损坏：说明之后有多余内容"),
            Self::InvalidManifest => write!(f, "资料包说明无法读取"),
            Self::UnsupportedVersion(v) => {
                write!(f, "资料包来自更新版本的 Koe（v{v}），请先更新 App")
            }
            Self::MinutesInV1Pack => write!(f, "旧版资料包不能携带纪要，请重新导出"),
            Self::MissingIdentity => write!(f, "资料包缺少资料身份"),
            Self::InvalidMinutesHistory => write!(f, "资料包里的纪要历史不完整或超过10版"),
            Self::InvalidMinutesEvidence(detail) => {
                write!(f, "资料包里的纪要或原文依据无法校验，未导入：{detail}")
            }
            Self::AudioCarrierUnsupported => {
                write!(f, "纯资料包解码器仅支持不含原音频的 .koepack")
            }
        }
    }
}

impl std::error::Error for MaterialPackError {}

/// Decodes and validates an audio-less `.koepack` (`v1`/`v2`) archive from `bytes`.
pub fn decode_koepack(bytes: &[u8]) -> Result<MaterialPack, MaterialPackError> {
    let Some(first_nl) = bytes.iter().position(|&b| b == b'\n') else {
        return Err(MaterialPackError::NotAKoePack);
    };
    let magic_line = &bytes[..first_nl];
    let magic_trimmed = magic_line.strip_suffix(b"\r").unwrap_or(magic_line);
    if magic_trimmed != KOEPACK_MAGIC.as_bytes() {
        return Err(MaterialPackError::NotAKoePack);
    }

    let after_first = &bytes[first_nl + 1..];
    let Some(second_nl_rel) = after_first.iter().position(|&b| b == b'\n') else {
        return Err(MaterialPackError::CorruptHeader);
    };
    let size_line = &after_first[..second_nl_rel];
    let size_trimmed = size_line.strip_suffix(b"\r").unwrap_or(size_line);
    let size_str =
        std::str::from_utf8(size_trimmed).map_err(|_| MaterialPackError::CorruptHeader)?;
    let manifest_len: usize = size_str
        .parse()
        .map_err(|_| MaterialPackError::CorruptHeader)?;
    if manifest_len == 0 || manifest_len > KOEPACK_MAX_MANIFEST_BYTES {
        return Err(MaterialPackError::CorruptHeader);
    }

    let manifest_start = first_nl + 1 + second_nl_rel + 1;
    let remaining = bytes.len().saturating_sub(manifest_start);
    if remaining < manifest_len {
        return Err(MaterialPackError::TruncatedManifest);
    }

    let manifest_slice = &bytes[manifest_start..manifest_start + manifest_len];
    let manifest_str =
        std::str::from_utf8(manifest_slice).map_err(|_| MaterialPackError::InvalidManifest)?;
    let val = JsonValue::parse(manifest_str).map_err(|_| MaterialPackError::InvalidManifest)?;
    let root = val.as_object().ok_or(MaterialPackError::InvalidManifest)?;

    if root.get("format").and_then(JsonValue::as_str) != Some(KOEPACK_FORMAT_NAME) {
        return Err(MaterialPackError::NotAKoePack);
    }

    let version_i64 = root
        .get("version")
        .and_then(JsonValue::as_i64)
        .ok_or(MaterialPackError::UnsupportedVersion(-1))?;
    if version_i64 != 1 && version_i64 != 2 {
        return Err(MaterialPackError::UnsupportedVersion(version_i64));
    }

    if version_i64 == 1 && root.contains_key("minutes") {
        return Err(MaterialPackError::MinutesInV1Pack);
    }

    let exported_at_iso = root
        .get("exportedAt")
        .and_then(JsonValue::as_str)
        .filter(|s| !s.trim().is_empty())
        .ok_or(MaterialPackError::MissingIdentity)?
        .to_string();

    let mat_obj = root
        .get("material")
        .and_then(JsonValue::as_object)
        .ok_or(MaterialPackError::MissingIdentity)?;
    let content_hash = mat_obj
        .get("contentHash")
        .and_then(JsonValue::as_str)
        .filter(|h| is_valid_sha256_hex(h))
        .ok_or(MaterialPackError::MissingIdentity)?
        .to_string();
    let title = mat_obj
        .get("title")
        .and_then(JsonValue::as_str)
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .ok_or(MaterialPackError::MissingIdentity)?
        .to_string();
    let source = mat_obj
        .get("source")
        .and_then(JsonValue::as_str)
        .unwrap_or("localImport")
        .to_string();
    let device_file_id = mat_obj
        .get("deviceFileId")
        .and_then(JsonValue::as_i64)
        .and_then(|n| u32::try_from(n).ok());
    let recorded_at_iso = mat_obj
        .get("recordedAt")
        .and_then(JsonValue::as_str)
        .map(ToString::to_string);
    let audio_extension = mat_obj
        .get("audioExtension")
        .and_then(JsonValue::as_str)
        .map(ToString::to_string);

    let audio_obj = root
        .get("audio")
        .and_then(JsonValue::as_object)
        .ok_or(MaterialPackError::InvalidManifest)?;
    if audio_obj.get("included").and_then(JsonValue::as_bool) == Some(true) {
        return Err(MaterialPackError::AudioCarrierUnsupported);
    }

    if bytes.len() != manifest_start + manifest_len {
        return Err(MaterialPackError::TrailingBytes);
    }

    let minutes = match root.get("minutes") {
        None | Some(JsonValue::Null) => None,
        Some(mins_val) => {
            let mins_obj = mins_val
                .as_object()
                .ok_or(MaterialPackError::InvalidMinutesHistory)?;
            let hist_arr = mins_obj
                .get("history")
                .and_then(JsonValue::as_array)
                .ok_or(MaterialPackError::InvalidMinutesHistory)?;
            if hist_arr.len() > KOEPACK_MAX_MINUTES_HISTORY {
                return Err(MaterialPackError::InvalidMinutesHistory);
            }
            let current_val = mins_obj
                .get("current")
                .ok_or(MaterialPackError::InvalidMinutesHistory)?;
            let current = PortableMinutesEntry::from_json_value(current_val)?;
            let mut history = Vec::with_capacity(hist_arr.len());
            for item in hist_arr {
                history.push(PortableMinutesEntry::from_json_value(item)?);
            }
            Some(PackMinutes { current, history })
        }
    };

    Ok(MaterialPack {
        version: version_i64 as u32,
        exported_at_iso,
        material: PackMaterialMeta {
            content_hash,
            title,
            source,
            device_file_id,
            recorded_at_iso,
            audio_extension,
        },
        minutes,
    })
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;

    fn sample_minutes_json(title: &str, cite: &str) -> String {
        format!(
            r#"{{"schemaVersion":2,"title":"{title}","overview":"概览","topics":[{{"text":"讨论","sources":["{cite}"],"summary":"摘要","points":[{{"text":"要点","sources":["{cite}"]}}]}}],"terms":[{{"name":"Koe","note":"术语","heard":[],"sources":["{cite}"]}}],"decisions":[],"actions":[],"questions":[]}}"#
        )
    }

    fn test_entry_to_json(entry: &PortableMinutesEntry) -> JsonValue {
        let mut map = BTreeMap::new();
        map.insert(
            "createdAt".to_string(),
            JsonValue::String(entry.created_at_iso.clone()),
        );
        if let Some(ref edited) = entry.edited_at_iso {
            map.insert("editedAt".to_string(), JsonValue::String(edited.clone()));
        }
        map.insert(
            "instruction".to_string(),
            JsonValue::String(entry.instruction.clone()),
        );
        map.insert("isDraft".to_string(), JsonValue::Bool(entry.is_draft));
        map.insert("model".to_string(), JsonValue::String(entry.model.clone()));
        map.insert(
            "sourceHash".to_string(),
            JsonValue::String(entry.source_hash.clone()),
        );
        map.insert(
            "sources".to_string(),
            JsonValue::Array(entry.sources.iter().cloned().map(JsonValue::String).collect()),
        );
        if let Some(ref tpl) = entry.template_id {
            map.insert("templateId".to_string(), JsonValue::String(tpl.clone()));
        }
        map.insert(
            "templateVersion".to_string(),
            JsonValue::Number(f64::from(entry.template_version)),
        );
        map.insert("text".to_string(), JsonValue::String(entry.text.clone()));
        JsonValue::Object(map)
    }

    fn build_test_koepack(pack: &MaterialPack) -> Vec<u8> {
        let mut root = BTreeMap::new();
        root.insert(
            "format".to_string(),
            JsonValue::String(KOEPACK_FORMAT_NAME.to_string()),
        );
        root.insert(
            "version".to_string(),
            JsonValue::Number(f64::from(pack.version)),
        );
        root.insert(
            "exportedAt".to_string(),
            JsonValue::String(pack.exported_at_iso.clone()),
        );

        let mut mat = BTreeMap::new();
        mat.insert(
            "contentHash".to_string(),
            JsonValue::String(pack.material.content_hash.clone()),
        );
        mat.insert(
            "title".to_string(),
            JsonValue::String(pack.material.title.clone()),
        );
        mat.insert(
            "source".to_string(),
            JsonValue::String(pack.material.source.clone()),
        );
        if let Some(id) = pack.material.device_file_id {
            mat.insert("deviceFileId".to_string(), JsonValue::Number(f64::from(id)));
        }
        if let Some(ref rec) = pack.material.recorded_at_iso {
            mat.insert("recordedAt".to_string(), JsonValue::String(rec.clone()));
        }
        if let Some(ref ext) = pack.material.audio_extension {
            mat.insert("audioExtension".to_string(), JsonValue::String(ext.clone()));
        }
        root.insert("material".to_string(), JsonValue::Object(mat));

        if let Some(ref mins) = pack.minutes {
            let mut mins_obj = BTreeMap::new();
            mins_obj.insert("current".to_string(), test_entry_to_json(&mins.current));
            mins_obj.insert(
                "history".to_string(),
                JsonValue::Array(mins.history.iter().map(test_entry_to_json).collect()),
            );
            root.insert("minutes".to_string(), JsonValue::Object(mins_obj));
        }

        let mut audio_obj = BTreeMap::new();
        audio_obj.insert("included".to_string(), JsonValue::Bool(false));
        root.insert("audio".to_string(), JsonValue::Object(audio_obj));

        let manifest_json = JsonValue::Object(root).to_json_string();
        let manifest_bytes = manifest_json.as_bytes();
        let mut out = format!("{KOEPACK_MAGIC}\n{}\n", manifest_bytes.len()).into_bytes();
        out.extend_from_slice(manifest_bytes);
        out
    }

    #[test]
    fn koepack_v2_decodes_valid_pack_and_rejects_trailing_bytes() {
        let sources = vec!["我们今天讨论 Koe 资料包。".to_string()];
        let source_hash = sha256_hex(sources.join("\n").as_bytes());
        let content_hash = sha256_hex(b"dummy-audio-bytes");

        let make_entry = |title: &str, created: &str| PortableMinutesEntry {
            text: sample_minutes_json(title, "S1"),
            source_hash: source_hash.clone(),
            model: "qwen3.8-flash".to_string(),
            instruction: "整理纪要".to_string(),
            sources: sources.clone(),
            created_at_iso: created.to_string(),
            edited_at_iso: None,
            template_id: Some("minutes".to_string()),
            template_version: 4,
            is_draft: false,
        };

        let incoming = make_entry("导入新版", "2026-11-07T11:00:00Z");
        let hist: Vec<PortableMinutesEntry> = (0..10)
            .map(|i| make_entry(&format!("历史-{i}"), &format!("2026-11-07T09:{i:02}:00Z")))
            .collect();

        let pack = MaterialPack {
            version: 2,
            exported_at_iso: "2026-11-07T12:00:00Z".to_string(),
            material: PackMaterialMeta {
                content_hash,
                title: "产品周会".to_string(),
                source: "device".to_string(),
                device_file_id: Some(7),
                recorded_at_iso: Some("2026-11-07T08:00:00Z".to_string()),
                audio_extension: Some(".wav".to_string()),
            },
            minutes: Some(PackMinutes {
                current: incoming,
                history: hist,
            }),
        };

        let encoded = build_test_koepack(&pack);
        let decoded = decode_koepack(&encoded).expect("decode valid v2 pack");
        assert_eq!(decoded, pack);

        let mut trailing = encoded;
        trailing.push(b'x');
        assert_eq!(
            decode_koepack(&trailing),
            Err(MaterialPackError::TrailingBytes)
        );
    }
}
