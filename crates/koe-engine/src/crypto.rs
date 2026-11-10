//! Cryptographic primitives for D3200 offline audio sync (`lib/crypto/device_crypto.dart`):
//! RFC 5869 HKDF-SHA256, FIPS 197 AES-128/192/256-CTR with compile-time T-tables,
//! per-file `AesCtrStreamDecrypt` (`sequence * 10` block counter), and `1A07` header parsing.
//!
//! # Examples
//!
//! ```
//! use koe_engine::crypto::{AesCtrStreamDecrypt, DeviceCrypto};
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
    if hi {
        sh ^ 0x1B
    } else {
        sh
    }
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
    /// use koe_engine::crypto::DeviceCrypto;
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

    /// Computes the 65-byte uncompressed X9.63 public key (`0x04 || X || Y`) for a 32-byte
    /// NIST P-256 (`secp256r1`) private scalar `private_key`.
    #[must_use]
    pub fn p256_public_key(private_key: &[u8; 32]) -> Option<[u8; 65]> {
        let d = p256_scalar_from_be(private_key)?;
        let g = P256Point {
            x: P256_GX,
            y: P256_GY,
            z: P256_ONE,
        };
        let pub_pt = p256_point_mul(&g, &d);
        let (x, y) = p256_point_to_affine(&pub_pt)?;
        let mut out = [0u8; 65];
        out[0] = 0x04;
        out[1..33].copy_from_slice(&p256_fe_to_be(&x));
        out[33..65].copy_from_slice(&p256_fe_to_be(&y));
        Some(out)
    }

    /// Computes the 32-byte ECDH shared secret X coordinate (`Z_x`) from our 32-byte
    /// NIST P-256 private scalar `private_key` and the peer's 65-byte uncompressed X9.63
    /// public key (`0x04 || X || Y`).
    #[must_use]
    pub fn p256_ecdh_shared_secret(
        private_key: &[u8; 32],
        peer_public_x963: &[u8],
    ) -> Option<[u8; 32]> {
        if peer_public_x963.len() < 65 || peer_public_x963[0] != 0x04 {
            return None;
        }
        let d = p256_scalar_from_be(private_key)?;
        let mut px_bytes = [0u8; 32];
        let mut py_bytes = [0u8; 32];
        px_bytes.copy_from_slice(&peer_public_x963[1..33]);
        py_bytes.copy_from_slice(&peer_public_x963[33..65]);
        let px = p256_fe_from_be(&px_bytes)?;
        let py = p256_fe_from_be(&py_bytes)?;
        if !p256_is_on_curve(&px, &py) {
            return None;
        }
        let peer_pt = P256Point {
            x: px,
            y: py,
            z: P256_ONE,
        };
        let shared_pt = p256_point_mul(&peer_pt, &d);
        let (sx, _sy) = p256_point_to_affine(&shared_pt)?;
        Some(p256_fe_to_be(&sx))
    }
}

const P256_ZERO: [u64; 4] = [0, 0, 0, 0];
const P256_ONE: [u64; 4] = [1, 0, 0, 0];
const P256_P: [u64; 4] = [
    0xFFFF_FFFF_FFFF_FFFF,
    0x0000_0000_FFFF_FFFF,
    0x0000_0000_0000_0000,
    0xFFFF_FFFF_0000_0001,
];
const P256_P_MINUS_2: [u64; 4] = [
    0xFFFF_FFFF_FFFF_FFFD,
    0x0000_0000_FFFF_FFFF,
    0x0000_0000_0000_0000,
    0xFFFF_FFFF_0000_0001,
];
const P256_N: [u64; 4] = [
    0xF3B9_CAC2_FC63_2551,
    0xBCE6_FAAD_A717_9E84,
    0xFFFF_FFFF_FFFF_FFFF,
    0xFFFF_FFFF_0000_0000,
];
const P256_B: [u64; 4] = [
    0x3BCE_3C3E_27D2_604B,
    0x651D_06B0_CC53_B0F6,
    0xB3EB_BD55_7698_86BC,
    0x5AC6_35D8_AA3A_93E7,
];
const P256_GX: [u64; 4] = [
    0xF4A1_3945_D898_C296,
    0x7703_7D81_2DEB_33A0,
    0xF8BC_E6E5_63A4_40F2,
    0x6B17_D1F2_E12C_4247,
];
const P256_GY: [u64; 4] = [
    0xCBB6_4068_37BF_51F5,
    0x2BCE_3357_6B31_5ECE,
    0x8EE7_EB4A_7C0F_9E16,
    0x4FE3_42E2_FE1A_7F9B,
];

