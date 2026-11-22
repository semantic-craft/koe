//! Safe `OpusStreamDecoder` adapter over `libopus` (`opus_decoder_create`,
//! `opus_decode`, `opus_decoder_ctl`, `opus_decoder_destroy`).

#![deny(missing_docs)]

use std::ffi::c_int;

use koe_engine::wav::{OpusStreamDecoder, OpusWave, MAX_OPUS_FRAME_SAMPLES_48K};

use audiopus_sys::{
    opus_decode, opus_decoder_create, opus_decoder_ctl, opus_decoder_destroy, OpusDecoder, OPUS_OK,
    OPUS_RESET_STATE,
};

/// Stateful mono `libopus` decoder implementing `koe_core::wav::OpusStreamDecoder`.
pub struct LibOpusDecoder {
    raw: *mut OpusDecoder,
    sample_rate: u32,
    scratch_pcm: Vec<i16>,
}

// SAFETY: LibOpusDecoder uniquely owns its heap-allocated OpusDecoder* and mutates it only via &mut self.
#[allow(unsafe_code)]
unsafe impl Send for LibOpusDecoder {}
// SAFETY: Shared &self methods never dereference the raw OpusDecoder* pointer.
#[allow(unsafe_code)]
unsafe impl Sync for LibOpusDecoder {}

impl LibOpusDecoder {
    /// Allocates a new mono `libopus` decoder at `sample_rate` Hz.
    #[must_use]
    pub fn new(sample_rate: u32) -> Option<Self> {
        if !OpusWave::is_valid_sample_rate(sample_rate) {
            return None;
        }
        let mut err: c_int = 0;
        // SAFETY: sample_rate was validated by OpusWave::is_valid_sample_rate, channels is 1, and err is a valid stack out-pointer.
        #[allow(unsafe_code)]
        let raw = unsafe { opus_decoder_create(sample_rate as i32, 1, &mut err) };
        if raw.is_null() || err != OPUS_OK {
            return None;
        }
        let max_samples = (sample_rate as usize * MAX_OPUS_FRAME_SAMPLES_48K) / 48_000;
        Some(Self {
            raw,
            sample_rate,
            scratch_pcm: vec![0i16; max_samples.max(960)],
        })
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
        if packet.is_empty() || self.raw.is_null() {
            return false;
        }
        let Ok(packet_len) = i32::try_from(packet.len()) else {
            return false;
        };
        let Ok(frame_size) = c_int::try_from(self.scratch_pcm.len()) else {
            return false;
        };
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
        if decoded_samples <= 0 {
            return false;
        }
        let count = decoded_samples as usize;
        out_pcm16_le.reserve(count * 2);
        for &sample in &self.scratch_pcm[..count] {
            out_pcm16_le.extend_from_slice(&sample.to_le_bytes());
        }
        true
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
    LibOpusDecoder::new(sample_rate).map(|d| Box::new(d) as Box<dyn OpusStreamDecoder>)
}
