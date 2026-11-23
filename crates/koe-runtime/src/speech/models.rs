use super::*;
use koe_client_providers::{offline_speech_models, OfflineSpeechEvent};
use serde_json::json;

impl KoeRuntime {
    pub(crate) fn configure_speech(
        &mut self,
        engine: &str,
        model_id: Option<String>,
    ) -> Result<(), String> {
        let engine = match engine {
            "apple_speech" => SpeechEngine::AppleSpeech,
            "cloud" => SpeechEngine::Cloud,
            "downloaded" => {
                let id = model_id.unwrap_or_else(|| "sensevoice-small".into());
                if !offline_speech_models().iter().any(|m| m.id == id) {
                    return Err("未找到此语音模型".into());
                }
                SpeechEngine::Downloaded(id)
            }
            _ => return Err("无法识别语音引擎".into()),
        };
        self.commit(|w| {
            let mut c = w.provider_configuration().clone();
            c.speech_engine = engine.clone();
            w.configure_provider(c)
        })?;
        if let SpeechEngine::Downloaded(id) = engine {
            if self.speech.loaded_model_id.as_deref() != Some(&id)
                && self.speech.models.get(&id).is_some_and(|s| s.bytes > 0)
            {
                self.prepare_speech_model(&id)?;
            }
        }
        Ok(())
    }
    pub(crate) fn prepare_speech_model(&mut self, id: &str) -> Result<(), String> {
        if self.env.is_replay_mode() {
            return Ok(());
        }
        if !offline_speech_models().iter().any(|m| m.id == id) {
            return Err("未找到此语音模型".into());
        }
        if self.speech.preparation.is_some() {
            return Err("请等待当前模型准备结束；取消后也需等待后台确认".into());
        }
        if self
            .captures
            .sessions
            .values()
            .any(|s| s.is_downloaded() && !s.is_terminal())
        {
            return Err("请等待当前本机转写结束后切换模型".into());
        }
        let worker = self.speech.worker.as_ref().ok_or_else(|| {
            self.speech
                .worker_error
                .clone()
                .unwrap_or_else(|| "本机识别不可用".into())
        })?;
        worker.prepare(id)?;
        self.speech.preparation = Some(ModelPreparation {
            id: id.into(),
            cancelled: false,
        });
        self.speech.loaded_model_id = None;
        for state in self
            .speech
            .models
            .values_mut()
            .filter(|s| s.state == "ready")
        {
            state.state = "downloaded".into();
        }
        self.speech.models.insert(
            id.into(),
            ModelState {
                state: "preparing".into(),
                bytes: 0,
                message: None,
            },
        );
        Ok(())
    }
    pub(crate) fn cancel_speech_model(&mut self) {
        if self
            .captures
            .sessions
            .values()
            .any(|s| s.is_downloaded() && !s.is_terminal())
        {
            self.notice = Some("请先结束当前本机转写".into());
            return;
        }
        if let Some(preparation) = &mut self.speech.preparation {
            preparation.cancelled = true;
        }
        self.speech.loaded_model_id = None;
        for state in self
            .speech
            .models
            .values_mut()
            .filter(|s| s.state == "ready")
        {
            state.state = "downloaded".into();
        }
        if let Some(worker) = &self.speech.worker {
            worker.cancel();
        }
        for state in self
            .speech
            .models
            .values_mut()
            .filter(|s| s.state == "preparing")
        {
            state.state = "missing".into();
            state.message = Some("已取消准备".into());
        }
    }
    pub(crate) fn speech_json(&self) -> Value {
        let engine = &self.workspace().provider_configuration().speech_engine;
        json!({"engine":engine.as_str(),"modelId":match engine { SpeechEngine::Downloaded(id)=>Some(id),_=>None },
            "models":offline_speech_models().iter().map(|m| {let s=self.speech.models.get(m.id);json!({"id":m.id,"name":m.name,"sizeBytes":m.size_bytes,"languages":m.languages,"state":s.map_or("missing",|s|s.state.as_str()),"downloadedBytes":s.map_or(0,|s|s.bytes),"message":s.and_then(|s|s.message.as_ref())})}).collect::<Vec<_>>(),
            "appleState":self.local_asr.state,"appleMessage":self.local_asr.message})
    }
    pub(crate) fn poll_offline_speech(&mut self) -> bool {
        let events = self
            .speech
            .worker
            .as_ref()
            .map_or_else(Vec::new, OfflineSpeechWorker::poll);
        let changed = !events.is_empty();
        for event in events {
            self.accept_offline_speech_event(event);
        }
        changed
    }
    pub(crate) fn accept_offline_speech_event(&mut self, event: OfflineSpeechEvent) {
        match event {
            OfflineSpeechEvent::Preparing {
                model_id,
                downloaded_bytes,
                ..
            } => {
                if !self
                    .speech
                    .preparation
                    .as_ref()
                    .is_some_and(|p| p.id == model_id && !p.cancelled)
                {
                    return;
                }
                self.speech.models.insert(
                    model_id,
                    ModelState {
                        state: "preparing".into(),
                        bytes: downloaded_bytes,
                        message: None,
                    },
                );
            }
            OfflineSpeechEvent::Ready { model_id } => {
                if !self.complete_model_preparation(&model_id) {
                    return;
                }
                self.speech.loaded_model_id = Some(model_id.clone());
                for state in self
                    .speech
                    .models
                    .values_mut()
                    .filter(|s| s.state == "ready")
                {
                    state.state = "downloaded".into();
                }
                let bytes = offline_speech_models()
                    .iter()
                    .find(|m| m.id == model_id)
                    .map_or(0, |m| m.size_bytes);
                self.speech.models.insert(
                    model_id,
                    ModelState {
                        state: "ready".into(),
                        bytes,
                        message: None,
                    },
                );
            }
            OfflineSpeechEvent::PreparationFailed { model_id, error } => {
                if !self.complete_model_preparation(&model_id) {
                    return;
                }
                self.speech.loaded_model_id = None;
                self.speech.models.insert(
                    model_id,
                    ModelState {
                        state: "failed".into(),
                        bytes: 0,
                        message: Some(error),
                    },
                );
            }
            OfflineSpeechEvent::TranscriptionFailed {
                operation_id,
                error,
            } => self.local_asr_failed(operation_id, error),
            OfflineSpeechEvent::Transcribed {
                operation_id,
                text,
                segments,
            } => {
                if segments.is_empty() && !text.trim().is_empty() {
                    let _ = self.local_asr_result(
                        operation_id,
                        text,
                        0,
                        self.captures
                            .sessions
                            .values()
                            .find_map(|s| {
                                s.local_operations()
                                    .and_then(|ops| ops.get(&operation_id))
                                    .map(|o| o.duration_ms)
                            })
                            .unwrap_or(0),
                        true,
                    );
                } else {
                    for segment in segments {
                        let _ = self.local_asr_result(
                            operation_id,
                            segment.text,
                            segment.start_ms,
                            segment.end_ms,
                            true,
                        );
                    }
                }
                self.local_asr_finished(operation_id);
            }
        }
    }
    fn complete_model_preparation(&mut self, id: &str) -> bool {
        if self.speech.preparation.as_ref().is_some_and(|p| p.id == id) {
            return self
                .speech
                .preparation
                .take()
                .is_some_and(|p| !p.cancelled);
        }
        false
    }
}