#[derive(Clone, Copy)]
struct P256Point {
    x: [u64; 4],
    y: [u64; 4],
    z: [u64; 4],
}

fn p256_ge(a: &[u64; 4], b: &[u64; 4]) -> bool {
    for i in (0..4).rev() {
        if a[i] != b[i] {
            return a[i] > b[i];
        }
    }
    true
}

fn p256_is_zero(a: &[u64; 4]) -> bool {
    (a[0] | a[1] | a[2] | a[3]) == 0
}

fn p256_raw_add(a: &[u64; 4], b: &[u64; 4]) -> ([u64; 4], u64) {
    let mut out = [0u64; 4];
    let mut carry = 0u128;
    for i in 0..4 {
        let sum = (a[i] as u128) + (b[i] as u128) + carry;
        out[i] = sum as u64;
        carry = sum >> 64;
    }
    (out, carry as u64)
}

fn p256_raw_sub(a: &[u64; 4], b: &[u64; 4]) -> ([u64; 4], u64) {
    let mut out = [0u64; 4];
    let mut borrow = 0u128;
    for i in 0..4 {
        let ai = a[i] as u128;
        let bi = (b[i] as u128) + borrow;
        if ai >= bi {
            out[i] = (ai - bi) as u64;
            borrow = 0;
        } else {
            out[i] = ((1u128 << 64) + ai - bi) as u64;
            borrow = 1;
        }
    }
    (out, borrow as u64)
}

fn p256_fp_add(a: &[u64; 4], b: &[u64; 4]) -> [u64; 4] {
    let (sum, carry) = p256_raw_add(a, b);
    if carry != 0 || p256_ge(&sum, &P256_P) {
        p256_raw_sub(&sum, &P256_P).0
    } else {
        sum
    }
}

fn p256_fp_sub(a: &[u64; 4], b: &[u64; 4]) -> [u64; 4] {
    let (diff, borrow) = p256_raw_sub(a, b);
    if borrow != 0 {
        p256_raw_add(&diff, &P256_P).0
    } else {
        diff
    }
}

fn p256_fp_mul(a: &[u64; 4], b: &[u64; 4]) -> [u64; 4] {
    let mut res = P256_ZERO;
    for i in (0..4).rev() {
        let word = b[i];
        for bit in (0..64).rev() {
            res = p256_fp_add(&res, &res);
            if ((word >> bit) & 1) != 0 {
                res = p256_fp_add(&res, a);
            }
        }
    }
    res
}

fn p256_fp_sqr(a: &[u64; 4]) -> [u64; 4] {
    p256_fp_mul(a, a)
}

fn p256_fp_inv(a: &[u64; 4]) -> Option<[u64; 4]> {
    if p256_is_zero(a) {
        return None;
    }
    let mut res = P256_ONE;
    for i in (0..4).rev() {
        let word = P256_P_MINUS_2[i];
        for bit in (0..64).rev() {
            res = p256_fp_sqr(&res);
            if ((word >> bit) & 1) != 0 {
                res = p256_fp_mul(&res, a);
            }
        }
    }
    Some(res)
}

