use super::*;
use koe_engine::session::TransferPhaseTag;
use serde::Serialize;
use serde_json::json;

#[derive(PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(super) enum HostAction {
    OpenResponsay,
}

impl KoeRuntime {
    fn ensure_voice_input_available(&self) -> Result<(), String> {
        if self.microphone.is_some()
            || self.all_day.run.is_some()
            || self.is_bean_meeting_recording()
        {
            return Err("请先结束当前记录，再进入语音输入".into());
        }
        if !self.companion.standby_stream_owned {
            self.ensure_device_idle()?;
        }
        Ok(())
    }

    pub(super) fn prepare_voice_input(&mut self, now: u64) -> Result<(), String> {
        self.ensure_voice_input_available()?;
        self.commit(|workspace| {
            workspace.set_companion_mode(CompanionRoutingMode::CollarStandby);
            workspace.set_ble_auto_connect(true);
            Ok(())
        })?;
        self.apply_companion_mode(CompanionRoutingMode::CollarStandby, now)?;
        self.go(Location {
            page: Page::VoiceInput,
            ..Location::default()
        });
        if !self.host_actions.contains(&HostAction::OpenResponsay) {
            self.host_actions.push(HostAction::OpenResponsay);
        }
        Ok(())
    }

    pub(super) fn apply_companion_mode(
        &mut self,
        mode: CompanionRoutingMode,
        now: u64,
    ) -> Result<(), String> {
        if !self.is_quitting() && self.device.session.transfer.phase == TransferPhaseTag::Failed {
            self.device.session.reset_active_transfer();
        }
        self.companion.standby_suppressed_for_connection = false;
        if mode != CompanionRoutingMode::CollarStandby && self.companion.standby_stream_owned {
            self.stop_owned_standby_stream()?;
        } else if mode == CompanionRoutingMode::Disabled {
            self.companion.capture_active = false;
            self.companion.post_tap_skip_slices = 0;
            self.companion.tail_holdback.clear();
        }
        self.drive_companion(now);
        Ok(())
    }

    pub(super) fn voice_input_json(&self) -> Value {
        let unavailable = self.ensure_voice_input_available().err();
        let ready = self.is_standby_ready();
        let status = if unavailable.is_some() {
            "当前记录进行中"
        } else if ready {
            "录音豆已待命"
        } else if !self.device.is_connected() {
            "等待录音豆连接"
        } else {
            "正在准备录音豆"
        };
        json!({
            "sourceLabel": self.device.device_name.as_deref().unwrap_or("soundcore Work · 待连接"),
            "canPrepare": unavailable.is_none() && !self.is_quitting() && !self.store.requires_reopen(),
            "deviceStatus": status,
            "message": unavailable.as_deref().unwrap_or(if ready {
                "将光标放入输入框，双击录音豆正面开始或结束听写。"
            } else {
                "请将录音豆取出充电仓，Koe 会自动连接并准备声音输入。"
            })
        })
    }

    /// Transfers one-shot application actions to the native platform adapter.
    pub fn drain_host_actions_json(&mut self) -> String {
        json!(std::mem::take(&mut self.host_actions)).to_string()
    }
}
