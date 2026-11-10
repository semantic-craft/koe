//! Typed domain models for D3200 device telemetry, offline file listings, and
//! BLE advertisement metadata (`PROTOCOL.md`).

use crate::frame::{read_u16_le, read_u32_le, to_hex};

/// Canonical 128-bit BLE GATT service UUID advertised by the soundcore Work (D3200).
pub const D3200_SERVICE_UUID_128: &str = "020cf5da-0000-1000-8000-00805f9b34fb";

/// Matched BLE advertisement identity for a soundcore Work (D3200) recording bean or charging case.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BleAdvertisementMatch {
    /// Human-readable display name (for example `"soundcore Work"` or `"soundcore Work (CC:A3)"`).
    pub display_name: String,
    /// Uppercase 6-byte BLE MAC (`AA:BB:CC:DD:EE:FF`) parsed from manufacturer data when available.
    pub ble_mac: String,
    /// Whether bit 7 (`0x80`) of manufacturer byte 6 indicates an existing binding.
    pub is_bound_advertised: bool,
    /// Whether the peripheral matched via a D3200 service UUID (`020cf5da` / `f5da`).
    pub matched_service_uuid: bool,
    /// Whether the peripheral matched via D3200 manufacturer payload (`soundc` mark or `f5da` signature).
    pub matched_manufacturer_data: bool,
    /// Whether the peripheral matched via advertised local name (`soundcore` / `d3200` / `work`).
    pub matched_local_name: bool,
}

impl BleAdvertisementMatch {
    /// Returns `true` when `uuid` matches the D3200 primary service UUID (`020cf5da` / `daf50c02` / `f5da`).
    #[must_use]
    pub fn is_d3200_service_uuid(uuid: &str) -> bool {
        let lower = uuid.trim().to_ascii_lowercase();
        lower.contains("020cf5da") || lower.contains("daf50c02") || lower.contains("f5da")
    }

    /// Returns `true` when `uuid` matches the D3200 GATT write characteristic (`0x7777`).
    #[must_use]
    pub fn is_write_characteristic_uuid(uuid: &str) -> bool {
        uuid.trim().to_ascii_lowercase().contains("7777")
    }

    /// Returns `true` when `uuid` matches the D3200 GATT notify characteristic (`0x8888`).
    #[must_use]
    pub fn is_notify_characteristic_uuid(uuid: &str) -> bool {
        uuid.trim().to_ascii_lowercase().contains("8888")
    }

