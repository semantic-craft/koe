//! Cryptographic primitives for D3200 offline audio sync (`lib/crypto/device_crypto.dart`):
//! RFC 5869 HKDF-SHA256, FIPS 197 AES-128/192/256-CTR with compile-time T-tables,
//! per-file `AesCtrStreamDecrypt` (`sequence * 10` block counter), and `1A07` header parsing.
//!
//! # Examples
//!
//! ```
//! use koe_core::crypto::{AesCtrStreamDecrypt, DeviceCrypto};
//!
//! let key = DeviceCrypto::hkdf_sha256(&[1u8; 32], &[1, 2, 3], &[1, 2, 3], 32);
//! let stream = AesCtrStreamDecrypt::new(&key, &[0u8; 16]).unwrap();
//! let plain = b"hello soundcore work!!";
//! let cipher = stream.decrypt_chunk(plain, 0);
//! assert_eq!(stream.decrypt_chunk(&cipher, 0), plain);
//! ```

use crate::frame::read_u32_le;
use crate::hash;

/// Expected 14-byte UTF-8 magic prefix inside an unwrapped D3200 file key.
pub const FILE_KEY_MAGIC: &[u8; 14] = b"soundcored3200";

const SBOX: [u8; 256] = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
];

const fn xtime(x: u8) -> u8 {
    let hi = (x & 0x80) != 0;
    let sh = x << 1;
    if hi { sh ^ 0x1B } else { sh }
}

const fn build_te0() -> [u32; 256] {
    let mut t = [0u32; 256];
    let mut i = 0usize;
    while i < 256 {
        let s = SBOX[i];
        let s2 = xtime(s);
        let s3 = s2 ^ s;
        t[i] = ((s2 as u32) << 24) | ((s as u32) << 16) | ((s as u32) << 8) | (s3 as u32);
        i += 1;
    }
    t
}

/// Compile-time AES forward T-table (`TE0`), rotated for columns 1..3.
const TE0: [u32; 256] = build_te0();

/// Stateless HKDF-SHA256 and AES-CTR helpers matching `lib/crypto/device_crypto.dart`.
#[derive(Debug, Clone, Copy)]
pub struct DeviceCrypto;

impl DeviceCrypto {
    /// Derives `length` bytes via RFC 5869 HKDF-SHA256 (`extract` + `expand`).
    ///
    /// # Examples
    ///
    /// ```
    /// use koe_core::crypto::DeviceCrypto;
    ///
    /// let k1 = DeviceCrypto::hkdf_sha256(&[7u8; 32], &[1, 2, 3], &[1, 2, 3], 32);
    /// let k2 = DeviceCrypto::hkdf_sha256(&[7u8; 32], &[1, 2, 3], &[1, 2, 3], 32);
    /// assert_eq!(k1, k2);
    /// assert_eq!(k1.len(), 32);
    /// ```
    #[must_use]
    pub fn hkdf_sha256(ikm: &[u8], salt: &[u8], info: &[u8], length: usize) -> Vec<u8> {
        hash::hkdf_sha256(ikm, salt, info, length)
    }

    /// Decrypts (or encrypts) `data` using AES-128/192/256 in CTR mode (`NoPadding`).
    #[must_use]
    pub fn aes_ctr_decrypt(data: &[u8], key: &[u8], iv: &[u8]) -> Option<Vec<u8>> {
        let cipher = AesCipher::new(key)?;
        let mut out = data.to_vec();
        cipher.apply_ctr_in_place(&mut out, iv);
        Some(out)
    }

    /// Unwraps a 46-byte `encrypted_file_key` with `session_key` and `session_nonce`,
    /// verifying the 14-byte `"soundcored3200"` prefix and returning the 32-byte file key.
    #[must_use]
    pub fn unwrap_file_key(
        session_key: &[u8],
        encrypted_file_key: &[u8],
        session_nonce: &[u8],
    ) -> Option<[u8; 32]> {
        if session_key.len() != 32 || session_nonce.len() != 16 {
            return None;
        }
        let plain = Self::aes_ctr_decrypt(encrypted_file_key, session_key, session_nonce)?;
        if plain.len() < 46 || &plain[0..14] != FILE_KEY_MAGIC {
            return None;
        }
        let mut file_key = [0u8; 32];
        file_key.copy_from_slice(&plain[14..46]);
        Some(file_key)
    }
}

