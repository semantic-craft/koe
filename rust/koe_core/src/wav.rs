//! PCM16 little-endian RIFF/WAVE header construction and raw 160-byte Opus
//! frame slicing utilities matching `lib/audio/opus_wave.dart`.
//!
//! # Examples
//!
//! ```
//! use koe_core::ogg_opus::OggOpus;
//! use koe_core::wav::OpusWave;
//!
//! let hdr = OpusWave::wav_header(960 * 2);
//! assert_eq!(hdr.len(), 44);
//! assert!(OggOpus::is_wav(&hdr));
//! ```

use crate::ogg_opus::FRAME_SIZE;

/// Standard output sample rate for decoded D3200 WAV files (`48_000` Hz).
pub const WAV_SAMPLE_RATE: u32 = 48_000;

/// Mono channel count (`1`).
pub const WAV_CHANNELS: u16 = 1;

/// Bits per PCM sample (`16`).
pub const WAV_BITS_PER_SAMPLE: u16 = 16;

/// Stateless WAV header builder and raw Opus frame chunker.
#[derive(Debug, Clone, Copy)]
pub struct OpusWave;

impl OpusWave {
    /// Builds a 44-byte RIFF/WAVE header for `pcm_length` bytes of 48 kHz mono PCM16 LE audio.
    ///
    /// # Examples
    ///
    /// ```
    /// use koe_core::frame::read_u32_le;
    /// use koe_core::wav::OpusWave;
    ///
    /// let hdr = OpusWave::wav_header(3840);
    /// assert_eq!(&hdr[0..4], b"RIFF");
    /// assert_eq!(read_u32_le(&hdr, 4), 36 + 3840);
    /// assert_eq!(&hdr[8..12], b"WAVE");
    /// assert_eq!(read_u32_le(&hdr, 40), 3840);
    /// ```
    #[must_use]
    pub const fn wav_header(pcm_length: u32) -> [u8; 44] {
        let byte_rate: u32 =
            WAV_SAMPLE_RATE * (WAV_CHANNELS as u32) * (WAV_BITS_PER_SAMPLE as u32) / 8;
        let block_align: u16 = WAV_CHANNELS * WAV_BITS_PER_SAMPLE / 8;
        let riff_size = 36u32.wrapping_add(pcm_length);

        let r = riff_size.to_le_bytes();
        let sr = WAV_SAMPLE_RATE.to_le_bytes();
        let br = byte_rate.to_le_bytes();
        let ch = WAV_CHANNELS.to_le_bytes();
        let ba = block_align.to_le_bytes();
        let bps = WAV_BITS_PER_SAMPLE.to_le_bytes();
        let dl = pcm_length.to_le_bytes();

        [
            b'R', b'I', b'F', b'F', r[0], r[1], r[2], r[3], b'W', b'A', b'V', b'E', b'f', b'm',
            b't', b' ', 16, 0, 0, 0, 1, 0, ch[0], ch[1], sr[0], sr[1], sr[2], sr[3], br[0], br[1],
            br[2], br[3], ba[0], ba[1], bps[0], bps[1], b'd', b'a', b't', b'a', dl[0], dl[1],
            dl[2], dl[3],
        ]
    }

    /// Splits a contiguous buffer into complete 160-byte slices and an optional trailing tail.
    ///
    /// # Examples
    ///
    /// ```
    /// use koe_core::wav::OpusWave;
    ///
    /// let raw = vec![0x78u8; 350];
    /// let (complete, tail) = OpusWave::split_frames(&raw);
    /// assert_eq!(complete.len(), 320);
    /// assert_eq!(tail.len(), 30);
    /// ```
    #[must_use]
    pub fn split_frames(data: &[u8]) -> (&[u8], &[u8]) {
        let complete_len = (data.len() / FRAME_SIZE) * FRAME_SIZE;
        (&data[..complete_len], &data[complete_len..])
    }

    /// Synthesizes a 48 kHz mono PCM16 RIFF/WAVE preview file of `duration_ms`
    /// with a 440 Hz carrier tone and 880 Hz chime within 50 ms of each mark in `mark_positions_ms`.
    ///
    /// # Examples
    ///
    /// ```
    /// use koe_core::ogg_opus::OggOpus;
    /// use koe_core::wav::OpusWave;
    ///
    /// let wav = OpusWave::build_audible_preview_wav(400, &[300]);
    /// assert!(OggOpus::is_wav(&wav));
    /// assert!(wav.len() > 44);
    /// ```
    #[must_use]
    pub fn build_audible_preview_wav(duration_ms: u64, mark_positions_ms: &[u64]) -> Vec<u8> {
        let clamped_ms = duration_ms.clamp(100, 60_000);
        let sample_rate = WAV_SAMPLE_RATE as usize;
        let total_samples = ((clamped_ms as usize) * sample_rate / 1000).max(1600);
        let pcm_byte_len = (total_samples * 2) as u32;
        let hdr = Self::wav_header(pcm_byte_len);
        let mut out = Vec::with_capacity(44 + pcm_byte_len as usize);
        out.extend_from_slice(&hdr);

        let mark_samples: Vec<usize> = mark_positions_ms
            .iter()
            .map(|&ms| (ms as usize).saturating_mul(sample_rate) / 1000)
            .collect();
        let half_window = sample_rate / 20;

        for i in 0..total_samples {
            let near_mark = mark_samples.iter().any(|&m| i.abs_diff(m) < half_window);
            let freq = if near_mark { 880.0 } else { 440.0 };
            let amp = if near_mark { 6000.0 } else { 1800.0 };
            let phase = 2.0 * core::f64::consts::PI * freq * (i as f64) / (sample_rate as f64);
            let sample = (phase.sin() * amp) as i16;
            out.extend_from_slice(&sample.to_le_bytes());
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::frame::{read_u16_le, read_u32_le};

    #[test]
    fn wav_header_matches_pcm16_48khz_mono_layout() {
        let pcm_len = 172_800u32;
        let hdr = OpusWave::wav_header(pcm_len);
        assert_eq!(&hdr[0..4], b"RIFF");
        assert_eq!(read_u32_le(&hdr, 4), 36 + pcm_len);
        assert_eq!(&hdr[8..12], b"WAVE");
        assert_eq!(&hdr[12..16], b"fmt ");
        assert_eq!(read_u32_le(&hdr, 16), 16);
        assert_eq!(read_u16_le(&hdr, 20), 1);
        assert_eq!(read_u16_le(&hdr, 22), 1);
        assert_eq!(read_u32_le(&hdr, 24), 48_000);
        assert_eq!(read_u32_le(&hdr, 28), 96_000);
        assert_eq!(read_u16_le(&hdr, 32), 2);
        assert_eq!(read_u16_le(&hdr, 34), 16);
        assert_eq!(&hdr[36..40], b"data");
        assert_eq!(read_u32_le(&hdr, 40), pcm_len);
    }
}