    /// Evaluates BLE advertisement fields against the D3200 discovery rules (`PROTOCOL.md` §3.1).
    #[must_use]
    pub fn parse(
        local_name: Option<&str>,
        service_uuids: &[&str],
        manufacturer_payloads: &[&[u8]],
    ) -> Option<Self> {
        let matched_service_uuid = service_uuids
            .iter()
            .any(|uuid| Self::is_d3200_service_uuid(uuid));

        let trimmed_name = local_name.map(str::trim).unwrap_or("");
        let lower_name = trimmed_name.to_ascii_lowercase();
        let matched_local_name = lower_name.contains("soundcore")
            || lower_name.contains("d3200")
            || lower_name.contains("work");

        let mut matched_manufacturer_data = false;
        let mut ble_mac = String::new();
        let mut is_bound_advertised = false;

        for bytes in manufacturer_payloads {
            let offset_10_mark = if bytes.len() >= 16 {
                let mark = String::from_utf8_lossy(&bytes[10..16]).to_ascii_lowercase();
                mark.contains("sound") || mark.contains("scor")
            } else {
                false
            };
            let offset_8_mark = if bytes.len() >= 14 {
                let mark = String::from_utf8_lossy(&bytes[8..14]).to_ascii_lowercase();
                mark.contains("sound") || mark.contains("scor")
            } else {
                false
            };
            let has_uuid_bytes = bytes.windows(4).any(|w| {
                w == [0x02, 0x0c, 0xf5, 0xda] || w == [0xda, 0xf5, 0x0c, 0x02]
            }) || (bytes.len() >= 7
                && bytes
                    .windows(2)
                    .any(|w| w == [0xf5, 0xda] || w == [0xda, 0xf5]));

            if offset_10_mark || offset_8_mark || has_uuid_bytes {
                matched_manufacturer_data = true;
                let base = if offset_10_mark { 2usize } else { 0usize };
                if bytes.len() >= base + 6 {
                    let candidate_mac = DeviceInfoModel::format_mac(&bytes[base..base + 6]);
                    if !candidate_mac.is_empty() {
                        ble_mac = candidate_mac;
                    }
                }
                if let Some(&flags) = bytes.get(base + 6) {
                    is_bound_advertised = (flags & 0x80) != 0;
                }
                break;
            }
        }

        if !matched_service_uuid && !matched_manufacturer_data && !matched_local_name {
            return None;
        }

        if ble_mac.is_empty() {
            for bytes in manufacturer_payloads {
                if bytes.len() >= 6 {
                    let candidate_mac = DeviceInfoModel::format_mac(&bytes[0..6]);
                    if !candidate_mac.is_empty() {
                        ble_mac = candidate_mac;
                        if let Some(&flags) = bytes.get(6) {
                            is_bound_advertised = (flags & 0x80) != 0;
                        }
                        break;
                    }
                }
            }
        }

        let display_name = if !trimmed_name.is_empty() {
            trimmed_name.replace('·', " ")
        } else if ble_mac.len() >= 5 {
            format!("soundcore Work ({})", &ble_mac[ble_mac.len() - 5..])
        } else {
            "soundcore Work".to_string()
        };

        Some(Self {
            display_name,
            ble_mac,
            is_bound_advertised,
            matched_service_uuid,
            matched_manufacturer_data,
            matched_local_name,
        })
    }
}

/// Parsed telemetry and identity state for a connected soundcore Work (D3200).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DeviceInfoModel {
    /// Connection status byte (`0` disconnected, `1` connected).
    pub connect_status: Option<u8>,
    /// Microphone / bean battery percentage (`0..=100`).
    pub battery: Option<u8>,
    /// Whether the microphone bean is currently charging.
    pub charging: bool,
    /// Microphone bean firmware version string.
    pub firmware_version: String,
    /// Lowercase device serial number string.
    pub serial_number: String,
    /// Total storage capacity in kilobytes.
    pub total_memory_kb: Option<u32>,
    /// Free storage capacity in kilobytes.
    pub free_memory_kb: Option<u32>,
    /// Charging case battery percentage (`0..=100`).
    pub box_battery: Option<u8>,
    /// Whether the charging case is currently charging.
    pub box_charging: bool,
    /// Charging case MAC address (`XX:XX:XX:XX:XX:XX`) or empty if unpopulated.
    pub box_mac: String,
    /// Charging case firmware version string.
    pub box_firmware: String,
    /// Wi-Fi module firmware version string.
    pub wifi_firmware: String,
    /// Wire recording state (`0` stopped, `1` recording, `2` paused).
    pub recording_status: u8,
    /// Uppercase space-separated hex dump of the source packet.
    pub raw_hex: String,
}

impl DeviceInfoModel {
    /// Whether the device report includes a non-empty serial number or firmware version.
    #[must_use]
    pub fn has_identity(&self) -> bool {
        !self.serial_number.is_empty() || !self.firmware_version.is_empty()
    }

    /// Whether the device is actively recording (`recording_status == 1`).
    #[must_use]
    pub fn recording(&self) -> bool {
        self.recording_status == 1
    }

    /// Returns the preferred display battery percentage (bean first, then case, else `0`).
    #[must_use]
    pub fn display_battery_percent(&self) -> u8 {
        if let Some(mic) = Self::clamp_pct(self.battery.map(i32::from)) {
            return mic;
        }
        if let Some(box_pct) = Self::clamp_pct(self.box_battery.map(i32::from)) {
            return box_pct;
        }
        0
    }