/// Pre-expanded AES-128/192/256 block cipher using compile-time `TE0` tables.
#[derive(Debug, Clone)]
pub struct AesCipher {
    rk: [u32; 60],
    rounds: usize,
}

impl AesCipher {
    /// Expands an AES-128 (16 B), AES-192 (24 B), or AES-256 (32 B) key schedule.
    #[must_use]
    pub fn new(key: &[u8]) -> Option<Self> {
        let (nk, rounds) = match key.len() {
            16 => (4, 10),
            24 => (6, 12),
            32 => (8, 14),
            _ => return None,
        };
        let mut rk = [0u32; 60];
        for i in 0..nk {
            rk[i] = u32::from_be_bytes([key[4 * i], key[4 * i + 1], key[4 * i + 2], key[4 * i + 3]]);
        }
        let rcon: [u32; 10] = [
            0x01000000, 0x02000000, 0x04000000, 0x08000000, 0x10000000,
            0x20000000, 0x40000000, 0x80000000, 0x1b000000, 0x36000000,
        ];
        let total_words = 4 * (rounds + 1);
        for i in nk..total_words {
            let mut temp = rk[i - 1];
            if i % nk == 0 {
                temp = Self::sub_word(temp.rotate_left(8)) ^ rcon[i / nk - 1];
            } else if nk > 6 && i % nk == 4 {
                temp = Self::sub_word(temp);
            }
            rk[i] = rk[i - nk] ^ temp;
        }
        Some(Self { rk, rounds })
    }

    const fn sub_word(w: u32) -> u32 {
        ((SBOX[(w >> 24) as usize] as u32) << 24)
            | ((SBOX[((w >> 16) & 0xFF) as usize] as u32) << 16)
            | ((SBOX[((w >> 8) & 0xFF) as usize] as u32) << 8)
            | (SBOX[(w & 0xFF) as usize] as u32)
    }

