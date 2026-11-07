//! Batch D3200 `0x1A / 0x07` file header opener and `0x1A / 0x08` (`0x12`)
//! 166-byte audio slice unpacker, AES-CTR decryptor, and double-tap mark extractor.
//!
//! Consolidates the hot real-time and offline slice loop shared by Bluetooth
//! realtime streaming, Bluetooth offline pull, and Wi-Fi SoftAP export.
//!
//! # Examples
//!
//! ```
//! use koe_core::transport::{TransportSliceProcessor, OPUS_FRAME_BYTES};
//!
//! let mut frame = vec![0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x08, 0xB0, 0x00];
//! frame.extend_from_slice(&42u32.to_le_bytes());
//! frame.push(0x01);
//! frame.extend_from_slice(&[0x78u8; OPUS_FRAME_BYTES]);
//! frame.push(0x00);
//! frame.push(0x00);
//!
//! let batch = TransportSliceProcessor::unpack_frame(&frame, None);
//! assert_eq!(batch.slice_count, 1);
//! assert_eq!(batch.opus_bytes.len(), OPUS_FRAME_BYTES);
//! assert_eq!(batch.marked_sequences, vec![42]);
//! ```

use crate::crypto::{AesCtrStreamDecrypt, AudioFileSecretKey, DeviceCrypto};
use crate::frame::read_u32_le;
use crate::slice_marks::SliceMark;

/// Wire size in bytes of one D3200 audio slice record (`seq u32 + flags u8 + 160B Opus + pad u8`).
pub const SLICE_RECORD_BYTES: usize = 166;

/// Size in bytes of one D3200 fixed-bitrate Opus frame (20 ms at 64 kbps).
pub const OPUS_FRAME_BYTES: usize = 160;

/// Sentinel `file_size` reported in `0x1A / 0x07` when a recording is still active on the bean.
pub const UNFINISHED_FILE_SIZE: u32 = 0xFFFF_FFFF;

/// Parsed `0x1A / 0x07` file transfer header paired with optional unwrapped 32-byte AES file key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenedFileHead {
    /// Raw parsed `0x1A / 0x07` header fields.
    pub secret: AudioFileSecretKey,
    /// Whether `secret.file_size == UNFINISHED_FILE_SIZE`.
    pub unfinished: bool,
    /// Unwrapped 32-byte AES-256 file key when `session_key` was provided and magic verified.
    pub file_key: Option<[u8; 32]>,
}

/// Output of unpacking and optionally decrypting all 166-byte slice records in a transport packet.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct UnpackedSliceBatch {
    /// Concatenated 160-byte Opus frames (`slice_count * 160` bytes), decrypted when a decryptor was supplied.
    pub opus_bytes: Vec<u8>,
    /// Sequence numbers of slices in this packet that carried the `0x01` double-tap mark flag.
    pub marked_sequences: Vec<u32>,
    /// Number of complete 160-byte Opus slices unpacked from the packet.
    pub slice_count: usize,
}

impl UnpackedSliceBatch {
    /// Total wire record bytes accounted for by this batch (`slice_count * 166`).
    #[must_use]
    pub const fn wire_record_bytes(&self) -> usize {
        self.slice_count * SLICE_RECORD_BYTES
    }
}

/// Stateless batch processor for `0x1A / 0x07` headers and `0x1A / 0x08` (`0x12`) slice packets.
pub struct TransportSliceProcessor;

impl TransportSliceProcessor {
    /// Parses a `0x1A / 0x07` frame and, if `session_key` is provided, unwraps and verifies the
    /// `"soundcoreD3200"` per-file AES key in a single step.
    #[must_use]
    pub fn open_file_head(raw: &[u8], session_key: Option<&[u8]>) -> Option<OpenedFileHead> {
        let secret = AudioFileSecretKey::parse_frame(raw)?;
        let unfinished = secret.file_size == UNFINISHED_FILE_SIZE;
        let file_key = session_key.and_then(|sk| {
            DeviceCrypto::unwrap_file_key(sk, &secret.encrypted_file_key, &secret.session_nonce)
        });
        Some(OpenedFileHead {
            secret,
            unfinished,
            file_key,
        })
    }

    /// Unpacks all 166-byte slice records starting at packet offset 9, extracts double-tap mark
    /// sequences, and decrypts each 160-byte Opus payload using `decryptor` when present.
    #[must_use]
    pub fn unpack_frame(
        frame: &[u8],
        decryptor: Option<&AesCtrStreamDecrypt>,
    ) -> UnpackedSliceBatch {
        Self::unpack_frame_from(frame, decryptor, 0)
    }