    /// Formats `used / total` storage from the kilobyte counters, or `"—"` when absent.
    #[must_use]
    pub fn storage_label(&self) -> String {
        let (Some(total_kb), Some(free_kb)) = (self.total_memory_kb, self.free_memory_kb) else {
            return "—".to_string();
        };
        let total = u64::from(total_kb);
        let free = u64::from(free_kb).min(total);
        let used = total - free;
        format!(
            "{} / {}",
            Self::format_storage_kb(used),
            Self::format_storage_kb(total)
        )
    }

    /// Parses a full RX frame using Feishu absolute offsets starting at byte 9.
    #[must_use]
    pub fn parse_packet(raw: &[u8]) -> Self {
        let hex = to_hex(raw);
        if raw.len() < 20 {
            return Self {
                raw_hex: hex,
                ..Self::default()
            };
        }

        let mut o = 9usize;
        let connect_status = raw[o];
        o += 1;
        let battery_raw = i32::from(raw[o]);
        o += 1;
        let battery = Self::battery_remaining(Some(battery_raw)).unwrap_or(0);
        let charging_status = raw[o];
        o += 1;

        let fw = Self::take_ascii(raw, &mut o, 5);
        let sn = Self::take_ascii(raw, &mut o, 16).to_ascii_lowercase();
        let total_mem = Self::read_u32_or_zero(raw, o);
        o = o.saturating_add(4);
        let free_mem = Self::read_u32_or_zero(raw, o);
        o = o.saturating_add(4);

        if o >= raw.len() {
            let payload = if raw.len() > 10 {
                &raw[9..raw.len() - 1]
            } else {
                &[]
            };
            return Self::parse_payload_with_hex(payload, hex);
        }
        let box_charging_flag = raw[o];
        o += 1;
        let box_fw = Self::take_ascii(raw, &mut o, 5);
        if o >= raw.len() {
            let payload = if raw.len() > 10 {
                &raw[9..raw.len() - 1]
            } else {
                &[]
            };
            return Self::parse_payload_with_hex(payload, hex);
        }
        let box_battery_raw = i32::from(raw[o]);
        o += 1;
        let mac_end = (o + 6).min(raw.len());
        let mac_bytes = &raw[o..mac_end];
        o = mac_end;
        let box_mac = Self::format_mac(mac_bytes);

        let mut wifi_fw = String::new();
        let mut recording_status = 0u8;
        let frame_body_end = raw.len().saturating_sub(1);
        if o + 6 <= frame_body_end {
            o += 5;
            if o < frame_body_end {
                recording_status = raw[o];
                o += 1;
            }
            if o + 5 <= frame_body_end {
                wifi_fw = Self::take_ascii(raw, &mut o, 5);
            }
        }

        Self {
            connect_status: Some(connect_status),
            battery: Some(battery),
            charging: charging_status == 1,
            firmware_version: fw,
            serial_number: sn,
            total_memory_kb: Some(total_mem),
            free_memory_kb: Some(free_mem),
            box_battery: Self::battery_remaining(Some(box_battery_raw)),
            box_charging: box_charging_flag == 1,
            box_mac,
            box_firmware: box_fw,
            wifi_firmware: wifi_fw,
            recording_status,
            raw_hex: hex,
        }
    }

    /// Parses a payload slice (starting at frame offset 9) without frame headers.
    #[must_use]
    pub fn parse_payload(payload: &[u8]) -> Self {
        Self::parse_payload_with_hex(payload, String::new())
    }

