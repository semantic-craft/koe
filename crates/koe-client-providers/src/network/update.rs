use std::time::Duration;

use koe_engine::{SemanticVersion, KOE_GITHUB_DOWNLOAD_PREFIX, KOE_GITHUB_RELEASES_URL};
use serde_json::Value;

use super::ProviderOutput;

const MAX_RELEASE_JSON_BYTES: usize = 512 * 1024;
const MAX_RELEASE_NOTES_BYTES: usize = 4096;
const MAX_REDIRECT_HOPS: usize = 3;

/// Verified downloadable archive attached to a GitHub Release.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReleaseAsset {
    /// Archive file name (for example `Koe-2.3.0-macos-arm64.zip`).
    pub name: String,
    /// Validated download URL.
    pub download_url: String,
    /// Asset byte length reported by GitHub Releases.
    pub size_bytes: u64,
}

/// Validated metadata for the latest stable Koe release.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteRelease {
    /// Parsed `MAJOR.MINOR.PATCH` semantic version.
    pub version: SemanticVersion,
    /// Raw release tag (for example `v2.3.0`).
    pub tag_name: String,
    /// Display title of the release.
    pub title: String,
    /// Optional ISO-8601 publication timestamp from GitHub.
    pub published_at: Option<String>,
    /// Bounded UTF-8 release notes markdown.
    pub notes: String,
    /// Validated browser URL for viewing the release.
    pub release_url: String,
    /// Optional architecture-matched macOS archive asset.
    pub asset: Option<ReleaseAsset>,
}

/// Result of querying the release metadata endpoint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UpdateCheckOutcome {
    /// A stable public release was returned and validated.
    Release(RemoteRelease),
    /// No public stable release is currently exposed (for example private repo HTTP 404 or draft/prerelease).
    Unavailable {
        /// User-facing explanation.
        message: String,
    },
}

/// Validates an update-check endpoint, returning `Ok(true)` for loopback test URLs
/// and `Ok(false)` for official GitHub HTTPS endpoints.
///
/// # Errors
///
/// Rejects invalid URLs, embedded credentials, URL fragments, non-loopback HTTP, non-443 ports,
/// and hosts outside `api.github.com` / `github.com`.
pub fn validate_update_endpoint(endpoint: &str) -> Result<bool, String> {
    if has_unsafe_raw_path_tokens(endpoint) {
        return Err("更新检查地址不能包含路径穿越或转义分隔符".into());
    }
    let url = reqwest::Url::parse(endpoint).map_err(|_| "更新检查地址无效".to_string())?;
    if !url.username().is_empty() || url.password().is_some() || url.fragment().is_some() {
        return Err("更新检查地址不能包含账户、密码或片段".into());
    }
    let is_loopback = super::is_loopback_host(&url);
    if is_loopback {
        if url.scheme() != "http" && url.scheme() != "https" {
            return Err("本机更新测试地址必须使用 HTTP 或 HTTPS".into());
        }
        return Ok(true);
    }
    if url.scheme() != "https" {
        return Err("更新检查地址必须使用 HTTPS".into());
    }
    if url.port_or_known_default() != Some(443) {
        return Err("更新检查地址仅允许 443 端口".into());
    }
    let host = url
        .host_str()
        .unwrap_or_default()
        .trim_end_matches('.')
        .to_ascii_lowercase();
    if host != "api.github.com" {
        return Err("更新检查地址必须使用 GitHub 官方 API 域名".into());
    }
    if !is_allowed_github_api_path(url.path()) {
        return Err("更新检查地址必须指向 Koe 官方发行版接口".into());
    }
    Ok(false)
}

pub(super) fn validate_user_agent(user_agent: &str) -> Result<(), String> {
    let trimmed = user_agent.trim();
    if trimmed.is_empty()
        || trimmed.len() > 128
        || trimmed.bytes().any(|b| !(0x20..=0x7E).contains(&b))
    {
        return Err("更新检查 User-Agent 无效".into());
    }
    Ok(())
}

