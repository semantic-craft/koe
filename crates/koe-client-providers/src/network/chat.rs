use serde_json::{json, Value};

use super::{ProviderConfig, ProviderOutput, ThinkingMode, MAX_RESPONSE_BYTES};

pub(super) async fn complete(
    config: &ProviderConfig,
    system: &str,
    user: &str,
) -> Result<ProviderOutput, String> {
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .retry(reqwest::retry::never())
        .no_proxy()
        .connect_timeout(std::time::Duration::from_secs(15))
        .build()
        .map_err(|_| "无法初始化 HTTPS 客户端")?;
    let mut request = client.post(&config.endpoint);
    if !config.api_key.trim().is_empty() {
        request = request.bearer_auth(&config.api_key);
    }
    let mut payload = json!({
        "model": config.model,
        "stream": false,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user}
        ]
    });
    if let Some(obj) = payload.as_object_mut() {
        match config.thinking {
            Some(ThinkingMode::DeepSeek(enabled)) => {
                obj.insert(
                    "thinking".into(),
                    json!({ "type": if enabled { "enabled" } else { "disabled" } }),
                );
            }
            None => {}
        }
    }
    let mut response = request
        .json(&payload)
        .send()
        .await
        .map_err(|error| {
            if error.is_connect() {
                "无法连接问答服务"
            } else {
                "问答请求中断，结果未知；未自动重试"
            }
        })?;
    if !response.status().is_success() {
        return Err(format!(
            "问答服务返回 HTTP {}；未自动重试",
            response.status().as_u16()
        ));
    }
    if response
        .content_length()
        .is_some_and(|len| len > MAX_RESPONSE_BYTES as u64)
    {
        return Err("问答响应超过 4 MiB 限制".into());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| "问答响应读取中断")? {
        if bytes.len().saturating_add(chunk.len()) > MAX_RESPONSE_BYTES {
            return Err("问答响应超过 4 MiB 限制".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    let value: Value = serde_json::from_slice(&bytes).map_err(|_| "问答服务返回无效 JSON")?;
    let choice = value
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|x| x.first())
        .ok_or("问答服务未返回回答")?;
    if let Some(reason) = choice.get("finish_reason").and_then(Value::as_str) {
        if reason == "length" {
            return Err("问答响应因长度限制被截断".into());
        }
        if reason != "stop" {
            return Err("问答服务未完整生成回答".into());
        }
    }
    let text = choice
        .pointer("/message/content")
        .and_then(Value::as_str)
        .filter(|text| !text.trim().is_empty())
        .ok_or("问答服务返回空回答")?;
    Ok(ProviderOutput::Chat {
        text: text.to_owned(),
    })
}
