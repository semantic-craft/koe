//! High-level D3200 BLE TX command builders and RX command identifiers (`PROTOCOL.md` §5).

use crate::frame::{u16_le, u32_le, ProtocolFrame};
use crate::session::VerifiedCustodyReceipt;

/// Stateless packet builders for D3200 BLE TX commands.
pub struct DeviceCommands;

impl DeviceCommands {
    /// Requests the full device telemetry and identity report (`0x01 0x01`).
    #[must_use]
    pub fn get_device_info() -> Vec<u8> {
        ProtocolFrame::encode(0x01, 0x01, &[])
    }

    /// Enables realtime recording notification mode on the device (`0x18 0x81`, payload `[0x01]`).
    #[must_use]
    pub fn start_realtime_record_81() -> Vec<u8> {
        ProtocolFrame::encode(0x18, 0x81, &[0x01])
    }

    /// Starts app-initiated recording on the device (`0x18 0x82`, payload `[0x01]`).
    #[must_use]
    pub fn start_app_recording() -> Vec<u8> {
        ProtocolFrame::encode(0x18, 0x82, &[0x01])
    }

    /// Pauses recording on the device (`0x18 0x82`, payload `[0x02]`).
    #[must_use]
    pub fn pause_record() -> Vec<u8> {
        ProtocolFrame::encode(0x18, 0x82, &[0x02])
    }

    /// Requests a page of offline files with end timestamps (`0x1B 0x0E`).
    #[must_use]
    pub fn list_files_with_end_time(page: u16) -> Vec<u8> {
        ProtocolFrame::encode(0x1B, 0x0E, &u16_le(page))
    }

    /// Deletes a stored recording (`0x1A 0x10`) authorized by a verified disk `fsync` receipt.
    ///
    /// Raw file IDs and forged [`VerifiedCustodyReceipt`] construction are rejected at compile time:
    ///
    /// ```compile_fail,E0308
    /// use koe_engine::commands::DeviceCommands;
    ///
    /// let _ = DeviceCommands::delete_file(42);
    /// ```
    ///
    /// ```compile_fail,E0423
    /// use koe_engine::commands::DeviceCommands;
    /// use koe_engine::session::{CustodyReceipt, VerifiedCustodyReceipt};
    ///
    /// let raw = CustodyReceipt {
    ///     file_id: 42,
    ///     byte_count: 1024,
    ///     sha256_hex: "a".repeat(64),
    ///     fsynced_at_epoch_sec: 1_700_000_000,
    /// };
    /// let forged = VerifiedCustodyReceipt(raw);
    /// let _ = DeviceCommands::delete_file(&forged);
    /// ```
    ///
    /// ```
    /// use koe_engine::commands::DeviceCommands;
    /// use koe_engine::session::CustodyReceipt;
    ///
    /// let verified = CustodyReceipt {
    ///     file_id: 42,
    ///     byte_count: 1024,
    ///     sha256_hex: "a".repeat(64),
    ///     fsynced_at_epoch_sec: 1_700_000_000,
    /// }
    /// .verify()
    /// .unwrap();
    /// let frame = DeviceCommands::delete_file(&verified);
    /// assert_eq!(&frame[9..13], &42u32.to_le_bytes());
    /// ```
    #[must_use]
    pub fn delete_file(receipt: &VerifiedCustodyReceipt) -> Vec<u8> {
        ProtocolFrame::encode(0x1A, 0x10, &u32_le(receipt.file_id()))
    }

    /// Starts streaming or resuming an offline audio file (`0x1A 0x07`).
    #[must_use]
    pub fn start_transport_audio_file(
        file_id: u32,
        already_transferred: u32,
        realtime_flag: u8,
    ) -> Vec<u8> {
        let mut payload = Vec::with_capacity(9);
        payload.extend_from_slice(&u32_le(already_transferred));
        payload.extend_from_slice(&u32_le(file_id));
        payload.push(realtime_flag);
        ProtocolFrame::encode(0x1A, 0x07, &payload)
    }

    /// Sends the app's uncompressed P-256 ECDH public key (`0x2E 0x01`).
    #[must_use]
    pub fn notify_encrypt_public_key(public_key_bytes: &[u8]) -> Vec<u8> {
        ProtocolFrame::encode(0x2E, 0x01, public_key_bytes)
    }
}

