//! Network-free foundational primitives for Koe (`hash`, `prng`, `atomic_fs`).
//!
//! Aligned with `metasequoiaime/msime`'s `crates/client-base`: this crate sits at the
//! bottom of the dependency graph and never depends on network stacks, protocol state
//! machines, or UI toolkits.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

pub mod atomic_fs;
pub mod hash;
pub mod prng;

pub use atomic_fs::{write_atomic, WorkspaceLockGuard};
pub use hash::{hkdf_sha256, hmac_sha256, is_valid_sha256_hex, sha256, sha256_hex};
pub use prng::{fnv1a64, fnv1a64_hex, to_hex_upper, SplitMix64};