    /// Parses a payload slice and attaches the caller's `raw_hex` string.
    #[must_use]
    pub fn parse_payload_with_hex(payload: &[u8], raw_hex: String) -> Self {
        if payload.len() < 3 {
            return Self {
                raw_hex,
                ..Self::default()
            };
        }
        let mut o = 0usize;
        let connect_status = payload[o];
        o += 1;
        let battery = Self::battery_remaining(Some(i32::from(payload[o]))).unwrap_or(0);
        o += 1;
        let charging_status = payload[o];
        o += 1;
        let fw = if payload.len() >= 8 {
            Self::take_ascii(payload, &mut o, 5)
        } else {
            String::new()
        };
        let sn = if payload.len() >= 24 {
            Self::take_ascii(payload, &mut o, 16).to_ascii_lowercase()
        } else {
            String::new()
        };

        let mut total_mem = None;
        let mut free_mem = None;
        let mut box_charging = false;
        let mut box_fw = String::new();
        let mut box_battery = None;
        let mut box_mac = String::new();

        if o + 8 <= payload.len() {
            total_mem = Some(read_u32_le(payload, o));
            o += 4;
            free_mem = Some(read_u32_le(payload, o));
            o += 4;
        }
        if o < payload.len() {
            box_charging = payload[o] == 1;
            o += 1;
        }
        if o + 5 <= payload.len() {
            box_fw = Self::take_ascii(payload, &mut o, 5);
        }
        if o < payload.len() {
            box_battery = Self::battery_remaining(Some(i32::from(payload[o])));
            o += 1;
        }
        if o + 6 <= payload.len() {
            box_mac = Self::format_mac(&payload[o..o + 6]);
        }

        Self {
            connect_status: Some(connect_status),
            battery: Some(battery),
            charging: charging_status == 1,
            firmware_version: fw,
            serial_number: sn,
            total_memory_kb: total_mem,
            free_memory_kb: free_mem,
            box_battery,
            box_charging,
            box_mac,
            box_firmware: box_fw,
            wifi_firmware: String::new(),
            recording_status: 0,
            raw_hex,
        }
    }

    /// Converts a raw D3200 battery byte (`0..=9` bucket or literal percentage) to `0..=100`.
    #[must_use]
    pub fn battery_remaining(raw: Option<i32>) -> Option<u8> {
        let clamped = Self::clamp_pct(raw)?;
        if clamped <= 9 {
            Some((clamped + 1) * 10)
        } else {
            Some(clamped)
        }
    }

    /// Formats a 6-byte MAC slice as uppercase `XX:XX:XX:XX:XX:XX`, rejecting all-zero or repeated padding bytes.
    #[must_use]
    pub fn format_mac(mac_bytes: &[u8]) -> String {
        if mac_bytes.len() < 6 {
            return String::new();
        }
        let first = mac_bytes[0];
        let all_same = mac_bytes[..6].iter().all(|&b| b == first);
        let all_zero = mac_bytes[..6].iter().all(|&b| b == 0);
        if all_same || all_zero {
            return String::new();
        }
        let mut out = String::with_capacity(17);
        for (i, &b) in mac_bytes[..6].iter().enumerate() {
            if i > 0 {
                out.push(':');
            }
            let hi = char::from_digit(u32::from(b >> 4), 16)
                .unwrap_or('0')
                .to_ascii_uppercase();
            let lo = char::from_digit(u32::from(b & 0x0F), 16)
                .unwrap_or('0')
                .to_ascii_uppercase();
            out.push(hi);
            out.push(lo);
        }
        out
    }

    /// Formats a kilobyte storage counter using compact `KB`, `MB`, or `GB` units.
    #[must_use]
    pub fn format_storage_kb(value: u64) -> String {
        if value == 0 {
            return "0 MB".to_string();
        }
        if value >= 1024 * 1024 {
            return format!(
                "{} GB",
                Self::compact_decimal(value as f64 / (1024.0 * 1024.0))
            );
        }
        if value >= 1024 {
            return format!("{} MB", Self::compact_decimal(value as f64 / 1024.0));
        }
        format!("{value} KB")
    }

    fn clamp_pct(v: Option<i32>) -> Option<u8> {
        let v = v?;
        if v < 0 {
            return Some(0);
        }
        if v > 100 {
            let masked = (v & 0x7F) as u8;
            if masked <= 100 {
                return Some(masked);
            }
            return Some(100);
        }
        Some(v as u8)
    }

    fn read_u32_or_zero(raw: &[u8], offset: usize) -> u32 {
        if offset + 4 > raw.len() {
            0
        } else {
            read_u32_le(raw, offset)
        }
    }