fn p256_fe_from_be(bytes: &[u8; 32]) -> Option<[u64; 4]> {
    let limbs = [
        u64::from_be_bytes([
            bytes[24], bytes[25], bytes[26], bytes[27], bytes[28], bytes[29], bytes[30], bytes[31],
        ]),
        u64::from_be_bytes([
            bytes[16], bytes[17], bytes[18], bytes[19], bytes[20], bytes[21], bytes[22], bytes[23],
        ]),
        u64::from_be_bytes([
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        ]),
        u64::from_be_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ]),
    ];
    if p256_ge(&limbs, &P256_P) {
        return None;
    }
    Some(limbs)
}

fn p256_scalar_from_be(bytes: &[u8; 32]) -> Option<[u64; 4]> {
    let limbs = [
        u64::from_be_bytes([
            bytes[24], bytes[25], bytes[26], bytes[27], bytes[28], bytes[29], bytes[30], bytes[31],
        ]),
        u64::from_be_bytes([
            bytes[16], bytes[17], bytes[18], bytes[19], bytes[20], bytes[21], bytes[22], bytes[23],
        ]),
        u64::from_be_bytes([
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        ]),
        u64::from_be_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ]),
    ];
    if p256_is_zero(&limbs) || p256_ge(&limbs, &P256_N) {
        return None;
    }
    Some(limbs)
}

fn p256_fe_to_be(a: &[u64; 4]) -> [u8; 32] {
    let mut out = [0u8; 32];
    out[0..8].copy_from_slice(&a[3].to_be_bytes());
    out[8..16].copy_from_slice(&a[2].to_be_bytes());
    out[16..24].copy_from_slice(&a[1].to_be_bytes());
    out[24..32].copy_from_slice(&a[0].to_be_bytes());
    out
}

fn p256_is_on_curve(x: &[u64; 4], y: &[u64; 4]) -> bool {
    let y2 = p256_fp_sqr(y);
    let x2 = p256_fp_sqr(x);
    let x3 = p256_fp_mul(&x2, x);
    let three_x = p256_fp_add(&p256_fp_add(x, x), x);
    let rhs = p256_fp_add(&p256_fp_sub(&x3, &three_x), &P256_B);
    y2 == rhs
}

fn p256_point_double(p: &P256Point) -> P256Point {
    if p256_is_zero(&p.z) || p256_is_zero(&p.y) {
        return P256Point {
            x: P256_ZERO,
            y: P256_ZERO,
            z: P256_ZERO,
        };
    }
    let z2 = p256_fp_sqr(&p.z);
    let x_minus_z2 = p256_fp_sub(&p.x, &z2);
    let x_plus_z2 = p256_fp_add(&p.x, &z2);
    let m_base = p256_fp_mul(&x_minus_z2, &x_plus_z2);
    let m = p256_fp_add(&p256_fp_add(&m_base, &m_base), &m_base);

    let y2 = p256_fp_sqr(&p.y);
    let xy2 = p256_fp_mul(&p.x, &y2);
    let two_xy2 = p256_fp_add(&xy2, &xy2);
    let s = p256_fp_add(&two_xy2, &two_xy2);

    let m2 = p256_fp_sqr(&m);
    let two_s = p256_fp_add(&s, &s);
    let x3 = p256_fp_sub(&m2, &two_s);

    let y4 = p256_fp_sqr(&y2);
    let two_y4 = p256_fp_add(&y4, &y4);
    let four_y4 = p256_fp_add(&two_y4, &two_y4);
    let eight_y4 = p256_fp_add(&four_y4, &four_y4);
    let s_minus_x3 = p256_fp_sub(&s, &x3);
    let y3 = p256_fp_sub(&p256_fp_mul(&m, &s_minus_x3), &eight_y4);

    let yz = p256_fp_mul(&p.y, &p.z);
    let z3 = p256_fp_add(&yz, &yz);

    P256Point {
        x: x3,
        y: y3,
        z: z3,
    }
}