pub(super) async fn check_latest(
    endpoint: &str,
    user_agent: &str,
) -> Result<ProviderOutput, String> {
    let initial_loopback = validate_update_endpoint(endpoint)?;
    validate_user_agent(user_agent)?;

    let mut builder = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .retry(reqwest::retry::never())
        .connect_timeout(Duration::from_secs(10))
        .read_timeout(Duration::from_secs(10));
    if initial_loopback {
        builder = builder.no_proxy();
    }
    let client = builder
        .build()
        .map_err(|_| "无法初始化 HTTPS 客户端".to_string())?;

    let mut current_url =
        reqwest::Url::parse(endpoint).map_err(|_| "更新检查地址无效".to_string())?;

    for _ in 0..=MAX_REDIRECT_HOPS {
        let mut response = client
            .get(current_url.clone())
            .header("Accept", "application/vnd.github+json")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .header("User-Agent", user_agent.trim())
            .send()
            .await
            .map_err(|error| {
                if error.is_connect() {
                    "无法连接更新服务器，请检查网络连接后重试。".to_string()
                } else {
                    "更新检查请求中断，请稍后重试。".to_string()
                }
            })?;

        let status = response.status();
        if matches!(status.as_u16(), 301 | 302 | 303 | 307 | 308) {
            let location = response
                .headers()
                .get(reqwest::header::LOCATION)
                .and_then(|v| v.to_str().ok())
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| {
                    format!(
                        "更新服务器返回重定向 HTTP {} 但缺少目标地址",
                        status.as_u16()
                    )
                })?;
            if location.starts_with("//") {
                return Err("拒绝协议相对重定向地址".into());
            }
            let next_url = current_url
                .join(location)
                .map_err(|_| "更新服务器返回无效的重定向地址".to_string())?;
            let next_loopback = validate_update_endpoint(next_url.as_str())?;
            if next_loopback != initial_loopback {
                return Err("拒绝跨信任边界的更新重定向".into());
            }
            current_url = next_url;
            continue;
        }

        if status.as_u16() == 404 {
            return Ok(ProviderOutput::UpdateCheck(UpdateCheckOutcome::Unavailable {
                message: "暂未找到公开发行版本（仓库当前保持私有或尚未发布公开版本），可在浏览器中查看发行页面。".into(),
            }));
        }
        if matches!(status.as_u16(), 403 | 429) {
            return Err("GitHub 更新接口请求受限，请稍后再试或直接查看发行页面。".into());
        }
        if !status.is_success() {
            return Err(format!(
                "更新服务器返回 HTTP {}，请稍后重试。",
                status.as_u16()
            ));
        }

        if response
            .content_length()
            .is_some_and(|len| len > MAX_RELEASE_JSON_BYTES as u64)
        {
            return Err("发行版元数据响应超过 512 KiB 限制".into());
        }

        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| "读取更新响应中断，请稍后重试。".to_string())?
        {
            if bytes.len().saturating_add(chunk.len()) > MAX_RELEASE_JSON_BYTES {
                return Err("发行版元数据响应超过 512 KiB 限制".into());
            }
            bytes.extend_from_slice(&chunk);
        }

        return parse_release_payload(&bytes, initial_loopback).map(ProviderOutput::UpdateCheck);
    }

    Err("更新服务器重定向次数过多".into())
}

/// Parses a GitHub Releases JSON payload into an [`UpdateCheckOutcome`].
///
/// # Errors
///
/// Returns an error if `bytes` is invalid JSON or lacks a valid stable `tag_name`.
pub fn parse_release_payload(
    bytes: &[u8],
    allow_loopback_urls: bool,
) -> Result<UpdateCheckOutcome, String> {
    let value: Value =
        serde_json::from_slice(bytes).map_err(|_| "更新服务器返回无效 JSON".to_string())?;
    let draft = value.get("draft").and_then(Value::as_bool).unwrap_or(false);
    let prerelease = value
        .get("prerelease")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if draft || prerelease {
        return Ok(UpdateCheckOutcome::Unavailable {
            message: "最新发行版为草稿或预发布版本，暂不作为正式更新推送。".into(),
        });
    }

    let tag_name = value
        .get("tag_name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| "发行版响应缺少 tag_name".to_string())?;
    let version = SemanticVersion::parse(tag_name)?;

    let title = value
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map_or_else(|| format!("Koe v{version}"), str::to_owned);

    let published_at = value
        .get("published_at")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty() && s.len() <= 64)
        .map(str::to_owned);

    let raw_notes = value
        .get("body")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    let notes = truncate_utf8(raw_notes, MAX_RELEASE_NOTES_BYTES).to_owned();

    let release_url = value
        .get("html_url")
        .and_then(Value::as_str)
        .map(str::trim)
        .and_then(|url| sanitize_release_page_url(url, allow_loopback_urls))
        .unwrap_or_else(|| KOE_GITHUB_RELEASES_URL.to_owned());

    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "x86_64"
    };
    let expected_names = [
        format!("Koe-{version}-macos-{arch}.zip"),
        format!("Koe-v{version}-macos-{arch}.zip"),
        format!("Koe-{version}-macos-universal.zip"),
        format!("Koe-v{version}-macos-universal.zip"),
        format!("Koe-{version}-macos.zip"),
    ];
    let asset = value
        .get("assets")
        .and_then(Value::as_array)
        .and_then(|assets| {
            expected_names.iter().find_map(|candidate| {
                assets.iter().find_map(|item| {
                    let name = item.get("name").and_then(Value::as_str)?.trim();
                    if name != candidate {
                        return None;
                    }
                    let raw_download_url = item
                        .get("browser_download_url")
                        .and_then(Value::as_str)?
                        .trim();
                    let download_url =
                        sanitize_download_url(raw_download_url, allow_loopback_urls)?;
                    let size_bytes = item.get("size").and_then(Value::as_u64).unwrap_or(0);
                    if size_bytes == 0 {
                        return None;
                    }
                    Some(ReleaseAsset {
                        name: name.to_owned(),
                        download_url,
                        size_bytes,
                    })
                })
            })
        });

    Ok(UpdateCheckOutcome::Release(RemoteRelease {
        version,
        tag_name: tag_name.to_owned(),
        title,
        published_at,
        notes,
        release_url,
        asset,
    }))
}

