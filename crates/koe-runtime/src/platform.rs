use serde_json::{json, Value};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum HostPlatformKind {
    Macos,
    Ios,
    Android,
}

impl HostPlatformKind {
    pub(crate) fn parse(raw: &str) -> Result<Self, String> {
        match raw.trim() {
            "macos" => Ok(Self::Macos),
            "ios" => Ok(Self::Ios),
            "android" => Ok(Self::Android),
            other => Err(format!("不支持的宿主平台：{other}")),
        }
    }

    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Macos => "macos",
            Self::Ios => "ios",
            Self::Android => "android",
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct PlatformMetadataPatch<'a> {
    pub(crate) platform: Option<&'a str>,
    pub(crate) host_display_name: Option<&'a str>,
    pub(crate) supports_system_audio: Option<bool>,
    pub(crate) supports_self_update: Option<bool>,
    pub(crate) native_speech_label: Option<&'a str>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct HostPlatformProfile {
    pub(crate) kind: HostPlatformKind,
    pub(crate) host_display_name: String,
    pub(crate) supports_native_speech: bool,
    pub(crate) supports_system_audio: bool,
    pub(crate) supports_self_update: bool,
    pub(crate) native_speech_label: String,
}

impl HostPlatformProfile {
    pub(crate) fn macos() -> Self {
        Self::for_kind(HostPlatformKind::Macos)
    }

    pub(crate) fn for_kind(kind: HostPlatformKind) -> Self {
        match kind {
            HostPlatformKind::Macos => Self {
                kind,
                host_display_name: "Mac".into(),
                supports_native_speech: true,
                supports_system_audio: true,
                supports_self_update: true,
                native_speech_label: "Apple 本机".into(),
            },
            HostPlatformKind::Ios => Self {
                kind,
                host_display_name: "iPhone".into(),
                supports_native_speech: true,
                supports_system_audio: false,
                supports_self_update: false,
                native_speech_label: "Apple 本机".into(),
            },
            HostPlatformKind::Android => Self {
                kind,
                host_display_name: "Android".into(),
                supports_native_speech: false,
                supports_system_audio: false,
                supports_self_update: false,
                native_speech_label: "Android 本机".into(),
            },
        }
    }

    pub(crate) fn apply_patch(&self, patch: PlatformMetadataPatch<'_>) -> Result<Self, String> {
        let mut next = match patch.platform {
            Some(raw) => Self::for_kind(HostPlatformKind::parse(raw)?),
            None => self.clone(),
        };
        if let Some(name) = patch
            .host_display_name
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            next.host_display_name = name.to_owned();
        }
        if let Some(supports_system_audio) = patch.supports_system_audio {
            next.supports_system_audio = supports_system_audio;
        }
        if let Some(supports_self_update) = patch.supports_self_update {
            next.supports_self_update = supports_self_update;
        }
        if let Some(label) = patch
            .native_speech_label
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            next.native_speech_label = label.to_owned();
        }
        Ok(next)
    }

    pub(crate) fn mic_label(&self) -> String {
        format!("{} 麦克风", self.host_display_name)
    }

    pub(crate) fn bluetooth_label(&self) -> String {
        format!("{} 蓝牙", self.host_display_name)
    }

    pub(crate) fn mic_recording_label(&self) -> String {
        format!("{} 麦克风录音", self.host_display_name)
    }

    pub(crate) fn dual_recording_label(&self) -> String {
        format!("{} 双路录音", self.host_display_name)
    }

    pub(crate) fn to_json(&self) -> Value {
        json!({
            "id": self.kind.as_str(),
            "hostDisplayName": self.host_display_name,
            "supportsNativeSpeech": self.supports_native_speech,
            "supportsSystemAudio": self.supports_system_audio,
            "supportsSelfUpdate": self.supports_self_update,
            "nativeSpeechLabel": self.native_speech_label,
        })
    }
}

impl Default for HostPlatformProfile {
    fn default() -> Self {
        Self::macos()
    }
}
