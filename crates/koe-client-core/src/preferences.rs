//! Canonical client version and preference defaults owned in one place in Rust
//! (aligned with `metasequoiaime/msime`'s `crates/client-core`).

/// Current Koe client semantic version.
pub const KOE_CLIENT_VERSION: &str = "2.0.0";

/// Default DashScope streaming ASR model identifier.
pub const DEFAULT_ASR_MODEL: &str = "qwen3-asr-flash-realtime";

/// Default Qwen structured minutes model identifier.
pub const DEFAULT_MINUTES_MODEL: &str = "qwen3.8-flash";

/// Default bilingual live caption translation target language (`"en"`).
pub const DEFAULT_TRANSLATION_TARGET_LANG: &str = "en";

/// Canonical user preferences owned by Rust and projected to native hosts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClientPreferences {
    /// Active streaming ASR model name.
    pub asr_model: String,
    /// Active structured minutes LLM model name.
    pub minutes_model: String,
    /// Target language code for bilingual live captions (`"en"`, `"ja"`, `"zh"`).
    pub translation_target_lang: String,
    /// Whether simultaneous interpretation TTS readout is enabled.
    pub live_tts_enabled: bool,
    /// Whether coarse place tagging (`"市 区"`) is enabled for phone recordings.
    pub coarse_place_enabled: bool,
    /// Whether launch-at-login is enabled on desktop hosts.
    pub auto_launch_enabled: bool,
    /// Whether background BLE keep-alive is enabled.
    pub keep_alive_enabled: bool,
}

impl Default for ClientPreferences {
    fn default() -> Self {
        Self {
            asr_model: DEFAULT_ASR_MODEL.to_string(),
            minutes_model: DEFAULT_MINUTES_MODEL.to_string(),
            translation_target_lang: DEFAULT_TRANSLATION_TARGET_LANG.to_string(),
            live_tts_enabled: false,
            coarse_place_enabled: true,
            auto_launch_enabled: true,
            keep_alive_enabled: true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_preferences_match_canonical_models() {
        let prefs = ClientPreferences::default();
        assert_eq!(prefs.asr_model, DEFAULT_ASR_MODEL);
        assert_eq!(prefs.minutes_model, DEFAULT_MINUTES_MODEL);
        assert_eq!(prefs.translation_target_lang, "en");
        assert!(prefs.coarse_place_enabled);
    }
}
