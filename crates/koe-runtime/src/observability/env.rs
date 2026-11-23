//! Injectable runtime environment boundaries (clock, RNG, timezone offset) for deterministic replay.

use chrono::{DateTime, FixedOffset, Local, NaiveDate};
use serde::{Deserialize, Serialize};
use std::{
    fs::File,
    io::Read,
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex, PoisonError,
    },
    time::{SystemTime, UNIX_EPOCH},
};

#[derive(Debug)]
struct SplitMix64(u64);

impl SplitMix64 {
    const fn new(seed: u64) -> Self {
        Self(seed)
    }

    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    fn fill_bytes(&mut self, buf: &mut [u8]) {
        for chunk in buf.chunks_mut(8) {
            let bytes = self.next_u64().to_le_bytes();
            chunk.copy_from_slice(&bytes[..chunk.len()]);
        }
    }
}

#[derive(Debug)]
enum ClockKind {
    System,
    Deterministic(AtomicU64),
}

/// Wall-clock provider injected at the [`crate::KoeRuntime`] boundary.
#[derive(Debug)]
pub struct RuntimeClock(ClockKind);

impl RuntimeClock {
    /// Production wall-clock provider backed by `SystemTime::now()`.
    #[must_use]
    pub const fn system() -> Self {
        Self(ClockKind::System)
    }

    /// Deterministic clock seeded at `initial_now_sec` Unix epoch seconds.
    #[must_use]
    pub const fn deterministic(initial_now_sec: u64) -> Self {
        Self(ClockKind::Deterministic(AtomicU64::new(
            initial_now_sec.saturating_mul(1_000_000_000),
        )))
    }

    /// Returns current Unix timestamp in nanoseconds (advancing deterministically when injected).
    pub fn now_nanos(&self) -> Result<u128, String> {
        match &self.0 {
            ClockKind::System => SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .map_err(|e| e.to_string()),
            ClockKind::Deterministic(counter) => {
                Ok(u128::from(counter.fetch_add(1, Ordering::Relaxed)))
            }
        }
    }

    /// Returns current Unix timestamp in seconds.
    #[must_use]
    pub fn now_sec(&self) -> u64 {
        match &self.0 {
            ClockKind::System => SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |d| d.as_secs()),
            ClockKind::Deterministic(counter) => counter.load(Ordering::Relaxed) / 1_000_000_000,
        }
    }
}

#[derive(Debug)]
enum RngKind {
    System,
    Deterministic {
        seed: u64,
        state: Mutex<SplitMix64>,
    },
}

/// Randomness provider injected at the [`crate::KoeRuntime`] boundary.
#[derive(Debug)]
pub struct RuntimeRng(RngKind);

impl RuntimeRng {
    /// Production OS entropy provider reading `/dev/urandom`.
    #[must_use]
    pub const fn system() -> Self {
        Self(RngKind::System)
    }

    /// Deterministic seedable PRNG.
    #[must_use]
    pub fn deterministic(seed: u64) -> Self {
        Self(RngKind::Deterministic {
            seed,
            state: Mutex::new(SplitMix64::new(seed)),
        })
    }

    /// Fills `buf` with random bytes from OS entropy or the seeded PRNG.
    pub fn fill_bytes(&self, buf: &mut [u8]) -> Result<(), String> {
        match &self.0 {
            RngKind::System => File::open("/dev/urandom")
                .and_then(|mut file| file.read_exact(buf))
                .map_err(|_| "无法生成设备连接密钥".to_string()),
            RngKind::Deterministic { state, .. } => {
                let mut prng = state.lock().unwrap_or_else(PoisonError::into_inner);
                prng.fill_bytes(buf);
                Ok(())
            }
        }
    }

    /// Returns the deterministic seed if seeded, or `None` when backed by OS entropy.
    #[must_use]
    pub const fn seed(&self) -> Option<u64> {
        match &self.0 {
            RngKind::System => None,
            RngKind::Deterministic { seed, .. } => Some(*seed),
        }
    }
}

/// Serializable environment capture attached to exported diagnostics bundles.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeEnvMetadata {
    /// Effective timezone offset east of UTC in seconds (captured on export).
    pub tz_offset_secs: Option<i32>,
    /// Deterministic PRNG seed when the session ran with a seeded RNG (`None` for OS entropy).
    pub rng_seed: Option<u64>,
    /// Non-secret nonce seed used for local recording session IDs so bundles replay deterministically.
    pub nonce_seed: u64,
    /// First observed Unix epoch timestamp in seconds for the session.
    pub initial_now_sec: u64,
}

impl RuntimeEnvMetadata {
    /// Seed used when constructing an isolated replay runtime.
    #[must_use]
    pub const fn replay_seed(&self) -> u64 {
        match self.rng_seed {
            Some(seed) => seed,
            None => self.nonce_seed,
        }
    }
}

/// Execution boundary injected into [`crate::KoeRuntime`].
#[derive(Debug)]
pub struct RuntimeEnv {
    clock: RuntimeClock,
    rng: RuntimeRng,
    nonce_seed: u64,
    nonce_prng: Mutex<SplitMix64>,
    tz_offset_secs: Option<i32>,
    initial_now_sec: AtomicU64,
    replay_mode: bool,
}

