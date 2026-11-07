//! Safe Rust core kernel for Koe audio recording, BLE protocol framing,
//! cryptographic stream decryption, Ogg Opus container muxing, and WAV framing.
//!
//! Every module in this crate is compiled under `#![forbid(unsafe_code)]` and
//! verified for byte-for-byte differential parity against the legacy Dart
//! reference implementation across deterministic `SplitMix64` seeds.
//!
//! # Examples
//!
//! ```
//! use koe_core::frame::ProtocolFrame;
//! use koe_core::ogg_opus::OggOpus;
//! use koe_core::wav::OpusWave;
//!
//! let pkt = ProtocolFrame::encode(0x01, 0x01, &[]);
//! assert!(ProtocolFrame::verify_checksum(&pkt));
//!
//! let wav = OpusWave::wav_header(1920);
//! assert!(OggOpus::is_wav(&wav));
//! ```

#![forbid(unsafe_code)]
#![deny(missing_docs)]

pub mod commands;
pub mod crypto;
pub mod frame;
pub mod hash;
pub mod library;
pub mod models;
pub mod ogg_opus;
pub mod prng;
pub mod session;
pub mod slice_marks;
pub mod transport;
pub mod wav;
