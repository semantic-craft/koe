use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

pub(super) const MAX_PCM_BYTES: usize = 2 * 1024 * 1024;
pub(super) const MAX_MESSAGE_BYTES: usize = 64 * 1024;
const DRAIN_PCM_BYTES: usize = 256 * 1024;

#[derive(Clone, Copy, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Readiness {
    Preparing,
    Ready,
    #[default]
    Unavailable,
}

#[derive(Serialize)]
#[serde(
    tag = "kind",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub(super) enum Effect {
    Start {
        operation_id: u64,
        locale: &'static str,
    },
    Audio {
        operation_id: u64,
        pcm16: Vec<i16>,
    },
    Finish {
        operation_id: u64,
    },
    Cancel {
        operation_id: u64,
    },
}
impl Effect {
    fn pcm_bytes(&self) -> usize {
        match self {
            Self::Audio { pcm16, .. } => pcm16.len() * 2,
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
}

pub(super) struct LocalAsr {
    pub state: Readiness,
    pub message: String,
    effects: VecDeque<Effect>,
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
        self.effects.push_back(Effect::Start {
            operation_id,
            locale: "zh-CN",
        });
    }
    pub fn audio(&mut self, operation_id: u64, bytes: &[u8]) -> Result<(), String> {
        if self.pcm_bytes.saturating_add(bytes.len()) > MAX_PCM_BYTES {
            return Err("本机识别音频队列已满，原始录音仍会保留".into());
        }
        for bytes in bytes.chunks(64 * 1024) {
            let pcm16 = bytes
                .as_chunks::<2>()
                .0
                .iter()
                .copied()
                .map(i16::from_le_bytes)
                .collect();
            self.effects.push_back(Effect::Audio {
                operation_id,
                pcm16,
            });
        }
        self.pcm_bytes += bytes.len();
        Ok(())
    }
    pub fn finish(&mut self, operation_id: u64) {
        self.effects.push_back(Effect::Finish { operation_id });
    }
    pub fn complete(&mut self, operation_id: u64) {
        self.effects
            .retain(|effect| effect.operation_id() != operation_id);
        self.pcm_bytes = self.effects.iter().map(Effect::pcm_bytes).sum();
    }
    pub fn cancel(&mut self, operation_id: u64) {
        self.complete(operation_id);
        self.effects.push_back(Effect::Cancel { operation_id });
    }
    pub fn drain(&mut self) -> String {
        let mut batch = Vec::new();
        let mut pcm_bytes = 0;
        while let Some(effect) = self.effects.front() {
            let bytes = effect.pcm_bytes();
            if pcm_bytes + bytes > DRAIN_PCM_BYTES {
                break;
            }
            pcm_bytes += bytes;
            batch.push(self.effects.pop_front().unwrap());
        }
        self.pcm_bytes -= pcm_bytes;
        serde_json::to_string(&batch).expect("local effects are serializable")
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
