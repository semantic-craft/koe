//! Safe `OpusStreamDecoder` adapter over `libopus` (`opus_decoder_create`,
//! `opus_decode`, `opus_decoder_ctl`, `opus_decoder_destroy`).

#![deny(missing_docs)]

use std::ffi::c_int;
use std::fmt;

use koe_engine::wav::{OpusStreamDecoder, OpusWave, MAX_OPUS_FRAME_SAMPLES_48K};

use audiopus_sys::{
    opus_decode, opus_decoder_create, opus_decoder_ctl, opus_decoder_destroy, OpusDecoder, OPUS_OK,
    OPUS_RESET_STATE,
};

/// Structured error returned by checked [`LibOpusDecoder`] construction and packet decoding.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpusError {
    /// Sample rate is not one of the 5 `libopus` rates (`8000`, `12000`, `16000`, `24000`, `48000`).
    InvalidSampleRate(u32),
    /// An integer conversion or buffer size calculation overflowed FFI/host bounds.
    IntegerOverflow,
    /// `opus_decoder_create` returned a null pointer or non-`OPUS_OK` error code.
    DecoderInitFailed(c_int),
    /// Packet input was empty or decoder handle was unavailable.
    EmptyPacket,
    /// `opus_decode` returned zero or a negative `libopus` error code.
    DecodeFailed(c_int),
    /// `opus_decode` reported more samples than the output scratch buffer capacity.
    InvalidDecodedSampleCount {
        /// Sample count reported by `libopus`.
        decoded: usize,
        /// Allocated scratch capacity in samples.
        capacity: usize,
    },
}

impl fmt::Display for OpusError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidSampleRate(rate) => write!(f, "unsupported Opus sample rate: {rate}"),
            Self::IntegerOverflow => f.write_str("Opus FFI integer conversion overflow"),
            Self::DecoderInitFailed(code) => write!(f, "libopus decoder init failed ({code})"),
            Self::EmptyPacket => f.write_str("empty Opus packet"),
            Self::DecodeFailed(code) => write!(f, "libopus decode failed ({code})"),
            Self::InvalidDecodedSampleCount { decoded, capacity } => {
                write!(
                    f,
                    "libopus decoded {decoded} samples exceeding scratch capacity {capacity}"
                )
            }
        }
    }
}

impl std::error::Error for OpusError {}

fn checked_sample_rate_ffi(sample_rate: u32) -> Result<i32, OpusError> {
    i32::try_from(sample_rate).map_err(|_| OpusError::IntegerOverflow)
}

fn checked_scratch_len(sample_rate: u32) -> Result<usize, OpusError> {
    let sr = usize::try_from(sample_rate).map_err(|_| OpusError::IntegerOverflow)?;
    let max_samples = sr
        .checked_mul(MAX_OPUS_FRAME_SAMPLES_48K)
        .ok_or(OpusError::IntegerOverflow)?
        / 48_000;
    let scratch_len = max_samples.max(960);
    c_int::try_from(scratch_len).map_err(|_| OpusError::IntegerOverflow)?;
    Ok(scratch_len)
}

fn checked_packet_len(len: usize) -> Result<i32, OpusError> {
    i32::try_from(len).map_err(|_| OpusError::IntegerOverflow)
}

fn checked_frame_size(len: usize) -> Result<c_int, OpusError> {
    c_int::try_from(len).map_err(|_| OpusError::IntegerOverflow)
}

fn checked_decoded_count(decoded_samples: c_int, capacity: usize) -> Result<usize, OpusError> {
    if decoded_samples <= 0 {
        return Err(OpusError::DecodeFailed(decoded_samples));
    }
    let count = usize::try_from(decoded_samples).map_err(|_| OpusError::IntegerOverflow)?;
    if count > capacity {
        return Err(OpusError::InvalidDecodedSampleCount {
            decoded: count,
            capacity,
        });
    }
    Ok(count)
}

/// Stateful mono `libopus` decoder implementing `koe_engine::wav::OpusStreamDecoder`.
///
/// `LibOpusDecoder` is `Send` (uniquely owns its `OpusDecoder*`), but intentionally `!Sync`:
///
/// ```compile_fail
/// fn assert_sync<T: Sync>() {}
/// assert_sync::<koe_opus::LibOpusDecoder>();
/// ```
pub struct LibOpusDecoder {
    raw: *mut OpusDecoder,
    sample_rate: u32,
    scratch_pcm: Vec<i16>,
}

// SAFETY: LibOpusDecoder uniquely owns its heap-allocated OpusDecoder* and mutates it only via &mut self.
#[allow(unsafe_code)]
unsafe impl Send for LibOpusDecoder {}