    fn take_ascii(buf: &[u8], offset: &mut usize, count: usize) -> String {
        let end = (*offset + count).min(buf.len());
        let slice = &buf[*offset..end];
        *offset = end;
        let nul_pos = slice.iter().position(|&b| b == 0).unwrap_or(slice.len());
        String::from_utf8_lossy(&slice[..nul_pos])
            .trim()
            .to_string()
    }

    fn compact_decimal(value: f64) -> String {
        let fixed = format!("{value:.1}");
        if let Some(stripped) = fixed.strip_suffix(".0") {
            stripped.to_string()
        } else {
            fixed
        }
    }
}

/// Metadata for a single recording stored on the D3200 device (`0x1A`/`0x1B` id `0x0E`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OfflineFileEntry {
    /// Device file identifier (typically a UTC Unix timestamp in seconds).
    pub file_id: u32,
    /// Recording duration in milliseconds reported by the listing.
    pub duration_ms: u32,
    /// Recording end timestamp in seconds when queried via `0x1B 0x0E`.
    pub end_time: Option<u32>,
}

impl OfflineFileEntry {
    /// Whether `duration_ms` contains a valid positive duration.
    #[must_use]
    pub fn has_duration(&self) -> bool {
        self.duration_ms > 0 && self.duration_ms != u32::MAX
    }

    /// Estimated wire transfer size in bytes (166-byte records per 20 ms slice).
    #[must_use]
    pub fn estimated_transfer_bytes(&self) -> u64 {
        if self.has_duration() {
            u64::from(self.duration_ms) * 166 / 20
        } else {
            0
        }
    }

    /// Human-readable `H:MM:SS` duration label, or `"时长未知"`.
    #[must_use]
    pub fn duration_label(&self) -> String {
        if !self.has_duration() {
            return "时长未知".to_string();
        }
        let seconds = self.duration_ms / 1000;
        format!(
            "{}:{:02}:{:02}",
            seconds / 3600,
            (seconds / 60) % 60,
            seconds % 60
        )
    }

    /// Human-readable estimated size label (`约 X B/KB/MB`), or `"大小未知"`.
    #[must_use]
    pub fn size_label(&self) -> String {
        if !self.has_duration() {
            return "大小未知".to_string();
        }
        let bytes = self.estimated_transfer_bytes();
        if bytes < 1024 {
            return format!("约 {bytes} B");
        }
        if bytes < 1024 * 1024 {
            return format!("约 {:.1} KB", bytes as f64 / 1024.0);
        }
        format!("约 {:.2} MB", bytes as f64 / (1024.0 * 1024.0))
    }
}

/// Parsed page of offline files returned by `0x1A 0x0E` or `0x1B 0x0E`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct OfflineFileList {
    /// Non-empty file entries on this page.
    pub files: Vec<OfflineFileEntry>,
    /// Total file count header reported by the device.
    pub file_count: u16,
    /// Optional trailing active transport timestamp.
    pub current_transport_timestamp: Option<u32>,
    /// Optional trailing active transport duration.
    pub current_transport_duration: Option<u32>,
}

