//! Structured meeting minutes grounding validator (`S1..Sn` evidence checks), DashScope Qwen ASR
//! batch/streaming protocol codec, two-stage chunked minutes state machine, and `qwennote-minutes`
//! hot-word/template engine.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

use std::collections::{BTreeMap, BTreeSet};

use crate::domain::{
    AiProviderCommand, MeetingMinutes, MinuteCause, MinuteCustomSection, MinuteFishbone,
    MinutePoint, MinuteTerm, MinuteTermAdoption, MinuteTopic, SegmentId, UtteranceSpine,
};

/// Default DashScope batch file transcription model (`qwen-audio-3.1-asr-flash-filetrans`).
pub const QWEN_FILETRANS_DEFAULT_MODEL: &str = "qwen-audio-3.1-asr-flash-filetrans";

/// Default DashScope realtime streaming ASR model (`qwen-audio-3.1-asr-flash-streaming`).
pub const QWEN_STREAMING_DEFAULT_MODEL: &str = "qwen-audio-3.1-asr-flash-streaming";

/// Legacy model rejected on the `file_urls` DashScope batch endpoint (`qwen3-asr-flash-filetrans`).
pub const QWEN_INCOMPATIBLE_FILE_URL_MODEL: &str = "qwen3-asr-flash-filetrans";

/// Default rune budget per leaf batch in two-stage minutes generation (`6000`).
pub const MINUTES_BATCH_DEFAULT_MAX_RUNES: usize = 6000;

/// Built-in meeting minutes template definition (`zh` / `en` / `ja`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuiltinMinuteTemplate {
    /// Stable template identifier (such as `"retro"`, `"fishbone"`, `"standup"`, `"one-on-one"`, `"interview"`).
    pub id: &'static str,
    /// Localized section headings (`[zh, en, ja]`).
    pub sections_zh: &'static [&'static str],
    /// English section headings.
    pub sections_en: &'static [&'static str],
    /// Japanese section headings.
    pub sections_ja: &'static [&'static str],
    /// Extra prompt instructions in Chinese.
    pub instructions_zh: &'static str,
    /// Extra prompt instructions in English.
    pub instructions_en: &'static str,
    /// Extra prompt instructions in Japanese.
    pub instructions_ja: &'static str,
}

/// Built-in templates matching `lib/state/meeting_minutes.dart`.
pub const BUILTIN_MINUTE_TEMPLATES: [BuiltinMinuteTemplate; 5] = [
    BuiltinMinuteTemplate {
        id: "retro",
        sections_zh: &["做得好的", "有待改进", "下次尝试"],
        sections_en: &["Went well", "Needs improvement", "Try next"],
        sections_ja: &["良かった点", "改善点", "次に試すこと"],
        instructions_zh: "",
        instructions_en: "",
        instructions_ja: "",
    },
    BuiltinMinuteTemplate {
        id: "fishbone",
        sections_zh: &["问题", "人员", "流程", "工具与环境", "根因假设"],
        sections_en: &[
            "Problem",
            "People",
            "Process",
            "Tools & environment",
            "Root-cause hypotheses",
        ],
        sections_ja: &["問題", "人", "プロセス", "ツール・環境", "根本原因の仮説"],
        instructions_zh: "只要原话有依据，在最主要的“问题/故障/卡点”主题上必须填 fishbone（question + 2 到 6 条 branches，每条含原因类别 text、具体原因 detail、原话编号 sources）。",
        instructions_en: "Whenever grounded in the transcript, populate fishbone on the primary problem/incident topic (question + 2 to 6 branches, each with category text, cause detail, and sources).",
        instructions_ja: "発言に根拠がある限り、主要な問題・障害トピックには必ず fishbone（question と 2〜6 件の branches：要因カテゴリ text、具体的原因 detail、sources）を入れてください。",
    },
    BuiltinMinuteTemplate {
        id: "standup",
        sections_zh: &["已完成", "进行中", "阻碍"],
        sections_en: &["Done", "In progress", "Blockers"],
        sections_ja: &["完了", "進行中", "ブロッカー"],
        instructions_zh: "",
        instructions_en: "",
        instructions_ja: "",
    },
    BuiltinMinuteTemplate {
        id: "one-on-one",
        sections_zh: &["近况与状态", "反馈", "成长与支持"],
        sections_en: &["Check-in", "Feedback", "Growth & support"],
        sections_ja: &["近況", "フィードバック", "成長とサポート"],
        instructions_zh: "",
        instructions_en: "",
        instructions_ja: "",
    },
    BuiltinMinuteTemplate {
        id: "interview",
        sections_zh: &["候选人表现", "优势", "疑虑"],
        sections_en: &["Highlights", "Strengths", "Concerns"],
        sections_ja: &["ハイライト", "強み", "懸念点"],
        instructions_zh: "",
        instructions_en: "",
        instructions_ja: "",
    },
];

/// Zero-dependency JSON DOM value with canonical `BTreeMap` key ordering.
#[derive(Debug, Clone, PartialEq)]
pub enum JsonValue {
    /// JSON `null`.
    Null,
    /// JSON boolean (`true` or `false`).
    Bool(bool),
    /// JSON IEEE-754 floating-point number.
    Number(f64),
    /// JSON UTF-8 string.
    String(String),
    /// JSON array.
    Array(Vec<JsonValue>),
    /// JSON object with deterministic lexicographical key order.
    Object(BTreeMap<String, JsonValue>),
}

impl JsonValue {
    /// Parses a JSON string into a [`JsonValue`].
    pub fn parse(raw: &str) -> Result<Self, String> {
        let mut parser = JsonParser::new(raw);
        let value = parser.parse_value()?;
        parser.skip_ws();
        if !parser.is_eof() {
            return Err(format!("trailing characters at byte {}", parser.pos));
        }
        Ok(value)
    }

    /// Serializes this [`JsonValue`] into a compact deterministic JSON string.
    #[must_use]
    pub fn to_json_string(&self) -> String {
        let mut out = String::new();
        self.write_json(&mut out);
        out
    }

    /// Returns `Some(&str)` if this value is a [`JsonValue::String`].
    #[must_use]
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Self::String(s) => Some(s.as_str()),
            _ => None,
        }
    }

    /// Returns `Some(bool)` if this value is a [`JsonValue::Bool`].
    #[must_use]
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Self::Bool(b) => Some(*b),
            _ => None,
        }
    }

    /// Returns `Some(f64)` if this value is a [`JsonValue::Number`].
    #[must_use]
    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Self::Number(n) => Some(*n),
            _ => None,
        }
    }

    /// Returns `Some(i64)` if this value is an integral [`JsonValue::Number`].
    #[must_use]
    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Self::Number(n) if n.is_finite() && (*n - n.trunc()).abs() < f64::EPSILON => {
                Some(*n as i64)
            }
            _ => None,
        }
    }

    /// Returns `Some(&[JsonValue])` if this value is a [`JsonValue::Array`].
    #[must_use]
    pub fn as_array(&self) -> Option<&[JsonValue]> {
        match self {
            Self::Array(items) => Some(items.as_slice()),
            _ => None,
        }
    }

    /// Returns `Some(&BTreeMap<String, JsonValue>)` if this value is a [`JsonValue::Object`].
    #[must_use]
    pub fn as_object(&self) -> Option<&BTreeMap<String, JsonValue>> {
        match self {
            Self::Object(map) => Some(map),
            _ => None,
        }
    }

    fn write_json(&self, out: &mut String) {
        match self {
            Self::Null => out.push_str("null"),
            Self::Bool(true) => out.push_str("true"),
            Self::Bool(false) => out.push_str("false"),
            Self::Number(n) => {
                if !n.is_finite() {
                    out.push_str("null");
                } else if (*n - n.trunc()).abs() < f64::EPSILON
                    && *n >= (i64::MIN as f64)
                    && *n <= (i64::MAX as f64)
                {
                    out.push_str(&(*n as i64).to_string());
                } else {
                    out.push_str(&n.to_string());
                }
            }
            Self::String(s) => write_escaped_json_string(s, out),
            Self::Array(items) => {
                out.push('[');
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    item.write_json(out);
                }
                out.push(']');
            }
            Self::Object(map) => {
                out.push('{');
                for (i, (k, v)) in map.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    write_escaped_json_string(k, out);
                    out.push(':');
                    v.write_json(out);
                }
                out.push('}');
            }
        }
    }
}

fn write_escaped_json_string(s: &str, out: &mut String) {
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0C}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => {
                let code = c as u32;
                out.push_str(&format!("\\u{code:04x}"));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

struct JsonParser<'a> {
    src: &'a str,
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> JsonParser<'a> {
    fn new(src: &'a str) -> Self {
        Self {
            src,
            bytes: src.as_bytes(),
            pos: 0,
        }
    }

    fn is_eof(&self) -> bool {
        self.pos >= self.bytes.len()
    }

    fn skip_ws(&mut self) {
        while self.pos < self.bytes.len() {
            match self.bytes[self.pos] {
                b' ' | b'\t' | b'\r' | b'\n' => self.pos += 1,
                _ => break,
            }
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn parse_value(&mut self) -> Result<JsonValue, String> {
        self.skip_ws();
        let Some(b) = self.peek() else {
            return Err("unexpected end of JSON".to_string());
        };
        match b {
            b'{' => self.parse_object(),
            b'[' => self.parse_array(),
            b'"' => self.parse_string().map(JsonValue::String),
            b't' => {
                if self.src[self.pos..].starts_with("true") {
                    self.pos += 4;
                    Ok(JsonValue::Bool(true))
                } else {
                    Err(format!("invalid literal at {}", self.pos))
                }
            }
            b'f' => {
                if self.src[self.pos..].starts_with("false") {
                    self.pos += 5;
                    Ok(JsonValue::Bool(false))
                } else {
                    Err(format!("invalid literal at {}", self.pos))
                }
            }
            b'n' => {
                if self.src[self.pos..].starts_with("null") {
                    self.pos += 4;
                    Ok(JsonValue::Null)
                } else {
                    Err(format!("invalid literal at {}", self.pos))
                }
            }
            b'-' | b'0'..=b'9' => self.parse_number(),
            other => Err(format!(
                "unexpected byte '{}' at {}",
                other as char, self.pos
            )),
        }
    }

    fn parse_object(&mut self) -> Result<JsonValue, String> {
        self.pos += 1;
        self.skip_ws();
        let mut map = BTreeMap::new();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(JsonValue::Object(map));
        }
        loop {
            self.skip_ws();
            if self.peek() != Some(b'"') {
                return Err(format!("expected string key at {}", self.pos));
            }
            let key = self.parse_string()?;
            self.skip_ws();
            if self.peek() != Some(b':') {
                return Err(format!("expected ':' at {}", self.pos));
            }
            self.pos += 1;
            let val = self.parse_value()?;
            map.insert(key, val);
            self.skip_ws();
            match self.peek() {
                Some(b',') => {
                    self.pos += 1;
                }
                Some(b'}') => {
                    self.pos += 1;
                    break;
                }
                _ => return Err(format!("expected ',' or '}}' at {}", self.pos)),
            }
        }
        Ok(JsonValue::Object(map))
    }

    fn parse_array(&mut self) -> Result<JsonValue, String> {
        self.pos += 1;
        self.skip_ws();
        let mut items = Vec::new();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(JsonValue::Array(items));
        }
        loop {
            let val = self.parse_value()?;
            items.push(val);
            self.skip_ws();
            match self.peek() {
                Some(b',') => {
                    self.pos += 1;
                }
                Some(b']') => {
                    self.pos += 1;
                    break;
                }
                _ => return Err(format!("expected ',' or ']' at {}", self.pos)),
            }
        }
        Ok(JsonValue::Array(items))
    }

    fn parse_string(&mut self) -> Result<String, String> {
        if self.peek() != Some(b'"') {
            return Err(format!("expected '\"' at {}", self.pos));
        }
        self.pos += 1;
        let mut out = String::new();
        while self.pos < self.bytes.len() {
            let ch = self.src[self.pos..]
                .chars()
                .next()
                .ok_or_else(|| "invalid UTF-8".to_string())?;
            self.pos += ch.len_utf8();
            match ch {
                '"' => return Ok(out),
                '\\' => {
                    if self.is_eof() {
                        return Err("unterminated escape sequence".to_string());
                    }
                    let esc = self.src[self.pos..]
                        .chars()
                        .next()
                        .ok_or_else(|| "invalid escape".to_string())?;
                    self.pos += esc.len_utf8();
                    match esc {
                        '"' => out.push('"'),
                        '\\' => out.push('\\'),
                        '/' => out.push('/'),
                        'b' => out.push('\u{08}'),
                        'f' => out.push('\u{0C}'),
                        'n' => out.push('\n'),
                        'r' => out.push('\r'),
                        't' => out.push('\t'),
                        'u' => {
                            let code = self.parse_hex4()?;
                            if (0xD800..=0xDBFF).contains(&code) {
                                if self.src[self.pos..].starts_with("\\u") {
                                    self.pos += 2;
                                    let low = self.parse_hex4()?;
                                    if (0xDC00..=0xDFFF).contains(&low) {
                                        let combined = 0x10000
                                            + (((code as u32 - 0xD800) << 10)
                                                | (low as u32 - 0xDC00));
                                        let c = char::from_u32(combined)
                                            .ok_or_else(|| "invalid surrogate pair".to_string())?;
                                        out.push(c);
                                        continue;
                                    }
                                }
                                return Err("unpaired high surrogate".to_string());
                            }
                            let c = char::from_u32(u32::from(code))
                                .ok_or_else(|| "invalid unicode escape".to_string())?;
                            out.push(c);
                        }
                        other => return Err(format!("invalid escape '\\{other}'")),
                    }
                }
                c if (c as u32) < 0x20 => {
                    return Err(format!("unescaped control character at {}", self.pos));
                }
                c => out.push(c),
            }
        }
        Err("unterminated JSON string".to_string())
    }

    fn parse_hex4(&mut self) -> Result<u16, String> {
        if self.pos + 4 > self.bytes.len() {
            return Err("truncated \\uXXXX escape".to_string());
        }
        let hex = &self.src[self.pos..self.pos + 4];
        self.pos += 4;
        u16::from_str_radix(hex, 16).map_err(|e| format!("invalid hex escape: {e}"))
    }

    fn parse_number(&mut self) -> Result<JsonValue, String> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        while let Some(b'0'..=b'9') = self.peek() {
            self.pos += 1;
        }
        if self.peek() == Some(b'.') {
            self.pos += 1;
            while let Some(b'0'..=b'9') = self.peek() {
                self.pos += 1;
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.pos += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            while let Some(b'0'..=b'9') = self.peek() {
                self.pos += 1;
            }
        }
        let slice = &self.src[start..self.pos];
        let num = slice
            .parse::<f64>()
            .map_err(|e| format!("invalid number '{slice}': {e}"))?;
        Ok(JsonValue::Number(num))
    }
}