impl LibOpusDecoder {
    /// Allocates a new mono `libopus` decoder at `sample_rate` Hz, returning a structured error on failure.
    pub fn try_new(sample_rate: u32) -> Result<Self, OpusError> {
        if !OpusWave::is_valid_sample_rate(sample_rate) {
            return Err(OpusError::InvalidSampleRate(sample_rate));
        }
        let fs = checked_sample_rate_ffi(sample_rate)?;
        let scratch_len = checked_scratch_len(sample_rate)?;
        let mut err: c_int = 0;
        // SAFETY: fs was validated against OpusWave::is_valid_sample_rate and checked_sample_rate_ffi, channels is 1, and err is a valid stack out-pointer.
        #[allow(unsafe_code)]
        let raw = unsafe { opus_decoder_create(fs, 1, &mut err) };
        if raw.is_null() || err != OPUS_OK {
            return Err(OpusError::DecoderInitFailed(err));
        }
        Ok(Self {
            raw,
            sample_rate,
            scratch_pcm: vec![0i16; scratch_len],
        })
    }

    /// Allocates a new mono `libopus` decoder at `sample_rate` Hz.
    #[must_use]
    pub fn new(sample_rate: u32) -> Option<Self> {
        Self::try_new(sample_rate).ok()
    }

    /// Decodes a single zero-trimmed Opus packet, appending PCM16 LE bytes and returning the decoded sample count.
    pub fn try_decode_trimmed_packet(
        &mut self,
        packet: &[u8],
        out_pcm16_le: &mut Vec<u8>,
    ) -> Result<usize, OpusError> {
        if packet.is_empty() || self.raw.is_null() {
            return Err(OpusError::EmptyPacket);
        }
        let packet_len = checked_packet_len(packet.len())?;
        let frame_size = checked_frame_size(self.scratch_pcm.len())?;
        // SAFETY: self.raw is a valid initialized OpusDecoder*, packet is valid for packet_len bytes, and scratch_pcm has capacity for frame_size samples.
        #[allow(unsafe_code)]
        let decoded_samples = unsafe {
            opus_decode(
                self.raw,
                packet.as_ptr(),
                packet_len,
                self.scratch_pcm.as_mut_ptr(),
                frame_size,
                0,
            )
        };
        let count = checked_decoded_count(decoded_samples, self.scratch_pcm.len())?;
        let out_bytes = count.checked_mul(2).ok_or(OpusError::IntegerOverflow)?;
        out_pcm16_le.reserve(out_bytes);
        for &sample in &self.scratch_pcm[..count] {
            out_pcm16_le.extend_from_slice(&sample.to_le_bytes());
        }
        Ok(count)
    }
}

impl Drop for LibOpusDecoder {
    fn drop(&mut self) {
        if !self.raw.is_null() {
            // SAFETY: self.raw is non-null, uniquely owned by self, and nulled immediately after destroy.
            #[allow(unsafe_code)]
            unsafe {
                opus_decoder_destroy(self.raw);
            }
            self.raw = std::ptr::null_mut();
        }
    }
}

impl OpusStreamDecoder for LibOpusDecoder {
    fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    fn decode_trimmed_packet(&mut self, packet: &[u8], out_pcm16_le: &mut Vec<u8>) -> bool {
        self.try_decode_trimmed_packet(packet, out_pcm16_le).is_ok()
    }

    fn reset(&mut self) {
        if !self.raw.is_null() {
            // SAFETY: self.raw is a valid uniquely owned OpusDecoder* initialized by opus_decoder_create.
            #[allow(unsafe_code)]
            unsafe {
                let _ = opus_decoder_ctl(self.raw, OPUS_RESET_STATE);
            }
        }
    }
}

/// Constructs a boxed `LibOpusDecoder` for `sample_rate`.
pub fn create_libopus_decoder(sample_rate: u32) -> Option<Box<dyn OpusStreamDecoder>> {
    LibOpusDecoder::new(sample_rate).map(|d| -> Box<dyn OpusStreamDecoder> { Box::new(d) })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checked_ffi_conversions_reject_overflow_and_invalid_decoded_counts() {
        assert_eq!(checked_sample_rate_ffi(48_000), Ok(48_000));
        assert_eq!(
            checked_sample_rate_ffi(u32::MAX),
            Err(OpusError::IntegerOverflow)
        );
        assert_eq!(checked_packet_len(usize::MAX), Err(OpusError::IntegerOverflow));
        if let Some(over_i32) = (i32::MAX as usize).checked_add(1) {
            assert_eq!(checked_packet_len(over_i32), Err(OpusError::IntegerOverflow));
        }
        assert_eq!(checked_frame_size(usize::MAX), Err(OpusError::IntegerOverflow));
        assert_eq!(checked_decoded_count(0, 960), Err(OpusError::DecodeFailed(0)));
        assert_eq!(
            checked_decoded_count(-4, 960),
            Err(OpusError::DecodeFailed(-4))
        );
        assert_eq!(
            checked_decoded_count(961, 960),
            Err(OpusError::InvalidDecodedSampleCount {
                decoded: 961,
                capacity: 960,
            })
        );
        assert_eq!(checked_decoded_count(320, 960), Ok(320));
    }
}