    /// Unpacks all 166-byte slice records starting at packet offset 9 whose sequence number is
    /// strictly monotonic and `>= min_sequence`, skipping retransmitted or duplicate records.
    #[must_use]
    pub fn unpack_frame_from(
        frame: &[u8],
        decryptor: Option<&AesCtrStreamDecrypt>,
        min_sequence: u32,
    ) -> UnpackedSliceBatch {
        if frame.len() < 9 + 165 {
            return UnpackedSliceBatch::default();
        }
        let max_slices = (frame.len() - 9) / 165;
        let mut opus_bytes = Vec::with_capacity(max_slices * OPUS_FRAME_BYTES);
        let mut marked_sequences = Vec::new();
        let mut slice_count = 0usize;
        let mut next_min_seq = min_sequence;

        let mut i = 9usize;
        while frame.len().saturating_sub(i) >= 165 {
            let seq = read_u32_le(frame, i);
            i += 4;
            let flags = frame[i];
            i += 1;
            let data_end = i + OPUS_FRAME_BYTES;
            if data_end > frame.len() {
                break;
            }
            if seq < next_min_seq {
                i = data_end;
                if i < frame.len() {
                    i += 1;
                }
                continue;
            }
            next_min_seq = seq.saturating_add(1);
            if SliceMark::is_mark(flags) {
                marked_sequences.push(seq);
            }
            let start_out = opus_bytes.len();
            opus_bytes.extend_from_slice(&frame[i..data_end]);
            if let Some(dec) = decryptor {
                dec.decrypt_contiguous_in_place(
                    &mut opus_bytes[start_out..start_out + OPUS_FRAME_BYTES],
                    seq,
                );
            }
            slice_count += 1;
            i = data_end;
            if i < frame.len() {
                i += 1;
            }
        }

        UnpackedSliceBatch {
            opus_bytes,
            marked_sequences,
            slice_count,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::FILE_KEY_MAGIC;
    use crate::prng::SplitMix64;

    #[test]
    fn open_file_head_unwraps_valid_key_and_detects_unfinished() {
        let session_key = [0x55u8; 32];
        let session_nonce = [0x22u8; 16];
        let file_nonce = [0x33u8; 16];
        let expected_file_key = [0xAAu8; 32];

        let mut plain_key_material = Vec::from(FILE_KEY_MAGIC.as_slice());
        plain_key_material.extend_from_slice(&expected_file_key);
        let enc_key =
            DeviceCrypto::aes_ctr_decrypt(&plain_key_material, &session_key, &session_nonce)
                .unwrap();

        let mut raw = vec![0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x07, 0x62, 0x00];
        raw.extend_from_slice(&12345u32.to_le_bytes());
        raw.extend_from_slice(&UNFINISHED_FILE_SIZE.to_le_bytes());
        raw.extend_from_slice(&file_nonce);
        raw.extend_from_slice(&enc_key);
        raw.extend_from_slice(&session_nonce);
        raw.push(0);
        raw.push(0);

        let opened = TransportSliceProcessor::open_file_head(&raw, Some(&session_key)).unwrap();
        assert_eq!(opened.secret.file_id, 12345);
        assert!(opened.unfinished);
        assert_eq!(opened.file_key, Some(expected_file_key));
    }

    #[test]
    fn unpack_frame_decrypts_multiple_slices_and_extracts_marks() {
        let mut rng = SplitMix64::new(2026);
        let file_key = rng.next_bytes(32);
        let nonce = rng.next_bytes(16);
        let dec = AesCtrStreamDecrypt::new(&file_key, &nonce).unwrap();

        let slice0_plain = rng.next_bytes(OPUS_FRAME_BYTES);
        let slice1_plain = rng.next_bytes(OPUS_FRAME_BYTES);
        let slice0_enc = dec.decrypt_chunk(&slice0_plain, 10);
        let slice1_enc = dec.decrypt_chunk(&slice1_plain, 11);

        let mut frame = vec![0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x08, 0x56, 0x01];
        frame.extend_from_slice(&10u32.to_le_bytes());
        frame.push(0x01);
        frame.extend_from_slice(&slice0_enc);
        frame.push(0x00);

        frame.extend_from_slice(&11u32.to_le_bytes());
        frame.push(0x00);
        frame.extend_from_slice(&slice1_enc);
        frame.push(0x00);
        frame.push(0x00);

        let batch = TransportSliceProcessor::unpack_frame(&frame, Some(&dec));
        assert_eq!(batch.slice_count, 2);
        assert_eq!(batch.wire_record_bytes(), 332);
        assert_eq!(batch.marked_sequences, vec![10]);
        assert_eq!(&batch.opus_bytes[0..160], slice0_plain.as_slice());
        assert_eq!(&batch.opus_bytes[160..320], slice1_plain.as_slice());
    }

    #[test]
    fn unpack_frame_from_skips_retransmitted_and_duplicate_sequences() {
        let mut rng = SplitMix64::new(2027);
        let file_key = rng.next_bytes(32);
        let nonce = rng.next_bytes(16);
        let dec = AesCtrStreamDecrypt::new(&file_key, &nonce).unwrap();

        let slice9_plain = rng.next_bytes(OPUS_FRAME_BYTES);
        let slice10_plain = rng.next_bytes(OPUS_FRAME_BYTES);
        let slice11_plain = rng.next_bytes(OPUS_FRAME_BYTES);
        let slice9_enc = dec.decrypt_chunk(&slice9_plain, 9);
        let slice10_enc = dec.decrypt_chunk(&slice10_plain, 10);
        let slice11_enc = dec.decrypt_chunk(&slice11_plain, 11);

        let mut frame = vec![0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x08, 0x00, 0x00];
        for (seq, flags, enc) in [
            (9u32, 0x01u8, &slice9_enc),
            (10u32, 0x01u8, &slice10_enc),
            (10u32, 0x01u8, &slice10_enc),
            (11u32, 0x00u8, &slice11_enc),
        ] {
            frame.extend_from_slice(&seq.to_le_bytes());
            frame.push(flags);
            frame.extend_from_slice(enc);
            frame.push(0x00);
        }
        frame.push(0x00);

        let batch = TransportSliceProcessor::unpack_frame_from(&frame, Some(&dec), 10);
        assert_eq!(batch.slice_count, 2);
        assert_eq!(batch.wire_record_bytes(), 332);
        assert_eq!(batch.marked_sequences, vec![10]);
        assert_eq!(&batch.opus_bytes[0..160], slice10_plain.as_slice());
        assert_eq!(&batch.opus_bytes[160..320], slice11_plain.as_slice());
    }
}
