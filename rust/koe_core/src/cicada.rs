//! Cicada synchronous bilingual interpreting queue, bounded rolling minutes budget
//! (`120` calls/hour, `200` chars or `30` s trigger), and `30` s silence auto-stop reducer.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

use crate::domain::{AiProviderCommand, SegmentId, UtteranceSpine};

/// Maximum rolling LLM minutes calls permitted per sliding 1-hour window (`wquguru/cicada`).
pub const CICADA_MAX_CALLS_PER_HOUR: u32 = 120;

/// Minimum accumulated untranslated/unmerged character count that triggers a rolling pass.
pub const CICADA_ROLLING_CHAR_THRESHOLD: usize = 200;

/// Minimum elapsed seconds between rolling summary ticks when below the character threshold.
pub const CICADA_ROLLING_INTERVAL_SEC: u64 = 30;

/// Consecutive microphone silence duration in milliseconds before auto-stopping live interpreting.
pub const CICADA_SILENCE_AUTO_STOP_MS: u64 = 30_000;

/// Returns all finalized [`SegmentId`]s in `spine` that do not yet have a translation
/// matching `target_language`.
///
/// # Examples
///
/// ```
/// use koe_core::cicada::pending_translation_segments;
/// use koe_core::domain::UtteranceSpine;
///
/// let mut spine = UtteranceSpine::new("cicada-1");
/// let s1 = spine.append_segment("你好", 0, 500, "zh", "qwen").unwrap();
/// let s2 = spine.append_segment("世界", 500, 1000, "zh", "qwen").unwrap();
/// spine.set_translation(s1, "Hello", "en");
///
/// assert_eq!(pending_translation_segments(&spine, "en"), vec![s2]);
/// ```
#[must_use]
pub fn pending_translation_segments(
    spine: &UtteranceSpine,
    target_language: &str,
) -> Vec<SegmentId> {
    let target = target_language.trim();
    if target.is_empty() {
        return Vec::new();
    }
    spine
        .segments()
        .iter()
        .filter(|seg| {
            seg.is_final
                && (seg.translation.is_none()
                    || seg.target_language.as_deref() != Some(target))
        })
        .map(|seg| seg.id)
        .collect()
}

/// Pure state for the Cicada live bilingual interpreting and rolling minutes module.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CicadaState {
    /// Target translation language code (such as `"en"` or `"zh"`).
    pub target_language: String,
    /// Number of rolling summary calls issued in the current hour window.
    pub calls_this_hour: u32,
    /// Continuous silence duration accumulated in milliseconds.
    pub silence_elapsed_ms: u64,
    /// Whether live interpreting has been auto-stopped due to silence.
    pub auto_stopped: bool,
}

impl Default for CicadaState {
    fn default() -> Self {
        Self {
            target_language: "en".to_string(),
            calls_this_hour: 0,
            silence_elapsed_ms: 0,
            auto_stopped: false,
        }
    }
}

/// Input events for [`CicadaReducer`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CicadaEvent {
    /// Spine updated; schedule any pending segment translations.
    SyncTranslations,
    /// Advance silence timer by `elapsed_ms` (`speech_detected == true` resets silence to `0`).
    OnAudioActivity {
        /// Elapsed milliseconds since last audio activity check.
        elapsed_ms: u64,
        /// Whether voice activity was detected in this window.
        speech_detected: bool,
    },
}

/// Pure output from [`CicadaReducer::reduce`].
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CicadaOutcome {
    /// Outbound AI provider commands to execute.
    pub commands: Vec<AiProviderCommand>,
    /// `true` when silence reached [`CICADA_SILENCE_AUTO_STOP_MS`] during this step.
    pub triggered_auto_stop: bool,
}

/// Pure reducer contract for the Cicada synchronous interpreting subsystem.
pub trait CicadaReducer {
    /// Applies `event` to `state` against `spine` without side effects.
    fn reduce(
        state: &mut CicadaState,
        spine: &UtteranceSpine,
        event: CicadaEvent,
    ) -> CicadaOutcome;
}

impl CicadaReducer for CicadaState {
    fn reduce(
        state: &mut CicadaState,
        spine: &UtteranceSpine,
        event: CicadaEvent,
    ) -> CicadaOutcome {
        match event {
            CicadaEvent::SyncTranslations => {
                let pending = pending_translation_segments(spine, &state.target_language);
                if pending.is_empty() {
                    return CicadaOutcome::default();
                }
                CicadaOutcome {
                    commands: vec![AiProviderCommand::TranslateSegments {
                        session_id: spine.session_id().to_string(),
                        target_language: state.target_language.clone(),
                        segments: pending,
                    }],
                    triggered_auto_stop: false,
                }
            }
            CicadaEvent::OnAudioActivity {
                elapsed_ms,
                speech_detected,
            } => {
                if speech_detected {
                    state.silence_elapsed_ms = 0;
                    state.auto_stopped = false;
                    return CicadaOutcome::default();
                }
                state.silence_elapsed_ms = state.silence_elapsed_ms.saturating_add(elapsed_ms);
                if !state.auto_stopped && state.silence_elapsed_ms >= CICADA_SILENCE_AUTO_STOP_MS {
                    state.auto_stopped = true;
                    return CicadaOutcome {
                        commands: Vec::new(),
                        triggered_auto_stop: true,
                    };
                }
                CicadaOutcome::default()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pending_translation_and_silence_auto_stop_follow_cicada_thresholds() {
        let mut spine = UtteranceSpine::new("cicada-test");
        let s1 = spine.append_segment("第一句", 0, 1_000, "zh", "qwen").unwrap();
        let s2 = spine.append_segment("第二句", 1_000, 2_000, "zh", "qwen").unwrap();
        spine.set_translation(s1, "First sentence", "en");

        let mut state = CicadaState::default();
        let out = CicadaState::reduce(&mut state, &spine, CicadaEvent::SyncTranslations);
        assert_eq!(
            out.commands,
            vec![AiProviderCommand::TranslateSegments {
                session_id: "cicada-test".to_string(),
                target_language: "en".to_string(),
                segments: vec![s2],
            }]
        );

        let step1 = CicadaState::reduce(
            &mut state,
            &spine,
            CicadaEvent::OnAudioActivity {
                elapsed_ms: 20_000,
                speech_detected: false,
            },
        );
        assert!(!step1.triggered_auto_stop);

        let step2 = CicadaState::reduce(
            &mut state,
            &spine,
            CicadaEvent::OnAudioActivity {
                elapsed_ms: 10_000,
                speech_detected: false,
            },
        );
        assert!(step2.triggered_auto_stop);
        assert!(state.auto_stopped);
    }
}