/// Strips optional markdown ```json fences and extracts the outermost `{...}` JSON substring,
/// matching `extractJsonObject` in `lib/state/meeting_minutes.dart`.
#[must_use]
pub fn extract_json_object(raw: &str) -> &str {
    let mut s = raw.trim();
    if let Some(after_fence) = s.strip_prefix("```") {
        let after_first_line = if let Some(nl) = after_fence.find('\n') {
            &after_fence[nl + 1..]
        } else {
            after_fence
        };
        let without_closing = after_first_line
            .trim_end()
            .strip_suffix("```")
            .unwrap_or(after_first_line);
        s = without_closing.trim();
    }
    if let (Some(start), Some(end)) = (s.find('{'), s.rfind('}')) {
        if end > start {
            return &s[start..=end];
        }
    }
    s
}

/// Encodes the DashScope batch file transcription submission JSON payload.
///
/// Rejects [`QWEN_INCOMPATIBLE_FILE_URL_MODEL`] (`qwen3-asr-flash-filetrans`) because that
/// model does not accept `file_urls` on the batch endpoint.
pub fn encode_qwen_file_submit_json(
    model: &str,
    file_url: &str,
    language: Option<&str>,
    expected_speakers: Option<u32>,
    hot_words: &[String],
) -> Result<String, String> {
    let trimmed_model = model.trim();
    let effective_model = if trimmed_model.is_empty() {
        QWEN_FILETRANS_DEFAULT_MODEL
    } else {
        trimmed_model
    };
    if effective_model == QWEN_INCOMPATIBLE_FILE_URL_MODEL {
        return Err(format!(
            "Model {QWEN_INCOMPATIBLE_FILE_URL_MODEL} is incompatible with DashScope file_urls batch transcription; use {QWEN_FILETRANS_DEFAULT_MODEL}"
        ));
    }
    let clean_url = file_url.trim();
    if clean_url.is_empty() {
        return Err("file_url must not be empty".to_string());
    }

    let supports_diarization = effective_model == QWEN_FILETRANS_DEFAULT_MODEL
        || effective_model == "fun-asr"
        || effective_model.starts_with("fun-asr-");

    let mut params = BTreeMap::new();
    params.insert(
        "channel_id".to_string(),
        JsonValue::Array(vec![JsonValue::Number(0.0)]),
    );
    if supports_diarization {
        params.insert("diarization_enabled".to_string(), JsonValue::Bool(true));
        if let Some(count) = expected_speakers {
            if (2..=100).contains(&count) {
                params.insert(
                    "speaker_count".to_string(),
                    JsonValue::Number(f64::from(count)),
                );
            }
        }
    }
    if let Some(lang) = language.map(str::trim).filter(|s| !s.is_empty()) {
        params.insert(
            "language_hints".to_string(),
            JsonValue::Array(vec![JsonValue::String(lang.to_string())]),
        );
    }
    let clean_hotwords: Vec<JsonValue> = hot_words
        .iter()
        .map(|w| w.trim())
        .filter(|w| !w.is_empty())
        .take(500)
        .map(|w| JsonValue::String(w.to_string()))
        .collect();
    if !clean_hotwords.is_empty() {
        params.insert("hotwords".to_string(), JsonValue::Array(clean_hotwords));
    }

    let mut input = BTreeMap::new();
    input.insert(
        "file_urls".to_string(),
        JsonValue::Array(vec![JsonValue::String(clean_url.to_string())]),
    );

    let mut root = BTreeMap::new();
    root.insert(
        "model".to_string(),
        JsonValue::String(effective_model.to_string()),
    );
    root.insert("input".to_string(), JsonValue::Object(input));
    root.insert("parameters".to_string(), JsonValue::Object(params));

    Ok(JsonValue::Object(root).to_json_string())
}

/// DashScope temporary OSS upload policy parsed from `getPolicy`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QwenUploadPolicy {
    /// Base64 policy document.
    pub policy: String,
    /// OSS signature string.
    pub signature: String,
    /// Normalized upload directory prefix without trailing `/`.
    pub upload_dir: String,
    /// HTTPS OSS upload host URL.
    pub upload_host: String,
    /// OSS access key ID.
    pub access_key_id: String,
    /// Object ACL (defaults to `"private"`).
    pub object_acl: String,
    /// Whether overwrite is forbidden (defaults to `"true"`).
    pub forbid_overwrite: String,
    /// Maximum allowed file size in megabytes, if reported by DashScope.
    pub max_file_size_mb: Option<u64>,
}

/// Parses a DashScope `uploads?action=getPolicy` JSON response into [`QwenUploadPolicy`].
pub fn parse_qwen_upload_policy_json(raw: &str) -> Result<QwenUploadPolicy, String> {
    let val = JsonValue::parse(raw)?;
    let root = val
        .as_object()
        .ok_or_else(|| "upload policy root must be a JSON object".to_string())?;
    let data = root
        .get("data")
        .and_then(JsonValue::as_object)
        .ok_or_else(|| "upload policy missing 'data' object".to_string())?;

    let req_str = |key: &str| -> Result<String, String> {
        data.get(key)
            .and_then(JsonValue::as_str)
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| format!("upload policy missing '{key}'"))
    };

    let policy = req_str("policy")?;
    let signature = req_str("signature")?;
    let raw_dir = req_str("upload_dir")?;
    let upload_dir = raw_dir.trim_end_matches('/').to_string();
    if upload_dir.is_empty() {
        return Err("upload_dir must not be empty".to_string());
    }
    let raw_host = req_str("upload_host")?;
    let upload_host = match raw_host.find('#') {
        Some(idx) => raw_host[..idx].to_string(),
        None => raw_host,
    };
    if !upload_host.starts_with("https://") {
        return Err(format!(
            "upload_host must use https://, got '{upload_host}'"
        ));
    }
    let access_key_id = req_str("oss_access_key_id")?;
    let object_acl = data
        .get("x_oss_object_acl")
        .and_then(JsonValue::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("private")
        .to_string();
    let forbid_overwrite = data
        .get("x_oss_forbid_overwrite")
        .and_then(JsonValue::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("true")
        .to_string();
    let max_file_size_mb = data
        .get("max_file_size_mb")
        .and_then(JsonValue::as_i64)
        .and_then(|n| u64::try_from(n).ok());

    Ok(QwenUploadPolicy {
        policy,
        signature,
        upload_dir,
        upload_host,
        access_key_id,
        object_acl,
        forbid_overwrite,
        max_file_size_mb,
    })
}

/// Parsed DashScope async transcription task status.
#[derive(Debug, Clone, PartialEq)]
pub struct QwenTaskStatus {
    /// Task status (`"PENDING"`, `"RUNNING"`, `"SUCCEEDED"`, `"FAILED"`).
    pub status: String,
    /// DashScope `task_id`, if present.
    pub task_id: Option<String>,
    /// Result `transcription_url` entries for succeeded subtasks.
    pub transcription_urls: Vec<String>,
    /// Failure reason when `status == "FAILED"` or all subtasks fail.
    pub failure_message: Option<String>,
    /// Billed audio duration in seconds from `usage.duration`.
    pub duration_sec: Option<f64>,
}

/// Parses a DashScope task submission or polling JSON response into [`QwenTaskStatus`].
pub fn parse_qwen_task_status_json(raw: &str) -> Result<QwenTaskStatus, String> {
    let val = JsonValue::parse(raw)?;
    let root = val
        .as_object()
        .ok_or_else(|| "task status root must be a JSON object".to_string())?;
    let Some(output) = root.get("output").and_then(JsonValue::as_object) else {
        let code = root.get("code").and_then(JsonValue::as_str).unwrap_or("");
        let msg = root
            .get("message")
            .and_then(JsonValue::as_str)
            .unwrap_or("invalid task response");
        return Err(if code.is_empty() {
            msg.to_string()
        } else {
            format!("{code}: {msg}")
        });
    };

    let task_id = output
        .get("task_id")
        .and_then(JsonValue::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToOwned::to_owned);
    let status = output
        .get("task_status")
        .and_then(JsonValue::as_str)
        .unwrap_or("UNKNOWN")
        .to_string();

    let mut transcription_urls = Vec::new();
    let mut subtask_errors = Vec::new();
    if let Some(results) = output.get("results").and_then(JsonValue::as_array) {
        for item in results {
            if let Some(obj) = item.as_object() {
                let sub_status = obj
                    .get("subtask_status")
                    .and_then(JsonValue::as_str)
                    .unwrap_or("");
                if sub_status == "SUCCEEDED" || sub_status.is_empty() {
                    if let Some(url) = obj
                        .get("transcription_url")
                        .and_then(JsonValue::as_str)
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                    {
                        transcription_urls.push(url.to_string());
                    }
                } else if sub_status == "FAILED" {
                    let code = obj.get("code").and_then(JsonValue::as_str).unwrap_or("");
                    let msg = obj.get("message").and_then(JsonValue::as_str).unwrap_or("");
                    let detail = format!("{code} {msg}").trim().to_string();
                    if !detail.is_empty() {
                        subtask_errors.push(detail);
                    }
                }
            }
        }
    }

    let top_msg = output
        .get("message")
        .or_else(|| root.get("message"))
        .and_then(JsonValue::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToOwned::to_owned);
    let failure_message = if !subtask_errors.is_empty() {
        Some(subtask_errors.join("; "))
    } else {
        top_msg
    };

    let duration_sec = root
        .get("usage")
        .and_then(JsonValue::as_object)
        .and_then(|u| u.get("duration"))
        .and_then(JsonValue::as_f64)
        .filter(|&d| d > 0.0);

    Ok(QwenTaskStatus {
        status,
        task_id,
        transcription_urls,
        failure_message,
        duration_sec,
    })
}

/// Summary of a parsed DashScope batch transcription result file.
#[derive(Debug, Clone, PartialEq)]
pub struct QwenTranscriptParsed {
    /// Formatted full transcript text (with `说话人 N：` speaker headers when diarized).
    pub text: String,
    /// Number of segments appended to the [`UtteranceSpine`] (`0` if timing was incomplete).
    pub segment_count: usize,
    /// Whether every non-empty sentence had valid `begin_time <= end_time` timestamps.
    pub timing_complete: bool,
    /// Total audio duration in seconds from `properties.original_duration_in_milliseconds`.
    pub duration_sec: Option<f64>,
}

/// Parses a DashScope `transcription_url` JSON result and populates `spine` when sentence timings
/// are complete, matching `parseQwenTranscript` in `lib/ai/qwen_stt.dart`.
pub fn parse_qwen_transcript_json(
    raw: &str,
    spine: &mut UtteranceSpine,
) -> Result<QwenTranscriptParsed, String> {
    let val = JsonValue::parse(raw)?;
    let root = val
        .as_object()
        .ok_or_else(|| "transcript JSON must be an object".to_string())?;
    let Some(transcripts) = root.get("transcripts").and_then(JsonValue::as_array) else {
        return Ok(QwenTranscriptParsed {
            text: String::new(),
            segment_count: 0,
            timing_complete: false,
            duration_sec: None,
        });
    };

    let mut lines: Vec<String> = Vec::new();
    let mut pending_segments: Vec<(String, Option<String>, u64, u64)> = Vec::new();
    let mut timing_complete = true;

    for item in transcripts {
        let Some(t_obj) = item.as_object() else {
            continue;
        };
        if let Some(sentences) = t_obj.get("sentences").and_then(JsonValue::as_array) {
            if !sentences.is_empty() {
                let mut last_speaker: Option<i64> = None;
                let mut current_line = String::new();
                for s in sentences {
                    let Some(s_obj) = s.as_object() else {
                        continue;
                    };
                    let piece = s_obj
                        .get("text")
                        .and_then(JsonValue::as_str)
                        .map(str::trim)
                        .unwrap_or("");
                    if piece.is_empty() {
                        continue;
                    };
                    let spk_id = s_obj.get("speaker_id").and_then(JsonValue::as_i64);
                    let begin_ms = s_obj.get("begin_time").and_then(JsonValue::as_i64);
                    let end_ms = s_obj.get("end_time").and_then(JsonValue::as_i64);

                    if let (Some(b), Some(e)) = (begin_ms, end_ms) {
                        if b >= 0 && e >= b {
                            let speaker_label = spk_id.map(|id| format!("说话人 {}", id + 1));
                            pending_segments.push((
                                piece.to_string(),
                                speaker_label,
                                b as u64,
                                e as u64,
                            ));
                        } else {
                            timing_complete = false;
                        }
                    } else {
                        timing_complete = false;
                    }

                    if let Some(spk) = spk_id {
                        if spk != last_speaker.unwrap_or(-1) {
                            if !current_line.is_empty() {
                                lines.push(current_line.clone());
                                current_line.clear();
                            }
                            last_speaker = Some(spk);
                            current_line.push_str(&format!("说话人 {}：{piece}", spk + 1));
                        } else {
                            current_line.push_str(piece);
                        }
                    } else {
                        current_line.push_str(piece);
                    }
                }
                if !current_line.is_empty() {
                    lines.push(current_line);
                }
                continue;
            }
        }
        if let Some(text) = t_obj
            .get("text")
            .and_then(JsonValue::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            timing_complete = false;
            lines.push(text.to_string());
        }
    }

    let duration_ms = root
        .get("properties")
        .and_then(JsonValue::as_object)
        .and_then(|p| p.get("original_duration_in_milliseconds"))
        .and_then(JsonValue::as_f64)
        .filter(|&d| d > 0.0);

    let mut segment_count = 0usize;
    if timing_complete && !pending_segments.is_empty() {
        for (text, speaker, start_ms, end_ms) in pending_segments {
            if let Some(id) = spine.append_segment(text, start_ms, end_ms, "zh", "qwen") {
                if speaker.is_some() {
                    spine.set_speaker(id, speaker);
                }
                segment_count += 1;
            }
        }
        spine.clear_stale();
    }

    Ok(QwenTranscriptParsed {
        text: lines.join("\n"),
        segment_count,
        timing_complete: timing_complete && segment_count > 0,
        duration_sec: duration_ms.map(|ms| ms / 1000.0),
    })
}

/// Encodes the DashScope WebSocket `run-task` frame for `qwen-audio-3.1-asr-flash-streaming`.
#[must_use]
pub fn encode_qwen_stream_run_task_json(
    task_id: &str,
    language: Option<&str>,
    hot_words: &[String],
) -> String {
    let mut header = BTreeMap::new();
    header.insert(
        "action".to_string(),
        JsonValue::String("run-task".to_string()),
    );
    header.insert(
        "task_id".to_string(),
        JsonValue::String(task_id.to_string()),
    );
    header.insert(
        "streaming".to_string(),
        JsonValue::String("duplex".to_string()),
    );

    let mut parameters = BTreeMap::new();
    parameters.insert("format".to_string(), JsonValue::String("pcm".to_string()));
    parameters.insert("sample_rate".to_string(), JsonValue::Number(16000.0));
    parameters.insert(
        "semantic_punctuation_enabled".to_string(),
        JsonValue::Bool(false),
    );
    if let Some(lang) = language.map(str::trim).filter(|s| !s.is_empty()) {
        parameters.insert(
            "language_hints".to_string(),
            JsonValue::Array(vec![JsonValue::String(lang.to_string())]),
        );
    }
    let clean_hw: Vec<JsonValue> = hot_words
        .iter()
        .map(|w| w.trim())
        .filter(|w| !w.is_empty())
        .take(500)
        .map(|w| JsonValue::String(w.to_string()))
        .collect();
    if !clean_hw.is_empty() {
        parameters.insert("hotwords".to_string(), JsonValue::Array(clean_hw));
    }

    let mut payload = BTreeMap::new();
    payload.insert(
        "task_group".to_string(),
        JsonValue::String("audio".to_string()),
    );
    payload.insert("task".to_string(), JsonValue::String("asr".to_string()));
    payload.insert(
        "function".to_string(),
        JsonValue::String("recognition".to_string()),
    );
    payload.insert(
        "model".to_string(),
        JsonValue::String(QWEN_STREAMING_DEFAULT_MODEL.to_string()),
    );
    payload.insert("parameters".to_string(), JsonValue::Object(parameters));
    payload.insert("input".to_string(), JsonValue::Object(BTreeMap::new()));

    let mut root = BTreeMap::new();
    root.insert("header".to_string(), JsonValue::Object(header));
    root.insert("payload".to_string(), JsonValue::Object(payload));
    JsonValue::Object(root).to_json_string()
}

/// Encodes the DashScope WebSocket `finish-task` frame.
#[must_use]
pub fn encode_qwen_stream_finish_task_json(task_id: &str) -> String {
    let mut header = BTreeMap::new();
    header.insert(
        "action".to_string(),
        JsonValue::String("finish-task".to_string()),
    );
    header.insert(
        "task_id".to_string(),
        JsonValue::String(task_id.to_string()),
    );
    header.insert(
        "streaming".to_string(),
        JsonValue::String("duplex".to_string()),
    );

    let mut payload = BTreeMap::new();
    payload.insert("input".to_string(), JsonValue::Object(BTreeMap::new()));

    let mut root = BTreeMap::new();
    root.insert("header".to_string(), JsonValue::Object(header));
    root.insert("payload".to_string(), JsonValue::Object(payload));
    JsonValue::Object(root).to_json_string()
}

/// Decoded step from [`QwenStreamAccumulator::handle_event_json`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QwenStreamStep {
    /// Server acknowledged `run-task` and is ready to receive PCM frames.
    TaskStarted,
    /// Heartbeat or empty frame with no transcript change.
    Heartbeat,
    /// Partial or finalized transcript update (`full_text`, `is_sentence_end`).
    TranscriptUpdate {
        /// Combined confirmed sentences + active partial sentence.
        full_text: String,
        /// Whether this frame finalized the current sentence.
        sentence_end: bool,
    },
    /// Server completed the streaming task.
    TaskFinished {
        /// Final combined transcript.
        full_text: String,
    },
    /// Server reported a task failure.
    TaskFailed {
        /// Error message from `header.error_message` or `header.error_code`.
        message: String,
    },
}