    /// Encrypts a single 16-byte block in 32-bit registers using `TE0` rotations.
    #[must_use]
    pub fn encrypt_block(&self, input: &[u8; 16]) -> [u8; 16] {
        let mut s0 = u32::from_be_bytes([input[0], input[1], input[2], input[3]]) ^ self.rk[0];
        let mut s1 = u32::from_be_bytes([input[4], input[5], input[6], input[7]]) ^ self.rk[1];
        let mut s2 = u32::from_be_bytes([input[8], input[9], input[10], input[11]]) ^ self.rk[2];
        let mut s3 = u32::from_be_bytes([input[12], input[13], input[14], input[15]]) ^ self.rk[3];

        for r in 1..self.rounds {
            let k = r * 4;
            let t0 = TE0[(s0 >> 24) as usize]
                ^ TE0[((s1 >> 16) & 0xFF) as usize].rotate_right(8)
                ^ TE0[((s2 >> 8) & 0xFF) as usize].rotate_right(16)
                ^ TE0[(s3 & 0xFF) as usize].rotate_right(24)
                ^ self.rk[k];
            let t1 = TE0[(s1 >> 24) as usize]
                ^ TE0[((s2 >> 16) & 0xFF) as usize].rotate_right(8)
                ^ TE0[((s3 >> 8) & 0xFF) as usize].rotate_right(16)
                ^ TE0[(s0 & 0xFF) as usize].rotate_right(24)
                ^ self.rk[k + 1];
            let t2 = TE0[(s2 >> 24) as usize]
                ^ TE0[((s3 >> 16) & 0xFF) as usize].rotate_right(8)
                ^ TE0[((s0 >> 8) & 0xFF) as usize].rotate_right(16)
                ^ TE0[(s1 & 0xFF) as usize].rotate_right(24)
                ^ self.rk[k + 2];
            let t3 = TE0[(s3 >> 24) as usize]
                ^ TE0[((s0 >> 16) & 0xFF) as usize].rotate_right(8)
                ^ TE0[((s1 >> 8) & 0xFF) as usize].rotate_right(16)
                ^ TE0[(s2 & 0xFF) as usize].rotate_right(24)
                ^ self.rk[k + 3];
            s0 = t0;
            s1 = t1;
            s2 = t2;
            s3 = t3;
        }

        let k = self.rounds * 4;
        let f0 = (((SBOX[(s0 >> 24) as usize] as u32) << 24)
            | ((SBOX[((s1 >> 16) & 0xFF) as usize] as u32) << 16)
            | ((SBOX[((s2 >> 8) & 0xFF) as usize] as u32) << 8)
            | (SBOX[(s3 & 0xFF) as usize] as u32))
            ^ self.rk[k];
        let f1 = (((SBOX[(s1 >> 24) as usize] as u32) << 24)
            | ((SBOX[((s2 >> 16) & 0xFF) as usize] as u32) << 16)
            | ((SBOX[((s3 >> 8) & 0xFF) as usize] as u32) << 8)
            | (SBOX[(s0 & 0xFF) as usize] as u32))
            ^ self.rk[k + 1];
        let f2 = (((SBOX[(s2 >> 24) as usize] as u32) << 24)
            | ((SBOX[((s3 >> 16) & 0xFF) as usize] as u32) << 16)
            | ((SBOX[((s0 >> 8) & 0xFF) as usize] as u32) << 8)
            | (SBOX[(s1 & 0xFF) as usize] as u32))
            ^ self.rk[k + 2];
        let f3 = (((SBOX[(s3 >> 24) as usize] as u32) << 24)
            | ((SBOX[((s0 >> 16) & 0xFF) as usize] as u32) << 16)
            | ((SBOX[((s1 >> 8) & 0xFF) as usize] as u32) << 8)
            | (SBOX[(s2 & 0xFF) as usize] as u32))
            ^ self.rk[k + 3];

        let mut out = [0u8; 16];
        out[0..4].copy_from_slice(&f0.to_be_bytes());
        out[4..8].copy_from_slice(&f1.to_be_bytes());
        out[8..12].copy_from_slice(&f2.to_be_bytes());
        out[12..16].copy_from_slice(&f3.to_be_bytes());
        out
    }

    /// Applies AES-CTR keystream XOR in-place starting from `iv` (padded/truncated to 16 bytes,
    /// incrementing the 128-bit big-endian counter per 16-byte block like JCE/PointyCastle `SICStreamCipher`).
    pub fn apply_ctr_in_place(&self, data: &mut [u8], iv: &[u8]) {
        let mut counter = [0u8; 16];
        let copy_len = iv.len().min(16);
        counter[..copy_len].copy_from_slice(&iv[..copy_len]);
        let mut ctr_u128 = u128::from_be_bytes(counter);

        for chunk in data.chunks_mut(16) {
            let block_iv = ctr_u128.to_be_bytes();
            let ks = self.encrypt_block(&block_iv);
            for (dst, &k) in chunk.iter_mut().zip(ks.iter()) {
                *dst ^= k;
            }
            ctr_u128 = ctr_u128.wrapping_add(1);
        }
    }
}

/// Per-file AES-CTR decryptor caching the expanded `AesCipher` schedule across chunks.
#[derive(Debug, Clone)]
pub struct AesCtrStreamDecrypt {
    cipher: AesCipher,
    nonce_prefix: [u8; 12],
}

impl AesCtrStreamDecrypt {
    /// Creates a new stream decryptor for `file_key` and `nonce`.
    #[must_use]
    pub fn new(file_key: &[u8], nonce: &[u8]) -> Option<Self> {
        let cipher = AesCipher::new(file_key)?;
        let mut nonce_prefix = [0u8; 12];
        let n = nonce.len().min(12);
        nonce_prefix[..n].copy_from_slice(&nonce[..n]);
        Some(Self { cipher, nonce_prefix })
    }