impl RuntimeEnv {
    /// Production environment using OS wall-clock, OS `/dev/urandom`, and local system timezone.
    #[must_use]
    pub fn system() -> Self {
        let clock = RuntimeClock::system();
        let initial_now_sec = clock.now_sec();
        let raw_nanos = clock.now_nanos().unwrap_or(0);
        let nonce_seed = (raw_nanos as u64)
            ^ ((raw_nanos >> 64) as u64).rotate_left(17)
            ^ u64::from(std::process::id()).rotate_left(32);
        Self {
            clock,
            rng: RuntimeRng::system(),
            nonce_seed,
            nonce_prng: Mutex::new(SplitMix64::new(nonce_seed)),
            tz_offset_secs: None,
            initial_now_sec: AtomicU64::new(initial_now_sec),
            replay_mode: false,
        }
    }

    /// Deterministic environment for replay and regression tests.
    #[must_use]
    pub fn deterministic(initial_now_sec: u64, rng_seed: u64, tz_offset_secs: Option<i32>) -> Self {
        Self {
            clock: RuntimeClock::deterministic(initial_now_sec),
            rng: RuntimeRng::deterministic(rng_seed),
            nonce_seed: rng_seed,
            nonce_prng: Mutex::new(SplitMix64::new(rng_seed)),
            tz_offset_secs,
            initial_now_sec: AtomicU64::new(initial_now_sec),
            replay_mode: false,
        }
    }

    /// Overrides the timezone offset east of UTC in seconds (`None` uses `chrono::Local`).
    #[must_use]
    pub const fn with_tz_offset(mut self, tz_offset_secs: Option<i32>) -> Self {
        self.tz_offset_secs = tz_offset_secs;
        self
    }

    pub(crate) fn for_replay(meta: &RuntimeEnvMetadata) -> Self {
        let rng_seed = meta.replay_seed();
        Self {
            clock: RuntimeClock::deterministic(meta.initial_now_sec),
            rng: RuntimeRng::deterministic(rng_seed),
            nonce_seed: meta.nonce_seed,
            nonce_prng: Mutex::new(SplitMix64::new(meta.nonce_seed)),
            tz_offset_secs: meta.tz_offset_secs,
            initial_now_sec: AtomicU64::new(meta.initial_now_sec),
            replay_mode: true,
        }
    }

    pub(crate) const fn is_replay_mode(&self) -> bool {
        self.replay_mode
    }

    /// Returns the injected wall-clock provider.
    #[must_use]
    pub const fn clock(&self) -> &RuntimeClock {
        &self.clock
    }

    /// Returns the injected RNG provider.
    #[must_use]
    pub const fn rng(&self) -> &RuntimeRng {
        &self.rng
    }

    /// Returns the configured timezone offset in seconds (`None` means `chrono::Local`).
    #[must_use]
    pub const fn tz_offset_secs(&self) -> Option<i32> {
        self.tz_offset_secs
    }

    /// Generates the next monotonic/deterministic local session nonce.
    #[must_use]
    pub fn next_nonce(&self) -> u64 {
        let mut prng = self
            .nonce_prng
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        prng.next_u64()
    }

    /// Fills `buf` from the configured cryptographic/deterministic RNG.
    pub fn fill_random(&self, buf: &mut [u8]) -> Result<(), String> {
        self.rng.fill_bytes(buf)
    }

    /// Records the first non-zero Unix epoch timestamp observed at a runtime boundary.
    pub(crate) fn note_now_sec(&self, now: u64) {
        if now > 0 {
            let _ = self.initial_now_sec.compare_exchange(
                0,
                now,
                Ordering::AcqRel,
                Ordering::Acquire,
            );
        }
    }

    /// Captures replayable metadata without exposing any cryptographic material.
    #[must_use]
    pub fn metadata(&self) -> RuntimeEnvMetadata {
        let effective_tz = self
            .tz_offset_secs
            .or_else(|| Some(Local::now().offset().local_minus_utc()));
        RuntimeEnvMetadata {
            tz_offset_secs: effective_tz,
            rng_seed: self.rng.seed(),
            nonce_seed: self.nonce_seed,
            initial_now_sec: self.initial_now_sec.load(Ordering::Acquire),
        }
    }

    /// Resolves `epoch` to a calendar date honoring `tz_offset_secs`.
    #[must_use]
    pub fn local_date(&self, epoch: u64) -> Option<NaiveDate> {
        local_date_with_offset(epoch, self.tz_offset_secs)
    }
}

/// Resolves a Unix epoch second to a calendar date using `offset_secs` or `chrono::Local`.
#[must_use]
pub fn local_date_with_offset(epoch: u64, offset_secs: Option<i32>) -> Option<NaiveDate> {
    let ts = i64::try_from(epoch).ok()?;
    let utc = DateTime::from_timestamp(ts, 0)?;
    match offset_secs {
        Some(secs) => FixedOffset::east_opt(secs).map(|tz| utc.with_timezone(&tz).date_naive()),
        None => Some(utc.with_timezone(&Local).date_naive()),
    }
}
