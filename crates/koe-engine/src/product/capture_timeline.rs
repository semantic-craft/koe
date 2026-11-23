//! Sparse sample-to-session mapping. Gaps contain no fabricated PCM; overlaps fail closed.
use super::ProductError;

/// One contiguous interval in a lane's immutable WAV, on a shared active-time clock.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CaptureSpan {
    /// Resume generation.
    pub epoch: u64,
    /// Start on the common active-time clock in nanoseconds.
    pub start_ns: u64,
    /// First sample in the immutable lane WAV.
    pub sample_offset: u64,
    /// Number of accepted samples in this contiguous interval.
    pub sample_count: u64,
}
impl CaptureSpan {
    /// Exclusive interval end, or None for invalid rate or arithmetic overflow.
    pub fn end_ns(&self, rate: u32) -> Option<u64> {
        self.start_ns.checked_add(
            self.sample_count
                .checked_mul(1_000_000_000)?
                .checked_div(u64::from(rate))?,
        )
    }
}
/// Bounded metadata and clock horizon, independent of callback frequency.
pub const MAX_CAPTURE_SPANS: usize = 4096;
const MAX_TIME_NS: u64 = 24 * 60 * 60 * 1_000_000_000;
const MAX_GAP_NS: u64 = 10 * 1_000_000_000;

/// Prepares a placement without mutating custody. Commit it only after the PCM append succeeds.
pub fn place_capture_span(
    spans: &[CaptureSpan],
    rate: u32,
    epoch: u64,
    start_ns: u64,
    count: usize,
) -> Result<(CaptureSpan, bool), ProductError> {
    let invalid = || ProductError::InvalidInput("采样时间重叠、间隔过大或时间轴已满".into());
    if !(8000..=96000).contains(&rate) || count == 0 || count > 8192 {
        return Err(invalid());
    }
    let previous = spans.last();
    let end = previous.and_then(|s| s.end_ns(rate)).unwrap_or(0);
    let tolerance = 1_000_000_000u64.div_ceil(u64::from(rate));
    if start_ns > MAX_TIME_NS
        || start_ns.saturating_add(tolerance) < end
        || start_ns.saturating_sub(end) > MAX_GAP_NS
        || previous.is_some_and(|s| epoch < s.epoch)
    {
        return Err(invalid());
    }
    let (span, merge) = match previous {
        Some(prev) if prev.epoch == epoch && start_ns.abs_diff(end) <= tolerance => {
            let mut s = prev.clone();
            s.sample_count = s.sample_count.checked_add(count as u64).ok_or_else(invalid)?;
            (s, true)
        }
        _ => {
            if spans.len() >= MAX_CAPTURE_SPANS {
                return Err(invalid());
            }
            (
                CaptureSpan {
                    epoch,
                    start_ns: start_ns.max(end),
                    sample_offset: previous.map_or(0, |s| s.sample_offset + s.sample_count),
                    sample_count: count as u64,
                },
                false,
            )
        }
    };
    if span.end_ns(rate).is_none_or(|e| e > MAX_TIME_NS) {
        return Err(invalid());
    }
    Ok((span, merge))
}

pub(super) fn validate_timeline(
    spans: &[CaptureSpan],
    rate: Option<u32>,
    duration_ms: u64,
    has_asset: bool,
) -> Result<(), ProductError> {
    if spans.is_empty() {
        return Ok(());
    }
    let rate = rate
        .filter(|r| (8000..=96000).contains(r))
        .ok_or(ProductError::InvalidPersistedState)?;
    if !has_asset || spans.len() > MAX_CAPTURE_SPANS {
        return Err(ProductError::InvalidPersistedState);
    }
    let (mut offset, mut end, mut epoch) = (0u64, 0u64, 0u64);
    for s in spans {
        let next = s.end_ns(rate).ok_or(ProductError::InvalidPersistedState)?;
        if s.sample_offset != offset
            || s.sample_count == 0
            || s.start_ns < end
            || s.start_ns - end > MAX_GAP_NS
            || s.epoch < epoch
            || next > MAX_TIME_NS
        {
            return Err(ProductError::InvalidPersistedState);
        }
        offset = offset
            .checked_add(s.sample_count)
            .ok_or(ProductError::InvalidPersistedState)?;
        end = next;
        epoch = s.epoch;
    }
    if offset.checked_mul(1000).map(|n| n / u64::from(rate)) != Some(duration_ms) {
        return Err(ProductError::InvalidPersistedState);
    }
    Ok(())
}
