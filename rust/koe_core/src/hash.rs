//! RFC 6234 SHA-256, RFC 2104 HMAC-SHA256, and RFC 5869 HKDF-SHA256 key derivation.
//!
//! # Examples
//!
//! ```
//! use koe_core::hash::{hkdf_sha256, hmac_sha256, sha256};
//!
//! let digest = sha256(b"abc");
//! assert_eq!(digest[0..4], [0xba, 0x78, 0x16, 0xbf]);
//! let mac = hmac_sha256(b"key", b"msg");
//! assert_eq!(mac.len(), 32);
//! let derived = hkdf_sha256(&[1u8; 32], &[1, 2, 3], &[1, 2, 3], 32);
//! assert_eq!(derived.len(), 32);
//! ```

const SHA256_K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// Computes the 32-byte FIPS 180-4 / RFC 6234 SHA-256 digest of `data`.
///
/// # Examples
///
/// ```
/// use koe_core::hash::sha256;
///
/// assert_eq!(sha256(b"")[0..4], [0xe3, 0xb0, 0xc4, 0x42]);
/// ```
#[must_use]
pub fn sha256(data: &[u8]) -> [u8; 32] {
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];
    let bit_len = (data.len() as u64) * 8;
    let rem = data.len() % 64;
    let pad_len = if rem < 56 { 56 - rem } else { 120 - rem };
    let mut msg = Vec::with_capacity(data.len() + pad_len + 8);
    msg.extend_from_slice(data);
    msg.push(0x80);
    msg.resize(data.len() + pad_len, 0);
    msg.extend_from_slice(&bit_len.to_be_bytes());

    for chunk in msg.as_chunks::<64>().0 {
        let mut w = [0u32; 64];
        for (i, &word) in chunk.as_chunks::<4>().0.iter().enumerate() {
            w[i] = u32::from_be_bytes(word);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let temp1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(SHA256_K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }
        for (st, add) in h.iter_mut().zip([a, b, c, d, e, f, g, hh]) {
            *st = st.wrapping_add(add);
        }
    }
    let mut out = [0u8; 32];
    for (i, word) in h.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&word.to_be_bytes());
    }
    out
}

/// Computes RFC 2104 HMAC-SHA256 (`key`, `message`).
#[must_use]
pub fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    let mut k_block = [0u8; 64];
    if key.len() > 64 {
        let hashed = sha256(key);
        k_block[..32].copy_from_slice(&hashed);
    } else {
        k_block[..key.len()].copy_from_slice(key);
    }
    let mut inner = Vec::with_capacity(64 + message.len());
    for &b in &k_block {
        inner.push(b ^ 0x36);
    }
    inner.extend_from_slice(message);
    let inner_hash = sha256(&inner);

    let mut outer = [0u8; 96];
    for (i, &b) in k_block.iter().enumerate() {
        outer[i] = b ^ 0x5C;
    }
    outer[64..96].copy_from_slice(&inner_hash);
    sha256(&outer)
}

/// Derives `length` bytes via RFC 5869 HKDF-SHA256 (`extract` + `expand`).
#[must_use]
pub fn hkdf_sha256(ikm: &[u8], salt: &[u8], info: &[u8], length: usize) -> Vec<u8> {
    let prk = hmac_sha256(salt, ikm);
    let mut out = Vec::with_capacity(length);
    let mut t = Vec::new();
    let mut counter = 1u8;
    while out.len() < length {
        let mut input = Vec::with_capacity(t.len() + info.len() + 1);
        input.extend_from_slice(&t);
        input.extend_from_slice(info);
        input.push(counter);
        let block = hmac_sha256(&prk, &input);
        t = block.to_vec();
        let take = (length - out.len()).min(block.len());
        out.extend_from_slice(&block[..take]);
        counter = counter.wrapping_add(1);
    }
    out
}
