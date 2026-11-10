use super::*;
use koe_client_providers::{
    ProviderConfig, ProviderOutput, ProviderRequest, ProviderTask, DASHSCOPE_ASR_MODEL,
};
use koe_client_services::product_store::StoreError;
use koe_engine::minutes::{build_meeting_minutes_prompt, parse_meeting_minutes_json};
use std::time::Duration;

enum CompletionError {
    Save(StoreError),
    Invalid(String),
}
impl From<StoreError> for CompletionError {
    fn from(error: StoreError) -> Self {
        Self::Save(error)
    }
}

pub(super) enum StartError {
    Storage(StoreError),
    Other(String),
}
impl From<StoreError> for StartError {
    fn from(error: StoreError) -> Self {
        Self::Storage(error)
    }
}
impl From<String> for StartError {
    fn from(error: String) -> Self {
        Self::Other(error)
    }
}
impl From<&str> for StartError {
    fn from(error: &str) -> Self {
        Self::Other(error.into())
    }
}
impl StartError {
    pub fn retryable(&self) -> bool {
        matches!(self, Self::Storage(error) if !matches!(error, StoreError::Domain(_)))
    }
    pub fn message(&self) -> String {
        match self {
            Self::Storage(error) => error.to_string(),
            Self::Other(error) => error.clone(),
        }
    }
}

impl KoeRuntime {
    fn ensure_configured(&self) -> Result<(), String> {
        if self.settings.key.is_empty() {
            Err("请先在设置中配置模型；录音和文字已保存在本机".into())
        } else {
            Ok(())
        }
    }

    pub(super) fn start_transcription(&mut self, id: &str) -> Result<(), String> {
        self.try_start_transcription(id).map_err(|e| e.message())
    }
    pub(super) fn try_start_transcription(&mut self, id: &str) -> Result<(), StartError> {
        self.ensure_meeting_audio_upload()?;
        self.ensure_configured()?;
        let record = self.workspace().record(id).ok_or("记录不存在")?;
        if matches!(record.analysis, AnalysisState::Pending { .. }) {
            return Err("这条记录仍在处理中".into());
        }
        let retry = if record.aggregate.spine.is_empty() {
            None
        } else {
            Some((
                format!("{id}-retry-{}", self.workspace().revision() + 1),
                format!("{}（重新转写）", record.title),
                record.aggregate.created_at_epoch_sec,
                record.aggregate.duration_ms,
            ))
        };
        let retry_id;
        let id = if let Some((new_id, title, created, duration)) = retry {
            let audio = std::fs::read(recording_assets::audio_path(&self.root, id)?)
                .map_err(|e| format!("无法读取原始音频：{e}"))?;
            recording_assets::save_audio(&self.root, &new_id, &audio)?;
            self.store.transact(|w| {
                w.insert_record(
                    new_id.clone(),
                    title,
                    RecordOrigin::ImportedAudio,
                    0,
                    created,
                    duration,
                )
            })?;
            self.open_record(&new_id, None)?;
            self.notice = Some("正在完整转写新副本，原记录和来源引用仍保留".into());
            retry_id = new_id;
            &retry_id
        } else {
            id
        };
        let pcm16 = recording_assets::transcription_pcm(&self.root, id)?;
        let timeout = Duration::from_secs((pcm16.len() as u64 / 32_000 + 120).min(1800));
        let key = self
            .store
            .transact(|w| w.begin_analysis(id, AnalysisStage::Transcribing))?;
        let config = ProviderConfig::new(
            self.workspace()
                .provider_configuration()
                .asr_endpoint
                .clone(),
            DASHSCOPE_ASR_MODEL.into(),
            self.settings.key.clone(),
        );
        let result = self.submit(
            id,
            config,
            ProviderTask::TranscribePcm16 { pcm16 },
            timeout,
            PendingWork::Transcription(key.clone()),
        );
        if let Err(error) = &result {
            self.defer_failure(id, PendingWork::Transcription(key), error);
        }
        result.map_err(StartError::Other)
    }

    pub(super) fn start_summary(&mut self, id: &str) -> Result<(), String> {
        self.try_start_summary(id).map_err(|e| e.message())
    }
    pub(super) fn try_start_summary(&mut self, id: &str) -> Result<(), StartError> {
        self.ensure_configured()?;
        let record = self.workspace().record(id).ok_or("记录不存在")?;
        if record.aggregate.spine.is_empty() {
            return Err("这条录音还没有文字，请先转写".into());
        }
        let sources = record.aggregate.spine.format_cited_sources().join("\n");
        let prompt = build_meeting_minutes_prompt(
            &sources,
            "zh",
            None,
            &[],
            Some("只写有来源的结论、行动和记忆。没有信息的栏目留空，不补全六个栏目。"),
            &[],
        );
        let key = self
            .store
            .transact(|w| w.begin_analysis(id, AnalysisStage::Summarizing))?;
        let config = self.chat_config();
        let result = self.submit(
            id,
            config,
            ProviderTask::Chat {
                system: prompt,
                user: sources,
            },
            Duration::from_secs(180),
            PendingWork::Summary(key.clone()),
        );
        if let Err(error) = &result {
            self.defer_failure(id, PendingWork::Summary(key), error);
        }
        result.map_err(StartError::Other)
    }

