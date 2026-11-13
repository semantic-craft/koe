use super::*;

pub(super) const LOCAL_ASR_UNAVAILABLE: &str = "音频只留本机；请在语音设置选择 Apple 或已下载的本机模型。文字纪要与问答仍可使用已配置的文字服务。";

impl KoeRuntime {
    pub(super) fn ensure_meeting_audio_upload(&self) -> Result<(), String> {
        if self.store.requires_reopen() {
            return Err("工作区保存结果尚未确认，请退出并重新打开 Koe。".into());
        }
        if let Some(error) = &self.audio_policy_error {
            return Err(error.clone());
        }
        match self
            .workspace()
            .provider_configuration()
            .meeting_audio_policy
        {
            MeetingAudioPolicy::CloudAllowed => Ok(()),
            MeetingAudioPolicy::LocalOnly => Err(LOCAL_ASR_UNAVAILABLE.into()),
        }
    }

    pub(super) fn set_meeting_audio_policy(&mut self, policy: &str) -> Result<(), String> {
        let policy = match policy {
            "cloud_allowed" => MeetingAudioPolicy::CloudAllowed,
            "local_only" => MeetingAudioPolicy::LocalOnly,
            _ => return Err("无法识别会议音频上传策略".into()),
        };
        let revoke = policy == MeetingAudioPolicy::LocalOnly || self.audio_policy_error.is_some();
        if revoke {
            self.audio_policy_error = Some("音频上传已暂停；策略尚未保存，请重新设置。".into());
            self.auto_transcribe.clear();
            self.cancel_cloud_captures();
            let jobs: Vec<_> = self
                .pending
                .iter()
                .filter_map(|(id, work)| {
                    matches!(work, PendingWork::Transcription(_)).then_some(*id)
                })
                .collect();
            if !jobs.is_empty() {
                let cancelled = self.provider.cancel_audio();
                self.pending.retain(|id, _| !jobs.contains(id));
                self.completed
                    .retain(|event| !jobs.contains(&event.operation_id));
                cancelled?;
            }
        }
        let local_records = self.local_capture_record_ids();
        self.commit(|workspace| {
            let mut config = workspace.provider_configuration().clone();
            config.meeting_audio_policy = policy;
            workspace.configure_provider(config)?;
            if revoke {
                let keys: Vec<_> = workspace
                    .records()
                    .values()
                    .filter_map(|record| match &record.analysis {
                        AnalysisState::Pending {
                            key,
                            stage: AnalysisStage::Transcribing,
                        } if !local_records.contains(&key.record_id) => Some(key.clone()),
                        _ => None,
                    })
                    .collect();
                for key in keys {
                    workspace
                        .fail_analysis(&key, "会议音频上传已取消；此前已发送的音频无法撤回。")?;
                }
            }
            Ok(())
        })?;
        self.audio_policy_error = None;
        self.notice = Some(match policy {
            MeetingAudioPolicy::LocalOnly => format!(
                "会议录音只留本机；Apple 识别状态：{}。本机文件转写使用所选语音引擎。",
                self.local_asr.message
            ),
            MeetingAudioPolicy::CloudAllowed => {
                "允许会议音频云端转写；已取消的任务不会自动恢复，请手动重试。".into()
            }
        });
        Ok(())
    }
}