fn has_unsafe_raw_path_tokens(raw: &str) -> bool {
    let before_query_or_frag = raw.split_once(['?', '#']).map_or(raw, |(prefix, _)| prefix);
    if before_query_or_frag.contains('\\') {
        return true;
    }
    let lower = before_query_or_frag.to_ascii_lowercase();
    if lower.contains("%2e") || lower.contains("%2f") || lower.contains("%5c") {
        return true;
    }
    let path_part = match before_query_or_frag.split_once("://") {
        Some((_, rest)) => rest.split_once('/').map_or("", |(_, path)| path),
        None => before_query_or_frag,
    };
    path_part.split('/').any(|seg| seg == "." || seg == "..")
}

fn is_allowed_github_api_path(path: &str) -> bool {
    if path == "/repos/semantic-craft/koe/releases"
        || path.starts_with("/repos/semantic-craft/koe/releases/")
    {
        return true;
    }
    if let Some(rest) = path.strip_prefix("/repositories/") {
        if let Some((repo_id, suffix)) = rest.split_once('/') {
            return !repo_id.is_empty()
                && repo_id.bytes().all(|b| b.is_ascii_digit())
                && (suffix == "releases" || suffix.starts_with("releases/"));
        }
    }
    false
}

fn sanitize_release_page_url(raw: &str, allow_loopback: bool) -> Option<String> {
    if has_unsafe_raw_path_tokens(raw) {
        return None;
    }
    let url = reqwest::Url::parse(raw).ok()?;
    if !url.username().is_empty() || url.password().is_some() || url.fragment().is_some() {
        return None;
    }
    if allow_loopback
        && super::is_loopback_host(&url)
        && (url.scheme() == "http" || url.scheme() == "https")
    {
        return Some(url.into());
    }
    let host = url.host_str()?.trim_end_matches('.').to_ascii_lowercase();
    let allowed = url.scheme() == "https"
        && url.port_or_known_default() == Some(443)
        && host == "github.com"
        && (url.path() == "/semantic-craft/koe/releases"
            || url.path().starts_with("/semantic-craft/koe/releases/"));
    allowed.then(|| url.into())
}

fn sanitize_download_url(raw: &str, allow_loopback: bool) -> Option<String> {
    if has_unsafe_raw_path_tokens(raw) {
        return None;
    }
    let url = reqwest::Url::parse(raw).ok()?;
    if !url.username().is_empty() || url.password().is_some() || url.fragment().is_some() {
        return None;
    }
    if allow_loopback
        && super::is_loopback_host(&url)
        && (url.scheme() == "http" || url.scheme() == "https")
    {
        return Some(url.into());
    }
    let host = url.host_str()?.trim_end_matches('.').to_ascii_lowercase();
    let allowed = url.scheme() == "https"
        && url.port_or_known_default() == Some(443)
        && host == "github.com"
        && url.as_str().starts_with(KOE_GITHUB_DOWNLOAD_PREFIX)
        && url.as_str().len() > KOE_GITHUB_DOWNLOAD_PREFIX.len();
    allowed.then(|| url.into())
}

fn truncate_utf8(input: &str, max_bytes: usize) -> &str {
    if input.len() <= max_bytes {
        return input;
    }
    let mut end = max_bytes;
    while end > 0 && !input.is_char_boundary(end) {
        end -= 1;
    }
    input[..end].trim_end()
}
