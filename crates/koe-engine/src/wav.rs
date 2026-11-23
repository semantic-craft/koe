//! PCM16 little-endian RIFF/WAVE header construction and raw 160-byte Opus
//! frame slicing utilities.
//!
//! # Examples
//!
//! ```
//! use koe_engine::ogg_opus::OggOpus;
//! use koe_engine::wav::OpusWave;
//!
//! let hdr = OpusWave::wav_header(960 * 2);
//! assert_eq!(hdr.len(), 44);
//! assert!(OggOpus::is_wav(&hdr));
//! ```

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
pub trait OpusStreamDecoder: Send {
    /// Target output sample rate in Hz (`8000`, `12000`, `16000`, `24000`, or `48000`).
    fn sample_rate(&self) -> u32;

    /// Decodes a single zero-trimmed Opus packet and appends mono PCM16 LE bytes to `out_pcm16_le`.
    fn decode_trimmed_packet(&mut self, packet: &[u8], out_pcm16_le: &mut Vec<u8>) -> bool;

    /// Resets internal decoder prediction state without reallocating.
    fn reset(&mut self);
}

/// Factory function that constructs a boxed `OpusStreamDecoder` for `sample_rate`.
pub type OpusDecoderFactory = fn(sample_rate: u32) -> Option<Box<dyn OpusStreamDecoder>>;

/// Validated PCM16 WAVE data, retaining the original sample rate and channels.
pub struct PcmWave<'a> {
    /// Interleaved little-endian signed samples.
    pub samples: &'a [u8],
    /// Samples per channel per second.
    pub sample_rate: u32,
    /// One or two interleaved channels.
    pub channels: u16,
}

fn resample_to_16khz_with<F>(
    frame_count: usize,
    sample_rate: u32,
    sample_at: F,
    mut emit: impl FnMut(i16),
) where
    F: Fn(usize) -> f64,
{
    if frame_count == 0 || sample_rate == 0 {
        return;
    }
    let count = frame_count as u64 * u64::from(ASR_SAMPLE_RATE) / u64::from(sample_rate);
    let max_frame_idx = frame_count - 1;
    for index in 0..count {
        let position = index as f64 * f64::from(sample_rate) / f64::from(ASR_SAMPLE_RATE);
        let left_idx = (position as usize).min(max_frame_idx);
        let right_idx = (left_idx + 1).min(max_frame_idx);
        let weight = position - left_idx as f64;
        let left = sample_at(left_idx);
        let sample = if right_idx == left_idx || weight == 0.0 {
            left.round() as i16
        } else {
            let right = sample_at(right_idx);
            (left * (1.0 - weight) + right * weight).round() as i16
        };
        emit(sample);
    }
}

/// Linearly resamples mono PCM16 samples from `sample_rate` Hz directly to 16 kHz without WAV framing.
#[must_use]
pub fn resample_mono_to_16khz(samples: &[i16], sample_rate: u32) -> Vec<i16> {
    if samples.is_empty() || sample_rate == 0 {
        return Vec::new();
    }
    if sample_rate == ASR_SAMPLE_RATE {
        return samples.to_vec();
    }
    let count = samples.len() as u64 * u64::from(ASR_SAMPLE_RATE) / u64::from(sample_rate);
    let mut output = Vec::with_capacity(count as usize);
    resample_to_16khz_with(
        samples.len(),
        sample_rate,
        |idx| f64::from(samples[idx]),
        |sample| output.push(sample),
    );
    output
}