fn p256_point_add(p: &P256Point, q: &P256Point) -> P256Point {
    if p256_is_zero(&p.z) {
        return *q;
    }
    if p256_is_zero(&q.z) {
        return *p;
    }
    let z1z1 = p256_fp_sqr(&p.z);
    let z2z2 = p256_fp_sqr(&q.z);
    let u1 = p256_fp_mul(&p.x, &z2z2);
    let u2 = p256_fp_mul(&q.x, &z1z1);
    let s1 = p256_fp_mul(&p.y, &p256_fp_mul(&q.z, &z2z2));
    let s2 = p256_fp_mul(&q.y, &p256_fp_mul(&p.z, &z1z1));

    if u1 == u2 {
        if s1 == s2 {
            return p256_point_double(p);
        }
        return P256Point {
            x: P256_ZERO,
            y: P256_ZERO,
            z: P256_ZERO,
        };
    }

    let h = p256_fp_sub(&u2, &u1);
    let r = p256_fp_sub(&s2, &s1);
    let h2 = p256_fp_sqr(&h);
    let h3 = p256_fp_mul(&h, &h2);
    let u1h2 = p256_fp_mul(&u1, &h2);

    let r2 = p256_fp_sqr(&r);
    let two_u1h2 = p256_fp_add(&u1h2, &u1h2);
    let x3 = p256_fp_sub(&p256_fp_sub(&r2, &h3), &two_u1h2);

    let u1h2_minus_x3 = p256_fp_sub(&u1h2, &x3);
    let y3 = p256_fp_sub(&p256_fp_mul(&r, &u1h2_minus_x3), &p256_fp_mul(&s1, &h3));

    let z1z2 = p256_fp_mul(&p.z, &q.z);
    let z3 = p256_fp_mul(&z1z2, &h);

    P256Point {
        x: x3,
        y: y3,
        z: z3,
    }
}

fn p256_point_mul(base: &P256Point, scalar: &[u64; 4]) -> P256Point {
    let mut acc = P256Point {
        x: P256_ZERO,
        y: P256_ZERO,
        z: P256_ZERO,
    };
    for i in (0..4).rev() {
        let word = scalar[i];
        for bit in (0..64).rev() {
            acc = p256_point_double(&acc);
            if ((word >> bit) & 1) != 0 {
                acc = p256_point_add(&acc, base);
            }
        }
    }
    acc
}

