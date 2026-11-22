//! Ogg Opus container muxing and non-reflected `0x04C11DB7` CRC-32 calculation
//! for D3200 raw 160-byte Opus frames (`lib/audio/ogg_opus.dart`).
//!
//! # Examples
//!
//! ```
//! use koe_engine::ogg_opus::OggOpus;
//!
//! let mut raw = vec![0u8; 320];
//! raw[0] = 0x78;
//! raw[160] = 0x78;
//! let ogg = OggOpus::mux_raw_frames(&raw);
//! assert!(OggOpus::is_ogg(&ogg));
//! ```

/// Fixed D3200 BLE/Wi-Fi Opus transport slice size in bytes.
pub const FRAME_SIZE: usize = 160;

/// Opus nominal output sample rate (`48_000` Hz).
pub const SAMPLE_RATE: u32 = 48_000;

/// PCM samples per 20 ms Opus frame at 48 kHz (`960`).
pub const SAMPLES_PER_FRAME: u64 = 960;

/// Logical bitstream serial number (`'ARKR'` = `0x4152_4B52`).
pub const OGG_SERIAL: u32 = 0x4152_4B52;

/// Maximum frames bundled into a single OggS data page.
pub const FRAMES_PER_PAGE: usize = 50;

/// OpusHead pre-skip sample count at 48 kHz (`3840` samples = 80 ms).
pub const OPUS_PRE_SKIP_SAMPLES: usize = 3840;

const OGG_CRC_POLY: u32 = 0x04C1_1DB7;

const fn build_ogg_crc_table() -> [u32; 256] {
    let mut table = [0u32; 256];
    let mut i = 0usize;
    while i < 256 {
        let mut crc = (i as u32) << 24;
        let mut bit = 0;
        while bit < 8 {
            if (crc & 0x8000_0000) != 0 {
                crc = (crc << 1) ^ OGG_CRC_POLY;
            } else {
                crc <<= 1;
            }
            bit += 1;
        }
        table[i] = crc;
        i += 1;
    }
    table
}

/// Compile-time 256-entry lookup table for non-reflected Ogg CRC-32 (`0x04C11DB7`).
const OGG_CRC_TABLE: [u32; 256] = build_ogg_crc_table();

/// Stateless Ogg Opus container muxer and header recognizer.
#[derive(Debug, Clone, Copy)]
pub struct OggOpus;

impl OggOpus {
    /// Returns `true` if `bytes` begins with the 4-byte `"OggS"` capture pattern.
    ///
    /// # Examples
    ///
    /// ```
    /// use koe_engine::ogg_opus::OggOpus;
    ///
    /// assert!(OggOpus::is_ogg(b"OggS\x00\x02"));
    /// assert!(!OggOpus::is_ogg(b"RIFF"));
    /// ```
    #[must_use]
    pub fn is_ogg(bytes: &[u8]) -> bool {
        bytes.len() >= 4 && &bytes[0..4] == b"OggS"
    }

    /// Returns `true` if `bytes` has a valid 12-byte `"RIFF....WAVE"` header.
    ///
    /// # Examples
    ///
    /// ```
    /// use koe_engine::ogg_opus::OggOpus;
    ///
    /// assert!(OggOpus::is_wav(b"RIFF\x24\x00\x00\x00WAVE"));
    /// assert!(!OggOpus::is_wav(b"OggS"));
    /// ```
    #[must_use]
    pub fn is_wav(bytes: &[u8]) -> bool {
        bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WAVE"
    }

    /// Strips trailing `0x00` padding bytes from a fixed 160-byte transport frame,
    /// always preserving at least 1 byte so empty packets are never emitted.
    ///
    /// # Examples
    ///
    /// ```
    /// use koe_engine::ogg_opus::OggOpus;
    ///
    /// assert_eq!(OggOpus::trim_trailing_zeros(&[0x78, 0x12, 0x00, 0x00]), &[0x78, 0x12]);
    /// assert_eq!(OggOpus::trim_trailing_zeros(&[0x00, 0x00]), &[0x00]);
    /// ```
    #[must_use]
    pub fn trim_trailing_zeros(frame: &[u8]) -> &[u8] {
        let mut n = frame.len();
        while n > 1 && frame[n - 1] == 0 {
            n -= 1;
        }
        &frame[..n]
    }