impl PcmWave<'_> {
    /// Duration derived from complete frames, not file size estimates.
    pub fn duration_ms(&self) -> u64 {
        self.samples.len() as u64 * 1000
            / (u64::from(self.channels) * 2 * u64::from(self.sample_rate))
    }

    /// Downmixes and linearly resamples actual PCM samples for the ASR protocol.
    #[must_use]
    pub fn mono_16khz(&self) -> Vec<u8> {
        let frame_bytes = usize::from(self.channels) * 2;
        if frame_bytes == 0 || self.sample_rate == 0 {
            return Vec::new();
        }
        let frame_count = self.samples.len() / frame_bytes;
        if frame_count == 0 {
            return Vec::new();
        }
        if self.channels == 1 && self.sample_rate == ASR_SAMPLE_RATE {
            return self.samples[..frame_count * 2].to_vec();
        }
        let count = frame_count as u64 * u64::from(ASR_SAMPLE_RATE) / u64::from(self.sample_rate);
        let mut output = Vec::with_capacity(count as usize * 2);
        resample_to_16khz_with(
            frame_count,
            self.sample_rate,
            |idx| self.mono_sample_at(idx, frame_bytes),
            |sample| output.extend_from_slice(&sample.to_le_bytes()),
        );
        output
    }

    #[inline]
    fn mono_sample_at(&self, frame_index: usize, frame_bytes: usize) -> f64 {
        let offset = frame_index * frame_bytes;
        let left = f64::from(i16::from_le_bytes([
            self.samples[offset],
            self.samples[offset + 1],
        ]));
        if self.channels == 1 {
            left
        } else {
            let right = f64::from(i16::from_le_bytes([
                self.samples[offset + 2],
                self.samples[offset + 3],
            ]));
            (left + right) * 0.5
        }
    }
}

fn read_le_u16(bytes: &[u8], offset: usize) -> Result<u16, &'static str> {
    let end = offset.checked_add(2).ok_or("WAV 文件不完整")?;
    bytes
        .get(offset..end)
        .and_then(|slice| slice.try_into().ok())
        .map(u16::from_le_bytes)
        .ok_or("WAV 文件不完整")
}

fn read_le_u32(bytes: &[u8], offset: usize) -> Result<u32, &'static str> {
    let end = offset.checked_add(4).ok_or("WAV 文件不完整")?;
    bytes
        .get(offset..end)
        .and_then(|slice| slice.try_into().ok())
        .map(u32::from_le_bytes)
        .ok_or("WAV 文件不完整")
}

