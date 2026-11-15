use super::*;
use serde::Serialize;
use serde_json::json;

#[derive(PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(super) enum HostAction {
    OpenResponsay,
}

impl KoeRuntime {
    pub(super) fn ensure_voice_input_available(&self) -> Result<(), String> {
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

    pub(super) fn set_voice_input_session(
        &mut self,
        enabled: bool,
        open_responsay: bool,
        now: u64,
    ) -> Result<(), String> {
        if enabled {
            self.ensure_voice_input_available()?;
            self.commit(|workspace| {
                workspace.set_companion_mode(CompanionRoutingMode::CollarStandby);
                workspace.set_ble_auto_connect(true);
                Ok(())
            })?;
            self.apply_companion_mode(CompanionRoutingMode::CollarStandby, now)?;
            if open_responsay {
                self.open_responsay_app();
            }
            Ok(())
        } else {
            self.commit(|workspace| {
                workspace.set_companion_mode(CompanionRoutingMode::Disabled);
                Ok(())
            })?;
            self.apply_companion_mode(CompanionRoutingMode::Disabled, now)
        }
    }

    pub(super) fn open_responsay_app(&mut self) {
        if !self.host_actions.contains(&HostAction::OpenResponsay) {
            self.host_actions.push(HostAction::OpenResponsay);
        }
    }

    pub(super) fn prepare_voice_input(&mut self, now: u64) -> Result<(), String> {
        self.set_voice_input_session(true, true, now)?;
        self.go(Location {
            page: Page::VoiceInput,
            ..Location::default()
        });
        Ok(())
    }

    pub(super) fn apply_companion_mode(
        &mut self,
        mode: CompanionRoutingMode,
        now: u64,
    ) -> Result<(), String> {
        let quitting = self.is_quitting();
        self.device.reset_failed_transfer_if_idle(quitting);
        self.companion.armed = mode != CompanionRoutingMode::Disabled;
        self.companion.standby_suppressed_for_connection = false;
        if mode != CompanionRoutingMode::CollarStandby && self.companion.standby_stream_owned {
            self.stop_owned_standby_stream()?;
        } else if mode == CompanionRoutingMode::Disabled {
            self.companion.clear_transient_capture();
        }
        self.drive_companion(now);
        Ok(())
    }

    /// Transfers one-shot application actions to the native platform adapter.
    pub fn drain_host_actions_json(&mut self) -> String {
        json!(std::mem::take(&mut self.host_actions)).to_string()
    }
}