    /// Computes the non-reflected Ogg CRC-32 (`0x04C11DB7`) using the compile-time
    /// 256-entry lookup table.
    ///
    /// # Examples
    ///
    /// ```
    /// use koe_engine::ogg_opus::OggOpus;
    ///
    /// assert_eq!(OggOpus::ogg_crc(b"OggS"), OggOpus::ogg_crc_bitwise(b"OggS"));
    /// ```
    #[must_use]
    pub fn ogg_crc(data: &[u8]) -> u32 {
        let mut crc: u32 = 0;
        for &byte in data {
            let idx = ((crc >> 24) ^ u32::from(byte)) as usize;
            crc = (crc << 8) ^ OGG_CRC_TABLE[idx];
        }
        crc
    }

    /// Bit-by-bit Ogg CRC-32 port used to benchmark Stage 2 (`safe_rust`) before table lookup.
    #[must_use]
    pub fn ogg_crc_bitwise(data: &[u8]) -> u32 {
        let mut crc: u32 = 0;
        for &byte in data {
            crc ^= u32::from(byte) << 24;
            for _ in 0..8 {
                if (crc & 0x8000_0000) != 0 {
                    crc = (crc << 1) ^ OGG_CRC_POLY;
                } else {
                    crc <<= 1;
                }
            }
        }
        crc
    }

    /// Muxes concatenated 160-byte Opus frames into a complete Ogg Opus byte buffer
    /// using pre-sized single-buffer allocation and table-driven CRC-32 (`soa_simd` fast path).
    #[must_use]
    pub fn mux_raw_frames(raw: &[u8]) -> Vec<u8> {
        Self::mux_raw_frames_with_crc(raw, true)
    }

    /// Idiomatic Stage 2 port using bitwise CRC-32 for benchmark staircase comparison.
    #[must_use]
    pub fn mux_raw_frames_naive(raw: &[u8]) -> Vec<u8> {
        Self::mux_raw_frames_with_crc(raw, false)
    }

    fn mux_raw_frames_with_crc(raw: &[u8], fast_crc: bool) -> Vec<u8> {
        if raw.is_empty() {
            return Vec::new();
        }
        let num_frames = if raw.len() >= FRAME_SIZE {
            raw.len().div_ceil(FRAME_SIZE)
        } else {
            1
        };
        let num_audio_pages = num_frames.div_ceil(FRAMES_PER_PAGE);
        let estimated_cap = 128 + num_audio_pages * 80 + raw.len();
        let mut out = Vec::with_capacity(estimated_cap);

        let head = Self::opus_head(1, SAMPLE_RATE);
        let tags = Self::opus_tags();
        let mut seq = 0u32;

        Self::append_page(
            &mut out,
            &[&head],
            OggPageSpec {
                serial: OGG_SERIAL,
                sequence: seq,
                granule: 0,
                bos: true,
                eos: false,
                fast_crc,
            },
        );
        seq += 1;
        Self::append_page(
            &mut out,
            &[&tags],
            OggPageSpec {
                serial: OGG_SERIAL,
                sequence: seq,
                granule: 0,
                bos: false,
                eos: false,
                fast_crc,
            },
        );
        seq += 1;

        let mut granule = 0u64;
        if raw.len() < FRAME_SIZE {
            let trimmed = Self::trim_trailing_zeros(raw);
            granule += SAMPLES_PER_FRAME;
            Self::append_page(
                &mut out,
                &[trimmed],
                OggPageSpec {
                    serial: OGG_SERIAL,
                    sequence: seq,
                    granule,
                    bos: false,
                    eos: true,
                    fast_crc,
                },
            );
            return out;
        }

        let mut offset = 0usize;
        let mut packets: [&[u8]; FRAMES_PER_PAGE] = [&[]; FRAMES_PER_PAGE];
        while offset < raw.len() {
            let mut count = 0usize;
            while count < FRAMES_PER_PAGE && offset < raw.len() {
                let end = (offset + FRAME_SIZE).min(raw.len());
                packets[count] = Self::trim_trailing_zeros(&raw[offset..end]);
                offset = end;
                count += 1;
            }
            granule += SAMPLES_PER_FRAME * (count as u64);
            let eos = offset >= raw.len();
            Self::append_page(
                &mut out,
                &packets[..count],
                OggPageSpec {
                    serial: OGG_SERIAL,
                    sequence: seq,
                    granule,
                    bos: false,
                    eos,
                    fast_crc,
                },
            );
            seq += 1;
        }
        out
    }