/// Known RX command types and identifiers used for packet dispatch.
pub struct RxCmd;

impl RxCmd {
    /// Device info command family (`0x01`).
    pub const DEVICE_INFO_TYPE: u8 = 0x01;
    /// Device info report (`0x01`).
    pub const DEVICE_INFO_ID: u8 = 0x01;

    /// Audio control command family (`0x18`).
    pub const AUDIO_TYPE: u8 = 0x18;
    /// Realtime recording status / start notification id (`0x81`).
    pub const AUDIO_REALTIME_START_ID: u8 = 0x81;
    /// Start/pause recording command id (`0x82`).
    pub const AUDIO_CONTROL_ID: u8 = 0x82;

    /// Primary file transport command family (`0x1A`).
    pub const TRANSPORT_TYPE: u8 = 0x1A;
    /// Alternate file transport command family with end timestamps (`0x1B`).
    pub const TRANSPORT_TYPE_ALT: u8 = 0x1B;
    /// Legacy offline file list response (`0x01`).
    pub const FILE_LIST_LEGACY_ID: u8 = 0x01;
    /// Realtime recording status notification (`0x06`).
    pub const RECORD_STATUS_ID: u8 = 0x06;
    /// File stream header (`0x07`).
    pub const FILE_HEAD_ID: u8 = 0x07;
    /// Encrypted Opus audio slice (`0x08`).
    pub const FILE_SLICE_ID: u8 = 0x08;
    /// File transfer completed notification (`0x0A`).
    pub const FILE_DONE_ID: u8 = 0x0A;
    /// File list page response without explicit page tag (`0x0D`).
    pub const FILE_LIST_NO_END_ID: u8 = 0x0D;
    /// File list page response (`0x0E`).
    pub const FILE_LIST_ID: u8 = 0x0E;
    /// File deletion response (`0x10`).
    pub const DELETE_ID: u8 = 0x10;
    /// Marked audio slice notification (`0x12`).
    pub const FILE_SLICE_MARK_ID: u8 = 0x12;

    /// Encryption handshake command family (`0x2E`).
    pub const ENCRYPT_TYPE: u8 = 0x2E;
    /// Encryption ECDH handshake id (`0x01`).
    pub const ENCRYPT_HANDSHAKE_ID: u8 = 0x01;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_commands_encode_valid_frames() {
        let info = DeviceCommands::get_device_info();
        assert_eq!(info[0], 0x08);
        assert_eq!(info[1], 0xEE);
        assert_eq!(info[5], 0x01);
        assert_eq!(info[6], 0x01);
        assert!(ProtocolFrame::verify_checksum(&info));

        let start = DeviceCommands::start_app_recording();
        assert_eq!(start[5], 0x18);
        assert_eq!(start[6], 0x82);
        assert_eq!(start[9], 0x01);
        assert!(ProtocolFrame::verify_checksum(&start));

        let list = DeviceCommands::list_files_with_end_time(2);
        assert_eq!(list[5], 0x1B);
        assert_eq!(list[6], 0x0E);
        assert_eq!(&list[9..11], &[0x02, 0x00]);
        assert!(ProtocolFrame::verify_checksum(&list));

        let pull = DeviceCommands::start_transport_audio_file(0x0102_0304, 332, 0);
        assert_eq!(pull[5], 0x1A);
        assert_eq!(pull[6], 0x07);
        assert_eq!(&pull[9..13], &332u32.to_le_bytes());
        assert_eq!(&pull[13..17], &0x0102_0304u32.to_le_bytes());
        assert_eq!(pull[17], 0);
        assert!(ProtocolFrame::verify_checksum(&pull));

        let receipt = crate::session::CustodyReceipt {
            file_id: 42,
            byte_count: 1024,
            sha256_hex: "a".repeat(64),
            fsynced_at_epoch_sec: 1_700_000_000,
        }
        .verify()
        .expect("valid custody receipt must verify");
        let del = DeviceCommands::delete_file(&receipt);
        assert_eq!(del[5], 0x1A);
        assert_eq!(del[6], 0x10);
        assert_eq!(&del[9..13], &42u32.to_le_bytes());
        assert!(ProtocolFrame::verify_checksum(&del));
    }
}
