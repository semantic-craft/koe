use crate::command::{AdapterEvent, DispatchMessage, HostIntent, Location, Page};
use crate::observability::lifecycle;
use crate::projection::mode_workspaces;
use crate::KoeRuntime;
use koe_client_services::recording_assets;
use koe_engine::domain::SegmentId;
use koe_engine::product::*;
use std::path::Path;

impl KoeRuntime {
    pub(crate) fn dispatch_message(&mut self, message: DispatchMessage, now: u64) -> Result<(), String> {
        let _ = self.enter_runtime_step(now);
        let allowed_while_quitting = match &message {
            DispatchMessage::Intent(intent) => intent.allowed_while_quitting(),
            DispatchMessage::Adapter(event) => event.allowed_while_quitting(),
        };
        if self.is_quitting() && !allowed_while_quitting {
            return Err("正在退出，请先取消退出再开始新操作".into());
        }
        match message {
            DispatchMessage::Intent(intent) => self.dispatch_intent(intent, now)?,
            DispatchMessage::Adapter(event) => self.dispatch_adapter_event(event, now)?,
        }
        self.reconcile_capture_session();
        Ok(())
    }

    fn dispatch_adapter_event(&mut self, event: AdapterEvent, now: u64) -> Result<(), String> {
        match event {
            AdapterEvent::SyncAudioInputs { inputs } => self.sync_audio_inputs(inputs)?,
            AdapterEvent::SyncAppMetadata {
                version,
                build,
                update_endpoint,
                platform,
                host_display_name,
                supports_system_audio,
                supports_self_update,
                native_speech_label,
            } => self.sync_app_metadata(
                &version,
                &build,
                update_endpoint.as_deref(),
                crate::workspace::platform::PlatformMetadataPatch {
                    platform: platform.as_deref(),
                    host_display_name: host_display_name.as_deref(),
                    supports_system_audio,
                    supports_self_update,
                    native_speech_label: native_speech_label.as_deref(),
                },
            )?,
            AdapterEvent::MicrophonePrepared {
                record_id,
                session_id,
                epoch,
                clock_ns,
            } => self.microphone_prepared(&record_id, &session_id, epoch, clock_ns)?,
            AdapterEvent::ResumeMicrophone { clock_ns } => self.resume_microphone(clock_ns)?,
            AdapterEvent::MicrophoneStarted {
                record_id,
                session_id,
                lane,
                sample_rate,
            } => self.microphone_started(&record_id, &session_id, &lane, sample_rate)?,
            AdapterEvent::MicrophonePaused {
                record_id,
                session_id,
                lane,
                sequence,
                epoch,
            } => self.microphone_paused(&record_id, &session_id, &lane, sequence, epoch)?,
            AdapterEvent::MicrophoneStopped {
                record_id,
                session_id,
                lane,
                sequence,
                epoch,
            } => self.microphone_stopped(&record_id, &session_id, &lane, sequence, epoch)?,
            AdapterEvent::MicrophoneFailed {
                record_id,
                session_id,
                lane,
                message,
                epoch,
            } => self.microphone_failed(&record_id, &session_id, &lane, message, epoch),
            AdapterEvent::LocalAsrReadiness { state, message } => {
                self.local_asr_readiness(state, message)?
            }
            AdapterEvent::LocalAsrResult {
                operation_id,
                text,
                start_ms,
                end_ms,
                is_final,
            } => self.local_asr_result(operation_id, text, start_ms, end_ms, is_final)?,
            AdapterEvent::LocalAsrFinished { operation_id } => self.local_asr_finished(operation_id),
            AdapterEvent::LocalAsrFailed {
                operation_id,
                message,
            } => self.local_asr_failed(operation_id, message),
            AdapterEvent::DeviceEvent {
                event,
                connection_id,
                device_name,
            } => {
                self.device
                    .event(&event, &connection_id, device_name.as_deref())?;
                self.save_captures(now)?;
            }
            AdapterEvent::DeviceDisconnect => {
                self.disconnect_device_session(now)?;
            }
            AdapterEvent::RequestQuit => self.request_quit(),
            AdapterEvent::CancelQuit => {
                self.quit = lifecycle::QuitState::Running;
                let quitting = self.is_quitting();
                self.device.reset_failed_transfer_if_idle(quitting);
            }
        }
        Ok(())
    }

