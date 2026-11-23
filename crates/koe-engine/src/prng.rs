//! Deterministic `SplitMix64` pseudo-random generator, `FNV-1a` 64-bit digest,
//! and uppercase hexadecimal formatting used for cross-language A/B parity checks.
//!
//! # Examples
//!
//! ```
//! use koe_engine::prng::{fnv1a64_hex, to_hex_upper, SplitMix64};
//!
//! let mut rng = SplitMix64::new(0);
//! let first = rng.next_byte();
//! assert_eq!(first, 0xAF);
//! assert_eq!(to_hex_upper(&[0x08, 0xEE]), "08EE");
//! assert_eq!(fnv1a64_hex(b"OggS").len(), 16);
//! ```

/// Deterministic `SplitMix64` generator matching the 64-bit Dart reference.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SplitMix64 {
    state: u64,
}

impl SplitMix64 {
    /// Creates a new `SplitMix64` generator seeded with `seed`.
    ///
    /// # Examples
    ///
    /// ```
    /// use koe_engine::prng::SplitMix64;
    ///
    /// let mut rng = SplitMix64::new(42);
    /// assert_ne!(rng.next_u64(), 0);
    /// ```
    #[must_use]
    pub const fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    /// Advances the state and returns the next 64-bit unsigned integer.
    pub fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Returns the lowest 8 bits of the next `SplitMix64` word.
    pub fn next_byte(&mut self) -> u8 {
        (self.next_u64() & 0xFF) as u8
    }

    /// Generates `len` deterministic pseudo-random bytes.
    ///
    /// # Examples
    ///
    /// ```
    /// use koe_engine::prng::SplitMix64;
    ///
    /// let mut rng = SplitMix64::new(7);
    /// let bytes = rng.next_bytes(16);
    /// assert_eq!(bytes.len(), 16);
    /// ```
    pub fn next_bytes(&mut self, len: usize) -> Vec<u8> {
        let mut out = Vec::with_capacity(len);
        for _ in 0..len {
            out.push(self.next_byte());
        }
        out
    }
}

/// Computes the 64-bit `FNV-1a` hash of `bytes`.
///
/// # Examples
///
/// ```
/// use koe_engine::prng::fnv1a64;
///
/// assert_eq!(fnv1a64(&[]), 0xCBF2_9CE4_8422_2325);
/// ```
#[must_use]
pub fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xCBF2_9CE4_8422_2325;
    for &b in bytes {
        hash ^= u64::from(b);
        hash = hash.wrapping_mul(0x0000_0100_0000_01B3);
    }
    hash
}

/// Formats the 64-bit `FNV-1a` digest of `bytes` as a 16-character uppercase hex string.
#[must_use]
pub fn fnv1a64_hex(bytes: &[u8]) -> String {
    let hash = fnv1a64(bytes);
    let mut out = String::with_capacity(16);
    for shift in (0..16).rev() {
        let nibble = ((hash >> (shift * 4)) & 0xF) as usize;
        out.push(HEX_UPPER[nibble] as char);
    }
    out
}

const HEX_UPPER: &[u8; 16] = b"0123456789ABCDEF";

/// Encodes `bytes` as a contiguous uppercase hexadecimal string.
///
/// # Examples
///
/// ```
/// use koe_engine::prng::to_hex_upper;
///
/// assert_eq!(to_hex_upper(&[0x09, 0xFF, 0x00, 0x1A]), "09FF001A");
/// ```
#[must_use]
pub fn to_hex_upper(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(HEX_UPPER[(b >> 4) as usize] as char);
        out.push(HEX_UPPER[(b & 0x0F) as usize] as char);
    }
    out
}