    fn opus_head(channels: u8, sample_rate: u32) -> [u8; 19] {
        let skip = (OPUS_PRE_SKIP_SAMPLES as u16).to_le_bytes();
        let sr = sample_rate.to_le_bytes();
        [
            b'O', b'p', b'u', b's', b'H', b'e', b'a', b'd', 1, channels, skip[0], skip[1], sr[0],
            sr[1], sr[2], sr[3], 0, 0, 0,
        ]
    }

    fn opus_tags() -> [u8; 29] {
        [
            b'O', b'p', b'u', b's', b'T', b'a', b'g', b's', 13, 0, 0, 0, b'A', b'n', b'k', b'e',
            b'r', b'R', b'e', b'c', b'o', b'r', b'd', b'e', b'r', 0, 0, 0, 0,
        ]
    }

    fn append_page(out: &mut Vec<u8>, packets: &[&[u8]], spec: OggPageSpec) {
        let page_start = out.len();
        let mut header_type = 0u8;
        if spec.bos {
            header_type |= 0x02;
        }
        if spec.eos {
            header_type |= 0x04;
        }

        let mut num_segs = 0usize;
        for pkt in packets {
            num_segs += pkt.len() / 255 + 1;
        }

        out.extend_from_slice(b"OggS");
        out.push(0);
        out.push(header_type);
        out.extend_from_slice(&spec.granule.to_le_bytes());
        out.extend_from_slice(&spec.serial.to_le_bytes());
        out.extend_from_slice(&spec.sequence.to_le_bytes());
        out.extend_from_slice(&[0, 0, 0, 0]);
        out.push(num_segs as u8);

        for pkt in packets {
            let mut rem = pkt.len();
            while rem >= 255 {
                out.push(255);
                rem -= 255;
            }
            out.push(rem as u8);
        }
        for pkt in packets {
            out.extend_from_slice(pkt);
        }

        let crc = if spec.fast_crc {
            Self::ogg_crc(&out[page_start..])
        } else {
            Self::ogg_crc_bitwise(&out[page_start..])
        };
        let crc_bytes = crc.to_le_bytes();
        out[page_start + 22..page_start + 26].copy_from_slice(&crc_bytes);
    }
}

#[derive(Debug, Clone, Copy)]
struct OggPageSpec {
    serial: u32,
    sequence: u32,
    granule: u64,
    bos: bool,
    eos: bool,
    fast_crc: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prng::SplitMix64;

    #[test]
    fn fast_table_crc_matches_bitwise_crc() {
        let mut rng = SplitMix64::new(2026);
        for len in [0, 1, 19, 29, 160, 1024, 8192] {
            let data = rng.next_bytes(len);
            assert_eq!(OggOpus::ogg_crc(&data), OggOpus::ogg_crc_bitwise(&data));
        }
    }

    #[test]
    fn fast_mux_and_naive_mux_are_byte_identical() {
        let mut rng = SplitMix64::new(77);
        let raw = rng.next_bytes(160 * 65);
        let fast = OggOpus::mux_raw_frames(&raw);
        let naive = OggOpus::mux_raw_frames_naive(&raw);
        assert_eq!(fast, naive);
        assert!(OggOpus::is_ogg(&fast));
    }
}