    /// Builds the 16-byte counter IV for 160-byte chunk `sequence` (`nonce[0..12] || BE_u32(sequence * 10)`).
    #[must_use]
    pub const fn build_counter(&self, sequence: u32) -> [u8; 16] {
        let c = sequence.wrapping_mul(10).to_be_bytes();
        let p = self.nonce_prefix;
        [
            p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9], p[10], p[11], c[0], c[1],
            c[2], c[3],
        ]
    }

    /// Decrypts a single chunk at `sequence` using the cached key schedule.
    #[must_use]
    pub fn decrypt_chunk(&self, data: &[u8], sequence: u32) -> Vec<u8> {
        let mut out = data.to_vec();
        let iv = self.build_counter(sequence);
        self.cipher.apply_ctr_in_place(&mut out, &iv);
        out
    }

    /// Decrypts contiguous 160-byte chunks in place starting at `start_sequence` (`soa_simd` zero-alloc path).
    pub fn decrypt_contiguous_in_place(&self, data: &mut [u8], start_sequence: u32) {
        let iv = self.build_counter(start_sequence);
        self.cipher.apply_ctr_in_place(data, &iv);
    }
}

/// Parsed `0x1A / 0x07` D3200 audio file transfer header (`>= 97` bytes).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioFileSecretKey {
    /// Numeric file identifier at offset 9.
    pub file_id: u32,
    /// Total file size in bytes at offset 13.
    pub file_size: u32,
    /// 16-byte per-file CTR nonce at offset 17..33.
    pub nonce: [u8; 16],
    /// 46-byte encrypted file key material at offset 33..79.
    pub encrypted_file_key: Vec<u8>,
    /// 16-byte session CTR nonce at offset 79..95.
    pub session_nonce: [u8; 16],
    /// Device error code at offset 95.
    pub error_code: u8,
}

impl AudioFileSecretKey {
    /// Parses a raw `0x1A / 0x07` RX frame (`len >= 97`).
    #[must_use]
    pub fn parse_frame(raw: &[u8]) -> Option<Self> {
        if raw.len() < 97 {
            return None;
        }
        let mut nonce = [0u8; 16];
        nonce.copy_from_slice(&raw[17..33]);
        let mut session_nonce = [0u8; 16];
        session_nonce.copy_from_slice(&raw[79..95]);
        Some(Self {
            file_id: read_u32_le(raw, 9),
            file_size: read_u32_le(raw, 13),
            nonce,
            encrypted_file_key: raw[33..79].to_vec(),
            session_nonce,
            error_code: raw[95],
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prng::SplitMix64;

    #[test]
    fn aes_ctr_and_contiguous_stream_roundtrip() {
        let mut rng = SplitMix64::new(777);
        let key = rng.next_bytes(32);
        let nonce = rng.next_bytes(16);
        let stream = AesCtrStreamDecrypt::new(&key, &nonce).unwrap();
        let plain = rng.next_bytes(160 * 6);
        let mut contiguous = plain.clone();
        stream.decrypt_contiguous_in_place(&mut contiguous, 0);
        for seq in 0..6usize {
            let single = stream.decrypt_chunk(&plain[seq * 160..(seq + 1) * 160], seq as u32);
            assert_eq!(&contiguous[seq * 160..(seq + 1) * 160], single.as_slice());
        }
        stream.decrypt_contiguous_in_place(&mut contiguous, 0);
        assert_eq!(contiguous, plain);
    }

    #[test]
    fn unwrap_file_key_verifies_soundcored3200_magic() {
        let session_key = [0x42u8; 32];
        let session_nonce = [0x11u8; 16];
        let mut raw_key = Vec::from(FILE_KEY_MAGIC.as_slice());
        raw_key.extend_from_slice(&[0x99u8; 32]);
        let enc = DeviceCrypto::aes_ctr_decrypt(&raw_key, &session_key, &session_nonce).unwrap();
        let unwrapped = DeviceCrypto::unwrap_file_key(&session_key, &enc, &session_nonce).unwrap();
        assert_eq!(unwrapped, [0x99u8; 32]);
    }
}
