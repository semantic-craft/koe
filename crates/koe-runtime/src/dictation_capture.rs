use super::*;
use crate::speech::DictationSource;
use koe_client_services::capture_asset::CaptureAsset;

pub(super) struct DictationCapture {
    id: String,
    created_at: u64,
    asset: CaptureAsset,
    sealing: bool,
}

impl KoeRuntime {
    pub(super) fn capture_standby_dictation(&mut self, samples: &[i16]) {
        if self.companion.standby_stream_owned && self.dictation_active(DictationSource::Standby) {
            if let Err(error) = self.append_standby_dictation(samples) {
                self.error = Some(error);
            }
        }
    }

    fn append_standby_dictation(&mut self, samples: &[i16]) -> Result<(), String> {
        self.retry_standby_dictation_save()?;
        if self.dictation_capture.is_none() {
            let created_at = self.last_now_sec;
            let id = format!("dictation-{created_at}-{}", self.workspace().revision() + 1);
            let asset = CaptureAsset::create(&self.root, &id, 16_000)?;
            self.dictation_capture = Some(DictationCapture {
                id,
                created_at,
                asset,
                sealing: false,
            });
        }
        let capture = self.dictation_capture.as_mut().unwrap();
        capture.asset.append(samples)?;
        let id = capture.id.clone();
        let created_at = capture.created_at;
        let seal = capture.asset.duration_ms() >= crate::all_day::SEGMENT_MS;
        if self.workspace().record(&id).is_none() {
            self.commit(|w| insert_dictation_record(w, &id, created_at))?;
        }
        let bytes: Vec<u8> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
        self.feed_speech(&id, &bytes, Some(DictationSource::Standby))?;
        if seal {
            self.finish_standby_dictation()?;
        }
        Ok(())
    }

    pub(super) fn retry_standby_dictation_save(&mut self) -> Result<(), String> {
        if self
            .dictation_capture
            .as_ref()
            .is_some_and(|capture| capture.sealing)
        {
            self.finish_standby_dictation()?;
        }
        Ok(())
    }

    pub(super) fn finish_standby_dictation(&mut self) -> Result<(), String> {
        let Some(mut capture) = self.dictation_capture.take() else {
            return Ok(());
        };
        capture.sealing = true;
        let result = (|| {
            if capture.asset.is_empty() {
                return capture.asset.discard();
            }
            capture.asset.publish()?;
            self.commit(|w| {
                insert_dictation_record(w, &capture.id, capture.created_at)?;
                w.finish_capture(&capture.id, capture.asset.duration_ms(), &[])
            })?;
            capture.asset.release_staging();
            self.finish_speech(&capture.id);
            self.capture_saved(&capture.id);
            self.poll_captures();
            Ok(())
        })();
        if let Err(error) = &result {
            self.dictation_capture = Some(capture);
            self.drain_error = Some(error.clone());
        }
        result
    }
}

fn insert_dictation_record(
    workspace: &mut ProductWorkspace,
    id: &str,
    created_at: u64,
) -> Result<(), ProductError> {
    workspace.insert_record(
        id.into(),
        "录音豆语音输入".into(),
        RecordOrigin::Bean,
        0,
        created_at,
        0,
    )?;
    workspace.set_record_mode(id, RecordMode::Dictation)
}