/// Stateful accumulator for DashScope `qwen-audio-3.1-asr-flash-streaming` WebSocket events,
/// matching `QwenSttStreamSession` in `lib/ai/cloud_stt_stream.dart`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct QwenStreamAccumulator {
    confirmed_sentences: Vec<String>,
    current_partial: String,
    started: bool,
    finished: bool,
}

impl QwenStreamAccumulator {
    /// Creates a new streaming ASR accumulator.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns whether `task-started` has been received.
    #[must_use]
    pub fn is_started(&self) -> bool {
        self.started
    }

    /// Returns whether `task-finished` has been received.
    #[must_use]
    pub fn is_finished(&self) -> bool {
        self.finished
    }

    /// Returns the combined confirmed sentences + current partial text.
    #[must_use]
    pub fn full_text(&self) -> String {
        let mut combined = self.confirmed_sentences.join("");
        if !self.current_partial.is_empty() {
            combined.push_str(&self.current_partial);
        }
        combined
    }

    /// Processes a single WebSocket JSON event frame and updates `spine` on finalized sentences.
    pub fn handle_event_json(
        &mut self,
        raw: &str,
        spine: &mut UtteranceSpine,
    ) -> Result<QwenStreamStep, String> {
        let val = JsonValue::parse(raw)?;
        let root = val
            .as_object()
            .ok_or_else(|| "stream event must be a JSON object".to_string())?;
        let header = root
            .get("header")
            .and_then(JsonValue::as_object)
            .ok_or_else(|| "stream event missing 'header'".to_string())?;
        let event = header
            .get("event")
            .and_then(JsonValue::as_str)
            .unwrap_or("");

        match event {
            "task-started" => {
                self.started = true;
                Ok(QwenStreamStep::TaskStarted)
            }
            "task-failed" => {
                let msg = header
                    .get("error_message")
                    .or_else(|| header.get("error_code"))
                    .and_then(JsonValue::as_str)
                    .unwrap_or("ASR stream failed")
                    .to_string();
                Ok(QwenStreamStep::TaskFailed { message: msg })
            }
            "task-finished" => {
                self.finished = true;
                Ok(QwenStreamStep::TaskFinished {
                    full_text: self.full_text(),
                })
            }
            "result-generated" => {
                let Some(sentence) = root
                    .get("payload")
                    .and_then(JsonValue::as_object)
                    .and_then(|p| p.get("output"))
                    .and_then(JsonValue::as_object)
                    .and_then(|o| o.get("sentence"))
                    .and_then(JsonValue::as_object)
                else {
                    return Ok(QwenStreamStep::Heartbeat);
                };
                if sentence.get("heartbeat").and_then(JsonValue::as_bool) == Some(true) {
                    return Ok(QwenStreamStep::Heartbeat);
                }
                let text = sentence
                    .get("text")
                    .and_then(JsonValue::as_str)
                    .unwrap_or("");
                if text.is_empty() {
                    return Ok(QwenStreamStep::Heartbeat);
                }
                let is_end = sentence
                    .get("sentence_end")
                    .and_then(JsonValue::as_bool)
                    .unwrap_or(false);
                let sentence_id = sentence
                    .get("sentence_id")
                    .and_then(JsonValue::as_i64)
                    .map(|id| id.to_string())
                    .unwrap_or_else(|| format!("s-{}", self.confirmed_sentences.len() + 1));

                if is_end {
                    self.confirmed_sentences.push(text.to_string());
                    self.current_partial.clear();
                    spine.accept_final(
                        "qwen-stream",
                        &sentence_id,
                        text,
                        "zh",
                        None,
                        None,
                        QWEN_STREAMING_DEFAULT_MODEL,
                    );
                } else {
                    self.current_partial = text.to_string();
                }
                Ok(QwenStreamStep::TranscriptUpdate {
                    full_text: self.full_text(),
                    sentence_end: is_end,
                })
            }
            _ => Ok(QwenStreamStep::Heartbeat),
        }
    }
}

/// A contiguous batch of `[S{k}] {text}` lines sized within the per-call rune budget.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MinutesChunkBatch {
    /// Formatted `[S{k}] {text}` lines joined by `\n`.
    pub numbered_text: String,
    /// Allowed [`SegmentId`]s included in this batch.
    pub allowed_sources: BTreeSet<SegmentId>,
}

/// Splits `spine` into contiguous batches where each batch's `[S{i+1}] {text}\n` rune count is
/// at most `max_runes` (matching `recording_analysis.dart` lines 1910–1929).
#[must_use]
pub fn build_minutes_batches(spine: &UtteranceSpine, max_runes: usize) -> Vec<MinutesChunkBatch> {
    let limit = if max_runes == 0 {
        MINUTES_BATCH_DEFAULT_MAX_RUNES
    } else {
        max_runes
    };
    let mut batches = Vec::new();
    let mut buf = String::new();
    let mut buf_runes = 0usize;
    let mut ids = BTreeSet::new();

    for seg in spine.segments() {
        let line = format!("[{}] {}\n", seg.id, seg.text);
        let line_runes = line.chars().count();
        if buf_runes + line_runes > limit && !ids.is_empty() {
            batches.push(MinutesChunkBatch {
                numbered_text: buf.trim_end().to_string(),
                allowed_sources: ids,
            });
            buf = String::new();
            buf_runes = 0;
            ids = BTreeSet::new();
        }
        buf.push_str(&line);
        buf_runes += line_runes;
        ids.insert(seg.id);
    }
    if !ids.is_empty() {
        batches.push(MinutesChunkBatch {
            numbered_text: buf.trim_end().to_string(),
            allowed_sources: ids,
        });
    }
    batches
}

/// Description of the next LLM node to execute in [`MinutesChunkJob`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MinutesNodeSpec {
    /// Node checkpoint identifier (`"final"`, `"片段 1/N"`, or `"汇总 {depth}-{idx}"`).
    pub node_id: String,
    /// Whether this node is a Stage-2 3-way merge node (`true`) or a Stage-1 leaf/single node (`false`).
    pub is_merge_node: bool,
    /// Prompt payload (`numbered_text` for leaf nodes, or `片段 {j}:\n{json}` for merge nodes).
    pub payload_text: String,
    /// Strict subset of [`SegmentId`]s this node is permitted to cite.
    pub allowed_sources: BTreeSet<SegmentId>,
}

/// Two-stage chunked meeting minutes state machine with checkpoint resume, per-node
/// `allowed_sources` enforcement, and `unconfirmed_node` duplicate-charge protection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MinutesChunkJob {
    batches: Vec<MinutesChunkBatch>,
    checkpoints: BTreeMap<String, String>,
    unconfirmed_node: Option<String>,
    avoid_duplicate_charges: bool,
}

impl MinutesChunkJob {
    /// Creates a new two-stage chunked minutes job from `spine`.
    #[must_use]
    pub fn new(spine: &UtteranceSpine, max_runes: usize, avoid_duplicate_charges: bool) -> Self {
        Self {
            batches: build_minutes_batches(spine, max_runes),
            checkpoints: BTreeMap::new(),
            unconfirmed_node: None,
            avoid_duplicate_charges,
        }
    }

    /// Restores existing checkpoints and optional `unconfirmed_node` marker.
    pub fn restore_checkpoints(
        &mut self,
        checkpoints: BTreeMap<String, String>,
        unconfirmed_node: Option<String>,
    ) {
        self.checkpoints = checkpoints;
        self.unconfirmed_node = unconfirmed_node;
    }

    /// Returns the leaf batches planned for this job.
    #[must_use]
    pub fn batches(&self) -> &[MinutesChunkBatch] {
        &self.batches
    }

    /// Returns the saved checkpoint map (`node_id -> raw_json`).
    #[must_use]
    pub fn checkpoints(&self) -> &BTreeMap<String, String> {
        &self.checkpoints
    }

    /// Returns the currently unconfirmed paid node ID, if any.
    #[must_use]
    pub fn unconfirmed_node(&self) -> Option<&str> {
        self.unconfirmed_node.as_deref()
    }

    /// Marks `node_id` as dispatched to the paid LLM endpoint before its response arrives.
    pub fn mark_node_dispatched(&mut self, node_id: &str) {
        self.unconfirmed_node = Some(node_id.to_string());
    }

    /// Determines the next [`MinutesNodeSpec`] to execute, or returns `Ok(None)` when all
    /// stages have converged to a single root checkpoint.
    ///
    /// Returns `Err` if `avoid_duplicate_charges` is enabled, the next node matches
    /// `unconfirmed_node`, and `confirmed_restart` is `false`.
    pub fn next_pending_node(
        &self,
        spine: &UtteranceSpine,
        confirmed_restart: bool,
    ) -> Result<Option<MinutesNodeSpec>, String> {
        if self.batches.is_empty() {
            return Ok(None);
        }
        if self.batches.len() == 1 {
            let node_id = "final".to_string();
            if self.checkpoints.contains_key(&node_id) {
                return Ok(None);
            }
            self.check_duplicate_guard(&node_id, confirmed_restart)?;
            return Ok(Some(MinutesNodeSpec {
                node_id,
                is_merge_node: false,
                payload_text: self.batches[0].numbered_text.clone(),
                allowed_sources: self.batches[0].allowed_sources.clone(),
            }));
        }

        let n = self.batches.len();
        let mut current_level = Vec::with_capacity(n);
        for (i, batch) in self.batches.iter().enumerate() {
            let node_id = format!("片段 {}/{n}", i + 1);
            if let Some(saved_json) = self.checkpoints.get(&node_id) {
                current_level.push(saved_json.clone());
            } else {
                self.check_duplicate_guard(&node_id, confirmed_restart)?;
                return Ok(Some(MinutesNodeSpec {
                    node_id,
                    is_merge_node: false,
                    payload_text: batch.numbered_text.clone(),
                    allowed_sources: batch.allowed_sources.clone(),
                }));
            }
        }

        let mut depth = 1usize;
        while current_level.len() > 1 {
            let mut next_level = Vec::new();
            let mut idx = 0usize;
            while idx < current_level.len() {
                let end = (idx + 3).min(current_level.len());
                let group = &current_level[idx..end];
                if group.len() == 1 {
                    next_level.push(group[0].clone());
                } else {
                    let node_id = format!("汇总 {depth}-{}", idx / 3);
                    if let Some(saved_json) = self.checkpoints.get(&node_id) {
                        next_level.push(saved_json.clone());
                    } else {
                        self.check_duplicate_guard(&node_id, confirmed_restart)?;
                        let mut allowed_sources = BTreeSet::new();
                        for part_json in group {
                            let parsed = parse_meeting_minutes_json(part_json, spine)
                                .map_err(|e| format!("invalid child checkpoint JSON: {e:?}"))?;
                            for cid in parsed.all_cited_ids() {
                                allowed_sources.insert(cid);
                            }
                        }
                        let payload_text = group
                            .iter()
                            .enumerate()
                            .map(|(j, part)| format!("片段 {}:\n{}", j + 1, part.trim()))
                            .collect::<Vec<_>>()
                            .join("\n\n");
                        return Ok(Some(MinutesNodeSpec {
                            node_id,
                            is_merge_node: true,
                            payload_text,
                            allowed_sources,
                        }));
                    }
                }
                idx += 3;
            }
            current_level = next_level;
            depth += 1;
        }

        Ok(None)
    }

    /// Validates `raw_json` against `spine` AND the `node_id`'s `allowed_sources`, then records
    /// the checkpoint and clears `unconfirmed_node`.
    pub fn complete_node(
        &mut self,
        node_id: &str,
        raw_json: &str,
        allowed_sources: &BTreeSet<SegmentId>,
        spine: &UtteranceSpine,
    ) -> Result<MeetingMinutes, MinutesValidationError> {
        let minutes = parse_meeting_minutes_json_with_allowed(
            raw_json,
            spine,
            Some((node_id, allowed_sources)),
        )?;
        let cleaned = extract_json_object(raw_json).to_string();
        self.checkpoints.insert(node_id.to_string(), cleaned);
        if self.unconfirmed_node.as_deref() == Some(node_id) {
            self.unconfirmed_node = None;
        }
        Ok(minutes)
    }