    fn dispatch_intent(&mut self, intent: HostIntent, now: u64) -> Result<(), String> {
        match intent {
            HostIntent::StartCaptureMode { mode, stay_on_page } => {
                self.start_capture_mode(mode, stay_on_page, now)?
            }
            HostIntent::CaptureAction { action, clock_ns } => {
                self.capture_action(action, clock_ns)?
            }
            HostIntent::StartMicrophone {
                input_id,
                include_system,
                clock_ns,
            } => self.start_microphone(input_id, include_system, clock_ns, now)?,
            HostIntent::SelectCaptureSource { source } => self.select_capture_source(&source)?,
            HostIntent::SetCaptureSystemAudio { enabled } => {
                self.set_capture_system_audio(enabled)?
            }
            HostIntent::PauseMicrophone => self.pause_microphone()?,
            HostIntent::StopMicrophone => self.stop_microphone(false)?,
            HostIntent::CancelMicrophone => self.stop_microphone(true)?,
            HostIntent::RetryMicrophoneSave => self.save_microphone()?,
            HostIntent::Navigate { section } => self.go(Location {
                page: section,
                ..self.selection.location.clone()
            }),
            HostIntent::Back => self.selection.pop_back(),
            HostIntent::SelectRecord { record_id } => self.open_record(&record_id, None)?,
            HostIntent::OpenSource {
                record_id,
                segment_id,
            } => {
                let source = self
                    .workspace()
                    .resolve_live_source(&source_ref(&record_id, &segment_id)?)
                    .map_err(|e| e.to_string())?;
                self.open_record(&record_id, Some(segment_id))?;
                self.seek_playback(source.start_ms)?;
            }
            HostIntent::CreateNote {
                title,
                text,
                stay_on_page,
            } => {
                let id = self.create_quick_note(title, &text, true, now)?;
                if !stay_on_page {
                    self.open_record(&id, None)?;
                }
            }
            HostIntent::ImportFile { path } => {
                let imported =
                    recording_assets::import_recording(&self.root, Path::new(&path), now)?;
                if imported.has_audio {
                    self.refresh_audio_storage_summary();
                }
                let id = imported.id.clone();
                if let Some(existing) = self.workspace().record(&id) {
                    if existing.is_trashed() {
                        self.commit(|w| w.restore_record(&id))?;
                        self.clear_undo_trash_for(&id);
                    }
                } else {
                    self.commit(|workspace| {
                        let origin = if imported.has_audio {
                            RecordOrigin::ImportedAudio
                        } else {
                            RecordOrigin::ImportedText
                        };
                        workspace.insert_record(
                            id.clone(),
                            imported.title,
                            origin,
                            0,
                            imported.created_at,
                            imported.duration_ms,
                        )?;
                        for paragraph in imported.paragraphs {
                            workspace.append_transcript(&id, &paragraph, 0, 0, "import")?;
                        }
                        if let Some(minutes) = imported.minutes {
                            let key = workspace.begin_analysis(&id, AnalysisStage::Summarizing)?;
                            workspace.complete_summary(&key, minutes)?;
                        }
                        Ok(())
                    })?;
                }
                self.open_record(&id, None)?;
                self.notice = Some("导入完成".into());
            }
            HostIntent::RenameRecord { record_id, title } => {
                self.commit(|w| w.rename_record(&record_id, &title))?
            }
            HostIntent::SetRecordProject { record_id, project } => {
                self.set_record_project(&record_id, project.as_deref())?
            }
            HostIntent::SelectQuickNoteRecord { record_id } => {
                self.select_quick_note_record(record_id)?
            }
            HostIntent::SelectAllDayDate { date } => self.select_all_day_date(&date)?,
            HostIntent::SelectLiveMinutesRecord { record_id } => {
                self.select_live_minutes_record(record_id)?
            }
            HostIntent::SetRecordArchived {
                record_id,
                archived,
            } => self.handle_set_record_archived(&record_id, archived)?,
            HostIntent::BatchSetRecordArchived {
                record_ids,
                archived,
            } => self.handle_batch_set_record_archived(&record_ids, archived)?,
            HostIntent::BatchSetRecordProject {
                record_ids,
                project,
            } => self.batch_set_record_project(&record_ids, project.as_deref())?,
            HostIntent::TrashRecord { record_id } => self.handle_trash_record(&record_id, now)?,
            HostIntent::BatchTrashRecords { record_ids } => {
                self.handle_batch_trash_records(&record_ids, now)?
            }
            HostIntent::RestoreRecord { record_id } => self.handle_restore_record(&record_id)?,
            HostIntent::BatchRestoreRecords { record_ids } => {
                self.handle_batch_restore_records(&record_ids)?
            }
            HostIntent::PurgeRecord { record_id } => self.handle_purge_record(&record_id)?,
            HostIntent::EmptyTrash => self.handle_empty_trash()?,
            HostIntent::DismissUndoTrash => self.handle_dismiss_undo_trash(),
            HostIntent::ExportWorkspaceMarkdown {
                record_id,
                date,
                path,
                include_analysis,
                include_sources,
            } => self.export_workspace_markdown(
                record_id.as_deref(),
                date.as_deref(),
                Path::new(&path),
                include_analysis,
                include_sources,
            )?,
            HostIntent::ExportRecordsMarkdown {
                record_ids,
                directory,
                include_analysis,
                include_sources,
            } => self.export_records_markdown(
                &record_ids,
                Path::new(&directory),
                include_analysis,
                include_sources,
            )?,
            HostIntent::ReviewItem { item_id, decision } => {
                let decision = match decision.as_str() {
                    "accept" => ReviewDecision::Accept,
                    "dismiss" => ReviewDecision::Dismiss,
                    "reset" => ReviewDecision::Reset,
                    _ => return Err("无效的确认操作".into()),
                };
                self.commit(|w| w.review_item(&item_id, decision))?;
            }
            HostIntent::CompleteTask { item_id, completed } => {
                self.commit(|w| w.complete_task(&item_id, completed))?
            }
            HostIntent::EditItem { item_id, text, due } => {
                self.commit(|w| w.edit_item(&item_id, &text, due))?
            }
            HostIntent::SaveMemory {
                record_id,
                segment_id,
            } => {
                let _ = self.accept_segment_item(ItemKind::Memory, &record_id, &segment_id)?;
            }
            HostIntent::CreateTask {
                record_id,
                segment_id,
            } => {
                let _ = self.accept_segment_item(ItemKind::Task, &record_id, &segment_id)?;
            }
            HostIntent::AddHighlight {
                record_id,
                segment_id,
            } => self.highlight_segment(&record_id, &segment_id)?,
            HostIntent::EditSegmentText {
                record_id,
                segment_id,
                text,
            } => self.edit_segment_text(&record_id, &segment_id, &text)?,
            HostIntent::SetSegmentSpeaker {
                record_id,
                segment_id,
                speaker,
            } => self.set_segment_speaker(&record_id, &segment_id, speaker.as_deref())?,
            HostIntent::RenameSpeaker {
                record_id,
                from_speaker,
                to_speaker,
            } => {
                let _ = self.rename_speaker(&record_id, &from_speaker, &to_speaker)?;
            }
            HostIntent::Ask {
                question,
                scope,
                record_id,
            } => {
                self.start_ask(search_scope(&scope, record_id)?, &question, now)?;
                self.go(Location {
                    page: Page::Ask,
                    ..self.selection.location.clone()
                });
            }
            HostIntent::SetAskScope { scope, record_id } => {
                let scope = search_scope(&scope, record_id)?;
                self.commit(|w| w.set_ask_scope(scope))?;
            }
            HostIntent::ConfigureSpeech { engine, model_id } => {
                self.configure_speech(&engine, model_id)?
            }
            HostIntent::PrepareSpeechModel { model_id } => self.prepare_speech_model(&model_id)?,
            HostIntent::CancelSpeechModel => self.cancel_speech_model(),
            HostIntent::StartAllDay { source, input_id } => {
                self.start_all_day(&source, input_id.unwrap_or_default(), now)?
            }
            HostIntent::StopAllDay => self.stop_all_day()?,
            HostIntent::Transcribe { record_id } => self.start_transcription(&record_id)?,
            HostIntent::SetMeetingAudioPolicy { policy } => self.set_meeting_audio_policy(&policy)?,
            HostIntent::Summarize { record_id } => self.start_summary(&record_id)?,
            HostIntent::ConfigureProvider {
                api_key,
                deepseek_api_key,
                asr_provider,
                asr_model,
                llm_provider,
                model,
                enable_thinking,
                qwen_workspace_id,
                asr_endpoint,
                chat_endpoint,
            } => self.configure_provider(
                crate::processing::provider_settings::ConfigureProviderParams {
                api_key,
                deepseek_api_key,
                asr_provider,
                asr_model,
                llm_provider,
                model,
                enable_thinking,
                qwen_workspace_id,
                asr_endpoint,
                chat_endpoint,
            })?,
            HostIntent::ClearProviderCredential { provider } => {
                self.clear_credential(provider.as_deref())?
            }
            HostIntent::RetryProviderCredentials { authorize } => self.retry_credentials(authorize)?,
            HostIntent::CheckAppUpdate => self.check_app_update(now)?,
            HostIntent::ClearError => {}
            HostIntent::Seek { position_ms } => self.seek_playback(position_ms)?,
            HostIntent::Playback { is_playing } => self.set_playback(is_playing)?,
            HostIntent::SelectPlaybackLane { lane } => self.select_playback_lane(lane)?,
            HostIntent::DeviceOpenGuide => {
                if !self.workspace().ble_auto_connect() {
                    self.commit(|w| {
                        w.set_ble_auto_connect(true);
                        Ok(())
                    })?;
                }
                self.device.open_guide();
            }
            HostIntent::DeviceOnboardingNext => self.device.onboarding_next(),
            HostIntent::DeviceCloseGuide => self.device.close_guide(),
            HostIntent::DeviceRefresh => {
                let quitting = self.is_quitting();
                self.device.reset_failed_transfer_if_idle(quitting);
                self.device.refresh();
            }
            HostIntent::DeviceRelease => {
                if let Some(reason) = self.release_to_phone_block_reason() {
                    return Err(reason.into());
                }
                if self.bean_control_owner() != mode_workspaces::BeanControlOwner::Released {
                    self.commit(|w| {
                        w.set_ble_auto_connect(false);
                        Ok(())
                    })?;
                    self.reset_bean_preference_if_needed();
                    self.disconnect_device_session(now)?;
                    self.notice = Some("已释放录音豆蓝牙控制权".into());
                }
            }
            HostIntent::SetBleAutoConnect { enabled } => {
                if !enabled {
                    if let Some(reason) = self.release_to_phone_block_reason() {
                        return Err(reason.into());
                    }
                }
                self.commit(|w| {
                    w.set_ble_auto_connect(enabled);
                    Ok(())
                })?;
                if !enabled {
                    self.reset_bean_preference_if_needed();
                }
            }
            HostIntent::DeviceDownload { file_id } => {
                if !self.device.is_connected() {
                    return Err("请先连接录音豆".into());
                }
                let quitting = self.is_quitting();
                self.device.reset_failed_transfer_if_idle(quitting);
                self.ensure_device_idle()?;
                let entry = self
                    .device
                    .session
                    .catalog
                    .iter()
                    .find(|v| v.file_id == file_id)
                    .cloned()
                    .ok_or("设备上没有这条录音")?;
                if self.workspace().is_bean_file_purged(file_id) {
                    self.commit(|w| {
                        w.clear_purged_bean_file_id(file_id);
                        Ok(())
                    })?;
                }
                let frame = self
                    .device
                    .session
                    .begin_offline_pull(file_id, entry.duration_ms);
                self.device.outbound.push(frame);
            }
            HostIntent::DeviceDownloadAll => {
                if !self.device.is_connected() {
                    return Err("请先连接录音豆".into());
                }
                let quitting = self.is_quitting();
                self.device.reset_failed_transfer_if_idle(quitting);
                self.ensure_device_idle()?;
                self.device.auto_pull_attempted.clear();
                if self.maybe_start_auto_offline_pull() {
                    self.notice = Some("已开始取回录音豆离线文件".into());
                } else {
                    self.notice = Some("没有待取回的离线录音文件".into());
                }
            }
            HostIntent::DeviceStart => {
                self.start_device_recording(now)?;
            }
            HostIntent::DeviceStop => {
                self.stop_device_recording();
            }
        }
        Ok(())
    }

}

pub(crate) fn source_ref(record: &str, segment: &str) -> Result<SourceRef, String> {
    Ok(SourceRef {
        record_id: record.into(),
        segment_id: SegmentId::parse_citation(segment).ok_or("原文片段标识无效")?,
    })
}

pub(crate) fn search_scope(scope: &str, id: Option<String>) -> Result<SearchScope, String> {
    match scope {
        "all" => Ok(SearchScope::All),
        "record" => Ok(SearchScope::Record(id.ok_or("先选择一条记录")?)),
        _ => Err("无效的问答范围".into()),
    }
}
