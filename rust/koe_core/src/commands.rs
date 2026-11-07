//! High-level D3200 BLE TX command builders and RX command identifiers (`PROTOCOL.md` §5).

use crate::frame::{u16_le, u32_le, ProtocolFrame};

/// Stateless packet builders for D3200 BLE TX commands.
pub struct DeviceCommands;

impl DeviceCommands {
    /// Requests the full device telemetry and identity report (`0x01 0x01`).
    #[must_use]
    pub fn get_device_info() -> Vec<u8> {
        ProtocolFrame::encode(0x01, 0x01, &[])
    }

    /// Resets the device (`0x01 0xB8`).
    #[must_use]
    pub fn reset_device() -> Vec<u8> {
        ProtocolFrame::encode(0x01, 0xB8, &[])
    }

    /// Synchronizes UTC Unix seconds and signed timezone offset in hours (`0x01 0xA6`).
    #[must_use]
    pub fn sync_time(unix_seconds: u32, timezone_hours: i8) -> Vec<u8> {
        let mut payload = Vec::with_capacity(5);
        payload.extend_from_slice(&u32_le(unix_seconds));
        payload.push(timezone_hours as u8);
        ProtocolFrame::encode(0x01, 0xA6, &payload)
    }

    /// Starts recording on the device (`0x18 0x82`, payload `[0x01]`).
    #[must_use]
    pub fn start_record() -> Vec<u8> {
        ProtocolFrame::encode(0x18, 0x82, &[0x01])
    }

    /// Pauses recording on the device (`0x18 0x82`, payload `[0x02]`).
    #[must_use]
    pub fn pause_record() -> Vec<u8> {
        ProtocolFrame::encode(0x18, 0x82, &[0x02])
    }

    /// Requests a page of offline files without end timestamps (`0x1A 0x0E`).
    #[must_use]
    pub fn list_files(page: u16) -> Vec<u8> {
        ProtocolFrame::encode(0x1A, 0x0E, &u16_le(page))
    }

    /// Requests a page of offline files with end timestamps (`0x1B 0x0E`).
    #[must_use]
    pub fn list_files_with_end_time(page: u16) -> Vec<u8> {
        ProtocolFrame::encode(0x1B, 0x0E, &u16_le(page))
    }

    /// Deletes a stored recording by `file_id` (`0x1A 0x10`).
    #[must_use]
    pub fn delete_file(file_id: u32) -> Vec<u8> {
        ProtocolFrame::encode(0x1A, 0x10, &u32_le(file_id))
    }

    /// Enters Bluetooth file transport mode (`0x1A 0x0F`).
    #[must_use]
    pub fn start_bt_transport(is_ios: bool) -> Vec<u8> {
        ProtocolFrame::encode(0x1A, 0x0F, &[u8::from(is_ios)])
    }

    /// Leaves Bluetooth file transport mode (`0x1A 0x11`).
    #[must_use]
    pub fn stop_bt_transport(is_ios: bool) -> Vec<u8> {
        ProtocolFrame::encode(0x1A, 0x11, &[u8::from(is_ios)])
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

    /// Sends SoftAP Wi-Fi credentials (`[ssid_len][ssid][pwd_len][pwd]`, `0x1A 0x05`).
    #[must_use]
    pub fn send_wifi_config(ssid: &str, password: &str) -> Vec<u8> {
        let ssid_bytes = ssid.as_bytes();
        let pwd_bytes = password.as_bytes();
        let mut payload = Vec::with_capacity(2 + ssid_bytes.len() + pwd_bytes.len());
        payload.push((ssid_bytes.len() & 0xFF) as u8);
        payload.extend_from_slice(ssid_bytes);
        payload.push((pwd_bytes.len() & 0xFF) as u8);
        payload.extend_from_slice(pwd_bytes);
        ProtocolFrame::encode(0x1A, 0x05, &payload)
    }

    /// Closes Wi-Fi SoftAP mode (`0x1A 0x02`).
    #[must_use]
    pub fn close_wifi_mode() -> Vec<u8> {
        ProtocolFrame::encode(0x1A, 0x02, &[])
    }

    /// Generates Feishu-compatible SoftAP credentials (`("WiFi-{epoch_ms}", "{epoch_ms}")`).
    #[must_use]
    pub fn generate_wifi_credentials(epoch_ms: u64) -> (String, String) {
        (format!("WiFi-{epoch_ms}"), epoch_ms.to_string())
    }

    /// Builds the fixed 18-byte `0x1A 0x07` WebSocket file header request frame
    /// (`[08 EE 00 00 00 1A 07 12 00 | already_transferred LE | file_id LE | 1B]`, no additive checksum).
    #[must_use]
    pub fn build_wifi_file_request_bytes(file_id: u32, already_transferred: u32) -> [u8; 18] {
        let t = u32_le(already_transferred);
        let f = u32_le(file_id);
        [
            0x08, 0xEE, 0x00, 0x00, 0x00, 0x1A, 0x07, 0x12, 0x00, t[0], t[1], t[2], t[3], f[0],
            f[1], f[2], f[3], 0x1B,
        ]
    }

    /// Formats `build_wifi_file_request_bytes` as a 36-character lowercase hex string for WebSocket TX.
    #[must_use]
    pub fn build_wifi_file_request_hex(file_id: u32, already_transferred: u32) -> String {
        let raw = Self::build_wifi_file_request_bytes(file_id, already_transferred);
        let mut out = String::with_capacity(36);
        for &b in &raw {
            out.push(char::from_digit(u32::from(b >> 4), 16).unwrap_or('0'));
            out.push(char::from_digit(u32::from(b & 0x0F), 16).unwrap_or('0'));
        }
        out
    }

    /// Returns the 22-character lowercase hex `0x1A 0x0A` WebSocket transfer-complete frame
    /// (`"08ee0000001a0a0b000126"`).
    #[must_use]
    pub fn wifi_transfer_complete_hex() -> String {
        "08ee0000001a0a0b000126".to_string()
    }

    /// Sends the app's uncompressed P-256 ECDH public key (`0x2E 0x01`).
    #[must_use]
    pub fn notify_encrypt_public_key(public_key_bytes: &[u8]) -> Vec<u8> {
        ProtocolFrame::encode(0x2E, 0x01, public_key_bytes)
    }

    /// Binds the device (`0x0B 0x87`, payload `[0x01]`).
    #[must_use]
    pub fn bind() -> Vec<u8> {
        ProtocolFrame::encode(0x0B, 0x87, &[0x01])
    }

    /// Unbinds the device (`0x0B 0x87`, payload `[0x00]`).
    #[must_use]
    pub fn unbind() -> Vec<u8> {
        ProtocolFrame::encode(0x0B, 0x87, &[0x00])
    }

    /// Sends an arbitrary bind/unbind payload (`0x0B 0x87`).
    #[must_use]
    pub fn bind_raw(payload: &[u8]) -> Vec<u8> {
        ProtocolFrame::encode(0x0B, 0x87, payload)
    }

    /// Toggles the Find My feature (`0x10 0xA2`).
    #[must_use]
    pub fn set_find_my(enable: bool) -> Vec<u8> {
        ProtocolFrame::encode(0x10, 0xA2, &[u8::from(enable)])
    }
}

/// Known RX command types and identifiers used for packet dispatch.
pub struct RxCmd;

impl RxCmd {
    /// Device info command family (`0x01`).
    pub const DEVICE_INFO_TYPE: u8 = 0x01;
    /// Device info report (`0x01`).
    pub const DEVICE_INFO_ID: u8 = 0x01;
    /// Battery change notification (`0x03`).
    pub const BATTERY_ID: u8 = 0x03;
    /// Charging status notification (`0x04`).
    pub const CHARGING_ID: u8 = 0x04;
    /// Time sync response (`0xA6`).
    pub const SYNC_TIME_ID: u8 = 0xA6;
    /// Device reset response (`0xB8`).
    pub const RESET_ID: u8 = 0xB8;

