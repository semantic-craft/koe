use std::time::Duration;

use koe_engine::wav::OpusWave;
use serde_json::{json, Value};

use super::{ProviderConfig, ProviderOutput, TranscriptSegment, MAX_RESPONSE_BYTES};

const SAMPLE_RATE: usize = 16_000;
const BYTES_PER_SEC: usize = SAMPLE_RATE * 2;
const DEEPSEEK_DIRECT_MAX_BYTES: usize = 120 * BYTES_PER_SEC;
const DEEPSEEK_CHUNK_MAX_BYTES: usize = 110 * BYTES_PER_SEC;
const DEEPSEEK_SEARCH_MIN_BYTES: usize = 80 * BYTES_PER_SEC;
const DEEPSEEK_MAX_WAV_BYTES: usize = 8 * 1024 * 1024;
const QWEN_FLASH_MAX_BYTES: usize = 300 * BYTES_PER_SEC;
const FRAME_BYTES: usize = (SAMPLE_RATE / 50) * 2; // 20 ms = 320 samples = 640 bytes
const SILENCE_WINDOW_FRAMES: usize = 10; // 200 ms

/// Splits 16 kHz mono PCM16 into DeepSeek-compatible chunks.
///
/// Recordings <= 120s (and <= 8 MiB WAV) are returned as one chunk. Longer recordings
/// are split at low-energy silence points so every chunk is <= 110s.
pub(crate) fn split_pcm16_for_deepseek(pcm16: &[u8]) -> Vec<(u64, u64, &[u8])> {
    if pcm16.len() < 2 {
        return Vec::new();
    }
    let aligned_len = pcm16.len() - (pcm16.len() % 2);
    let pcm = &pcm16[..aligned_len];
    let direct_limit = DEEPSEEK_DIRECT_MAX_BYTES.min(DEEPSEEK_MAX_WAV_BYTES - 44);
    if pcm.len() <= direct_limit {
        let dur_ms = (pcm.len() as u64 * 1000) / BYTES_PER_SEC as u64;
        return vec![(0, dur_ms, pcm)];
    }

    let chunk_limit = DEEPSEEK_CHUNK_MAX_BYTES.min(DEEPSEEK_MAX_WAV_BYTES - 44);
    let mut chunks = Vec::new();
    let mut offset = 0usize;
    while offset < pcm.len() {
        let remaining = pcm.len() - offset;
        let end = if remaining <= chunk_limit {
            pcm.len()
        } else {
            let search_start = offset + DEEPSEEK_SEARCH_MIN_BYTES.min(chunk_limit);
            let search_end = offset + chunk_limit;
            find_quietest_cut(pcm, search_start, search_end)
        };
        let start_ms = (offset as u64 * 1000) / BYTES_PER_SEC as u64;
        let end_ms = (end as u64 * 1000) / BYTES_PER_SEC as u64;
        chunks.push((start_ms, end_ms, &pcm[offset..end]));
        offset = end;
    }
    chunks
}

fn find_quietest_cut(pcm: &[u8], search_start: usize, search_end: usize) -> usize {
    let start_frame = search_start / FRAME_BYTES;
    let end_frame = search_end / FRAME_BYTES;
    if end_frame <= start_frame + SILENCE_WINDOW_FRAMES {
        return (search_end / 2) * 2;
    }
    let frame_count = end_frame - start_frame;
    let mut energies = Vec::with_capacity(frame_count);
    for idx in 0..frame_count {
        let f_start = (start_frame + idx) * FRAME_BYTES;
        let f_end = (f_start + FRAME_BYTES).min(pcm.len());
        let mut energy: u64 = 0;
        for pair in pcm[f_start..f_end].as_chunks::<2>().0 {
            let sample = i64::from(i16::from_le_bytes(*pair));
            energy = energy.saturating_add((sample * sample) as u64);
        }
        energies.push(energy);
    }

    let mut best_window_start = frame_count - SILENCE_WINDOW_FRAMES;
    let mut best_sum = u128::MAX;
    let mut window_sum: u128 = energies[..SILENCE_WINDOW_FRAMES]
        .iter()
        .map(|&e| u128::from(e))
        .sum();
    if window_sum < best_sum {
        best_sum = window_sum;
        best_window_start = 0;
    }
    for i in SILENCE_WINDOW_FRAMES..frame_count {
        window_sum = window_sum
            .saturating_add(u128::from(energies[i]))
            .saturating_sub(u128::from(energies[i - SILENCE_WINDOW_FRAMES]));
        let win_start = i + 1 - SILENCE_WINDOW_FRAMES;
        if window_sum <= best_sum {
            best_sum = window_sum;
            best_window_start = win_start;
        }
    }

    let cut_frame = start_frame + best_window_start + SILENCE_WINDOW_FRAMES / 2;
    (cut_frame * FRAME_BYTES).min(search_end)
}