    /// Returns the final converged [`MeetingMinutes`] when all nodes are complete.
    pub fn finalized_minutes(
        &self,
        spine: &UtteranceSpine,
    ) -> Result<Option<MeetingMinutes>, MinutesValidationError> {
        if self.batches.is_empty() {
            return Ok(None);
        }
        if self.batches.len() == 1 {
            let Some(raw) = self.checkpoints.get("final") else {
                return Ok(None);
            };
            return parse_meeting_minutes_json_with_allowed(
                raw,
                spine,
                Some(("final", &self.batches[0].allowed_sources)),
            )
            .map(Some);
        }

        let n = self.batches.len();
        let mut current_level = Vec::with_capacity(n);
        for i in 0..n {
            let node_id = format!("片段 {}/{n}", i + 1);
            let Some(saved) = self.checkpoints.get(&node_id) else {
                return Ok(None);
            };
            current_level.push(saved.clone());
        }
        let mut depth = 1usize;
        while current_level.len() > 1 {
            let mut next_level = Vec::new();
            let mut idx = 0usize;
            while idx < current_level.len() {
                let end = (idx + 3).min(current_level.len());
                let group = &current_level[idx..end];
                if group.len() == 1 {
                    next_level.push(group[0].clone());
                } else {
                    let node_id = format!("汇总 {depth}-{}", idx / 3);
                    let Some(saved) = self.checkpoints.get(&node_id) else {
                        return Ok(None);
                    };
                    next_level.push(saved.clone());
                }
                idx += 3;
            }
            current_level = next_level;
            depth += 1;
        }
        parse_meeting_minutes_json(&current_level[0], spine).map(Some)
    }

    fn check_duplicate_guard(&self, node_id: &str, confirmed_restart: bool) -> Result<(), String> {
        if self.avoid_duplicate_charges
            && !confirmed_restart
            && self.unconfirmed_node.as_deref() == Some(node_id)
        {
            return Err(format!(
                "Node '{node_id}' was already dispatched to a paid endpoint and its completion is unconfirmed; pass confirmed_restart=true to retry"
            ));
        }
        Ok(())
    }
}

/// Validation failure returned when a [`MeetingMinutes`] document or claim violates `S1..Sn` grounding.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MinutesValidationError {
    /// Raw output was not valid JSON or missed required schema fields.
    InvalidJson(String),
    /// `schemaVersion` was neither `1` nor `2`.
    UnsupportedSchemaVersion(i64),
    /// A claim referenced an empty citation list or a [`SegmentId`] outside `spine`.
    InvalidCitation {
        /// The ungrounded claim text.
        claim: String,
        /// The missing or invalid citation, if any.
        invalid_id: Option<SegmentId>,
    },
    /// A chunk/merge node cited a [`SegmentId`] outside its permitted `allowed_sources` subset.
    NodeCitedDisallowedSource {
        /// The chunk or merge node identifier.
        node_id: String,
        /// The disallowed citation.
        disallowed_id: SegmentId,
    },
    /// A `terms[].heard` variant did not appear verbatim in any cited `S{k}` segment.
    UngroundedHeardVariant {
        /// Canonical term name.
        term: String,
        /// Misheard spelling that was not found in the cited source segments.
        heard: String,
    },
    /// A claim synthesized a wage/salary + percentage calculation across multiple segments
    /// instead of citing a single source sentence that already states both figures.
    UngroundedWageCalculation {
        /// The rejected calculation claim text.
        claim: String,
    },
    /// A claim synthesized a calculation ratio (`基数`, `按...计算`, `基于...计算`, `按...比例...缴纳/计算`)
    /// with a percentage without a single cited sentence containing both `工资`/`基数` and a percentage.
    BaselessRatioCalculation {
        /// The rejected calculation ratio claim text.
        claim: String,
    },
    /// A concrete percentage figure in `claim` (such as `80%` or `百分之80`) did not appear
    /// in any of its cited `S{k}` source segments.
    UncitedPercentageNumber {
        /// The claim containing the fabricated percentage.
        claim: String,
        /// The ungrounded percentage token.
        percentage: String,
    },
}

/// Returns `true` if `text` contains a percentage figure (such as `"80%"`, `"80％"`, or `"百分之"`).
#[must_use]
pub fn contains_percentage(text: &str) -> bool {
    !extract_percentage_tokens(text).is_empty() || text.contains("百分之")
}

/// Extracts concrete percentage tokens from `text` (such as `"80%"`, `"15.5％"`, `"百分之80"`, `"百分之八十"`).
#[must_use]
pub fn extract_percentage_tokens(text: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let chars: Vec<char> = text.chars().collect();
    let n = chars.len();
    let mut i = 0usize;

    while i < n {
        if chars[i].is_ascii_digit() {
            let start = i;
            while i < n && chars[i].is_ascii_digit() {
                i += 1;
            }
            if i + 1 < n && chars[i] == '.' && chars[i + 1].is_ascii_digit() {
                i += 1;
                while i < n && chars[i].is_ascii_digit() {
                    i += 1;
                }
            }
            let num_end = i;
            let mut ws = i;
            while ws < n && (chars[ws] == ' ' || chars[ws] == '\t') {
                ws += 1;
            }
            if ws < n && (chars[ws] == '%' || chars[ws] == '％') {
                let num_str: String = chars[start..num_end].iter().collect();
                tokens.push(format!("{num_str}%"));
                i = ws + 1;
                continue;
            }
            continue;
        }

        if i + 3 <= n && chars[i] == '百' && chars[i + 1] == '分' && chars[i + 2] == '之' {
            let start = i;
            i += 3;
            let num_start = i;
            while i < n
                && (chars[i].is_ascii_digit()
                    || matches!(
                        chars[i],
                        '.' | '点'
                            | '零'
                            | '一'
                            | '二'
                            | '两'
                            | '三'
                            | '四'
                            | '五'
                            | '六'
                            | '七'
                            | '八'
                            | '九'
                            | '十'
                            | '百'
                    ))
            {
                i += 1;
            }
            if i > num_start {
                let tok: String = chars[start..i].iter().collect();
                tokens.push(tok);
                continue;
            }
        }
        i += 1;
    }
    tokens
}

fn normalize_percentage_value(token: &str) -> String {
    if let Some(rest) = token.strip_prefix("百分之") {
        let converted = chinese_num_to_ascii(rest);
        format!("{converted}%")
    } else {
        token
            .trim()
            .trim_end_matches(['%', '％'])
            .trim()
            .to_string()
            + "%"
    }
}

fn chinese_num_to_ascii(s: &str) -> String {
    if s.chars().all(|c| c.is_ascii_digit() || c == '.') {
        return s.to_string();
    }
    match s {
        "十" => "10".to_string(),
        "二十" => "20".to_string(),
        "三十" => "30".to_string(),
        "四十" => "40".to_string(),
        "五十" => "50".to_string(),
        "六十" => "60".to_string(),
        "七十" => "70".to_string(),
        "八十" => "80".to_string(),
        "九十" => "90".to_string(),
        "一百" => "100".to_string(),
        _ => s.replace('点', "."),
    }
}

/// Returns `true` if `text` contains a wage/salary keyword (`"工资"`, `"薪资"`, `"底薪"`, `"月薪"`, `"基本工资"`, `"实发"`).
#[must_use]
pub fn contains_wage_keyword(text: &str) -> bool {
    const WAGE_KEYWORDS: [&str; 6] = ["工资", "薪资", "底薪", "月薪", "基本工资", "实发"];
    WAGE_KEYWORDS.iter().any(|kw| text.contains(kw))
}

/// Returns `true` if `text` contains a wage/salary calculation phrase (such as `"工资"`, `"薪资"`,
/// `"底薪"`, `"乘以"`, or `"*"`).
#[must_use]
pub fn contains_calculation_phrase(text: &str) -> bool {
    const KEYWORDS: [&str; 9] = [
        "工资",
        "薪资",
        "底薪",
        "月薪",
        "基本工资",
        "乘以",
        "实发",
        "×",
        "*",
    ];
    KEYWORDS.iter().any(|kw| text.contains(kw))
}