    /// Audio control command family (`0x18`).
    pub const AUDIO_TYPE: u8 = 0x18;
    /// Start/pause recording command id (`0x82`).
    pub const AUDIO_CONTROL_ID: u8 = 0x82;

    /// Primary file transport command family (`0x1A`).
    pub const TRANSPORT_TYPE: u8 = 0x1A;
    /// Alternate file transport command family with end timestamps (`0x1B`).
    pub const TRANSPORT_TYPE_ALT: u8 = 0x1B;
    /// Wi-Fi SoftAP close id (`0x02`).
    pub const WIFI_CLOSE_ID: u8 = 0x02;
    /// Wi-Fi SoftAP config id (`0x05`).
    pub const WIFI_CONFIG_ID: u8 = 0x05;
    /// Realtime recording status notification (`0x06`).
    pub const RECORD_STATUS_ID: u8 = 0x06;
    /// File stream header (`0x07`).
    pub const FILE_HEAD_ID: u8 = 0x07;
    /// Encrypted Opus audio slice (`0x08`).
    pub const FILE_SLICE_ID: u8 = 0x08;
    /// File transfer completed notification (`0x0A`).
    pub const FILE_DONE_ID: u8 = 0x0A;
    /// File list page response (`0x0E`).
    pub const FILE_LIST_ID: u8 = 0x0E;
    /// Bluetooth transport mode response (`0x0F`).
    pub const BT_STATUS_ID: u8 = 0x0F;
    /// File deletion response (`0x10`).
    pub const DELETE_ID: u8 = 0x10;
    ///Marked audio slice notification (`0x12`).
    pub const FILE_SLICE_MARK_ID: u8 = 0x12;

    /// Binding command family (`0x0B`).
    pub const BIND_TYPE: u8 = 0x0B;
    /// Bind/unbind result id (`0x87`).
    pub const BIND_RESULT_ID: u8 = 0x87;
    /// Hardware double-tap bind confirmation id (`0x88`).
    pub const BIND_CONFIRM_ID: u8 = 0x88;

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

        let wifi = DeviceCommands::send_wifi_config("WiFi-1", "123");
        assert_eq!(wifi[5], 0x1A);
        assert_eq!(wifi[6], 0x05);
        assert_eq!(wifi[9], 6);
        assert_eq!(&wifi[10..16], b"WiFi-1");
        assert_eq!(wifi[16], 3);
        assert_eq!(&wifi[17..20], b"123");
        assert!(ProtocolFrame::verify_checksum(&wifi));

        let (ssid, pwd) = DeviceCommands::generate_wifi_credentials(1_761_100_000_000);
        assert_eq!(ssid, "WiFi-1761100000000");
        assert_eq!(pwd, "1761100000000");

        let req_bytes = DeviceCommands::build_wifi_file_request_bytes(0x0102_0304, 332);
        assert_eq!(req_bytes.len(), 18);
        assert_eq!(req_bytes[17], 0x1B);
        let req_hex = DeviceCommands::build_wifi_file_request_hex(0x0102_0304, 332);
        assert_eq!(req_hex.len(), 36);
        assert_eq!(req_hex, "08ee0000001a0712004c010000040302011b");
        assert_eq!(
            DeviceCommands::wifi_transfer_complete_hex(),
            "08ee0000001a0a0b000126"
        );
    }
}