fn build_http_client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .retry(reqwest::retry::never())
        .no_proxy()
        .connect_timeout(Duration::from_secs(15))
        .build()
        .map_err(|_| "无法初始化 HTTPS 客户端".to_string())
}

fn pcm16_to_wav(pcm16: &[u8]) -> Result<Vec<u8>, String> {
    let pcm_len = u32::try_from(pcm16.len()).map_err(|_| "音频超过 WAV 大小限制")?;
    let header = OpusWave::wav_header_with_rate(pcm_len, SAMPLE_RATE as u32);
    let mut wav = Vec::with_capacity(44 + pcm16.len());
    wav.extend_from_slice(&header);
    wav.extend_from_slice(pcm16);
    Ok(wav)
}

fn build_multipart(
    boundary: &str,
    fields: &[(&str, &str)],
    file_field: &str,
    filename: &str,
    content_type: &str,
    file_bytes: &[u8],
) -> Vec<u8> {
    let mut body = Vec::with_capacity(file_bytes.len() + 1024);
    for (name, value) in fields {
        body.extend_from_slice(b"--");
        body.extend_from_slice(boundary.as_bytes());
        body.extend_from_slice(b"\r\nContent-Disposition: form-data; name=\"");
        body.extend_from_slice(name.as_bytes());
        body.extend_from_slice(b"\"\r\n\r\n");
        body.extend_from_slice(value.as_bytes());
        body.extend_from_slice(b"\r\n");
    }
    body.extend_from_slice(b"--");
    body.extend_from_slice(boundary.as_bytes());
    body.extend_from_slice(b"\r\nContent-Disposition: form-data; name=\"");
    body.extend_from_slice(file_field.as_bytes());
    body.extend_from_slice(b"\"; filename=\"");
    body.extend_from_slice(filename.as_bytes());
    body.extend_from_slice(b"\"\r\nContent-Type: ");
    body.extend_from_slice(content_type.as_bytes());
    body.extend_from_slice(b"\r\n\r\n");
    body.extend_from_slice(file_bytes);
    body.extend_from_slice(b"\r\n--");
    body.extend_from_slice(boundary.as_bytes());
    body.extend_from_slice(b"--\r\n");
    body
}

pub(crate) fn encode_base64(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let b0 = u32::from(chunk[0]);
        let b1 = if chunk.len() > 1 {
            u32::from(chunk[1])
        } else {
            0
        };
        let b2 = if chunk.len() > 2 {
            u32::from(chunk[2])
        } else {
            0
        };
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(TABLE[((triple >> 18) & 0x3F) as usize] as char);
        out.push(TABLE[((triple >> 12) & 0x3F) as usize] as char);
        out.push(if chunk.len() > 1 {
            TABLE[((triple >> 6) & 0x3F) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            TABLE[(triple & 0x3F) as usize] as char
        } else {
            '='
        });
    }
    out
}

