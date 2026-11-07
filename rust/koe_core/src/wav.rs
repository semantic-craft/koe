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

use std::sync::{OnceLock, RwLock};

use crate::ogg_opus::{OggOpus, FRAME_SIZE};

/// Standard output sample rate for decoded D3200 WAV files (`48_000` Hz).
pub const WAV_SAMPLE_RATE: u32 = 48_000;

/// Standard output sample rate for live streaming ASR (`16_000` Hz).
pub const ASR_SAMPLE_RATE: u32 = 16_000;

/// Mono channel count (`1`).
pub const WAV_CHANNELS: u16 = 1;

/// Bits per PCM sample (`16`).
pub const WAV_BITS_PER_SAMPLE: u16 = 16;

/// Maximum samples per channel for a single 120 ms Opus packet at 48 kHz (`5760`).
pub const MAX_OPUS_FRAME_SAMPLES_48K: usize = 5760;

/// Object-safe stateful Opus packet decoder implemented by the FFI layer (`libopus`).
pub trait OpusStreamDecoder: Send + Sync {
    /// Target output sample rate in Hz (`8000`, `12000`, `16000`, `24000`, or `48000`).
    fn sample_rate(&self) -> u32;

    /// Decodes a single zero-trimmed Opus packet and appends mono PCM16 LE bytes to `out_pcm16_le`.
    fn decode_trimmed_packet(&mut self, packet: &[u8], out_pcm16_le: &mut Vec<u8>) -> bool;

    /// Resets internal decoder prediction state without reallocating.
    fn reset(&mut self);
}

/// Factory function that constructs a boxed `OpusStreamDecoder` for `sample_rate`.
pub type OpusDecoderFactory = fn(sample_rate: u32) -> Option<Box<dyn OpusStreamDecoder>>;

static DEFAULT_DECODER_FACTORY: OnceLock<RwLock<Option<OpusDecoderFactory>>> = OnceLock::new();

/// Registers the process-wide default `OpusDecoderFactory`.
pub fn register_default_opus_decoder_factory(factory: OpusDecoderFactory) {
    let lock = DEFAULT_DECODER_FACTORY.get_or_init(|| RwLock::new(None));
    if let Ok(mut guard) = lock.write() {
        *guard = Some(factory);
    }
}

/// Clears the process-wide default `OpusDecoderFactory`.
pub fn clear_default_opus_decoder_factory() {
    let lock = DEFAULT_DECODER_FACTORY.get_or_init(|| RwLock::new(None));
    if let Ok(mut guard) = lock.write() {
        *guard = None;
    }
}

/// Returns the currently registered default `OpusDecoderFactory`, if any.
#[must_use]
pub fn default_opus_decoder_factory() -> Option<OpusDecoderFactory> {
    let lock = DEFAULT_DECODER_FACTORY.get_or_init(|| RwLock::new(None));
    lock.read().ok().and_then(|g| *g)
}

/// Stateless WAV header builder and raw Opus frame chunker.
#[derive(Debug, Clone, Copy)]
pub struct OpusWave;

