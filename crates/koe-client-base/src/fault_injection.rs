//! Zero-production-overhead, thread-local pure-Rust filesystem fault-injection seam.
//!
//! When no [`FsFaultGuard`] is active anywhere in the process, [`check`] performs
//! a single relaxed atomic load and returns immediately without touching thread-local
//! storage. Active faults are scoped to the installing thread and automatically
//! disarmed when their [`FsFaultGuard`] drops.

use std::cell::RefCell;
use std::io;
use std::marker::PhantomData;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

static ACTIVE_GUARDS: AtomicUsize = AtomicUsize::new(0);
static NEXT_GUARD_ID: AtomicU64 = AtomicU64::new(1);

/// Named persistence boundary where deterministic I/O faults can be injected.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FsFaultPoint {
    /// Before writing bytes into an atomic temporary file.
    AtomicWrite,
    /// Before `sync_all` on an atomic temporary file.
    AtomicSync,
    /// Before renaming an atomic temporary file over its target path.
    AtomicRename,
    /// During directory `sync_all` after atomic rename in `ProductStore::commit`.
    StoreDirSync,
    /// After writing PCM payload bytes but before checkpointing WAV header in `CaptureAsset::append`.
    CaptureAssetAppend,
    /// Before sealing/publishing a capture asset in `CaptureAsset::publish`.
    CaptureAssetPublish,
}

struct ArmedFault {
    id: u64,
    point: FsFaultPoint,
    remaining_skips: usize,
    fired: bool,
    message: String,
}

thread_local! {
    static THREAD_FAULTS: RefCell<Vec<ArmedFault>> = const { RefCell::new(Vec::new()) };
}

/// RAII guard that keeps a thread-local fault armed until dropped.
#[must_use = "drop immediately disarms the injected filesystem fault"]
pub struct FsFaultGuard {
    id: u64,
    armed: bool,
    _not_send: PhantomData<*const ()>,
}

impl Drop for FsFaultGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let _ = THREAD_FAULTS.try_with(|cell| {
            if let Ok(mut faults) = cell.try_borrow_mut() {
                faults.retain(|entry| entry.id != self.id);
            }
        });
        ACTIVE_GUARDS.fetch_sub(1, Ordering::Release);
    }
}

/// Arms a one-shot thread-local fault at `point` after skipping `skip_hits` occurrences.
pub fn arm_fs_fault(
    point: FsFaultPoint,
    skip_hits: usize,
    message: impl Into<String>,
) -> FsFaultGuard {
    let id = NEXT_GUARD_ID.fetch_add(1, Ordering::Relaxed);
    let message = message.into();
    let inserted = THREAD_FAULTS
        .try_with(|cell| {
            if let Ok(mut faults) = cell.try_borrow_mut() {
                faults.push(ArmedFault {
                    id,
                    point,
                    remaining_skips: skip_hits,
                    fired: false,
                    message,
                });
                true
            } else {
                false
            }
        })
        .unwrap_or(false);
    if inserted {
        ACTIVE_GUARDS.fetch_add(1, Ordering::AcqRel);
    }
    FsFaultGuard {
        id,
        armed: inserted,
        _not_send: PhantomData,
    }
}

/// Checks whether the current thread has an armed fault for `point`.
#[inline]
pub fn check(point: FsFaultPoint) -> io::Result<()> {
    if ACTIVE_GUARDS.load(Ordering::Acquire) == 0 {
        return Ok(());
    }
    check_slow(point)
}

#[cold]
fn check_slow(point: FsFaultPoint) -> io::Result<()> {
    let triggered = THREAD_FAULTS
        .try_with(|cell| {
            let Ok(mut faults) = cell.try_borrow_mut() else {
                return None;
            };
            for entry in faults.iter_mut() {
                if entry.point != point || entry.fired {
                    continue;
                }
                if entry.remaining_skips > 0 {
                    entry.remaining_skips -= 1;
                    return None;
                }
                entry.fired = true;
                return Some(entry.message.clone());
            }
            None
        })
        .unwrap_or(None);

    match triggered {
        Some(message) => Err(io::Error::other(message)),
        None => Ok(()),
    }
}