    pub(super) fn start_ask(
        &mut self,
        scope: SearchScope,
        question: &str,
        now: u64,
    ) -> Result<(), String> {
        if self.settings.key.is_empty() {
            return self.commit(|w| {
                if let Some(request) = w.begin_ask(scope, question, now)? {
                    w.complete_retrieval(request.operation)?;
                }
                Ok(())
            });
        }
        let request = self.commit(|w| w.begin_ask(scope, question, now))?;
        let Some(request) = request else {
            return Ok(());
        };
        let config = self.chat_config();
        let result = self.submit(
            "ask",
            config,
            ProviderTask::Chat {
                system: request.system_prompt,
                user: format!("{}\n\n{}", request.source_text, request.instruction),
            },
            Duration::from_secs(180),
            PendingWork::Ask(request.operation),
        );
        if let Err(error) = &result {
            self.defer_failure("ask", PendingWork::Ask(request.operation), error);
        }
        result
    }

    fn chat_config(&self) -> ProviderConfig {
        ProviderConfig::new(
            self.workspace()
                .provider_configuration()
                .chat_endpoint
                .clone(),
            self.workspace().provider_configuration().model.clone(),
            self.settings.key.clone(),
        )
    }

    fn defer_failure(&mut self, id: &str, pending: PendingWork, error: &str) {
        let operation_id = self.next_job;
        self.next_job += 1;
        self.pending.insert(operation_id, pending);
        self.completed
            .push_back(koe_client_providers::ProviderEvent {
                operation_id,
                record_id: id.into(),
                result: Err(error.into()),
            });
    }

    fn submit(
        &mut self,
        id: &str,
        config: ProviderConfig,
        task: ProviderTask,
        timeout: Duration,
        pending: PendingWork,
    ) -> Result<(), String> {
        let operation_id = self.next_job;
        self.next_job += 1;
        self.provider.submit(ProviderRequest {
            operation_id,
            record_id: id.into(),
            config,
            task,
            timeout,
        })?;
        self.pending.insert(operation_id, pending);
        Ok(())
    }

    pub(super) fn poll_provider(&mut self) -> bool {
        let events = self.provider.poll();
        let mut changed = !events.is_empty();
        self.completed.extend(events);
        while let Some(event) = self.completed.front().cloned() {
            let Some(work) = self.pending.get(&event.operation_id).cloned() else {
                self.completed.pop_front();
                continue;
            };
            let result = match &event.result {
                Ok(output) => self.apply_output(&work, &event.record_id, output.clone()),
                Err(error) => Err(CompletionError::Invalid(error.clone())),
            };
            let succeeded = result.is_ok();
            match result {
                Err(CompletionError::Save(error)) if !matches!(error, StoreError::Domain(_)) => {
                    self.error = Some(format!("结果等待保存，正在保留本次云端返回：{error}"));
                    break;
                }
                Err(CompletionError::Save(StoreError::Domain(ProductError::StaleRequest))) => {
                    if let PendingWork::Ask(operation) = work {
                        if self
                            .workspace()
                            .pending_ask()
                            .is_some_and(|request| request.operation == operation)
                        {
                            if let Err(error) = self
                                .commit(|w| w.fail_ask(operation, "来源在回答期间更新，请重新提问"))
                            {
                                self.error = Some(error);
                                break;
                            }
                        }
                    }
                    self.error = None;
                    self.notice = Some("记录已更新，过期的处理结果已忽略".into());
                }
                Err(error) => {
                    let error = match error {
                        CompletionError::Save(e) => e.to_string(),
                        CompletionError::Invalid(e) => e,
                    };
                    let recorded = match &work {
                        PendingWork::Transcription(key) | PendingWork::Summary(key) => {
                            self.commit(|w| w.fail_analysis(key, &error))
                        }
                        PendingWork::Ask(operation) => {
                            self.commit(|w| w.fail_ask(*operation, &error))
                        }
                    };
                    if let Err(save_error) = recorded {
                        self.error = Some(save_error);
                        break;
                    }
                    self.error = Some(error);
                }
                Ok(()) => {
                    self.error = None;
                }
            }
            self.completed.pop_front();
            self.pending.remove(&event.operation_id);
            changed = true;
            if succeeded {
                if let PendingWork::Transcription(key) = work {
                    self.auto_summarize.insert(key.record_id);
                }
            }
        }
        changed
    }

    fn apply_output(
        &mut self,
        work: &PendingWork,
        id: &str,
        output: ProviderOutput,
    ) -> Result<(), CompletionError> {
        match (work, output) {
            (PendingWork::Transcription(key), ProviderOutput::Transcript { segments })
                if id == key.record_id =>
            {
                if segments.is_empty() {
                    return Err(CompletionError::Invalid(
                        "未识别到语音，录音仍已保留".into(),
                    ));
                }
                self.store.transact(|w| {
                    for (index, segment) in segments.iter().enumerate() {
                        w.accept_transcript(
                            key,
                            &index.to_string(),
                            &segment.text,
                            segment.start_ms,
                            segment.end_ms,
                            "dashscope",
                        )?;
                    }
                    w.finish_transcription(key)
                })?;
                self.notice = Some("转写完成".into());
            }
            (PendingWork::Summary(key), ProviderOutput::Chat { text }) if id == key.record_id => {
                let record = self
                    .workspace()
                    .record(id)
                    .ok_or_else(|| CompletionError::Invalid("记录不存在".into()))?;
                let minutes =
                    parse_meeting_minutes_json(&text, &record.aggregate.spine).map_err(|_| {
                        CompletionError::Invalid(
                            "模型返回的纪要没有通过来源校验，原文保持不变".into(),
                        )
                    })?;
                self.store.transact(|w| w.complete_summary(key, minutes))?;
                self.notice = Some("整理完成，待办与记忆等待你的确认".into());
            }
            (PendingWork::Ask(operation), ProviderOutput::Chat { text }) if id == "ask" => {
                self.store.transact(|w| w.complete_ask(*operation, &text))?
            }
            _ => return Err(CompletionError::Invalid("处理结果与原始请求不匹配".into())),
        }
        Ok(())
    }
}