impl OpusWave {
    /// Returns `true` if `sample_rate` is one of the 5 sample rates supported by `libopus`
    /// (`8000`, `12000`, `16000`, `24000`, or `48000` Hz).
    #[must_use]
    pub const fn is_valid_sample_rate(sample_rate: u32) -> bool {
        matches!(sample_rate, 8_000 | 12_000 | 16_000 | 24_000 | 48_000)
    }

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
        Self::wav_header_with_rate(pcm_length, WAV_SAMPLE_RATE)
    }

    /// Builds a 44-byte RIFF/WAVE header for `pcm_length` bytes of mono PCM16 LE audio
    /// at `sample_rate` Hz.
    #[must_use]
    pub const fn wav_header_with_rate(pcm_length: u32, sample_rate: u32) -> [u8; 44] {
        let byte_rate: u32 =
            sample_rate * (WAV_CHANNELS as u32) * (WAV_BITS_PER_SAMPLE as u32) / 8;
        let block_align: u16 = WAV_CHANNELS * WAV_BITS_PER_SAMPLE / 8;
        let riff_size = 36u32.wrapping_add(pcm_length);

        let r = riff_size.to_le_bytes();
        let sr = sample_rate.to_le_bytes();
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

    /// Decodes a single raw 160-byte (or shorter) Opus slice by stripping trailing zero
    /// padding via `OggOpus::trim_trailing_zeros` and feeding the trimmed packet to `decoder`.
    pub fn decode_frame_into(
        decoder: &mut dyn OpusStreamDecoder,
        raw_frame: &[u8],
        out_pcm16_le: &mut Vec<u8>,
    ) -> bool {
        if raw_frame.is_empty() {
            return false;
        }
        let trimmed = OggOpus::trim_trailing_zeros(raw_frame);
        if trimmed.is_empty() || (trimmed.len() == 1 && trimmed[0] == 0) {
            return false;
        }
        decoder.decode_trimmed_packet(trimmed, out_pcm16_le)
    }

    /// Splits `raw_opus` into 160-byte D3200 frames (plus any non-empty tail), trims
    /// trailing `0x00` padding on each frame, and decodes all frames into contiguous
    /// mono PCM16 LE bytes at `sample_rate`.
    #[must_use]
    pub fn decode_raw_frames_to_pcm16(
        raw_opus: &[u8],
        sample_rate: u32,
        factory: Option<OpusDecoderFactory>,
    ) -> Option<Vec<u8>> {
        if raw_opus.is_empty() || !Self::is_valid_sample_rate(sample_rate) {
            return None;
        }
        let make_decoder = factory.or_else(default_opus_decoder_factory)?;
        let mut decoder = make_decoder(sample_rate)?;
        let estimated_frames = raw_opus.len().div_ceil(FRAME_SIZE);
        let bytes_per_20ms = (sample_rate as usize / 50) * 2;
        let mut out_pcm = Vec::with_capacity(estimated_frames * bytes_per_20ms);

        let (complete, tail) = Self::split_frames(raw_opus);
        let mut frames_ok = 0usize;
        for chunk in complete.chunks_exact(FRAME_SIZE) {
            if Self::decode_frame_into(decoder.as_mut(), chunk, &mut out_pcm) {
                frames_ok += 1;
            }
        }
        if !tail.is_empty() && Self::decode_frame_into(decoder.as_mut(), tail, &mut out_pcm) {
            frames_ok += 1;
        }
        if frames_ok == 0 || out_pcm.is_empty() {
            return None;
        }
        Some(out_pcm)
    }

    /// Additively mixes an 880 Hz chime (peak amplitude `3000.0`) using saturating `i16`
    /// arithmetic within 50 ms of each mark in `mark_positions_ms`.
    pub fn overlay_mark_chimes_in_place(
        pcm_le_bytes: &mut [u8],
        sample_rate: u32,
        mark_positions_ms: &[u64],
    ) {
        if pcm_le_bytes.len() < 2 || sample_rate == 0 || mark_positions_ms.is_empty() {
            return;
        }
        let sr = sample_rate as usize;
        let half_window = (sr / 20).max(1);
        let mark_samples: Vec<usize> = mark_positions_ms
            .iter()
            .map(|&ms| (ms as usize).saturating_mul(sr) / 1000)
            .collect();

        for (i, pair) in pcm_le_bytes.chunks_exact_mut(2).enumerate() {
            if mark_samples.iter().any(|&m| i.abs_diff(m) < half_window) {
                let phase = 2.0 * core::f64::consts::PI * 880.0 * (i as f64) / (sr as f64);
                let chime = (phase.sin() * 3000.0) as i16;
                let orig = i16::from_le_bytes([pair[0], pair[1]]);
                let mixed = orig.saturating_add(chime).to_le_bytes();
                pair[0] = mixed[0];
                pair[1] = mixed[1];
            }
        }
    }

    /// Decodes concatenated 160-byte Opus frames into a complete 44-byte RIFF/WAVE
    /// header followed by mono PCM16 LE samples at `sample_rate`, overlaying 880 Hz
    /// mark chimes when `mark_positions_ms` is non-empty.
    #[must_use]
    pub fn decode_raw_frames_to_wav(
        raw_opus: &[u8],
        sample_rate: u32,
        mark_positions_ms: &[u64],
        factory: Option<OpusDecoderFactory>,
    ) -> Option<Vec<u8>> {
        let mut pcm = Self::decode_raw_frames_to_pcm16(raw_opus, sample_rate, factory)?;
        if !mark_positions_ms.is_empty() {
            Self::overlay_mark_chimes_in_place(&mut pcm, sample_rate, mark_positions_ms);
        }
        let hdr = Self::wav_header_with_rate(pcm.len() as u32, sample_rate);
        let mut wav = Vec::with_capacity(44 + pcm.len());
        wav.extend_from_slice(&hdr);
        wav.extend_from_slice(&pcm);
        Some(wav)
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

    struct MockStepDecoder {
        sample_rate: u32,
        step: i16,
    }

    impl OpusStreamDecoder for MockStepDecoder {
        fn sample_rate(&self) -> u32 {
            self.sample_rate
        }

        fn decode_trimmed_packet(&mut self, packet: &[u8], out_pcm16_le: &mut Vec<u8>) -> bool {
            if packet.is_empty() || packet[0] != 0x78 {
                return false;
            }
            self.step = self.step.saturating_add(1);
            let samples = (self.sample_rate as usize) / 50;
            out_pcm16_le.reserve(samples * 2);
            for i in 0..samples {
                let val = self.step.saturating_mul(100).saturating_add(i as i16);
                out_pcm16_le.extend_from_slice(&val.to_le_bytes());
            }
            true
        }

        fn reset(&mut self) {
            self.step = 0;
        }
    }

    fn mock_decoder_factory(sample_rate: u32) -> Option<Box<dyn OpusStreamDecoder>> {
        if !OpusWave::is_valid_sample_rate(sample_rate) {
            return None;
        }
        Some(Box::new(MockStepDecoder {
            sample_rate,
            step: 0,
        }))
    }

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

    #[test]
    fn decode_raw_frames_trims_zeros_and_preserves_state_across_slices() {
        let mut raw = vec![0u8; 320];
        raw[0] = 0x78;
        raw[1] = 0x81;
        raw[160] = 0x78;
        raw[161] = 0x82;

        let pcm16 =
            OpusWave::decode_raw_frames_to_pcm16(&raw, ASR_SAMPLE_RATE, Some(mock_decoder_factory))
                .expect("two valid 160-byte frames must decode at 16 kHz");
        assert_eq!(pcm16.len(), 2 * 320 * 2);
        let first_frame_sample0 = i16::from_le_bytes([pcm16[0], pcm16[1]]);
        let second_frame_sample0 = i16::from_le_bytes([pcm16[640], pcm16[641]]);
        assert_eq!(first_frame_sample0, 100);
        assert_eq!(second_frame_sample0, 200);
    }

    #[test]
    fn overlay_mark_chimes_mixes_in_place_without_clipping() {
        let mut pcm = vec![0u8; 16_000 * 2];
        OpusWave::overlay_mark_chimes_in_place(&mut pcm, 16_000, &[500]);
        let near_mark = i16::from_le_bytes([pcm[8001 * 2], pcm[8001 * 2 + 1]]);
        let far_from_mark = i16::from_le_bytes([pcm[100 * 2], pcm[100 * 2 + 1]]);
        assert_ne!(near_mark, 0);
        assert_eq!(far_from_mark, 0);
    }
}