impl OfflineFileList {
    /// Parses a file-list payload (`with_end_time = false` for `0x1A 0x0E`, `true` for `0x1B 0x0E`).
    #[must_use]
    pub fn parse(payload: &[u8], with_end_time: bool) -> Self {
        if payload.len() < 2 {
            return Self::default();
        }
        let count = read_u16_le(payload, 0);
        let mut o = 2usize;
        let mut files = Vec::new();
        let entry_size = if with_end_time { 12usize } else { 8usize };

        for _ in 0..count {
            if o + entry_size > payload.len() {
                break;
            }
            let file_id = read_u32_le(payload, o);
            o += 4;
            let end_time = if with_end_time {
                let et = read_u32_le(payload, o);
                o += 4;
                Some(et)
            } else {
                None
            };
            let duration_ms = read_u32_le(payload, o);
            o += 4;
            if file_id > 0 && (duration_ms > 0 || end_time == Some(0)) {
                files.push(OfflineFileEntry {
                    file_id,
                    duration_ms,
                    end_time,
                });
            }
        }

        let (curr_ts, curr_dur) = if o + 8 <= payload.len() {
            (
                Some(read_u32_le(payload, o)),
                Some(read_u32_le(payload, o + 4)),
            )
        } else {
            (None, None)
        };

        Self {
            files,
            file_count: count,
            current_transport_timestamp: curr_ts,
            current_transport_duration: curr_dur,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn battery_remaining_expands_buckets_and_preserves_percentages() {
        assert_eq!(DeviceInfoModel::battery_remaining(Some(0)), Some(10));
        assert_eq!(DeviceInfoModel::battery_remaining(Some(2)), Some(30));
        assert_eq!(DeviceInfoModel::battery_remaining(Some(3)), Some(40));
        assert_eq!(DeviceInfoModel::battery_remaining(Some(9)), Some(100));
        assert_eq!(DeviceInfoModel::battery_remaining(Some(100)), Some(100));
        assert_eq!(DeviceInfoModel::battery_remaining(Some(50)), Some(50));
    }

    #[test]
    fn storage_label_scales_kilobyte_counters() {
        let info = DeviceInfoModel {
            total_memory_kb: Some(64 * 1024 * 1024),
            free_memory_kb: Some(60 * 1024 * 1024),
            ..DeviceInfoModel::default()
        };
        assert_eq!(info.storage_label(), "4 GB / 64 GB");
    }

    #[test]
    fn offline_file_list_parses_with_end_time() {
        let payload = [
            1, 0, 100, 0, 0, 0, 200, 0, 0, 0, 44, 1, 0, 0, 144, 1, 0, 0, 244, 1, 0, 0,
        ];
        let page = OfflineFileList::parse(&payload, true);
        assert_eq!(page.file_count, 1);
        assert_eq!(page.files.len(), 1);
        assert_eq!(page.files[0].file_id, 100);
        assert_eq!(page.files[0].end_time, Some(200));
        assert_eq!(page.files[0].duration_ms, 300);
        assert_eq!(page.current_transport_timestamp, Some(400));
        assert_eq!(page.current_transport_duration, Some(500));
    }

    #[test]
    fn ble_advertisement_matches_service_uuid_manufacturer_and_local_name() {
        let by_uuid = BleAdvertisementMatch::parse(
            None,
            &["020cf5da-0000-1000-8000-00805f9b34fb"],
            &[],
        )
        .expect("should match D3200 128-bit service UUID even without local name");
        assert!(by_uuid.matched_service_uuid);
        assert_eq!(by_uuid.display_name, "soundcore Work");

        let mfg: [u8; 14] = [
            0x00, 0x7F, 0x1D, 0x04, 0xCC, 0xA3, 0x90, 0x00, b's', b'o', b'u', b'n', b'd', b'c',
        ];
        let by_mfg = BleAdvertisementMatch::parse(None, &[], &[&mfg])
            .expect("should match D3200 manufacturer data with soundc mark");
        assert!(by_mfg.matched_manufacturer_data);
        assert_eq!(by_mfg.ble_mac, "00:7F:1D:04:CC:A3");
        assert!(by_mfg.is_bound_advertised);
        assert_eq!(by_mfg.display_name, "soundcore Work (CC:A3)");

        let by_name = BleAdvertisementMatch::parse(Some("Anker Soundcore Work"), &[], &[])
            .expect("should match local name");
        assert!(by_name.matched_local_name);

        assert!(BleAdvertisementMatch::parse(Some("AirPods Pro"), &["180A"], &[]).is_none());
        assert!(BleAdvertisementMatch::is_d3200_service_uuid(
            "020CF5DA-0000-1000-8000-00805F9B34FB"
        ));
        assert!(BleAdvertisementMatch::is_write_characteristic_uuid(
            "00007777-0000-1000-8000-00805F9B34FB"
        ));
        assert!(BleAdvertisementMatch::is_notify_characteristic_uuid(
            "00008888-0000-1000-8000-00805F9B34FB"
        ));
    }
}