async fn read_bounded_bytes(
    mut response: reqwest::Response,
    limit: usize,
) -> Result<Vec<u8>, String> {
    if response
        .content_length()
        .is_some_and(|len| len > limit as u64)
    {
        return Err("语音响应超过 4 MiB 限制".into());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "语音响应读取中断")?
    {
        if bytes.len().saturating_add(chunk.len()) > limit {
            return Err("语音响应超过 4 MiB 限制".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

fn validate_remote_http_url(raw: &str) -> Result<reqwest::Url, String> {
    let url = reqwest::Url::parse(raw).map_err(|_| "语音服务返回的临时地址无效")?;
    if !url.username().is_empty() || url.password().is_some() || url.fragment().is_some() {
        return Err("语音服务返回的临时地址无效".into());
    }
    let loopback = url.host_str().is_some_and(|host| {
        host == "localhost"
            || host
                .trim_matches(['[', ']'])
                .parse::<std::net::IpAddr>()
                .is_ok_and(|ip| ip.is_loopback())
    });
    if url.scheme() != "https" && !(url.scheme() == "http" && loopback) {
        return Err("语音服务返回了不安全的非加密地址".into());
    }
    Ok(url)
}

fn origin_of(endpoint: &str) -> Result<String, String> {
    let url = reqwest::Url::parse(endpoint).map_err(|_| "语音服务地址无效")?;
    let host = url.host_str().ok_or("语音服务地址无效")?;
    Ok(match url.port() {
        Some(port) => format!("{}://{host}:{port}", url.scheme()),
        None => format!("{}://{host}", url.scheme()),
    })
}

fn format_speaker_id(value: Option<&Value>) -> Option<String> {
    let id = value?.as_u64()?;
    Some(format!("说话人 {}", id.saturating_add(1)))
}

fn parse_sentence_array(sentences: &[Value]) -> Vec<TranscriptSegment> {
    let mut out = Vec::new();
    for item in sentences {
        let Some(text) = item
            .get("text")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        else {
            continue;
        };
        let start_ms = item.get("begin_time").and_then(Value::as_u64).unwrap_or(0);
        let end_ms = item
            .get("end_time")
            .and_then(Value::as_u64)
            .unwrap_or(start_ms)
            .max(start_ms);
        let speaker = format_speaker_id(item.get("speaker_id"));
        out.push(TranscriptSegment {
            start_ms,
            end_ms,
            text: text.to_owned(),
            speaker,
        });
    }
    out
}

pub(super) async fn transcribe_deepseek(
    config: &ProviderConfig,
    pcm16: &[u8],
) -> Result<ProviderOutput, String> {
    let client = build_http_client()?;
    let chunks = split_pcm16_for_deepseek(pcm16);
    let mut segments = Vec::new();
    for (index, (start_ms, end_ms, chunk_pcm)) in chunks.into_iter().enumerate() {
        let wav = pcm16_to_wav(chunk_pcm)?;
        let boundary = format!("----KoeDeepSeekAsr{}", uuid::Uuid::new_v4().simple());
        let filename = format!("chunk-{index}.wav");
        let body = build_multipart(&boundary, &[], "file", &filename, "audio/wav", &wav);
        let mut req = client
            .post(&config.endpoint)
            .header(
                reqwest::header::CONTENT_TYPE,
                format!("multipart/form-data; boundary={boundary}"),
            )
            .body(body);
        if !config.api_key.trim().is_empty() {
            req = req.bearer_auth(&config.api_key);
        }
        let response = req.send().await.map_err(|error| {
            if error.is_connect() {
                "无法连接 DeepSeek 语音服务"
            } else {
                "DeepSeek 语音请求中断，结果未知；未自动重试"
            }
        })?;
        if !response.status().is_success() {
            return Err(format!(
                "DeepSeek 语音服务返回 HTTP {}；未自动重试",
                response.status().as_u16()
            ));
        }
        let bytes = read_bounded_bytes(response, MAX_RESPONSE_BYTES).await?;
        let value: Value =
            serde_json::from_slice(&bytes).map_err(|_| "DeepSeek 语音服务返回无效 JSON")?;
        if let Some(text) = value
            .get("text")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|t| !t.is_empty())
        {
            segments.push(TranscriptSegment {
                start_ms,
                end_ms: end_ms.max(start_ms),
                text: text.to_owned(),
                speaker: None,
            });
        }
    }
    Ok(ProviderOutput::Transcript { segments })
}

pub(super) async fn transcribe_qwen_flash(
    config: &ProviderConfig,
    pcm16: &[u8],
) -> Result<ProviderOutput, String> {
    if pcm16.len() > QWEN_FLASH_MAX_BYTES {
        return Err(
            "qwen-audio-3.1-asr-flash 仅支持 5 分钟以内的音频；长录音请改用 qwen-audio-3.1-asr-flash-filetrans 或流式模型"
                .into(),
        );
    }
    let wav = pcm16_to_wav(pcm16)?;
    let data_uri = format!("data:audio/wav;base64,{}", encode_base64(&wav));
    let client = build_http_client()?;
    let mut req = client.post(&config.endpoint).json(&json!({
        "model": config.model,
        "input": {
            "messages": [
                {
                    "role": "user",
                    "content": [{"audio": data_uri}]
                }
            ]
        },
        "parameters": {
            "format": "wav",
            "speaker_diarization_enabled": true
        }
    }));
    if !config.api_key.trim().is_empty() {
        req = req.bearer_auth(&config.api_key);
    }
    let response = req.send().await.map_err(|error| {
        if error.is_connect() {
            "无法连接 Qwen 语音服务"
        } else {
            "Qwen 语音请求中断，结果未知；未自动重试"
        }
    })?;
    if !response.status().is_success() {
        return Err(format!(
            "Qwen 语音服务返回 HTTP {}；未自动重试",
            response.status().as_u16()
        ));
    }
    let bytes = read_bounded_bytes(response, MAX_RESPONSE_BYTES).await?;
    let value: Value = serde_json::from_slice(&bytes).map_err(|_| "Qwen 语音服务返回无效 JSON")?;
    let duration_ms = (pcm16.len() as u64 * 1000) / BYTES_PER_SEC as u64;
    let segments = parse_qwen_flash_response(&value, duration_ms);
    Ok(ProviderOutput::Transcript { segments })
}

fn parse_qwen_flash_response(value: &Value, duration_ms: u64) -> Vec<TranscriptSegment> {
    for ptr in ["/output/sentences", "/output/output/sentences"] {
        if let Some(arr) = value.pointer(ptr).and_then(Value::as_array) {
            let segs = parse_sentence_array(arr);
            if !segs.is_empty() {
                return segs;
            }
        }
    }
    for ptr in ["/output/sentence", "/output/output/sentence"] {
        if let Some(obj) = value.pointer(ptr) {
            let segs = parse_sentence_array(std::slice::from_ref(obj));
            if !segs.is_empty() {
                return segs;
            }
        }
    }
    for ptr in [
        "/output/text",
        "/output/output/text",
        "/output/choices/0/message/content/0/text",
    ] {
        if let Some(text) = value
            .pointer(ptr)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            return vec![TranscriptSegment {
                start_ms: 0,
                end_ms: duration_ms,
                text: text.to_owned(),
                speaker: None,
            }];
        }
    }
    Vec::new()
}

pub(super) async fn transcribe_qwen_filetrans(
    config: &ProviderConfig,
    pcm16: &[u8],
) -> Result<ProviderOutput, String> {
    let origin = origin_of(&config.endpoint)?;
    let client = build_http_client()?;

    // Step 1: Request temporary OSS upload policy.
    let policy_url = format!("{origin}/api/v1/uploads?action=getPolicy&model={}", config.model);
    let mut policy_req = client.get(&policy_url);
    if !config.api_key.trim().is_empty() {
        policy_req = policy_req.bearer_auth(&config.api_key);
    }
    let policy_resp = policy_req
        .send()
        .await
        .map_err(|_| "无法获取 Qwen 临时上传凭据；未自动重试")?;
    if !policy_resp.status().is_success() {
        return Err(format!(
            "获取 Qwen 临时上传凭据返回 HTTP {}；未自动重试",
            policy_resp.status().as_u16()
        ));
    }
    let policy_bytes = read_bounded_bytes(policy_resp, MAX_RESPONSE_BYTES).await?;
    let policy_json: Value =
        serde_json::from_slice(&policy_bytes).map_err(|_| "Qwen 上传凭据响应无效")?;
    let data = policy_json
        .get("data")
        .ok_or("Qwen 上传凭据缺少 data 字段")?;
    let upload_host = data
        .get("upload_host")
        .and_then(Value::as_str)
        .ok_or("Qwen 上传凭据缺少 upload_host")?;
    let _ = validate_remote_http_url(upload_host)?;
    let oss_access_key_id = data
        .get("oss_access_key_id")
        .and_then(Value::as_str)
        .ok_or("Qwen 上传凭据缺少 oss_access_key_id")?;
    let signature = data
        .get("signature")
        .and_then(Value::as_str)
        .ok_or("Qwen 上传凭据缺少 signature")?;
    let policy = data
        .get("policy")
        .and_then(Value::as_str)
        .ok_or("Qwen 上传凭据缺少 policy")?;
    let upload_dir = data
        .get("upload_dir")
        .and_then(Value::as_str)
        .ok_or("Qwen 上传凭据缺少 upload_dir")?;
    let acl = data
        .get("x_oss_object_acl")
        .and_then(Value::as_str)
        .unwrap_or("private");
    let forbid_overwrite = data
        .get("x_oss_forbid_overwrite")
        .and_then(Value::as_str)
        .unwrap_or("true");

    // Step 2: Upload WAV to temporary OSS bucket.
    let wav = pcm16_to_wav(pcm16)?;
    let filename = format!("koe-{}.wav", uuid::Uuid::new_v4().simple());
    let obj_key = format!("{}/{filename}", upload_dir.trim_end_matches('/'));
    let boundary = format!("----KoeQwenUpload{}", uuid::Uuid::new_v4().simple());
    let body = build_multipart(
        &boundary,
        &[
            ("OSSAccessKeyId", oss_access_key_id),
            ("Signature", signature),
            ("policy", policy),
            ("x-oss-object-acl", acl),
            ("x-oss-forbid-overwrite", forbid_overwrite),
            ("key", &obj_key),
            ("success_action_status", "200"),
        ],
        "file",
        &filename,
        "audio/wav",
        &wav,
    );
    let upload_resp = client
        .post(upload_host)
        .header(
            reqwest::header::CONTENT_TYPE,
            format!("multipart/form-data; boundary={boundary}"),
        )
        .body(body)
        .send()
        .await
        .map_err(|_| "音频上传到 Qwen 临时存储失败；未自动重试")?;
    if !upload_resp.status().is_success() {
        return Err(format!(
            "音频上传返回 HTTP {}；未自动重试",
            upload_resp.status().as_u16()
        ));
    }

    // Step 3: Submit asynchronous transcription task.
    let oss_url = format!("oss://{obj_key}");
    let mut submit_req = client
        .post(&config.endpoint)
        .header("X-DashScope-Async", "enable")
        .header("X-DashScope-OssResourceResolve", "enable")
        .json(&json!({
            "model": config.model,
            "input": { "file_url": oss_url },
            "parameters": {
                "enable_words": true,
                "diarization_enabled": true
            }
        }));
    if !config.api_key.trim().is_empty() {
        submit_req = submit_req.bearer_auth(&config.api_key);
    }
    let submit_resp = submit_req
        .send()
        .await
        .map_err(|_| "提交 Qwen 异步转写任务失败；未自动重试")?;
    if !submit_resp.status().is_success() {
        return Err(format!(
            "提交 Qwen 异步转写返回 HTTP {}；未自动重试",
            submit_resp.status().as_u16()
        ));
    }
    let submit_bytes = read_bounded_bytes(submit_resp, MAX_RESPONSE_BYTES).await?;
    let submit_json: Value =
        serde_json::from_slice(&submit_bytes).map_err(|_| "Qwen 异步转写响应无效")?;
    let task_id = submit_json
        .pointer("/output/task_id")
        .and_then(Value::as_str)
        .filter(|id| {
            !id.is_empty()
                && id.len() <= 128
                && id
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        })
        .ok_or("Qwen 异步转写响应缺少有效的 task_id")?
        .to_owned();

    // Step 4: Poll task until completion.
    let poll_url = format!("{origin}/api/v1/tasks/{task_id}");
    let mut poll_delay = Duration::from_millis(250);
    let transcription_url = loop {
        tokio::time::sleep(poll_delay).await;
        poll_delay = (poll_delay * 2).min(Duration::from_millis(1500));
        let mut poll_req = client.get(&poll_url);
        if !config.api_key.trim().is_empty() {
            poll_req = poll_req.bearer_auth(&config.api_key);
        }
        let poll_resp = poll_req
            .send()
            .await
            .map_err(|_| "查询 Qwen 异步转写状态中断，结果未知；未自动重试")?;
        if !poll_resp.status().is_success() {
            return Err(format!(
                "查询 Qwen 异步转写返回 HTTP {}；未自动重试",
                poll_resp.status().as_u16()
            ));
        }
        let poll_bytes = read_bounded_bytes(poll_resp, MAX_RESPONSE_BYTES).await?;
        let poll_json: Value =
            serde_json::from_slice(&poll_bytes).map_err(|_| "Qwen 任务状态响应无效")?;
        match poll_json
            .pointer("/output/task_status")
            .and_then(Value::as_str)
        {
            Some("SUCCEEDED") => {
                let url = [
                    "/output/result/transcription_url",
                    "/output/results/0/transcription_url",
                    "/output/transcription_url",
                    "/output/output/transcription_url",
                    "/output/output/results/0/transcription_url",
                ]
                .into_iter()
                .find_map(|ptr| poll_json.pointer(ptr).and_then(Value::as_str))
                .ok_or("Qwen 异步转写已完成，但未返回结果链接")?;
                break url.to_owned();
            }
            Some("FAILED" | "CANCELED") => {
                let code = poll_json
                    .pointer("/output/code")
                    .and_then(Value::as_str)
                    .unwrap_or("Failed");
                let safe_code: String = code
                    .chars()
                    .filter(|c| c.is_ascii_alphanumeric() || *c == '_')
                    .take(64)
                    .collect();
                return Err(format!("Qwen 异步转写失败（{safe_code}）；未自动重试"));
            }
            _ => {}
        }
    };

    // Step 5: Download final transcription JSON from OSS result URL (no Bearer header).
    let _ = validate_remote_http_url(&transcription_url)?;
    let dl_resp = client
        .get(&transcription_url)
        .send()
        .await
        .map_err(|_| "下载 Qwen 异步转写结果失败；未自动重试")?;
    if !dl_resp.status().is_success() {
        return Err(format!(
            "下载 Qwen 异步转写结果返回 HTTP {}；未自动重试",
            dl_resp.status().as_u16()
        ));
    }
    let dl_bytes = read_bounded_bytes(dl_resp, MAX_RESPONSE_BYTES).await?;
    let dl_json: Value =
        serde_json::from_slice(&dl_bytes).map_err(|_| "Qwen 异步转写结果 JSON 无效")?;
    let duration_ms = (pcm16.len() as u64 * 1000) / BYTES_PER_SEC as u64;
    let segments = parse_filetrans_transcript(&dl_json, duration_ms);
    Ok(ProviderOutput::Transcript { segments })
}

fn parse_filetrans_transcript(value: &Value, duration_ms: u64) -> Vec<TranscriptSegment> {
    let mut segments = Vec::new();
    if let Some(transcripts) = value.get("transcripts").and_then(Value::as_array) {
        for channel in transcripts {
            if let Some(sentences) = channel.get("sentences").and_then(Value::as_array) {
                segments.extend(parse_sentence_array(sentences));
            } else if let Some(text) = channel
                .get("text")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                segments.push(TranscriptSegment {
                    start_ms: 0,
                    end_ms: duration_ms,
                    text: text.to_owned(),
                    speaker: None,
                });
            }
        }
    }
    segments.sort_by_key(|s| (s.start_ms, s.end_ms));
    segments
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_encodes_rfc4648_vectors() {
        assert_eq!(encode_base64(b""), "");
        assert_eq!(encode_base64(b"f"), "Zg==");
        assert_eq!(encode_base64(b"fo"), "Zm8=");
        assert_eq!(encode_base64(b"foo"), "Zm9v");
        assert_eq!(encode_base64(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn deepseek_splitter_keeps_short_audio_single_chunk() {
        let pcm = vec![0u8; 60 * BYTES_PER_SEC];
        let chunks = split_pcm16_for_deepseek(&pcm);
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].0, 0);
        assert_eq!(chunks[0].1, 60_000);
        assert_eq!(chunks[0].2.len(), pcm.len());
    }

    #[test]
    fn deepseek_splitter_cuts_long_audio_at_silence_within_110s() {
        // 150 seconds of loud tone with a 1-second silent gap at 95..96s
        let total_samples = 150 * SAMPLE_RATE;
        let mut pcm = Vec::with_capacity(total_samples * 2);
        for i in 0..total_samples {
            let sec = i / SAMPLE_RATE;
            let sample: i16 = if sec == 95 { 0 } else { 12_000 };
            pcm.extend_from_slice(&sample.to_le_bytes());
        }
        let chunks = split_pcm16_for_deepseek(&pcm);
        assert_eq!(chunks.len(), 2);
        // Cut should land inside the silent second [95_000, 96_000]
        assert!(
            chunks[0].1 >= 95_000 && chunks[0].1 <= 96_000,
            "expected cut inside 95..96s silence, got {}ms",
            chunks[0].1
        );
        assert!(chunks[0].1 <= 110_000);
        assert_eq!(chunks[1].0, chunks[0].1);
        assert_eq!(chunks[1].1, 150_000);
        assert_eq!(chunks[0].2.len() + chunks[1].2.len(), pcm.len());
    }
}
