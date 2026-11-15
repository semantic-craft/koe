//! Safe `OpusStreamDecoder` adapter over `libopus` (`opus_decoder_create`,
//! `opus_decode`, `opus_decoder_ctl`, `opus_decoder_destroy`).

// FFI boundary crate: links the pinned, source-built static libopus.
#![allow(unsafe_code)]
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

// Each `LibOpusDecoder` owns a unique `OpusDecoder*` heap allocation and is only
// mutated through `&mut self`.
unsafe impl Send for LibOpusDecoder {}
unsafe impl Sync for LibOpusDecoder {}

impl LibOpusDecoder {
    /// Allocates a new mono `libopus` decoder at `sample_rate` Hz.
    #[must_use]
    pub fn new(sample_rate: u32) -> Option<Self> {
        if !OpusWave::is_valid_sample_rate(sample_rate) {
            return None;
        }
        let mut err: c_int = 0;
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
        let decoded_samples = unsafe {
            opus_decode(
                self.raw,
                packet.as_ptr(),
                packet.len() as i32,
                self.scratch_pcm.as_mut_ptr(),
                self.scratch_pcm.len() as c_int,
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
