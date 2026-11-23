use serde::Deserialize;
use std::collections::VecDeque;

pub(super) const MAX_PCM_BYTES: usize = 2 * 1024 * 1024;
pub(super) const MAX_MESSAGE_BYTES: usize = 64 * 1024;
const DRAIN_PCM_BYTES: usize = 256 * 1024;

#[derive(Clone, Copy, Default, Deserialize, serde::Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Readiness {
    Preparing,
    Ready,
    #[default]
    Unavailable,
}

/// Typed outbound instruction queued for the native Apple speech adapter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LocalAsrEffect {
    /// Start a local recognition session for `operation_id` with BCP-47 `locale`.
    Start {
        /// Runtime-assigned speech operation identifier.
        operation_id: u64,
        /// BCP-47 locale tag (for example `"zh-CN"`).
        locale: &'static str,
    },
    /// Append little-endian PCM16 samples for `operation_id`.
    Audio {
        /// Runtime-assigned speech operation identifier.
        operation_id: u64,
        /// Raw little-endian PCM16 bytes.
        pcm16_le: Vec<u8>,
    },
    /// Finish recognition and flush remaining final transcripts for `operation_id`.
    Finish {
        /// Runtime-assigned speech operation identifier.
        operation_id: u64,
    },
    /// Cancel recognition for `operation_id`.
    Cancel {
        /// Runtime-assigned speech operation identifier.
        operation_id: u64,
    },
}

impl LocalAsrEffect {
    fn pcm_bytes(&self) -> usize {
        match self {
            Self::Audio { pcm16_le, .. } => pcm16_le.len(),
            _ => 0,
        }
    }

    fn operation_id(&self) -> u64 {
        match self {
            Self::Start { operation_id, .. }
            | Self::Audio { operation_id, .. }
            | Self::Finish { operation_id }
            | Self::Cancel { operation_id } => *operation_id,
        }
    }

    fn encode_binary_into(&self, out: &mut Vec<u8>) {
        match self {
            Self::Start {
                operation_id,
                locale,
            } => {
                let bytes = locale.as_bytes();
                let Ok(len) = u32::try_from(bytes.len()) else {
                    return;
                };
                out.push(1);
                out.extend_from_slice(&operation_id.to_le_bytes());
                out.extend_from_slice(&len.to_le_bytes());
                out.extend_from_slice(bytes);
            }
            Self::Audio {
                operation_id,
                pcm16_le,
            } => {
                let Ok(len) = u32::try_from(pcm16_le.len()) else {
                    return;
                };
                out.push(2);
                out.extend_from_slice(&operation_id.to_le_bytes());
                out.extend_from_slice(&len.to_le_bytes());
                out.extend_from_slice(pcm16_le);
            }
            Self::Finish { operation_id } => {
                out.push(3);
                out.extend_from_slice(&operation_id.to_le_bytes());
                out.extend_from_slice(&0u32.to_le_bytes());
            }
            Self::Cancel { operation_id } => {
                out.push(4);
                out.extend_from_slice(&operation_id.to_le_bytes());
                out.extend_from_slice(&0u32.to_le_bytes());
            }
        }
    }
}

pub(crate) struct LocalAsr {
    pub state: Readiness,
    pub message: String,
    effects: VecDeque<LocalAsrEffect>,
    pcm_bytes: usize,
}

impl Default for LocalAsr {
    fn default() -> Self {
        Self {
            state: Readiness::Unavailable,
            message: "当前宿主未提供本机语音识别".into(),
            effects: VecDeque::new(),
            pcm_bytes: 0,
        }
    }
}

impl LocalAsr {
    pub fn start(&mut self, operation_id: u64) {
        self.effects.push_back(LocalAsrEffect::Start {
            operation_id,
            locale: "zh-CN",
        });
    }

    pub fn audio(&mut self, operation_id: u64, bytes: &[u8]) -> Result<(), String> {
        let aligned_len = bytes.len() - (bytes.len() % 2);
        if self.pcm_bytes.saturating_add(aligned_len) > MAX_PCM_BYTES {
            return Err("本机识别音频队列已满，原始录音仍会保留".into());
        }
        for chunk in bytes[..aligned_len].chunks(64 * 1024) {
            self.effects.push_back(LocalAsrEffect::Audio {
                operation_id,
                pcm16_le: chunk.to_vec(),
            });
        }
        self.pcm_bytes += aligned_len;
        Ok(())
    }

    pub fn finish(&mut self, operation_id: u64) {
        self.effects
            .push_back(LocalAsrEffect::Finish { operation_id });
    }

    pub fn complete(&mut self, operation_id: u64) {
        self.effects
            .retain(|effect| effect.operation_id() != operation_id);
        self.pcm_bytes = self
            .effects
            .iter()
            .map(LocalAsrEffect::pcm_bytes)
            .sum();
    }

    pub fn cancel(&mut self, operation_id: u64) {
        self.complete(operation_id);
        self.effects
            .push_back(LocalAsrEffect::Cancel { operation_id });
    }

    pub fn drain_effects(&mut self) -> Vec<LocalAsrEffect> {
        let mut batch = Vec::new();
        let mut pcm_bytes = 0;
        while let Some(effect) = self.effects.front() {
            let bytes = effect.pcm_bytes();
            if pcm_bytes + bytes > DRAIN_PCM_BYTES {
                break;
            }
            if let Some(effect) = self.effects.pop_front() {
                pcm_bytes += bytes;
                batch.push(effect);
            }
        }
        self.pcm_bytes -= pcm_bytes;
        batch
    }

    pub fn drain_binary(&mut self) -> Vec<u8> {
        let batch = self.drain_effects();
        if batch.is_empty() {
            return Vec::new();
        }
        let total_payload: usize = batch
            .iter()
            .map(|effect| match effect {
                LocalAsrEffect::Start { locale, .. } => 13 + locale.len(),
                LocalAsrEffect::Audio { pcm16_le, .. } => 13 + pcm16_le.len(),
                LocalAsrEffect::Finish { .. } | LocalAsrEffect::Cancel { .. } => 13,
            })
            .sum();
        let mut out = Vec::with_capacity(total_payload);
        for effect in &batch {
            effect.encode_binary_into(&mut out);
        }
        out
    }
}

pub(super) enum LocalPhase {
    Active,
    Finishing,
}

pub(super) struct LocalSession {
    pub operation_id: u64,
    pub phase: LocalPhase,
    pub draft: String,
    pub elapsed_ms: u64,
    pub offset_ms: u64,
    pub duration_ms: u64,
}