fn p256_point_to_affine(p: &P256Point) -> Option<([u64; 4], [u64; 4])> {
    let z_inv = p256_fp_inv(&p.z)?;
    let z_inv2 = p256_fp_sqr(&z_inv);
    let z_inv3 = p256_fp_mul(&z_inv2, &z_inv);
    let x = p256_fp_mul(&p.x, &z_inv2);
    let y = p256_fp_mul(&p.y, &z_inv3);
    Some((x, y))
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
            rk[i] =
                u32::from_be_bytes([key[4 * i], key[4 * i + 1], key[4 * i + 2], key[4 * i + 3]]);
        }
        let rcon: [u32; 10] = [
            0x01000000, 0x02000000, 0x04000000, 0x08000000, 0x10000000, 0x20000000, 0x40000000,
            0x80000000, 0x1b000000, 0x36000000,
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
        Some(Self {
            cipher,
            nonce_prefix,
        })
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

    #[test]
    fn p256_ecdh_matches_rfc5903_section_8_1_vectors_and_rejects_invalid_points() {
        let i_priv: [u8; 32] = [
            0xC8, 0x8F, 0x01, 0xF5, 0x10, 0xD9, 0xAC, 0x3F, 0x70, 0xA2, 0x92, 0xDA, 0xA2, 0x31,
            0x6D, 0xE5, 0x44, 0xE9, 0xAA, 0xB8, 0xAF, 0xE8, 0x40, 0x49, 0xC6, 0x2A, 0x9C, 0x57,
            0x86, 0x2D, 0x14, 0x33,
        ];
        let i_pub_expected: [u8; 65] = [
            0x04, 0xDA, 0xD0, 0xB6, 0x53, 0x94, 0x22, 0x1C, 0xF9, 0xB0, 0x51, 0xE1, 0xFE, 0xCA,
            0x57, 0x87, 0xD0, 0x98, 0xDF, 0xE6, 0x37, 0xFC, 0x90, 0xB9, 0xEF, 0x94, 0x5D, 0x0C,
            0x37, 0x72, 0x58, 0x11, 0x80, 0x52, 0x71, 0xA0, 0x46, 0x1C, 0xDB, 0x82, 0x52, 0xD6,
            0x1F, 0x1C, 0x45, 0x6F, 0xA3, 0xE5, 0x9A, 0xB1, 0xF4, 0x5B, 0x33, 0xAC, 0xCF, 0x5F,
            0x58, 0x38, 0x9E, 0x05, 0x77, 0xB8, 0x99, 0x0B, 0xB3,
        ];
        let r_priv: [u8; 32] = [
            0xC6, 0xEF, 0x9C, 0x5D, 0x78, 0xAE, 0x01, 0x2A, 0x01, 0x11, 0x64, 0xAC, 0xB3, 0x97,
            0xCE, 0x20, 0x88, 0x68, 0x5D, 0x8F, 0x06, 0xBF, 0x9B, 0xE0, 0xB2, 0x83, 0xAB, 0x46,
            0x47, 0x6B, 0xEE, 0x53,
        ];
        let r_pub_expected: [u8; 65] = [
            0x04, 0xD1, 0x2D, 0xFB, 0x52, 0x89, 0xC8, 0xD4, 0xF8, 0x12, 0x08, 0xB7, 0x02, 0x70,
            0x39, 0x8C, 0x34, 0x22, 0x96, 0x97, 0x0A, 0x0B, 0xCC, 0xB7, 0x4C, 0x73, 0x6F, 0xC7,
            0x55, 0x44, 0x94, 0xBF, 0x63, 0x56, 0xFB, 0xF3, 0xCA, 0x36, 0x6C, 0xC2, 0x3E, 0x81,
            0x57, 0x85, 0x4C, 0x13, 0xC5, 0x8D, 0x6A, 0xAC, 0x23, 0xF0, 0x46, 0xAD, 0xA3, 0x0F,
            0x83, 0x53, 0xE7, 0x4F, 0x33, 0x03, 0x98, 0x72, 0xAB,
        ];
        let shared_expected: [u8; 32] = [
            0xD6, 0x84, 0x0F, 0x6B, 0x42, 0xF6, 0xED, 0xAF, 0xD1, 0x31, 0x16, 0xE0, 0xE1, 0x25,
            0x65, 0x20, 0x2F, 0xEF, 0x8E, 0x9E, 0xCE, 0x7D, 0xCE, 0x03, 0x81, 0x24, 0x64, 0xD0,
            0x4B, 0x94, 0x42, 0xDE,
        ];

        let i_pub = DeviceCrypto::p256_public_key(&i_priv).unwrap();
        let r_pub = DeviceCrypto::p256_public_key(&r_priv).unwrap();
        assert_eq!(i_pub, i_pub_expected);
        assert_eq!(r_pub, r_pub_expected);

        let shared_ir = DeviceCrypto::p256_ecdh_shared_secret(&i_priv, &r_pub).unwrap();
        let shared_ri = DeviceCrypto::p256_ecdh_shared_secret(&r_priv, &i_pub).unwrap();
        assert_eq!(shared_ir, shared_expected);
        assert_eq!(shared_ri, shared_expected);

        let mut bad_pub = r_pub;
        bad_pub[64] ^= 0x01;
        assert!(DeviceCrypto::p256_ecdh_shared_secret(&i_priv, &bad_pub).is_none());
        assert!(DeviceCrypto::p256_public_key(&[0u8; 32]).is_none());
    }
}
