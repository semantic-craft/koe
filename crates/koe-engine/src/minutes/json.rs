use std::collections::BTreeMap;

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

pub(super) fn write_escaped_json_string(s: &str, out: &mut String) {
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

/// Strips optional markdown ```json fences and extracts the outermost `{...}` JSON substring.
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
