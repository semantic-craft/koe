use super::*;
use koe_engine::session::TransferPhaseTag;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeSet;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AudioInputTransport {
    Bluetooth,
    Usb,
    BuiltIn,
    External,
}

impl AudioInputTransport {
    pub(crate) fn badge(&self) -> &'static str {
        match self {
            Self::Bluetooth => "Mac 蓝牙",
            Self::Usb => "USB 外接",
            Self::BuiltIn => "本机内置",
            Self::External => "音频输入",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct AudioInputDescriptor {
    pub id: String,
    pub name: String,
    pub transport: AudioInputTransport,
    #[serde(default)]
    pub is_default: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) enum CaptureSourcePreference {
    #[default]
    Auto,
    Bean,
    SystemDefault,
    CoreAudioInput(String),
}

#[derive(Clone, Debug, Default)]
pub(crate) struct CaptureStudioState {
    pub preference: CaptureSourcePreference,
    pub inputs: Vec<AudioInputDescriptor>,
}

impl KoeRuntime {
    pub(super) fn is_bean_meeting_recording(&self) -> bool {
        (self.device.session.device_recording_active && !self.companion.standby_stream_owned)
            || self.device.awaiting_stop
            || (!self.companion.standby_stream_owned
                && matches!(
                    self.device.session.transfer.phase,
                    TransferPhaseTag::StreamingRealtime
                ))
    }

    pub(super) fn sync_audio_inputs(
        &mut self,
        raw: Vec<AudioInputDescriptor>,
    ) -> Result<(), String> {
        if raw.len() > 64 {
            return Err("音频输入设备数量超过上限".into());
        }
        let mut seen_ids = BTreeSet::new();
        let mut seen_default = false;
        let mut cleaned = Vec::with_capacity(raw.len());
        for item in raw {
            let id = item.id.trim().to_string();
            if id.is_empty() || id.len() > 256 {
                return Err("音频输入设备标识无效".into());
            }
            if !seen_ids.insert(id.clone()) {
                continue;
            }
            let trimmed_name = item.name.trim();
            let name = if trimmed_name.is_empty() {
                id.clone()
            } else {
                trimmed_name.to_string()
            };
            let is_default = if item.is_default && !seen_default {
                seen_default = true;
                true
            } else {
                false
            };
            cleaned.push(AudioInputDescriptor {
                id,
                name,
                transport: item.transport,
                is_default,
            });
        }
        cleaned.sort_by(|a, b| {
            (
                a.transport != AudioInputTransport::Bluetooth,
                !a.is_default,
                &a.name,
                &a.id,
            )
                .cmp(&(
                    b.transport != AudioInputTransport::Bluetooth,
                    !b.is_default,
                    &b.name,
                    &b.id,
                ))
        });
        self.capture_studio.inputs = cleaned;
        if let CaptureSourcePreference::CoreAudioInput(uid) = &self.capture_studio.preference {
            if !self.capture_studio.inputs.iter().any(|i| i.id == *uid) {
                self.capture_studio.preference = CaptureSourcePreference::Auto;
            }
        }
        Ok(())
    }

    pub(super) fn select_capture_source(&mut self, source: &str) -> Result<(), String> {
        if self.microphone.is_some() || self.is_bean_meeting_recording() {
            return Err("正在录音中，请先停止当前录音再切换音源".into());
        }
        match source.trim() {
            "bean" => self.capture_studio.preference = CaptureSourcePreference::Bean,
            "auto" => self.capture_studio.preference = CaptureSourcePreference::Auto,
            "system_default" | "" => {
                self.capture_studio.preference = CaptureSourcePreference::SystemDefault;
            }
            s => {
                let uid = s.strip_prefix("input:").unwrap_or(s);
                if uid.is_empty() || uid.len() > 256 {
                    return Err("音频输入设备标识无效".into());
                }
                if !self.capture_studio.inputs.iter().any(|i| i.id == uid) {
                    return Err("所选输入设备已不可用，请刷新后重试".into());
                }
                self.capture_studio.preference =
                    CaptureSourcePreference::CoreAudioInput(uid.to_string());
            }
        }
        Ok(())
    }

    pub(super) fn capture_studio_json(&self) -> Value {
        let device_name = self
            .device
            .device_name
            .clone()
            .unwrap_or_else(|| "Soundcore Work".to_string());
        let inputs = &self.capture_studio.inputs;
        let bean_recording = self.is_bean_meeting_recording();
        let active_source = if bean_recording {
            Some("bean".to_string())
        } else {
            self.microphone.as_ref().map(|m| {
                if m.input_id.is_empty() {
                    "system_default".to_string()
                } else {
                    format!("input:{}", m.input_id)
                }
            })
        };

        let device_busy = (matches!(
            self.device.session.transfer.phase,
            TransferPhaseTag::PullingOffline | TransferPhaseTag::StreamingRealtime
        ) || self.device.session.device_recording_active
            || self.device.awaiting_stop)
            && !self.companion.standby_stream_owned;
        let bean_ready = self.device.is_connected()
            && !device_busy
            && self.workspace().companion_mode() != CompanionRoutingMode::CollarStandby;

        let resolve_auto = || -> (String, String, String, &'static str) {
            if bean_ready {
                ("bean".into(), String::new(), device_name.clone(), "录音豆")
            } else if let Some(bt) = inputs
                .iter()
                .find(|i| i.transport == AudioInputTransport::Bluetooth && i.is_default)
                .or_else(|| {
                    inputs
                        .iter()
                        .find(|i| i.transport == AudioInputTransport::Bluetooth)
                })
            {
                (
                    format!("input:{}", bt.id),
                    bt.id.clone(),
                    bt.name.clone(),
                    "Mac 蓝牙",
                )
            } else if let Some(def) = inputs
                .iter()
                .find(|i| i.is_default)
                .or_else(|| inputs.first())
            {
                (
                    format!("input:{}", def.id),
                    def.id.clone(),
                    def.name.clone(),
                    def.transport.badge(),
                )
            } else {
                (
                    "system_default".into(),
                    String::new(),
                    "系统默认麦克风".into(),
                    "系统默认",
                )
            }
        };

        let (selected_source, selected_input_id, selected_label, selected_badge, selection_mode) =
            if bean_recording {
                (
                    "bean".to_string(),
                    String::new(),
                    device_name,
                    "录音豆",
                    "active",
                )
            } else if let Some(m) = &self.microphone {
                if m.input_id.is_empty() {
                    if let Some(def) = inputs.iter().find(|i| i.is_default) {
                        (
                            "system_default".into(),
                            String::new(),
                            def.name.clone(),
                            def.transport.badge(),
                            "active",
                        )
                    } else {
                        (
                            "system_default".into(),
                            String::new(),
                            "系统默认麦克风".into(),
                            "系统默认",
                            "active",
                        )
                    }
                } else if let Some(found) = inputs.iter().find(|i| i.id == m.input_id) {
                    (
                        format!("input:{}", found.id),
                        found.id.clone(),
                        found.name.clone(),
                        found.transport.badge(),
                        "active",
                    )
                } else {
                    (
                        format!("input:{}", m.input_id),
                        m.input_id.clone(),
                        "Mac 麦克风".into(),
                        "音频输入",
                        "active",
                    )
                }
            } else {
                match &self.capture_studio.preference {
                    CaptureSourcePreference::Auto => {
                        let (s, id, lbl, bdg) = resolve_auto();
                        (s, id, lbl, bdg, "auto")
                    }
                    CaptureSourcePreference::Bean => (
                        "bean".into(),
                        String::new(),
                        device_name,
                        "录音豆",
                        "manual",
                    ),
                    CaptureSourcePreference::SystemDefault => {
                        if let Some(def) = inputs.iter().find(|i| i.is_default) {
                            (
                                "system_default".into(),
                                String::new(),
                                def.name.clone(),
                                def.transport.badge(),
                                "manual",
                            )
                        } else {
                            (
                                "system_default".into(),
                                String::new(),
                                "系统默认麦克风".into(),
                                "系统默认",
                                "manual",
                            )
                        }
                    }
                    CaptureSourcePreference::CoreAudioInput(uid) => {
                        if let Some(found) = inputs.iter().find(|i| i.id == *uid) {
                            (
                                format!("input:{}", found.id),
                                found.id.clone(),
                                found.name.clone(),
                                found.transport.badge(),
                                "manual",
                            )
                        } else {
                            let (s, id, lbl, bdg) = resolve_auto();
                            (s, id, lbl, bdg, "auto")
                        }
                    }
                }
            };

        let can_start =
            if self.is_quitting() || self.store.requires_reopen() || active_source.is_some() {
                false
            } else if selected_source == "bean" {
                bean_ready
            } else {
                true
            };

        let inputs_json: Vec<Value> = inputs
            .iter()
            .map(|input| {
                json!({
                    "id": input.id,
                    "sourceKey": format!("input:{}", input.id),
                    "name": input.name,
                    "transport": input.transport,
                    "badge": input.transport.badge(),
                    "isDefault": input.is_default,
                })
            })
            .collect();

        json!({
            "selectedSource": selected_source,
            "selectedInputId": selected_input_id,
            "selectedLabel": selected_label,
            "selectedBadge": selected_badge,
            "selectionMode": selection_mode,
            "activeSource": active_source,
            "canStart": can_start,
            "inputs": inputs_json,
        })
    }
}
