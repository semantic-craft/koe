use super::*;
use koe_client_providers::{
    AsrTransportMode, ProviderConfig, ProviderLane, ProviderOutput, ProviderRequest, ProviderTask,
    ThinkingMode,
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
    pub(super) fn text_provider_configured(&self) -> bool {
        if !self.active_llm_key().is_empty() {
            return true;
        }
        Self::is_loopback_http(&self.workspace().provider_configuration().chat_endpoint)
    }
    fn ensure_configured(&self) -> Result<(), String> {
        if !self.text_provider_configured() {
            Err("请先在模型设置中配置服务与 API Key；录音和文字已保存在本机".into())
        } else {
            Ok(())
        }
    }

    pub(super) fn has_pending_in_lane(&self, lane: ProviderLane) -> bool {
        self.pending.values().any(|work| work.lane() == lane)
    }

    fn is_stale_summary(&self, work: &PendingWork) -> bool {
        match work {
            PendingWork::Summary(key) => self.workspace().record(&key.record_id).is_none_or(|r| {
                !r.is_live()
                    || r.content_revision != key.input_revision
                    || !matches!(
                        &r.analysis,
                        AnalysisState::Pending {
                            key: cur,
                            stage: AnalysisStage::Summarizing,
                        } if cur == key
                    )
            }),
            PendingWork::LiveSummary { key, .. } => self
                .workspace()
                .record(&key.record_id)
                .is_none_or(|r| !r.is_live()),
            PendingWork::Transcription(_) | PendingWork::Ask(_) => false,
        }
    }

    pub(super) fn reclaim_stale_summaries(&mut self) -> Result<(), String> {
        let stale_ids: Vec<u64> = self
            .pending
            .iter()
            .filter_map(|(&id, work)| self.is_stale_summary(work).then_some(id))
            .collect();
        if stale_ids.is_empty() {
            return Ok(());
        }
        for &id in &stale_ids {
            self.provider.cancel(ProviderLane::Summary, id);
            self.pending.remove(&id);
        }
        self.completed
            .retain(|event| !stale_ids.contains(&event.operation_id));
        Ok(())
    }

    pub(super) fn start_transcription(&mut self, id: &str) -> Result<(), String> {
        self.try_start_transcription(id).map_err(|e| e.message())
    }
    pub(super) fn try_start_transcription(&mut self, id: &str) -> Result<(), StartError> {
        if self.record_speech_engine(id) != SpeechEngine::Cloud {
            let record = self.workspace().record(id).ok_or("记录不存在")?;
            record.ensure_live().map_err(|e| e.to_string())?;
            if matches!(record.analysis, AnalysisState::Pending { .. }) {
                return Err("这条记录仍在处理中".into());
            }
            if !record.aggregate.spine.is_empty()
                && !matches!(
                    record.analysis,
                    AnalysisState::Interrupted { .. } | AnalysisState::Failed { .. }
                )
            {
                return Err("本机转写保留已有原文，请导入新副本后重新转写".into());
            }
            let pcm = recording_assets::transcription_pcm(&self.root, id)?;
            self.start_file_speech(id, pcm)?;
            return Ok(());
        }
        self.ensure_meeting_audio_upload()?;
        if !self.cloud_asr_configured() {
            return Err("请先配置云端语音凭据；原始录音已保留".into());
        }
        if self.has_pending_in_lane(ProviderLane::Audio) {
            return Err(StartError::Other("已有云端任务正在处理，请稍后重试".into()));
        }
        let record = self.workspace().record(id).ok_or("记录不存在")?;
        record.ensure_live().map_err(|e| e.to_string())?;
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
                record.mode,
                record.project.clone(),
                record.all_day.clone(),
            ))
        };
        let retry_id;
        let id = if let Some((new_id, title, created, duration, mode, project, all_day)) = retry {
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
                )?;
                w.set_record_mode(&new_id, mode)?;
                if let Some(proj) = project.as_deref() {
                    w.set_record_project(&new_id, Some(proj))?;
                }
                if let Some(seg) = all_day {
                    w.group_all_day(&new_id, seg)?;
                }
                Ok(())
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
        let config = self.asr_config();
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
        if self
            .captures
            .sessions
            .get(id)
            .is_some_and(|s| !s.terminal && s.capture_source().is_some())
        {
            return self.try_start_live_summary(id);
        }
        self.ensure_configured()?;
        let record = self.workspace().record(id).ok_or("记录不存在")?;
        record.ensure_live().map_err(|e| e.to_string())?;
        if record.aggregate.spine.is_empty() {
            return Err("这条录音还没有文字，请先转写".into());
        }
        let sources = record.aggregate.spine.format_cited_sources().join("\n");
        self.reclaim_stale_summaries()?;
        if self.has_pending_in_lane(ProviderLane::Summary) {
            return Err(StartError::Other("已有云端任务正在处理，请稍后重试".into()));
        }
        let prompt = build_meeting_minutes_prompt(
            &sources,
            "zh",
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

    pub(super) fn try_start_live_summary(&mut self, id: &str) -> Result<(), StartError> {
        self.ensure_configured()?;
        self.reclaim_stale_summaries()?;
        if self.has_pending_in_lane(ProviderLane::Summary) {
            return Err("已有云端任务正在处理，请稍后重试".into());
        }
        let record = self.workspace().record(id).ok_or("记录不存在")?;
        record.ensure_live().map_err(|e| e.to_string())?;
        if record.aggregate.spine.is_empty() {
            return Err("这条录音还没有文字，请先转写".into());
        }
        let sources = record.aggregate.spine.clone();
        let source_text = sources.format_cited_sources().join("\n");
        let prompt = build_meeting_minutes_prompt(
            &source_text,
            "zh",
            &[],
            Some("录音仍在继续。只整理本次提供原文中有来源的结论，保留未决事项，不推测后续内容。"),
            &[],
        );
        let key = self.store.transact(|w| w.begin_live_summary(id))?;
        if let Some(session) = self.captures.sessions.get_mut(id) {
            session.minutes_schedule.requested(key.input_revision);
        }
        let pending = PendingWork::LiveSummary { key, sources };
        let config = self.chat_config();
        let result = self.submit(
            id,
            config,
            ProviderTask::Chat {
                system: prompt,
                user: source_text,
            },
            Duration::from_secs(180),
            pending.clone(),
        );
        if let Err(error) = &result {
            self.defer_failure(id, pending, error);
        }
        result.map_err(StartError::Other)
    }

    pub(super) fn start_ask(
        &mut self,
        scope: SearchScope,
        question: &str,
        now: u64,
    ) -> Result<(), String> {
        if !self.text_provider_configured() {
            return self.commit(|w| {
                if let Some(request) = w.begin_ask(scope, question, now)? {
                    w.complete_retrieval(request.operation)?;
                }
                Ok(())
            });
        }
        if self.has_pending_in_lane(ProviderLane::Ask) {
            return Err("已有云端问答正在处理，请稍后重试".into());
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

    fn asr_config(&self) -> ProviderConfig {
        let cfg = self.workspace().provider_configuration();
        let asr_mode = match cfg.asr_provider {
            CloudAsrProvider::DeepSeek => AsrTransportMode::DeepSeekHttp,
            CloudAsrProvider::Qwen => match cfg.asr_model.trim() {
                QWEN_FLASH_ASR_MODEL => AsrTransportMode::DashScopeFlashHttp,
                QWEN_FILETRANS_ASR_MODEL => AsrTransportMode::DashScopeFiletransHttp,
                _ => AsrTransportMode::DashScopeWebSocket,
            },
        };
        let model = if cfg.asr_provider == CloudAsrProvider::DeepSeek {
            String::new()
        } else if cfg.asr_model.trim().is_empty() {
            DEFAULT_ASR_MODEL.into()
        } else {
            cfg.asr_model.clone()
        };
        ProviderConfig::new(
            cfg.asr_endpoint.clone(),
            model,
            self.active_asr_key().to_owned(),
        )
        .with_asr_mode(asr_mode)
    }

    fn chat_config(&self) -> ProviderConfig {
        let cfg = self.workspace().provider_configuration();
        let thinking = match cfg.llm_provider {
            LlmProvider::DeepSeek => Some(ThinkingMode::DeepSeek(cfg.enable_thinking)),
            LlmProvider::Custom => None,
        };
        ProviderConfig::new(
            cfg.chat_endpoint.clone(),
            cfg.model.clone(),
            self.active_llm_key().to_owned(),
        )
        .with_thinking(thinking)
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
        let lane = pending.lane();
        self.provider.submit(
            lane,
            ProviderRequest {
                operation_id,
                record_id: id.into(),
                config,
                task,
                timeout,
            },
        )?;
        self.pending.insert(operation_id, pending);
        Ok(())
    }

    pub(super) fn poll_provider(&mut self) -> bool {
        let events = self.provider.poll();
        let mut changed = false;
        let now = self.last_now_sec;
        for event in events {
            if self.handle_app_update_event(&event, now) {
                changed = true;
            } else {
                changed = true;
                self.completed.push_back(event);
            }
        }
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
                    let message = format!("结果等待保存，正在保留本次云端返回：{error}");
                    self.drain_error = Some(message.clone());
                    self.error = Some(message);
                    break;
                }
                Err(CompletionError::Save(StoreError::Domain(
                    ProductError::StaleRequest
                    | ProductError::UnknownRecord
                    | ProductError::RecordTrashed,
                ))) => {
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
                    if let PendingWork::LiveSummary { ref key, .. } = work {
                        match self
                            .store
                            .transact(|w| w.fail_live_summary(key, "原文已更新，等待下一轮整理"))
                        {
                            Ok(())
                            | Err(StoreError::Domain(
                                ProductError::StaleRequest
                                | ProductError::UnknownRecord
                                | ProductError::RecordTrashed,
                            )) => {}
                            Err(error) => {
                                self.drain_error = Some(error.to_string());
                                self.error = self.drain_error.clone();
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
                            self.store.transact(|w| w.fail_analysis(key, &error))
                        }
                        PendingWork::LiveSummary { key, .. } => {
                            self.store.transact(|w| w.fail_live_summary(key, &error))
                        }
                        PendingWork::Ask(operation) => {
                            self.store.transact(|w| w.fail_ask(*operation, &error))
                        }
                    };
                    match recorded {
                        Err(StoreError::Domain(
                            ProductError::StaleRequest
                            | ProductError::UnknownRecord
                            | ProductError::RecordTrashed,
                        )) => {
                            self.notice = Some("已忽略过期请求的失败结果".into());
                        }
                        Err(save_error) => {
                            let message = save_error.to_string();
                            self.drain_error = Some(message.clone());
                            self.error = Some(message);
                            break;
                        }
                        Ok(()) => self.error = Some(error),
                    }
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
                let provider_tag = match self.workspace().provider_configuration().asr_provider {
                    CloudAsrProvider::DeepSeek => "deepseek",
                    CloudAsrProvider::Qwen => "dashscope",
                };
                for (index, segment) in segments.iter().enumerate() {
                    self.accept_speech_final(key, &index.to_string(), segment, provider_tag)?;
                }
                self.store.transact(|w| w.finish_transcription(key))?;
                self.notice = Some("转写完成".into());
            }
            (PendingWork::Summary(key), ProviderOutput::Chat { text }) if id == key.record_id => {
                let record = self
                    .workspace()
                    .record(id)
                    .ok_or(StoreError::Domain(ProductError::UnknownRecord))?;
                record.ensure_live().map_err(StoreError::Domain)?;
                if record.content_revision != key.input_revision
                    || !matches!(
                        &record.analysis,
                        AnalysisState::Pending {
                            key: cur,
                            stage: AnalysisStage::Summarizing,
                        } if cur == key
                    )
                {
                    return Err(CompletionError::Save(StoreError::Domain(
                        ProductError::StaleRequest,
                    )));
                }
                let minutes =
                    parse_meeting_minutes_json(&text, &record.aggregate.spine).map_err(|_| {
                        CompletionError::Invalid(
                            "模型返回的纪要没有通过来源校验，原文保持不变".into(),
                        )
                    })?;
                self.store.transact(|w| w.complete_summary(key, minutes))?;
                self.notice = Some("整理完成，待办与记忆等待你的确认".into());
            }
            (PendingWork::LiveSummary { key, sources }, ProviderOutput::Chat { text })
                if id == key.record_id =>
            {
                let minutes = parse_meeting_minutes_json(&text, sources).map_err(|_| {
                    CompletionError::Invalid("模型返回的纪要没有通过来源校验，原文保持不变".into())
                })?;
                self.store
                    .transact(|w| w.complete_live_summary(key, sources, minutes))?;
                self.notice = Some("实时纪要已更新".into());
            }
            (PendingWork::Ask(operation), ProviderOutput::Chat { text }) if id == "ask" => {
                self.store.transact(|w| w.complete_ask(*operation, &text))?
            }
            _ => return Err(CompletionError::Invalid("处理结果与原始请求不匹配".into())),
        }
        Ok(())
    }
}