/// Returns `true` if `text` matches the calculation-ratio pattern from `_calcPattern` in
/// `lib/state/meeting_minutes.dart`: `"基数"`, `"按...计算"`, `"基于...计算"`, or `"按...比例...(缴纳|计算)"`.
#[must_use]
pub fn contains_ratio_calculation_pattern(text: &str) -> bool {
    if text.contains("基数") {
        return true;
    }
    for clause in text.split(['。', '；', '\n']) {
        let chars: Vec<char> = clause.chars().collect();
        let n = chars.len();
        for i in 0..n {
            if i + 1 < n && chars[i] == '基' && chars[i + 1] == '于' {
                let rest: String = chars[i + 2..(i + 2 + 26).min(n)].iter().collect();
                if let Some(pos) = rest.find("计算") {
                    if rest[..pos].chars().count() <= 24 {
                        return true;
                    }
                }
            }
            if chars[i] == '按' {
                let window: String = chars[i + 1..(i + 1 + 48).min(n)].iter().collect();
                if let Some(pos) = window.find("计算") {
                    if window[..pos].chars().count() <= 24 {
                        return true;
                    }
                }
                if let Some(p_pos) = window.find("比例") {
                    if window[..p_pos].chars().count() <= 24 {
                        let after_ratio = &window[p_pos + "比例".len()..];
                        for target in ["缴纳", "计算"] {
                            if let Some(t_pos) = after_ratio.find(target) {
                                if after_ratio[..t_pos].chars().count() <= 16 {
                                    return true;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    false
}

/// Validates that a single `claim` and its `citations` are grounded in `spine`.
///
/// Specifically:
/// 1. `citations` must be non-empty and every [`SegmentId`] must resolve to a non-empty segment in `spine`.
/// 2. If `claim` combines a wage/salary keyword with a percentage in the same clause, at least one
///    cited `S{k}` must contain both a wage/base keyword and a percentage (`UngroundedWageCalculation`).
/// 3. If `claim` combines a ratio calculation pattern (`基数`, `按...计算`, `基于...计算`,
///    `按...比例...缴纳/计算`) with a percentage, at least one cited `S{k}` must contain both
///    `工资`/`基数` and a percentage (`BaselessRatioCalculation`).
/// 4. Every concrete percentage token in `claim` (such as `80%` or `百分之80`) must appear in at least
///    one cited `S{k}` segment (`UncitedPercentageNumber`).
pub fn validate_calculation_grounding(
    claim: &str,
    citations: &[SegmentId],
    spine: &UtteranceSpine,
) -> Result<(), MinutesValidationError> {
    validate_claim_grounding_inner(claim, citations, spine, true)
}

fn validate_claim_grounding_inner(
    claim: &str,
    citations: &[SegmentId],
    spine: &UtteranceSpine,
    check_uncited_percentage_number: bool,
) -> Result<(), MinutesValidationError> {
    if citations.is_empty() {
        return Err(MinutesValidationError::InvalidCitation {
            claim: claim.to_string(),
            invalid_id: None,
        });
    }
    for &id in citations {
        if !spine.validate_citation(id) {
            return Err(MinutesValidationError::InvalidCitation {
                claim: claim.to_string(),
                invalid_id: Some(id),
            });
        }
    }

    if !contains_percentage(claim) {
        return Ok(());
    }

    let wage_in_same_clause = claim
        .split(['。', '；', '！', '？', '\n'])
        .any(|clause| contains_percentage(clause) && contains_wage_keyword(clause));
    let wage_with_mult = contains_wage_keyword(claim)
        && (claim.contains("乘以") || claim.contains('×') || claim.contains('*'));
    let has_ratio_calc = contains_ratio_calculation_pattern(claim);

    let single_segment_grounds_wage_and_pct = citations.iter().any(|&id| {
        spine.get(id).is_some_and(|seg| {
            contains_percentage(&seg.text)
                && (contains_wage_keyword(&seg.text) || seg.text.contains("基数"))
        })
    });

    if (wage_in_same_clause || wage_with_mult) && !single_segment_grounds_wage_and_pct {
        return Err(MinutesValidationError::UngroundedWageCalculation {
            claim: claim.to_string(),
        });
    }

    if has_ratio_calc && !single_segment_grounds_wage_and_pct {
        return Err(MinutesValidationError::BaselessRatioCalculation {
            claim: claim.to_string(),
        });
    }

    if check_uncited_percentage_number {
        let claim_pcts = extract_percentage_tokens(claim);
        for pct in claim_pcts {
            let norm = normalize_percentage_value(&pct);
            let found_in_cited = citations.iter().any(|&id| {
                spine.get(id).is_some_and(|seg| {
                    if seg.text.contains(&pct) {
                        return true;
                    }
                    extract_percentage_tokens(&seg.text)
                        .iter()
                        .any(|s_pct| normalize_percentage_value(s_pct) == norm)
                })
            });
            if !found_in_cited {
                return Err(MinutesValidationError::UncitedPercentageNumber {
                    claim: claim.to_string(),
                    percentage: pct,
                });
            }
        }
    }

    Ok(())
}

/// Validates every overview, topic, point, decision, action, question, fishbone cause, term
/// (including `heard` variants), and custom section in `minutes` against `spine`.
pub fn validate_minutes_grounding(
    minutes: &MeetingMinutes,
    spine: &UtteranceSpine,
) -> Result<(), MinutesValidationError> {
    if !spine.is_empty() && !minutes.overview.trim().is_empty() {
        let all_ids: Vec<SegmentId> = spine.segments().iter().map(|s| s.id).collect();
        validate_claim_grounding_inner(&minutes.overview, &all_ids, spine, false)?;
    }

    for topic in &minutes.topics {
        if !topic.citations.is_empty() {
            validate_calculation_grounding(&topic.title, &topic.citations, spine)?;
            if !topic.summary.trim().is_empty() {
                validate_calculation_grounding(&topic.summary, &topic.citations, spine)?;
            }
        }
        for point in &topic.points {
            validate_point(point, spine)?;
        }
        if let Some(fb) = &topic.fishbone {
            for cause in &fb.causes {
                let combined = format!("{} {}", cause.category, cause.description);
                validate_calculation_grounding(&combined, &cause.citations, spine)?;
            }
        }
    }

    for d in &minutes.decisions {
        validate_point(d, spine)?;
    }
    for a in &minutes.actions {
        validate_point(a, spine)?;
    }
    for q in &minutes.questions {
        validate_point(q, spine)?;
    }
    for fb in &minutes.fishbones {
        for cause in &fb.causes {
            let combined = format!("{} {}", cause.category, cause.description);
            validate_calculation_grounding(&combined, &cause.citations, spine)?;
        }
    }
    for term in &minutes.terms {
        for spelling in &term.heard {
            let trimmed = spelling.trim();
            if trimmed.is_empty() {
                return Err(MinutesValidationError::UngroundedHeardVariant {
                    term: term.term.clone(),
                    heard: spelling.clone(),
                });
            }
            let grounded = term
                .citations
                .iter()
                .any(|&id| spine.get(id).is_some_and(|seg| seg.text.contains(trimmed)));
            if !grounded {
                return Err(MinutesValidationError::UngroundedHeardVariant {
                    term: term.term.clone(),
                    heard: trimmed.to_string(),
                });
            }
        }
        let combined = format!("{} {}", term.term, term.definition);
        validate_calculation_grounding(&combined, &term.citations, spine)?;
    }
    for section in &minutes.custom_sections {
        for point in &section.points {
            validate_point(point, spine)?;
        }
    }
    Ok(())
}

fn validate_point(
    point: &MinutePoint,
    spine: &UtteranceSpine,
) -> Result<(), MinutesValidationError> {
    validate_calculation_grounding(&point.claim, &point.citations, spine)
}

fn validate_citation_slice(
    claim: &str,
    citations: &[SegmentId],
    spine: &UtteranceSpine,
) -> Result<(), MinutesValidationError> {
    if citations.is_empty() {
        return Err(MinutesValidationError::InvalidCitation {
            claim: claim.to_string(),
            invalid_id: None,
        });
    }
    for &id in citations {
        if !spine.validate_citation(id) {
            return Err(MinutesValidationError::InvalidCitation {
                claim: claim.to_string(),
                invalid_id: Some(id),
            });
        }
    }
    Ok(())
}

/// Validates non-empty citation lists and live `S1..Sn` existence across all sections of `minutes`.
pub fn validate_minutes_citations(
    minutes: &MeetingMinutes,
    spine: &UtteranceSpine,
) -> Result<(), MinutesValidationError> {
    for topic in &minutes.topics {
        if !topic.citations.is_empty() {
            validate_citation_slice(&topic.title, &topic.citations, spine)?;
        }
        for point in &topic.points {
            validate_citation_slice(&point.claim, &point.citations, spine)?;
        }
        if let Some(fb) = &topic.fishbone {
            for cause in &fb.causes {
                let combined = format!("{} {}", cause.category, cause.description);
                validate_citation_slice(&combined, &cause.citations, spine)?;
            }
        }
    }
    for d in &minutes.decisions {
        validate_citation_slice(&d.claim, &d.citations, spine)?;
    }
    for a in &minutes.actions {
        validate_citation_slice(&a.claim, &a.citations, spine)?;
    }
    for q in &minutes.questions {
        validate_citation_slice(&q.claim, &q.citations, spine)?;
    }
    for fb in &minutes.fishbones {
        for cause in &fb.causes {
            let combined = format!("{} {}", cause.category, cause.description);
            validate_citation_slice(&combined, &cause.citations, spine)?;
        }
    }
    for term in &minutes.terms {
        for spelling in &term.heard {
            let trimmed = spelling.trim();
            if trimmed.is_empty() || trimmed.chars().count() > 20_000 {
                return Err(MinutesValidationError::InvalidJson(
                    "empty or oversized term.heard item".to_string(),
                ));
            }
        }
        let combined = format!("{} {}", term.term, term.definition);
        validate_citation_slice(&combined, &term.citations, spine)?;
    }
    for section in &minutes.custom_sections {
        for point in &section.points {
            validate_citation_slice(&point.claim, &point.citations, spine)?;
        }
    }
    Ok(())
}

/// Parses persisted [`MeetingMinutes`] JSON against `spine`, enforcing full lexical grounding
/// when `require_lexical_grounding` is `true` and citation totality when `false`.
pub fn parse_persisted_meeting_minutes_json(
    raw: &str,
    spine: &UtteranceSpine,
    require_lexical_grounding: bool,
) -> Result<MeetingMinutes, MinutesValidationError> {
    parse_meeting_minutes_json_inner(raw, spine, None, require_lexical_grounding)
}

/// Parses and validates a raw LLM JSON response into [`MeetingMinutes`] against `spine`,
/// enforcing all schema, citation, `heard`, and calculation grounding rules from `MeetingMinutes.parse`.
pub fn parse_meeting_minutes_json(
    raw: &str,
    spine: &UtteranceSpine,
) -> Result<MeetingMinutes, MinutesValidationError> {
    parse_meeting_minutes_json_with_allowed(raw, spine, None)
}

/// Parses and validates a raw LLM JSON response into [`MeetingMinutes`] against `spine` and an
/// optional `(node_id, allowed_sources)` constraint.
pub fn parse_meeting_minutes_json_with_allowed(
    raw: &str,
    spine: &UtteranceSpine,
    allowed_node: Option<(&str, &BTreeSet<SegmentId>)>,
) -> Result<MeetingMinutes, MinutesValidationError> {
    parse_meeting_minutes_json_inner(raw, spine, allowed_node, true)
}

fn parse_meeting_minutes_json_inner(
    raw: &str,
    spine: &UtteranceSpine,
    allowed_node: Option<(&str, &BTreeSet<SegmentId>)>,
    require_lexical_grounding: bool,
) -> Result<MeetingMinutes, MinutesValidationError> {
    let extracted = extract_json_object(raw);
    let val = JsonValue::parse(extracted).map_err(MinutesValidationError::InvalidJson)?;
    let map = val
        .as_object()
        .ok_or_else(|| MinutesValidationError::InvalidJson("root must be an object".to_string()))?;

    let version = match map.get("schemaVersion") {
        None | Some(JsonValue::Null) => 1u32,
        Some(v) => {
            let Some(n) = v.as_i64() else {
                return Err(MinutesValidationError::UnsupportedSchemaVersion(-1));
            };
            if n != 1 && n != 2 {
                return Err(MinutesValidationError::UnsupportedSchemaVersion(n));
            }
            n as u32
        }
    };

    let req_str =
        |obj: &BTreeMap<String, JsonValue>, key: &str| -> Result<String, MinutesValidationError> {
            let Some(s) = obj.get(key).and_then(JsonValue::as_str) else {
                return Err(MinutesValidationError::InvalidJson(format!(
                    "missing or non-string field '{key}'"
                )));
            };
            let t = s.trim();
            if t.is_empty() || (version == 2 && t.chars().count() > 20_000) {
                return Err(MinutesValidationError::InvalidJson(format!(
                    "empty or oversized field '{key}'"
                )));
            }
            Ok(t.to_string())
        };

    let opt_str = |obj: &BTreeMap<String, JsonValue>,
                   key: &str|
     -> Result<Option<String>, MinutesValidationError> {
        match obj.get(key) {
            None | Some(JsonValue::Null) => Ok(None),
            Some(JsonValue::String(s)) => {
                let t = s.trim();
                if version == 2 && t.chars().count() > 20_000 {
                    return Err(MinutesValidationError::InvalidJson(format!(
                        "oversized optional field '{key}'"
                    )));
                }
                if t.is_empty() {
                    Ok(None)
                } else {
                    Ok(Some(t.to_string()))
                }
            }
            _ => Err(MinutesValidationError::InvalidJson(format!(
                "non-string optional field '{key}'"
            ))),
        }
    };

    let parse_sources = |obj: &BTreeMap<String, JsonValue>,
                         claim_label: &str|
     -> Result<Vec<SegmentId>, MinutesValidationError> {
        let Some(arr) = obj.get("sources").and_then(JsonValue::as_array) else {
            return Err(MinutesValidationError::InvalidCitation {
                claim: claim_label.to_string(),
                invalid_id: None,
            });
        };
        if arr.is_empty() {
            return Err(MinutesValidationError::InvalidCitation {
                claim: claim_label.to_string(),
                invalid_id: None,
            });
        }
        let mut seen = BTreeSet::new();
        let mut out = Vec::with_capacity(arr.len());
        for entry in arr {
            let Some(s) = entry.as_str() else {
                return Err(MinutesValidationError::InvalidCitation {
                    claim: claim_label.to_string(),
                    invalid_id: None,
                });
            };
            let trimmed = s.trim();
            if !trimmed.starts_with('S') {
                return Err(MinutesValidationError::InvalidCitation {
                    claim: claim_label.to_string(),
                    invalid_id: None,
                });
            }
            let Some(seg_id) = SegmentId::parse_citation(trimmed) else {
                return Err(MinutesValidationError::InvalidCitation {
                    claim: claim_label.to_string(),
                    invalid_id: None,
                });
            };
            if !spine.validate_citation(seg_id) {
                return Err(MinutesValidationError::InvalidCitation {
                    claim: claim_label.to_string(),
                    invalid_id: Some(seg_id),
                });
            }
            if let Some((node_id, allowed)) = allowed_node {
                if !allowed.contains(&seg_id) {
                    return Err(MinutesValidationError::NodeCitedDisallowedSource {
                        node_id: node_id.to_string(),
                        disallowed_id: seg_id,
                    });
                }
            }
            if seen.insert(seg_id) {
                out.push(seg_id);
            }
        }
        Ok(out)
    };

    let parse_point = |val: &JsonValue| -> Result<MinutePoint, MinutesValidationError> {
        let obj = val.as_object().ok_or_else(|| {
            MinutesValidationError::InvalidJson("item must be an object".to_string())
        })?;
        let text = req_str(obj, "text")?;
        let owner = opt_str(obj, "owner")?;
        let due = opt_str(obj, "due")?;
        let speaker = opt_str(obj, "speaker")?;
        let citations = parse_sources(obj, &text)?;
        Ok(MinutePoint {
            claim: text,
            speaker,
            owner,
            due,
            citations,
        })
    };

    let parse_point_list =
        |key: &str, required: bool| -> Result<Vec<MinutePoint>, MinutesValidationError> {
            let Some(v) = map.get(key) else {
                if required {
                    return Err(MinutesValidationError::InvalidJson(format!(
                        "missing required array '{key}'"
                    )));
                }
                return Ok(Vec::new());
            };
            if matches!(v, JsonValue::Null) && !required {
                return Ok(Vec::new());
            }
            let arr = v.as_array().ok_or_else(|| {
                MinutesValidationError::InvalidJson(format!("field '{key}' must be an array"))
            })?;
            arr.iter().map(parse_point).collect()
        };

    let parse_fishbone = |val: &JsonValue| -> Result<MinuteFishbone, MinutesValidationError> {
        let obj = val.as_object().ok_or_else(|| {
            MinutesValidationError::InvalidJson("fishbone must be an object".to_string())
        })?;
        let question = req_str(obj, "question")?;
        let branches = obj
            .get("branches")
            .and_then(JsonValue::as_array)
            .ok_or_else(|| {
                MinutesValidationError::InvalidJson(
                    "fishbone.branches must be an array".to_string(),
                )
            })?;
        if branches.is_empty() || branches.len() > 8 {
            return Err(MinutesValidationError::InvalidJson(
                "fishbone.branches must have 1..=8 items".to_string(),
            ));
        }
        let mut causes = Vec::with_capacity(branches.len());
        for b in branches {
            let b_obj = b.as_object().ok_or_else(|| {
                MinutesValidationError::InvalidJson("fishbone branch must be an object".to_string())
            })?;
            let category = req_str(b_obj, "text")?;
            let description = req_str(b_obj, "detail")?;
            let citations = parse_sources(b_obj, &format!("{category} {description}"))?;
            causes.push(MinuteCause {
                category,
                description,
                citations,
            });
        }
        Ok(MinuteFishbone {
            issue: question,
            causes,
        })
    };

    let title = req_str(map, "title")?;
    let overview = req_str(map, "overview")?;

    let topics_arr = map
        .get("topics")
        .and_then(JsonValue::as_array)
        .ok_or_else(|| MinutesValidationError::InvalidJson("missing 'topics' array".to_string()))?;
    let mut topics = Vec::with_capacity(topics_arr.len());
    let mut top_fishbones = Vec::new();
    for t_val in topics_arr {
        let t_obj = t_val.as_object().ok_or_else(|| {
            MinutesValidationError::InvalidJson("topic must be an object".to_string())
        })?;
        let t_title = req_str(t_obj, "text")?;
        let t_citations = parse_sources(t_obj, &t_title)?;
        let t_summary = opt_str(t_obj, "summary")?.unwrap_or_default();
        let t_points = match t_obj.get("points") {
            None | Some(JsonValue::Null) => Vec::new(),
            Some(JsonValue::Array(arr)) => {
                arr.iter().map(parse_point).collect::<Result<Vec<_>, _>>()?
            }
            _ => {
                return Err(MinutesValidationError::InvalidJson(
                    "topic.points must be an array".to_string(),
                ))
            }
        };
        let t_fishbone = match t_obj.get("fishbone") {
            None | Some(JsonValue::Null) => None,
            Some(fb_val) => {
                let fb = parse_fishbone(fb_val)?;
                top_fishbones.push(fb.clone());
                Some(fb)
            }
        };
        topics.push(MinuteTopic {
            title: t_title,
            summary: t_summary,
            citations: t_citations,
            points: t_points,
            fishbone: t_fishbone,
        });
    }
    if let Some(fbs_val) = map.get("fishbones") {
        if !matches!(fbs_val, JsonValue::Null) {
            let arr = fbs_val.as_array().ok_or_else(|| {
                MinutesValidationError::InvalidJson("'fishbones' must be an array".to_string())
            })?;
            for fb_val in arr {
                let fb = parse_fishbone(fb_val)?;
                if !top_fishbones.contains(&fb) {
                    top_fishbones.push(fb);
                }
            }
        }
    }

    let decisions = parse_point_list("decisions", true)?;
    let actions = parse_point_list("actions", true)?;
    let questions = parse_point_list("questions", true)?;

    let mut custom_sections = Vec::new();
    if let Some(custom_val) = map.get("custom") {
        if !matches!(custom_val, JsonValue::Null) {
            let custom_obj = custom_val.as_object().ok_or_else(|| {
                MinutesValidationError::InvalidJson("'custom' must be an object".to_string())
            })?;
            for (heading, items_val) in custom_obj {
                let clean_heading = heading.trim();
                if clean_heading.is_empty()
                    || (version == 2 && clean_heading.chars().count() > 20_000)
                {
                    return Err(MinutesValidationError::InvalidJson(
                        "invalid custom section heading".to_string(),
                    ));
                }
                let arr = items_val.as_array().ok_or_else(|| {
                    MinutesValidationError::InvalidJson(
                        "custom section items must be an array".to_string(),
                    )
                })?;
                let pts = arr.iter().map(parse_point).collect::<Result<Vec<_>, _>>()?;
                custom_sections.push(MinuteCustomSection {
                    heading: clean_heading.to_string(),
                    points: pts,
                });
            }
        }
    }

    let mut review_items = Vec::new();
    if let Some(rev_val) = map.get("reviewItems") {
        if !matches!(rev_val, JsonValue::Null) {
            let arr = rev_val.as_array().ok_or_else(|| {
                MinutesValidationError::InvalidJson("'reviewItems' must be an array".to_string())
            })?;
            for r in arr {
                let Some(s) = r.as_str() else {
                    return Err(MinutesValidationError::InvalidJson(
                        "reviewItems entry must be a string".to_string(),
                    ));
                };
                let t = s.trim();
                if t.is_empty() || (version == 2 && t.chars().count() > 20_000) {
                    return Err(MinutesValidationError::InvalidJson(
                        "invalid reviewItems entry".to_string(),
                    ));
                }
                review_items.push(t.to_string());
            }
        }
    }

    let mut terms = Vec::new();
    if let Some(terms_val) = map.get("terms") {
        if !matches!(terms_val, JsonValue::Null) {
            if version < 2 {
                return Err(MinutesValidationError::InvalidJson(
                    "'terms' is only supported in schemaVersion 2".to_string(),
                ));
            }
            let arr = terms_val.as_array().ok_or_else(|| {
                MinutesValidationError::InvalidJson("'terms' must be an array".to_string())
            })?;
            for entry in arr {
                let t_obj = entry.as_object().ok_or_else(|| {
                    MinutesValidationError::InvalidJson("term entry must be an object".to_string())
                })?;
                let name = req_str(t_obj, "name")?;
                let note = req_str(t_obj, "note")?;
                let citations = parse_sources(t_obj, &format!("{name} {note}"))?;
                let mut heard = Vec::new();
                if let Some(h_val) = t_obj.get("heard") {
                    if !matches!(h_val, JsonValue::Null) {
                        let h_arr = h_val.as_array().ok_or_else(|| {
                            MinutesValidationError::InvalidJson(
                                "term.heard must be an array".to_string(),
                            )
                        })?;
                        if h_arr.len() > 30 {
                            return Err(MinutesValidationError::InvalidJson(
                                "term.heard exceeds 30 entries".to_string(),
                            ));
                        }
                        let mut seen_h = BTreeSet::new();
                        for h_item in h_arr {
                            let Some(hs) = h_item.as_str() else {
                                return Err(MinutesValidationError::InvalidJson(
                                    "term.heard item must be a string".to_string(),
                                ));
                            };
                            let ht = hs.trim();
                            if ht.is_empty() || ht.chars().count() > 20_000 {
                                return Err(MinutesValidationError::InvalidJson(
                                    "empty or oversized term.heard item".to_string(),
                                ));
                            }
                            if require_lexical_grounding {
                                let grounded = citations.iter().any(|&cid| {
                                    spine.get(cid).is_some_and(|seg| seg.text.contains(ht))
                                });
                                if !grounded {
                                    return Err(MinutesValidationError::UngroundedHeardVariant {
                                        term: name,
                                        heard: ht.to_string(),
                                    });
                                }
                            }
                            if seen_h.insert(ht.to_string()) {
                                heard.push(ht.to_string());
                            }
                        }
                    }
                }
                terms.push(MinuteTerm {
                    term: name,
                    definition: note,
                    heard,
                    adoption: MinuteTermAdoption::Suggested,
                    citations,
                });
            }
        }
    }

    let minutes = MeetingMinutes {
        version,
        spine_revision: spine.revision(),
        title,
        overview,
        topics,
        decisions,
        actions,
        questions,
        fishbones: top_fishbones,
        terms,
        custom_sections,
        review_items,
    };

    if require_lexical_grounding {
        validate_minutes_grounding(&minutes, spine)?;
    } else {
        validate_minutes_citations(&minutes, spine)?;
    }
    Ok(minutes)
}

/// Encodes [`MeetingMinutes`] into the canonical JSON schema consumed by Koe's Dart UI
/// (`MeetingMinutes.toJson` in `lib/state/meeting_minutes.dart`).
#[must_use]
pub fn encode_meeting_minutes_json(minutes: &MeetingMinutes) -> String {
    let encode_sources = |citations: &[SegmentId]| -> JsonValue {
        JsonValue::Array(
            citations
                .iter()
                .map(|id| JsonValue::String(id.to_string()))
                .collect(),
        )
    };
    let encode_point = |pt: &MinutePoint| -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert("text".to_string(), JsonValue::String(pt.claim.clone()));
        if let Some(owner) = &pt.owner {
            obj.insert("owner".to_string(), JsonValue::String(owner.clone()));
        }
        if let Some(due) = &pt.due {
            obj.insert("due".to_string(), JsonValue::String(due.clone()));
        }
        if let Some(speaker) = &pt.speaker {
            obj.insert("speaker".to_string(), JsonValue::String(speaker.clone()));
        }
        obj.insert("sources".to_string(), encode_sources(&pt.citations));
        JsonValue::Object(obj)
    };
    let encode_fishbone = |fb: &MinuteFishbone| -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert("question".to_string(), JsonValue::String(fb.issue.clone()));
        let branches = fb
            .causes
            .iter()
            .map(|c| {
                let mut b = BTreeMap::new();
                b.insert("text".to_string(), JsonValue::String(c.category.clone()));
                b.insert(
                    "detail".to_string(),
                    JsonValue::String(c.description.clone()),
                );
                b.insert("sources".to_string(), encode_sources(&c.citations));
                JsonValue::Object(b)
            })
            .collect();
        obj.insert("branches".to_string(), JsonValue::Array(branches));
        JsonValue::Object(obj)
    };

    let mut root = BTreeMap::new();
    root.insert(
        "schemaVersion".to_string(),
        JsonValue::Number(f64::from(minutes.version.max(1))),
    );
    root.insert(
        "title".to_string(),
        JsonValue::String(minutes.title.clone()),
    );
    root.insert(
        "overview".to_string(),
        JsonValue::String(minutes.overview.clone()),
    );

    let topics_json: Vec<JsonValue> = minutes
        .topics
        .iter()
        .map(|t| {
            let mut obj = BTreeMap::new();
            obj.insert("text".to_string(), JsonValue::String(t.title.clone()));
            let citations = if t.citations.is_empty() {
                t.points
                    .first()
                    .map(|p| p.citations.clone())
                    .unwrap_or_default()
            } else {
                t.citations.clone()
            };
            obj.insert("sources".to_string(), encode_sources(&citations));
            if !t.summary.is_empty() {
                obj.insert("summary".to_string(), JsonValue::String(t.summary.clone()));
            }
            if !t.points.is_empty() {
                obj.insert(
                    "points".to_string(),
                    JsonValue::Array(t.points.iter().map(encode_point).collect()),
                );
            }
            if let Some(fb) = &t.fishbone {
                obj.insert("fishbone".to_string(), encode_fishbone(fb));
            }
            JsonValue::Object(obj)
        })
        .collect();
    root.insert("topics".to_string(), JsonValue::Array(topics_json));
    if !minutes.fishbones.is_empty() {
        root.insert(
            "fishbones".to_string(),
            JsonValue::Array(minutes.fishbones.iter().map(encode_fishbone).collect()),
        );
    }
    root.insert(
        "decisions".to_string(),
        JsonValue::Array(minutes.decisions.iter().map(encode_point).collect()),
    );
    root.insert(
        "actions".to_string(),
        JsonValue::Array(minutes.actions.iter().map(encode_point).collect()),
    );
    root.insert(
        "questions".to_string(),
        JsonValue::Array(minutes.questions.iter().map(encode_point).collect()),
    );

    if !minutes.custom_sections.is_empty() {
        let mut custom_map = BTreeMap::new();
        for sec in &minutes.custom_sections {
            custom_map.insert(
                sec.heading.clone(),
                JsonValue::Array(sec.points.iter().map(encode_point).collect()),
            );
        }
        root.insert("custom".to_string(), JsonValue::Object(custom_map));
    }
    if !minutes.review_items.is_empty() {
        root.insert(
            "reviewItems".to_string(),
            JsonValue::Array(
                minutes
                    .review_items
                    .iter()
                    .map(|s| JsonValue::String(s.clone()))
                    .collect(),
            ),
        );
    }
    if !minutes.terms.is_empty() {
        let terms_json: Vec<JsonValue> = minutes
            .terms
            .iter()
            .map(|term| {
                let mut obj = BTreeMap::new();
                obj.insert("name".to_string(), JsonValue::String(term.term.clone()));
                obj.insert(
                    "note".to_string(),
                    JsonValue::String(term.definition.clone()),
                );
                if !term.heard.is_empty() {
                    obj.insert(
                        "heard".to_string(),
                        JsonValue::Array(
                            term.heard
                                .iter()
                                .map(|h| JsonValue::String(h.clone()))
                                .collect(),
                        ),
                    );
                }
                obj.insert("sources".to_string(), encode_sources(&term.citations));
                JsonValue::Object(obj)
            })
            .collect();
        root.insert("terms".to_string(), JsonValue::Array(terms_json));
    }

    JsonValue::Object(root).to_json_string()
}

/// Replaces all occurrences of non-empty keys in `replacements` in a single left-to-right pass,
/// matching the longest key at each position without re-scanning replacement text
/// (matching `replaceMinuteTerms` in `lib/state/meeting_minutes.dart`).
#[must_use]
pub fn replace_minute_terms(text: &str, replacements: &[(&str, &str)]) -> String {
    if text.is_empty() || replacements.is_empty() {
        return text.to_string();
    }
    let mut sorted: Vec<(&str, &str, usize)> = Vec::new();
    let mut seen_keys = BTreeSet::new();
    for &(from, to) in replacements {
        if !from.is_empty() && from != to && seen_keys.insert(from) {
            sorted.push((from, to, from.chars().count()));
        }
    }
    if sorted.is_empty() {
        return text.to_string();
    }
    sorted.sort_by(|a, b| b.2.cmp(&a.2).then_with(|| a.0.cmp(b.0)));

    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while !rest.is_empty() {
        let mut matched: Option<(&str, &str)> = None;
        for &(from, to, _) in &sorted {
            if rest.starts_with(from) {
                matched = Some((from, to));
                break;
            }
        }
        if let Some((from, to)) = matched {
            out.push_str(to);
            rest = &rest[from.len()..];
        } else {
            let ch = rest.chars().next().unwrap();
            out.push(ch);
            rest = &rest[ch.len_utf8()..];
        }
    }
    out
}

impl MeetingMinutes {
    /// Returns the deduplicated set of all [`SegmentId`]s cited anywhere in this document.
    #[must_use]
    pub fn all_cited_ids(&self) -> BTreeSet<SegmentId> {
        let mut ids = BTreeSet::new();
        for t in &self.topics {
            ids.extend(t.citations.iter().copied());
            for p in &t.points {
                ids.extend(p.citations.iter().copied());
            }
            if let Some(fb) = &t.fishbone {
                for c in &fb.causes {
                    ids.extend(c.citations.iter().copied());
                }
            }
        }
        for d in &self.decisions {
            ids.extend(d.citations.iter().copied());
        }
        for a in &self.actions {
            ids.extend(a.citations.iter().copied());
        }
        for q in &self.questions {
            ids.extend(q.citations.iter().copied());
        }
        for fb in &self.fishbones {
            for c in &fb.causes {
                ids.extend(c.citations.iter().copied());
            }
        }
        for term in &self.terms {
            ids.extend(term.citations.iter().copied());
        }
        for sec in &self.custom_sections {
            for p in &sec.points {
                ids.extend(p.citations.iter().copied());
            }
        }
        ids
    }

    /// Applies single-pass longest-match term replacement across all text fields, custom section
    /// headings, and `terms` (merging duplicate term names after replacement), matching
    /// `MeetingMinutes.replaceTerms` in `lib/state/meeting_minutes.dart`.
    pub fn replace_terms(&mut self, replacements: &[(&str, &str)]) {
        if replacements.is_empty() {
            return;
        }
        let r = |s: &str| replace_minute_terms(s, replacements);
        self.title = r(&self.title);
        self.overview = r(&self.overview);

        let replace_point = |pt: &mut MinutePoint| {
            pt.claim = r(&pt.claim);
            pt.owner = pt.owner.as_deref().map(&r);
            pt.due = pt.due.as_deref().map(&r);
            pt.speaker = pt.speaker.as_deref().map(&r);
        };
        let replace_fb = |fb: &mut MinuteFishbone| {
            fb.issue = r(&fb.issue);
            for c in &mut fb.causes {
                c.category = r(&c.category);
                c.description = r(&c.description);
            }
        };

        for t in &mut self.topics {
            t.title = r(&t.title);
            t.summary = r(&t.summary);
            for pt in &mut t.points {
                replace_point(pt);
            }
            if let Some(fb) = &mut t.fishbone {
                replace_fb(fb);
            }
        }
        for d in &mut self.decisions {
            replace_point(d);
        }
        for a in &mut self.actions {
            replace_point(a);
        }
        for q in &mut self.questions {
            replace_point(q);
        }
        for fb in &mut self.fishbones {
            replace_fb(fb);
        }
        for sec in &mut self.custom_sections {
            sec.heading = r(&sec.heading);
            for pt in &mut sec.points {
                replace_point(pt);
            }
        }
        self.review_items = self.review_items.iter().map(|s| r(s)).collect();

        let mut merged_terms: Vec<MinuteTerm> = Vec::new();
        for term in &self.terms {
            let next_name = r(&term.term);
            let next_note = r(&term.definition);
            let mut next_heard = Vec::new();
            for h in &term.heard {
                let rh = r(h);
                if rh != next_name && !next_heard.contains(&rh) {
                    next_heard.push(rh);
                }
            }
            if let Some(existing) = merged_terms.iter_mut().find(|t| t.term == next_name) {
                for h in next_heard {
                    if !existing.heard.contains(&h) {
                        existing.heard.push(h);
                    }
                }
                for &cid in &term.citations {
                    if !existing.citations.contains(&cid) {
                        existing.citations.push(cid);
                    }
                }
            } else {
                merged_terms.push(MinuteTerm {
                    term: next_name,
                    definition: next_note,
                    heard: next_heard,
                    adoption: term.adoption,
                    citations: term.citations.clone(),
                });
            }
        }
        self.terms = merged_terms;
    }

    /// Replaces `old_name` with `new_name` across all fields (`replaceSpeakerName`).
    pub fn replace_speaker_name(&mut self, old_name: &str, new_name: &str) {
        let from = old_name.trim();
        let to = new_name.trim();
        if from.is_empty() || to.is_empty() || from == to {
            return;
        }
        self.replace_terms(&[(from, to)]);
    }

    /// Removes a specific `heard` spelling from the term matching `term_name` (`pruneHeard`).
    pub fn prune_heard(&mut self, term_name: &str, heard_spelling: &str) {
        for t in &mut self.terms {
            if t.term == term_name {
                t.heard.retain(|h| h != heard_spelling);
            }
        }
    }
}

/// Builds the trilingual (`zh` / `en` / `ja`) meeting minutes LLM system/user prompt with
/// optional built-in or custom template sections and hot-word vocabulary hints, matching
/// `buildMeetingMinutesPrompt` in `lib/state/meeting_minutes.dart`.
#[must_use]
pub fn build_meeting_minutes_prompt(
    numbered_transcript: &str,
    locale_code: &str,
    template_id: Option<&str>,
    custom_sections: &[String],
    custom_instructions: Option<&str>,
    vocabulary: &[String],
) -> String {
    let builtin = template_id.and_then(|id| {
        BUILTIN_MINUTE_TEMPLATES
            .iter()
            .find(|tpl| tpl.id == id.trim())
    });

    let sections: Vec<String> = if !custom_sections.is_empty() {
        custom_sections
            .iter()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect()
    } else if let Some(tpl) = builtin {
        let list = match locale_code {
            "en" => tpl.sections_en,
            "ja" => tpl.sections_ja,
            _ => tpl.sections_zh,
        };
        list.iter().map(|s| (*s).to_string()).collect()
    } else {
        Vec::new()
    };

    let extra_instructions = custom_instructions
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToOwned::to_owned)
        .or_else(|| {
            builtin.and_then(|tpl| {
                let s = match locale_code {
                    "en" => tpl.instructions_en,
                    "ja" => tpl.instructions_ja,
                    _ => tpl.instructions_zh,
                };
                if s.is_empty() {
                    None
                } else {
                    Some(s.to_string())
                }
            })
        })
        .unwrap_or_default();

    let clean_vocab: Vec<String> = vocabulary
        .iter()
        .map(|w| w.trim().to_string())
        .filter(|w| !w.is_empty())
        .take(200)
        .collect();

    let mut custom_schema = String::new();
    let mut custom_rule = String::new();
    if !sections.is_empty() {
        let entries: Vec<String> = sections
            .iter()
            .map(|h| {
                let mut key = String::new();
                write_escaped_json_string(h, &mut key);
                format!("    {key}: [{{ \"text\": \"...\", \"sources\": [\"S1\"] }}]")
            })
            .collect();
        custom_schema = format!(",\n  \"custom\": {{\n{}\n  }}", entries.join(",\n"));
        let extra = if extra_instructions.is_empty() {
            String::new()
        } else {
            format!("\n- {extra_instructions}")
        };
        custom_rule = match locale_code {
            "en" => format!(
                "\n- Fill \"custom\" with the template sections ({}); use [] when a section has no grounded points.{extra}",
                sections.join(", ")
            ),
            "ja" => format!(
                "\n- \"custom\" にはテンプレートの各セクション（{}）を入れ、該当がない場合は [] にしてください。{extra}",
                sections.join("、")
            ),
            _ => format!(
                "\n- 按模板填写 \"custom\" 中的各个分栏（{}），原话未提及时填 []。{extra}",
                sections.join("、")
            ),
        };
    }

    let vocab_rule = if clean_vocab.is_empty() {
        String::new()
    } else {
        let joined = clean_vocab.join(", ");
        match locale_code {
            "en" => format!(
                "\n- Known terms / proper nouns (correct obvious homophone ASR errors to these spellings when context matches, and cite the original sentence): {joined}"
            ),
            "ja" => format!(
                "\n- 既知の固有名詞・専門用語（同音異字の認識誤りがあれば文脈に応じてこの表記に揃え、元の文の番号を引用してください）：{joined}"
            ),
            _ => format!(
                "\n- 已知专有名词/术语表（若原话中有同音或近音识别错误，请在纪要与 terms.name 中统一写成以下标准写法，并在 terms.heard 中列出原话里实际出现的错别字，同时引用原句编号）：{}",
                clean_vocab.join("、")
            ),
        }
    };

    match locale_code {
        "en" => format!(
            "Turn the numbered transcript below into structured meeting minutes.\nReturn ONLY a single JSON object (no markdown fences, no commentary) matching this exact schema:\n{{\n  \"schemaVersion\": 2,\n  \"title\": \"Concise title (<= 16 words)\",\n  \"overview\": \"2-4 sentence executive summary\",\n  \"topics\": [\n    {{\n      \"text\": \"Topic title\",\n      \"summary\": \"1-2 sentence synthesis of this topic\",\n      \"sources\": [\"S1\", \"S2\"],\n      \"points\": [\n        {{ \"text\": \"Specific viewpoint, argument, or fact\", \"sources\": [\"S1\"] }}\n      ],\n      \"fishbone\": {{\n        \"question\": \"Core problem or question (optional: include ONLY when the topic analyzes causes of an issue)\",\n        \"branches\": [\n          {{ \"text\": \"Cause category\", \"detail\": \"Specific cause\", \"sources\": [\"S2\"] }}\n        ]\n      }}\n    }}\n  ],\n  \"decisions\": [\n    {{ \"text\": \"Decision reached\", \"sources\": [\"S3\"] }}\n  ],\n  \"actions\": [\n    {{ \"text\": \"Concrete next step\", \"owner\": \"Person (optional)\", \"due\": \"Deadline (optional)\", \"sources\": [\"S4\"] }}\n  ],\n  \"questions\": [\n    {{ \"text\": \"Unresolved question or risk\", \"sources\": [\"S5\"] }}\n  ],\n  \"terms\": [\n    {{ \"name\": \"Proper noun or domain term (<= 6 items)\", \"note\": \"Brief role or meaning in this recording\", \"heard\": [\"Exact substring in cited S# if ASR misheard it\"], \"sources\": [\"S1\"] }}\n  ],\n  \"reviewItems\": [\"S3: possible ASR error or ambiguity worth checking\"]{custom_schema}\n}}\n\nStrict grounding rules:\n- Every item in topics, topic.points, fishbone.branches, decisions, actions, questions, and terms MUST have a non-empty \"sources\" array containing only sentence IDs (S1, S2, ...) that directly support it.\n- Never invent facts, numbers, ratios, formulas, or deadlines not stated in the transcript.\n- Never combine numbers from different sentences to infer a formula or calculation (e.g., do NOT write \"salary is base * 80%\" or \"calculated at 80% of X\" unless a single source sentence explicitly states that exact calculation).\n- Use [] for any list that has no grounded items; omit \"fishbone\" when a topic is not a root-cause discussion; omit \"owner\" / \"due\" when not explicitly mentioned.\n- In \"terms.heard\", include ONLY exact substrings that literally appear in the cited sentences when ASR misheard the term; omit \"heard\" if the transcript already uses the canonical spelling.\n- Keep the language of the transcript.{custom_rule}{vocab_rule}\n\nNumbered transcript:\n{numbered_transcript}"
        ),
        "ja" => format!(
            "以下の番号付き文字起こしから構造化された議事録を作成してください。\nマークダウンのコードブロックや説明文は一切付けず、次のスキーマに厳密に従う JSON オブジェクトのみを返してください:\n{{\n  \"schemaVersion\": 2,\n  \"title\": \"簡潔なタイトル（25文字以内）\",\n  \"overview\": \"2〜4文の要約\",\n  \"topics\": [\n    {{\n      \"text\": \"トピック見出し\",\n      \"summary\": \"このトピックの1〜2文のまとめ\",\n      \"sources\": [\"S1\", \"S2\"],\n      \"points\": [\n        {{ \"text\": \"具体的な発言・論点・事実\", \"sources\": [\"S1\"] }}\n      ],\n      \"fishbone\": {{\n        \"question\": \"中心となる問題・問い（原因分析をしているトピックのみ任意で記載）\",\n        \"branches\": [\n          {{ \"text\": \"要因カテゴリ\", \"detail\": \"具体的な原因\", \"sources\": [\"S2\"] }}\n        ]\n      }}\n    }}\n  ],\n  \"decisions\": [\n    {{ \"text\": \"決定事項\", \"sources\": [\"S3\"] }}\n  ],\n  \"actions\": [\n    {{ \"text\": \"具体的な次のアクション\", \"owner\": \"担当者（任意）\", \"due\": \"期限（任意）\", \"sources\": [\"S4\"] }}\n  ],\n  \"questions\": [\n    {{ \"text\": \"未解決の課題・疑問\", \"sources\": [\"S5\"] }}\n  ],\n  \"terms\": [\n    {{ \"name\": \"固有名詞・専門用語（最大6件）\", \"note\": \"この録音における簡単な説明\", \"heard\": [\"誤変換されている場合、引用した S# 内に実際に出現する文字列\"], \"sources\": [\"S1\"] }}\n  ],\n  \"reviewItems\": [\"S3: 認識誤りや曖昧さがあり確認が必要な箇所\"]{custom_schema}\n}}\n\n厳守事項:\n- topics、topic.points、fishbone.branches、decisions、actions、questions、terms の各要素には、根拠となる文番号（S1, S2, ...）のみを含む非空の \"sources\" 配列を必ず付けてください。\n- 文字起こしにない事実・数値・割合・計算式・期限を絶対に創作しないでください。\n- 複数の文の数値を組み合わせて計算式や割合を推測しないでください（1つの文で明言されていない限り「基本給×80%」「Xの80%で計算」等と書かないこと）。\n- 該当がない配列は [] にし、原因分析でないトピックでは \"fishbone\" を省略し、明言されていない \"owner\" / \"due\" は省略してください。\n- \"terms.heard\" には、音声認識の誤りがある場合に引用元の文にそのまま含まれる部分文字列のみを入れてください。元の文がすでに正しい表記なら \"heard\" は省略してください。{custom_rule}{vocab_rule}\n\n番号付き文字起こし:\n{numbered_transcript}"
        ),
        _ => format!(
            "请根据下方带编号的逐句原话，整理结构化闪记纪要。\n只返回一个 JSON 对象（不要 ``` 代码块，不要任何额外说明），严格符合以下结构：\n{{\n  \"schemaVersion\": 2,\n  \"title\": \"简短标题（20字以内）\",\n  \"overview\": \"2到4句话的整体概述\",\n  \"topics\": [\n    {{\n      \"text\": \"主题标题\",\n      \"summary\": \"1到2句话概括该主题的核心内容\",\n      \"sources\": [\"S1\", \"S2\"],\n      \"points\": [\n        {{ \"text\": \"该主题下的具体观点、论据或事实\", \"sources\": [\"S1\"] }}\n      ],\n      \"fishbone\": {{\n        \"question\": \"核心问题（可选：仅在该主题讨论问题成因/故障排查时填写）\",\n        \"branches\": [\n          {{ \"text\": \"原因类别（如人员/流程/环境）\", \"detail\": \"具体原因说明\", \"sources\": [\"S2\"] }}\n        ]\n      }}\n    }}\n  ],\n  \"decisions\": [\n    {{ \"text\": \"已达成的决定或结论\", \"sources\": [\"S3\"] }}\n  ],\n  \"actions\": [\n    {{ \"text\": \"具体待办事项\", \"owner\": \"负责人（原话未提则省略）\", \"due\": \"期限（原话未提则省略）\", \"sources\": [\"S4\"] }}\n  ],\n  \"questions\": [\n    {{ \"text\": \"未解决的问题或风险\", \"sources\": [\"S5\"] }}\n  ],\n  \"terms\": [\n    {{ \"name\": \"专有名词/人名/项目名/术语（最多6个）\", \"note\": \"在本次录音中的简短说明\", \"heard\": [\"若原话被识别成同音错字，填所引原句中实际出现的错字子串\"], \"sources\": [\"S1\"] }}\n  ],\n  \"reviewItems\": [\"S3：疑似识别有误或表述含糊、建议人工复核的地方\"]{custom_schema}\n}}\n\n严格约束：\n- topics、topic.points、fishbone.branches、decisions、actions、questions、terms 中的每一条都必须带有非空的 \"sources\" 数组，且只能引用直接支撑该条内容的原句编号（S1、S2……）。\n- 严禁编造原话中没有的事实、数字、比例、计算公式、人名或期限。\n- 严禁把不同句子的数字拼在一起推算工资、基数或比例公式（例如原话未在同一句明确说出“按基本工资乘以80%计算”，绝不能自行合成此类算式）。\n- 没有对应内容的列表填 []；非原因分析的主题省略 \"fishbone\"；未明确提及的 \"owner\" / \"due\" 直接省略字段。\n- \"terms.heard\" 只能填写所引原句（sources）中逐字出现过的错别字子串；若原话本身写法正确则省略 \"heard\"。{custom_rule}{vocab_rule}\n\n带编号原话：\n{numbered_transcript}"
        ),
    }
}

/// Extracts up to `max_items` candidate domain terms/proper nouns from `summary_text` that are
/// not already present in `existing_vocabulary`, matching `extractVocabularySuggestions` in
/// `lib/state/meeting_minutes.dart`.
#[must_use]
pub fn extract_vocabulary_suggestions(
    summary_text: &str,
    existing_vocabulary: &[String],
    max_items: usize,
) -> Vec<String> {
    let limit = if max_items == 0 { 8 } else { max_items };
    let existing_lower: BTreeSet<String> = existing_vocabulary
        .iter()
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty())
        .collect();
    let stopwords: BTreeSet<&str> = [
        "会议",
        "讨论",
        "问题",
        "方案",
        "情况",
        "工作",
        "内容",
        "时间",
        "结果",
        "建议",
        "待办",
        "纪要",
        "总结",
        "要点",
        "部分",
        "方面",
        "目前",
        "后续",
        "需要",
        "可以",
        "进行",
        "完成",
        "确认",
        "发言人",
        "说话人",
        "今天",
        "我们",
        "他们",
        "这个",
        "那个",
        "一个",
    ]
    .into_iter()
    .collect();

    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    let mut push_candidate = |raw: &str| -> bool {
        let cleaned = raw
            .trim_matches(|c: char| {
                c.is_whitespace()
                    || matches!(
                        c,
                        '"' | '\''
                            | '“'
                            | '”'
                            | '‘'
                            | '’'
                            | '《'
                            | '》'
                            | '「'
                            | '」'
                            | '『'
                            | '』'
                            | '【'
                            | '】'
                            | '('
                            | ')'
                            | '（'
                            | '）'
                            | ','
                            | '，'
                            | '。'
                            | '、'
                            | ':'
                            | '：'
                            | ';'
                            | '；'
                    )
            })
            .trim();
        let rune_len = cleaned.chars().count();
        if !(2..=24).contains(&rune_len) {
            return false;
        }
        if stopwords.contains(cleaned) {
            return false;
        }
        if cleaned.chars().all(|c| c.is_ascii_digit()) {
            return false;
        }
        let key = cleaned.to_lowercase();
        if existing_lower.contains(&key) || !seen.insert(key) {
            return false;
        }
        out.push(cleaned.to_string());
        out.len() >= limit
    };

    for (open, close) in [
        ('《', '》'),
        ('「', '」'),
        ('『', '』'),
        ('【', '】'),
        ('“', '”'),
    ] {
        let mut rest = summary_text;
        while let Some(start) = rest.find(open) {
            let after_open = &rest[start + open.len_utf8()..];
            if let Some(end) = after_open.find(close) {
                let inner = &after_open[..end];
                if inner.chars().count() <= 20 && push_candidate(inner) {
                    return out;
                }
                rest = &after_open[end + close.len_utf8()..];
            } else {
                break;
            }
        }
    }

    for token in summary_text.split(|c: char| !c.is_ascii_alphanumeric() && c != '-' && c != '_') {
        let len = token.len();
        if (2..=24).contains(&len)
            && token.as_bytes()[0].is_ascii_uppercase()
            && token
                .chars()
                .skip(1)
                .any(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
            && push_candidate(token)
        {
            return out;
        }
    }

    out
}

/// Pure state for the structured meeting minutes domain module.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MinutesState {
    /// Latest validated meeting minutes document, if any.
    pub latest_minutes: Option<MeetingMinutes>,
    /// User-configured hot-words (`qwennote-minutes`).
    pub hot_words: Vec<String>,
    /// Active template identifier, if any.
    pub active_template_id: Option<String>,
    /// Last grounding validation error encountered.
    pub last_error: Option<MinutesValidationError>,
}

/// Input events for [`MinutesReducer`].
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MinutesEvent {
    /// Request minutes generation over the current [`UtteranceSpine`].
    RequestGenerate {
        /// Optional template override.
        template_id: Option<String>,
    },
    /// Candidate [`MeetingMinutes`] returned by the AI provider.
    CandidateReceived(MeetingMinutes),
    /// Add a personal hot-word (`qwennote-minutes`).
    AddHotWord(String),
}

/// Pure output from [`MinutesReducer::reduce`].
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MinutesOutcome {
    /// Outbound AI provider commands to execute.
    pub commands: Vec<AiProviderCommand>,
    /// Validation error if a candidate document failed grounding checks.
    pub validation_error: Option<MinutesValidationError>,
}

/// Pure reducer contract for the meeting minutes subsystem.
pub trait MinutesReducer {
    /// Applies `event` to `state` against `spine` without side effects.
    fn reduce(
        state: &mut MinutesState,
        spine: &UtteranceSpine,
        event: MinutesEvent,
    ) -> MinutesOutcome;
}

impl MinutesReducer for MinutesState {
    fn reduce(
        state: &mut MinutesState,
        spine: &UtteranceSpine,
        event: MinutesEvent,
    ) -> MinutesOutcome {
        match event {
            MinutesEvent::RequestGenerate { template_id } => {
                if let Some(tid) = &template_id {
                    state.active_template_id = Some(tid.clone());
                }
                let Some(first) = spine.segments().first().map(|s| s.id) else {
                    return MinutesOutcome::default();
                };
                let Some(last) = spine.segments().last().map(|s| s.id) else {
                    return MinutesOutcome::default();
                };
                MinutesOutcome {
                    commands: vec![AiProviderCommand::GenerateMinutes {
                        session_id: spine.session_id().to_string(),
                        spine_revision: spine.revision(),
                        segment_range: (first, last),
                        template_id: template_id.or_else(|| state.active_template_id.clone()),
                    }],
                    validation_error: None,
                }
            }
            MinutesEvent::CandidateReceived(candidate) => {
                match validate_minutes_grounding(&candidate, spine) {
                    Ok(()) => {
                        state.latest_minutes = Some(candidate);
                        state.last_error = None;
                        MinutesOutcome::default()
                    }
                    Err(err) => {
                        state.last_error = Some(err.clone());
                        MinutesOutcome {
                            commands: Vec::new(),
                            validation_error: Some(err),
                        }
                    }
                }
            }
            MinutesEvent::AddHotWord(word) => {
                let clean = word.trim().to_string();
                if !clean.is_empty() && !state.hot_words.contains(&clean) {
                    state.hot_words.push(clean);
                }
                MinutesOutcome::default()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_cross_segment_wage_and_percentage_stitching_but_accepts_single_segment() {
        let mut spine = UtteranceSpine::new("rec-wage");
        let s1 = spine
            .append_segment("合同约定基本工资为3910元。", 0, 1_500, "zh", "qwen")
            .unwrap();
        let s2 = spine
            .append_segment("本月出勤率是80%。", 1_500, 3_000, "zh", "qwen")
            .unwrap();
        let s3 = spine
            .append_segment(
                "所以实发工资按3910元乘以80%折算。",
                3_000,
                4_500,
                "zh",
                "qwen",
            )
            .unwrap();

        let stitched =
            validate_calculation_grounding("员工实发工资按3910元乘以80%计算", &[s1, s2], &spine);
        assert_eq!(
            stitched,
            Err(MinutesValidationError::UngroundedWageCalculation {
                claim: "员工实发工资按3910元乘以80%计算".to_string(),
            })
        );

        let baseless_ratio =
            validate_calculation_grounding("社保缴费基数按80%计算", &[s1, s2], &spine);
        assert_eq!(
            baseless_ratio,
            Err(MinutesValidationError::BaselessRatioCalculation {
                claim: "社保缴费基数按80%计算".to_string(),
            })
        );

        let uncited_pct = validate_calculation_grounding("本月出勤率达到85%", &[s2], &spine);
        assert_eq!(
            uncited_pct,
            Err(MinutesValidationError::UncitedPercentageNumber {
                claim: "本月出勤率达到85%".to_string(),
                percentage: "85%".to_string(),
            })
        );

        let grounded =
            validate_calculation_grounding("员工实发工资按3910元乘以80%计算", &[s3], &spine);
        assert_eq!(grounded, Ok(()));
    }

    #[test]
    fn qwen_batch_and_streaming_protocol_codec_roundtrips() {
        let rejected = encode_qwen_file_submit_json(
            QWEN_INCOMPATIBLE_FILE_URL_MODEL,
            "oss://bucket/a.wav",
            Some("zh"),
            Some(2),
            &[],
        );
        assert!(rejected.is_err());

        let submit = encode_qwen_file_submit_json(
            QWEN_FILETRANS_DEFAULT_MODEL,
            "oss://bucket/a.wav",
            Some("zh"),
            Some(3),
            &["声刻".to_string(), "D3200".to_string()],
        )
        .unwrap();
        assert!(submit.contains("\"model\":\"qwen-audio-3.1-asr-flash-filetrans\""));
        assert!(submit.contains("\"diarization_enabled\":true"));
        assert!(submit.contains("\"speaker_count\":3"));
        assert!(submit.contains("\"hotwords\":[\"声刻\",\"D3200\"]"));

        let policy_raw = r#"{
            "data": {
                "policy": "eyJleHBpcmF0aW9uIjoiMjAyNiJ9",
                "signature": "sig-123",
                "upload_dir": "dashscope-instant/2026/",
                "upload_host": "https://dashscope-file.oss-cn-beijing.aliyuncs.com#frag",
                "oss_access_key_id": "LTAI5t",
                "max_file_size_mb": 100
            }
        }"#;
        let policy = parse_qwen_upload_policy_json(policy_raw).unwrap();
        assert_eq!(policy.upload_dir, "dashscope-instant/2026");
        assert_eq!(
            policy.upload_host,
            "https://dashscope-file.oss-cn-beijing.aliyuncs.com"
        );
        assert_eq!(policy.max_file_size_mb, Some(100));

        let mut spine = UtteranceSpine::new("qwen-batch");
        let transcript_raw = r#"{
            "properties": { "original_duration_in_milliseconds": 4500 },
            "transcripts": [{
                "sentences": [
                    { "text": "大家好。", "begin_time": 0, "end_time": 1200, "speaker_id": 0 },
                    { "text": "开始周会。", "begin_time": 1200, "end_time": 2500, "speaker_id": 0 },
                    { "text": "我汇报进度。", "begin_time": 2500, "end_time": 4500, "speaker_id": 1 }
                ]
            }]
        }"#;
        let parsed = parse_qwen_transcript_json(transcript_raw, &mut spine).unwrap();
        assert!(parsed.timing_complete);
        assert_eq!(parsed.segment_count, 3);
        assert_eq!(
            parsed.text,
            "说话人 1：大家好。开始周会。\n说话人 2：我汇报进度。"
        );
        assert_eq!(spine.len(), 3);
        assert_eq!(
            spine
                .get(SegmentId::new(1).unwrap())
                .unwrap()
                .speaker
                .as_deref(),
            Some("说话人 1")
        );

        let mut stream_spine = UtteranceSpine::new("qwen-stream");
        let mut acc = QwenStreamAccumulator::new();
        assert_eq!(
            acc.handle_event_json(r#"{"header":{"event":"task-started"}}"#, &mut stream_spine)
                .unwrap(),
            QwenStreamStep::TaskStarted
        );
        let step1 = acc
            .handle_event_json(
                r#"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"sentence_id":1,"text":"你好","sentence_end":false}}}}"#,
                &mut stream_spine,
            )
            .unwrap();
        assert_eq!(
            step1,
            QwenStreamStep::TranscriptUpdate {
                full_text: "你好".to_string(),
                sentence_end: false,
            }
        );
        assert_eq!(stream_spine.len(), 0);

        let step2 = acc
            .handle_event_json(
                r#"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"sentence_id":1,"text":"你好世界。","sentence_end":true}}}}"#,
                &mut stream_spine,
            )
            .unwrap();
        assert_eq!(
            step2,
            QwenStreamStep::TranscriptUpdate {
                full_text: "你好世界。".to_string(),
                sentence_end: true,
            }
        );
        assert_eq!(stream_spine.len(), 1);
    }

    #[test]
    fn two_stage_chunked_minutes_job_enforces_allowed_sources_and_unconfirmed_guard() {
        let mut spine = UtteranceSpine::new("chunk-test");
        for i in 1..=4 {
            spine.append_segment(
                format!("第{i}段测试内容，长度超过单批阈值。"),
                (i - 1) * 1000,
                i * 1000,
                "zh",
                "qwen",
            );
        }
        let mut job = MinutesChunkJob::new(&spine, 30, true);
        assert_eq!(job.batches().len(), 4);

        let node1 = job.next_pending_node(&spine, false).unwrap().unwrap();
        assert_eq!(node1.node_id, "片段 1/4");
        assert!(!node1.is_merge_node);

        job.mark_node_dispatched(&node1.node_id);
        assert!(job.next_pending_node(&spine, false).is_err());
        assert!(job.next_pending_node(&spine, true).is_ok());

        let bad_leaf = r#"{"schemaVersion":2,"title":"T1","overview":"O1","topics":[{"text":"主題","sources":["S2"]}],"decisions":[],"actions":[],"questions":[]}"#;
        assert_eq!(
            job.complete_node(&node1.node_id, bad_leaf, &node1.allowed_sources, &spine),
            Err(MinutesValidationError::NodeCitedDisallowedSource {
                node_id: "片段 1/4".to_string(),
                disallowed_id: SegmentId::new(2).unwrap(),
            })
        );

        for i in 1..=4 {
            let spec = job.next_pending_node(&spine, true).unwrap().unwrap();
            let leaf_json = format!(
                r#"{{"schemaVersion":2,"title":"T{i}","overview":"O{i}","topics":[{{"text":"主题{i}","sources":["S{i}"]}}],"decisions":[],"actions":[],"questions":[]}}"#
            );
            job.complete_node(&spec.node_id, &leaf_json, &spec.allowed_sources, &spine)
                .unwrap();
        }

        let merge1 = job.next_pending_node(&spine, false).unwrap().unwrap();
        assert_eq!(merge1.node_id, "汇总 1-0");
        assert!(merge1.is_merge_node);
        assert!(merge1.allowed_sources.contains(&SegmentId::new(1).unwrap()));
        assert!(!merge1.allowed_sources.contains(&SegmentId::new(4).unwrap()));

        let merge1_json = r#"{"schemaVersion":2,"title":"M1","overview":"OM1","topics":[{"text":"汇总主题1","sources":["S1","S2","S3"]}],"decisions":[],"actions":[],"questions":[]}"#;
        job.complete_node(
            &merge1.node_id,
            merge1_json,
            &merge1.allowed_sources,
            &spine,
        )
        .unwrap();

        let merge2 = job.next_pending_node(&spine, false).unwrap().unwrap();
        assert_eq!(merge2.node_id, "汇总 2-0");
        let merge2_json = r#"{"schemaVersion":2,"title":"Final","overview":"All","topics":[{"text":"总结","sources":["S1","S4"]}],"decisions":[],"actions":[],"questions":[]}"#;
        job.complete_node(
            &merge2.node_id,
            merge2_json,
            &merge2.allowed_sources,
            &spine,
        )
        .unwrap();

        assert!(job.next_pending_node(&spine, false).unwrap().is_none());
        let final_doc = job.finalized_minutes(&spine).unwrap().unwrap();
        assert_eq!(final_doc.title, "Final");
    }

    #[test]
    fn longest_match_single_pass_term_replacement_and_heard_pruning() {
        let out = replace_minute_terms(
            "深科的深科Work录音豆",
            &[("深科", "声刻"), ("深科Work", "Soundcore Work")],
        );
        assert_eq!(out, "声刻的Soundcore Work录音豆");

        let mut spine = UtteranceSpine::new("rec-terms");
        spine.append_segment("今天测试深科录音豆。", 0, 1000, "zh", "qwen");
        let raw = r#"{
            "schemaVersion": 2,
            "title": "深科测试",
            "overview": "测试深科设备",
            "topics": [{"text": "深科蓝牙", "sources": ["S1"]}],
            "decisions": [],
            "actions": [],
            "questions": [],
            "terms": [{"name": "声刻", "note": "品牌", "heard": ["深科"], "sources": ["S1"]}]
        }"#;
        let mut doc = parse_meeting_minutes_json(raw, &spine).unwrap();
        doc.replace_terms(&[("深科", "声刻")]);
        assert_eq!(doc.title, "声刻测试");
        assert!(doc.terms[0].heard.is_empty());
    }

    #[test]
    fn minutes_reducer_validates_candidate_and_records_errors() {
        let mut spine = UtteranceSpine::new("rec-200");
        let s1 = spine
            .append_segment("确定下周三发布版本。", 0, 2_000, "zh", "qwen")
            .unwrap();
        let mut state = MinutesState::default();

        let out_req = MinutesState::reduce(
            &mut state,
            &spine,
            MinutesEvent::RequestGenerate {
                template_id: Some("tpl-weekly".to_string()),
            },
        );
        assert_eq!(out_req.commands.len(), 1);

        let bad_doc = MeetingMinutes {
            version: 2,
            spine_revision: spine.revision(),
            title: "周会".to_string(),
            overview: "发布计划".to_string(),
            topics: vec![MinuteTopic {
                title: "排期".to_string(),
                summary: "下周发布".to_string(),
                citations: vec![s1],
                points: vec![MinutePoint {
                    claim: "下周三上线".to_string(),
                    speaker: None,
                    owner: None,
                    due: None,
                    citations: vec![SegmentId::new(99).unwrap()],
                }],
                fishbone: None,
            }],
            decisions: Vec::new(),
            actions: Vec::new(),
            questions: Vec::new(),
            fishbones: Vec::new(),
            terms: Vec::new(),
            custom_sections: Vec::new(),
            review_items: Vec::new(),
        };
        let out_bad =
            MinutesState::reduce(&mut state, &spine, MinutesEvent::CandidateReceived(bad_doc));
        assert!(out_bad.validation_error.is_some());
        assert!(state.latest_minutes.is_none());

        let good_doc = MeetingMinutes {
            version: 2,
            spine_revision: spine.revision(),
            title: "周会".to_string(),
            overview: "发布计划".to_string(),
            topics: vec![MinuteTopic {
                title: "排期".to_string(),
                summary: "下周发布".to_string(),
                citations: vec![s1],
                points: vec![MinutePoint {
                    claim: "确定下周三发布版本".to_string(),
                    speaker: None,
                    owner: None,
                    due: None,
                    citations: vec![s1],
                }],
                fishbone: None,
            }],
            decisions: Vec::new(),
            actions: Vec::new(),
            questions: Vec::new(),
            fishbones: Vec::new(),
            terms: Vec::new(),
            custom_sections: Vec::new(),
            review_items: Vec::new(),
        };
        let out_good = MinutesState::reduce(
            &mut state,
            &spine,
            MinutesEvent::CandidateReceived(good_doc.clone()),
        );
        assert!(out_good.validation_error.is_none());
        assert_eq!(state.latest_minutes, Some(good_doc));
    }
}
