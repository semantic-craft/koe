//! Semantic version parsing, comparison, and canonical Koe release metadata.

use std::fmt;
use std::str::FromStr;

/// Current marketing version of Koe (`CFBundleShortVersionString`).
pub const KOE_APP_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Current macOS bundle build number (`CFBundleVersion`).
pub const KOE_APP_BUILD: &str = "13";

/// Official GitHub Releases page for Koe.
pub const KOE_GITHUB_RELEASES_URL: &str = "https://github.com/semantic-craft/koe/releases";

/// Official GitHub REST API endpoint for the latest published Koe release.
pub const KOE_GITHUB_LATEST_RELEASE_API_URL: &str =
    "https://api.github.com/repos/semantic-craft/koe/releases/latest";

/// Official GitHub release download URL prefix for Koe binary archives.
pub const KOE_GITHUB_DOWNLOAD_PREFIX: &str =
    "https://github.com/semantic-craft/koe/releases/download/";

/// Strict `MAJOR.MINOR.PATCH` semantic version for release comparison.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SemanticVersion {
    /// Major version component.
    pub major: u32,
    /// Minor version component.
    pub minor: u32,
    /// Patch version component.
    pub patch: u32,
}

impl SemanticVersion {
    /// Constructs a [`SemanticVersion`] from numeric components.
    #[must_use]
    pub const fn new(major: u32, minor: u32, patch: u32) -> Self {
        Self {
            major,
            minor,
            patch,
        }
    }

    /// Returns the compiled [`KOE_APP_VERSION`] as a [`SemanticVersion`].
    ///
    /// # Panics
    ///
    /// Panics only if `CARGO_PKG_VERSION` is not valid `MAJOR.MINOR.PATCH`.
    #[must_use]
    pub fn current() -> Self {
        Self::parse(KOE_APP_VERSION).expect("CARGO_PKG_VERSION must be valid MAJOR.MINOR.PATCH")
    }

    /// Parses a stable `MAJOR.MINOR.PATCH` version string with an optional single `v`/`V` prefix.
    ///
    /// # Errors
    ///
    /// Returns a human-readable diagnostic when `raw` is empty, contains a prerelease suffix,
    /// has leading zeros, or does not consist of three `u32` components.
    pub fn parse(raw: &str) -> Result<Self, String> {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return Err("版本号不能为空".into());
        }
        let without_prefix = trimmed
            .strip_prefix('v')
            .or_else(|| trimmed.strip_prefix('V'))
            .unwrap_or(trimmed);
        if without_prefix.is_empty()
            || without_prefix.starts_with('v')
            || without_prefix.starts_with('V')
        {
            return Err(format!("无效的版本号格式：{trimmed}"));
        }

        let core = match without_prefix.split_once('+') {
            Some((before_build, build_meta)) => {
                if build_meta.is_empty()
                    || !build_meta
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
                {
                    return Err(format!("无效的构建元数据：{trimmed}"));
                }
                before_build
            }
            None => without_prefix,
        };

        if core.contains('-') {
            return Err("预发布版本不作为正式更新目标".into());
        }

        let mut parts = core.split('.');
        let major = parse_numeric_part(parts.next(), trimmed)?;
        let minor = parse_numeric_part(parts.next(), trimmed)?;
        let patch = parse_numeric_part(parts.next(), trimmed)?;
        if parts.next().is_some() {
            return Err(format!("无效的版本号格式：{trimmed}"));
        }

        Ok(Self::new(major, minor, patch))
    }
}

fn parse_numeric_part(part: Option<&str>, original: &str) -> Result<u32, String> {
    let Some(part) = part.filter(|s| !s.is_empty()) else {
        return Err(format!("无效的版本号格式：{original}"));
    };
    if part.len() > 1 && part.starts_with('0') {
        return Err(format!("版本号组件不能包含前导零：{original}"));
    }
    if !part.bytes().all(|b| b.is_ascii_digit()) {
        return Err(format!("无效的版本号格式：{original}"));
    }
    part.parse::<u32>()
        .map_err(|_| format!("版本号数值超出范围：{original}"))
}

impl fmt::Display for SemanticVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

impl FromStr for SemanticVersion {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse(s)
    }
}

/// Validates and trims a bundle build identifier (`CFBundleVersion`).
///
/// # Errors
///
/// Returns an error if `raw` is empty, exceeds 32 bytes, or contains non-ASCII-identifier bytes.
pub fn validate_build_number(raw: &str) -> Result<&str, String> {
    if raw.bytes().any(|b| b == b'\r' || b == b'\n') {
        return Err("构建号包含换行字符".into());
    }
    let trimmed = raw.trim_matches([' ', '\t']);
    if trimmed.is_empty() || trimmed.len() > 32 {
        return Err("无效的构建号".into());
    }
    if !trimmed
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_' | b'+'))
    {
        return Err("构建号包含无效字符".into());
    }
    Ok(trimmed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_valid_semver_and_compares_numerically() {
        let current = SemanticVersion::current();
        assert_eq!(current.to_string(), KOE_APP_VERSION);
        assert!(validate_build_number(KOE_APP_BUILD).is_ok());
        assert_eq!(validate_build_number("12_qa+1").unwrap(), "12_qa+1");

        let v2_3_0 = SemanticVersion::parse("v2.3.0").expect("parse v2.3.0");
        let v2_3_0_upper = SemanticVersion::parse(" V2.3.0+build.12 ").expect("parse V2.3.0+build");
        let v2_9_0 = SemanticVersion::parse("2.9.0").expect("parse 2.9.0");
        let v2_10_0 = SemanticVersion::parse("v2.10.0").expect("parse v2.10.0");

        assert_eq!(v2_3_0, v2_3_0_upper);
        assert_eq!(v2_3_0.to_string(), "2.3.0");
        assert!(v2_10_0 > v2_9_0, "2.10.0 must compare greater than 2.9.0");
        assert!(SemanticVersion::new(3, 0, 0) > v2_10_0);
    }

    #[test]
    fn rejects_prerelease_malformed_and_leading_zero_versions() {
        for invalid in [
            "",
            "   ",
            "v",
            "vv2.3.0",
            "2.3",
            "2.3.0.1",
            "02.3.0",
            "2.03.0",
            "2.3.00",
            "v2.3.0-beta.1",
            "2.3.0-rc1",
            "2.3.0+",
            "2.3.0+bad space",
            "99999999999999.0.0",
        ] {
            assert!(
                SemanticVersion::parse(invalid).is_err(),
                "expected error for {invalid:?}"
            );
        }
        for invalid_build in ["", "   ", "12 3", "12\n", &"1".repeat(33)] {
            assert!(
                validate_build_number(invalid_build).is_err(),
                "expected error for build {invalid_build:?}"
            );
        }
    }
}