/// Parses RIFF chunks and rejects compressed, truncated, or misaligned audio.
pub fn parse_pcm_wave(bytes: &[u8]) -> Result<PcmWave<'_>, &'static str> {
    if bytes.len() < 12 || &bytes[..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("请选择 PCM16 WAV 音频");
    }
    let riff_size = usize::try_from(read_le_u32(bytes, 4)?)
        .ok()
        .and_then(|n| n.checked_add(8))
        .ok_or("WAV 文件不完整")?;
    if riff_size > bytes.len() {
        return Err("WAV 文件不完整");
    }
    let mut offset = 12usize;
    let mut format = None;
    let mut data = None;
    while offset + 8 <= riff_size {
        let length = read_le_u32(bytes, offset + 4)? as usize;
        let start = offset + 8;
        let end = start
            .checked_add(length)
            .filter(|end| *end <= riff_size)
            .ok_or("WAV 数据块不完整")?;
        match &bytes[offset..offset + 4] {
            b"fmt " if length >= 16 => {
                let encoding = read_le_u16(bytes, start)?;
                let channels = read_le_u16(bytes, start + 2)?;
                let rate = read_le_u32(bytes, start + 4)?;
                let bits = read_le_u16(bytes, start + 14)?;
                if encoding != 1
                    || bits != 16
                    || !(1..=2).contains(&channels)
                    || !(8000..=96000).contains(&rate)
                {
                    return Err("支持 8–96 kHz、单声道或双声道的 PCM16 WAV");
                }
                format = Some((channels, rate));
            }
            b"data" => data = Some(&bytes[start..end]),
            _ => {}
        }
        offset = end + length % 2;
    }
    let (channels, sample_rate) = format.ok_or("WAV 缺少音频格式")?;
    let samples = data.ok_or("WAV 缺少音频数据")?;
    if samples.is_empty() || samples.len() % (usize::from(channels) * 2) != 0 {
        return Err("WAV 没有完整的音频采样");
    }
    Ok(PcmWave {
        samples,
        sample_rate,
        channels,
    })
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
    /// use koe_engine::frame::read_u32_le;
    /// use koe_engine::wav::OpusWave;
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
        let byte_rate: u32 = sample_rate * (WAV_CHANNELS as u32) * (WAV_BITS_PER_SAMPLE as u32) / 8;
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
    /// use koe_engine::wav::OpusWave;
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
        let make_decoder = factory?;
        let mut decoder = make_decoder(sample_rate)?;
        let estimated_frames = raw_opus.len().div_ceil(FRAME_SIZE);
        let bytes_per_20ms = (sample_rate as usize / 50) * 2;
        let mut out_pcm = Vec::with_capacity(estimated_frames * bytes_per_20ms);

        let (complete, tail) = Self::split_frames(raw_opus);
        let mut frames_ok = 0usize;
        for chunk in complete.as_chunks::<FRAME_SIZE>().0 {
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

        for (i, pair) in pcm_le_bytes.as_chunks_mut::<2>().0.iter_mut().enumerate() {
            if mark_samples.iter().any(|&m| i.abs_diff(m) < half_window) {
                let phase = 2.0 * core::f64::consts::PI * 880.0 * (i as f64) / (sr as f64);
                let chime = (phase.sin() * 3000.0) as i16;
                let orig = i16::from_le_bytes(*pair);
                *pair = orig.saturating_add(chime).to_le_bytes();
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
    /// use koe_engine::ogg_opus::OggOpus;
    /// use koe_engine::wav::OpusWave;
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

    #[test]
    fn parse_pcm_wave_rejects_truncated_chunks_without_panicking() {
        let valid = OpusWave::wav_header_with_rate(4, 16_000);
        let mut full = valid.to_vec();
        full.extend_from_slice(&[1, 0, 2, 0]);
        assert!(parse_pcm_wave(&full).is_ok());
        assert!(parse_pcm_wave(&full[..12]).is_err());
        assert!(parse_pcm_wave(&full[..20]).is_err());
        assert!(parse_pcm_wave(&full[..35]).is_err());
        assert!(parse_pcm_wave(&full[..44]).is_err());
    }

    #[test]
    fn mono_16khz_streams_stereo_48khz_44100hz_and_edge_cases_accurately() {
        let mut stereo_48k = Vec::new();
        let frames_48k: [(i16, i16); 6] = [
            (1000, 3000),
            (9999, -9999),
            (500, 500),
            (-4000, -2000),
            (i16::MAX, i16::MAX),
            (i16::MIN, i16::MIN),
        ];
        for (l, r) in frames_48k {
            stereo_48k.extend_from_slice(&l.to_le_bytes());
            stereo_48k.extend_from_slice(&r.to_le_bytes());
        }
        let wave_48k = PcmWave {
            samples: &stereo_48k,
            sample_rate: 48_000,
            channels: 2,
        };
        let out_48k = wave_48k.mono_16khz();
        assert_eq!(out_48k.len(), 4);
        assert_eq!(i16::from_le_bytes([out_48k[0], out_48k[1]]), 2000);
        assert_eq!(i16::from_le_bytes([out_48k[2], out_48k[3]]), -3000);

        let mut stereo_441 = Vec::new();
        let mut ref_mono_441 = Vec::new();
        for i in 0..441usize {
            let l = ((i as f64 * 0.17).sin() * 20_000.0) as i16;
            let r = ((i as f64 * 0.17).cos() * 12_000.0) as i16;
            stereo_441.extend_from_slice(&l.to_le_bytes());
            stereo_441.extend_from_slice(&r.to_le_bytes());
            ref_mono_441.push((f64::from(l) + f64::from(r)) / 2.0);
        }
        let wave_441 = PcmWave {
            samples: &stereo_441,
            sample_rate: 44_100,
            channels: 2,
        };
        let out_441 = wave_441.mono_16khz();
        let expected_count = (441u64 * 16_000 / 44_100) as usize;
        assert_eq!(out_441.len(), expected_count * 2);
        for index in 0..expected_count {
            let pos = index as f64 * 44_100.0 / 16_000.0;
            let left = pos as usize;
            let right = (left + 1).min(ref_mono_441.len() - 1);
            let weight = pos - left as f64;
            let expected =
                (ref_mono_441[left] * (1.0 - weight) + ref_mono_441[right] * weight).round() as i16;
            let actual = i16::from_le_bytes([out_441[index * 2], out_441[index * 2 + 1]]);
            assert_eq!(actual, expected, "mismatch at 44.1 kHz output sample {index}");
        }

        let mono_16k_raw: Vec<u8> = [i16::MIN, -1234, 0, 5678, i16::MAX]
            .into_iter()
            .flat_map(i16::to_le_bytes)
            .collect();
        let wave_16k = PcmWave {
            samples: &mono_16k_raw,
            sample_rate: 16_000,
            channels: 1,
        };
        assert_eq!(wave_16k.mono_16khz(), mono_16k_raw);

        let mono_8k_raw: Vec<u8> = [0i16, 1000, 2000]
            .into_iter()
            .flat_map(i16::to_le_bytes)
            .collect();
        let out_8k = PcmWave {
            samples: &mono_8k_raw,
            sample_rate: 8_000,
            channels: 1,
        }
        .mono_16khz();
        let samples_8k: Vec<i16> = out_8k
            .as_chunks::<2>()
            .0
            .iter()
            .map(|b| i16::from_le_bytes(*b))
            .collect();
        assert_eq!(samples_8k, vec![0, 500, 1000, 1500, 2000, 2000]);

        assert!(PcmWave {
            samples: &[],
            sample_rate: 48_000,
            channels: 2,
        }
        .mono_16khz()
        .is_empty());
    }

    #[test]
    fn opus_stream_decoder_trait_requires_only_send_not_sync() {
        struct NonSyncDecoder(core::cell::Cell<u32>);

        impl OpusStreamDecoder for NonSyncDecoder {
            fn sample_rate(&self) -> u32 {
                self.0.get()
            }

            fn decode_trimmed_packet(&mut self, _packet: &[u8], _out_pcm16_le: &mut Vec<u8>) -> bool {
                false
            }

            fn reset(&mut self) {}
        }

        let dec: Box<dyn OpusStreamDecoder> = Box::new(NonSyncDecoder(core::cell::Cell::new(16_000)));
        assert_eq!(dec.sample_rate(), 16_000);
    }

    #[test]
    fn resample_mono_to_16khz_matches_wav_parse_pipeline_bit_for_bit() {
        for rate in [8_000u32, 16_000, 24_000, 44_100, 48_000, 96_000] {
            let samples: Vec<i16> = (0..960usize)
                .map(|i| {
                    if i == 0 {
                        i16::MIN
                    } else if i == 1 {
                        i16::MAX
                    } else {
                        ((i as f64 * 0.23).sin() * 25_000.0) as i16
                    }
                })
                .collect();
            let direct_bytes: Vec<u8> = resample_mono_to_16khz(&samples, rate)
                .into_iter()
                .flat_map(i16::to_le_bytes)
                .collect();

            let mut wav = OpusWave::wav_header_with_rate((samples.len() * 2) as u32, rate).to_vec();
            wav.extend(samples.iter().flat_map(|s| s.to_le_bytes()));
            let via_wav = parse_pcm_wave(&wav).unwrap().mono_16khz();
            assert_eq!(direct_bytes, via_wav, "mismatch at sample_rate={rate}");
        }
        assert!(resample_mono_to_16khz(&[], 48_000).is_empty());
        assert!(resample_mono_to_16khz(&[100, 200], 0).is_empty());
    }
}
