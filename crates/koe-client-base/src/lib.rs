//! Atomic file persistence and advisory workspace lockfile primitives (`atomic_fs`).
//!
//! Aligned with `metasequoiaime/msime`'s `crates/client-base`: this crate provides
//! local filesystem persistence primitives and never depends on network stacks,
//! protocol state machines, or UI toolkits.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

pub mod atomic_fs;

pub use atomic_fs::{write_atomic, WorkspaceLockGuard};
