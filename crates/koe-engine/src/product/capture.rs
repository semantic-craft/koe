use super::*;

/// Factual outcome for one expected native source. No asset means no fabricated silence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CaptureLaneRecord {
    /// Stable lane name: microphone or system.
    pub lane: String,
    /// Owned immutable WAV identity, absent when no samples were captured.
    pub asset_id: Option<String>,
    /// Confirmed native PCM sample rate, absent if startup failed.
    pub sample_rate: Option<u32>,
    /// Actual accepted audio duration, not a shared session timeline.
    pub duration_ms: u64,
    /// Explicit partial-result reason; survives reopening the record.
    pub interruption: Option<String>,
    /// Sparse common-clock mapping; empty for older untimed recordings.
    pub timeline: Vec<CaptureSpan>,
}
impl ProductRecord {
    /// Validates restored capture outcomes before they enter the product workspace.
    pub fn restore_capture_lanes(
        &mut self,
        lanes: Vec<CaptureLaneRecord>,
    ) -> Result<(), ProductError> {
        let mut names = BTreeSet::new();
        for l in &lanes {
            super::capture_timeline::validate_timeline(
                &l.timeline,
                l.sample_rate,
                l.duration_ms,
                l.asset_id.is_some(),
            )?;
            let expected = match l.lane.as_str() {
                "microphone" => self.aggregate.recording_id.clone(),
                "system" => format!("{}-system", self.aggregate.recording_id),
                _ => return Err(ProductError::InvalidEvidence),
            };
            if !names.insert(&l.lane)
                || l.asset_id.as_ref().is_some_and(|id| *id != expected)
                || l.sample_rate.is_some_and(|r| !(8000..=96000).contains(&r))
                || (l.asset_id.is_some() && l.sample_rate.is_none())
                || (l.asset_id.is_none() && (l.duration_ms != 0 || l.interruption.is_none()))
                || l.interruption
                    .as_ref()
                    .is_some_and(|s| s.trim().is_empty() || s.chars().count() > 500)
            {
                return Err(ProductError::InvalidEvidence);
            }
        }
        self.capture_lanes = lanes;
        Ok(())
    }
}
impl ProductWorkspace {
    /// Attaches durable per-lane outcomes within the same transaction as record creation.
    pub fn set_capture_lanes(
        &mut self,
        id: &str,
        lanes: Vec<CaptureLaneRecord>,
    ) -> Result<(), ProductError> {
        self.records
            .get_mut(id)
            .ok_or(ProductError::UnknownRecord)?
            .restore_capture_lanes(lanes)?;
        self.changed();
        Ok(())
    }
}
