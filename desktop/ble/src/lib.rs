//! Pure-Rust macOS `CoreBluetooth` adapter (`CBCentralManagerDelegate` + `CBPeripheralDelegate`)
//! for Soundcore Work (`D3200`) BLE scanning, GATT service/characteristic discovery
//! (`0xF5DA` service, `0x7777` write without response, `0x8888` notifications), and frame I/O.

#![deny(missing_docs)]

#[cfg(not(target_os = "macos"))]
use std::sync::mpsc;

/// D3200 primary BLE advertisement and GATT service UUID (`020CF5DA-0000-1000-8000-00805F9B34FB`).
pub const D3200_SERVICE_UUID: &str = "020CF5DA-0000-1000-8000-00805F9B34FB";

/// D3200 GATT write-without-response characteristic UUID (`00007777-0000-1000-8000-00805F9B34FB`).
pub const D3200_WRITE_UUID: &str = "00007777-0000-1000-8000-00805F9B34FB";

/// D3200 GATT notification characteristic UUID (`00008888-0000-1000-8000-00805F9B34FB`).
pub const D3200_NOTIFY_UUID: &str = "00008888-0000-1000-8000-00805F9B34FB";

/// Classification of a discovered GATT characteristic UUID on a D3200 peripheral.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GattCharacteristicKind {
    /// Outbound TX write characteristic (`0x7777`).
    WriteTx,
    /// Inbound RX notification characteristic (`0x8888`).
    NotifyRx,
    /// Unrelated GATT characteristic.
    Other,
}

/// Events emitted by [`MacBleController`] to the GPUI desktop host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BleEvent {
    /// CoreBluetooth central is powered on and actively scanning for a D3200 bean.
    Scanning,
    /// CoreBluetooth is unavailable, unauthorized, or powered off.
    Unavailable(String),
    /// Discovered a matching D3200 peripheral and started GATT connection.
    Connecting(String),
    /// Both `0x7777` write and `0x8888` notify characteristics are ready for `2E/01` handshake.
    GattReady(String),
    /// Received a raw BLE notification payload on `0x8888`.
    Notification(Vec<u8>),
    /// Peripheral disconnected (with an optional error description).
    Disconnected(Option<String>),
}

/// Returns `true` when a BLE advertisement's local name or service UUIDs match a Soundcore Work (`D3200`) bean.
#[must_use]
pub fn matches_d3200_advertisement(name: Option<&str>, service_uuids: &[String]) -> bool {
    if service_uuids.iter().any(|u| {
        let up = u.to_ascii_uppercase();
        up.contains("F5DA") || up == D3200_SERVICE_UUID
    }) {
        return true;
    }
    if let Some(n) = name {
        let lower = n.to_ascii_lowercase();
        if lower.contains("soundcore") || lower.contains("work") || lower.contains("d3200") {
            return true;
        }
    }
    false
}

/// Classifies a GATT characteristic UUID string into [`GattCharacteristicKind`].
#[must_use]
pub fn classify_characteristic_uuid(uuid: &str) -> GattCharacteristicKind {
    let up = uuid.trim().to_ascii_uppercase();
    if up == "7777" || up == D3200_WRITE_UUID || up.starts_with("00007777-") {
        GattCharacteristicKind::WriteTx
    } else if up == "8888" || up == D3200_NOTIFY_UUID || up.starts_with("00008888-") {
        GattCharacteristicKind::NotifyRx
    } else {
        GattCharacteristicKind::Other
    }
}

#[cfg(target_os = "macos")]
mod macos {
    use super::{
        classify_characteristic_uuid, matches_d3200_advertisement, BleEvent, GattCharacteristicKind,
    };
    use objc2::rc::Retained;
    use objc2::runtime::{AnyObject, Bool};
    use objc2::{class, define_class, msg_send, AnyThread, DefinedClass};
    use objc2_foundation::{ns_string, NSData, NSObject, NSString};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{mpsc, Mutex};

    pub struct KoeBleDelegateIvars {
        tx: mpsc::Sender<BleEvent>,
        peripheral: Mutex<Option<Retained<AnyObject>>>,
        write_char: Mutex<Option<Retained<AnyObject>>>,
        notify_ready: AtomicBool,
        gatt_announced: AtomicBool,
        want_scan: AtomicBool,
    }

    define_class!(
        #[unsafe(super(NSObject))]
        #[name = "KoePureRustBleDelegate"]
        #[ivars = KoeBleDelegateIvars]
        pub struct KoeBleDelegate;

        impl KoeBleDelegate {
            #[unsafe(method(centralManagerDidUpdateState:))]
            fn central_did_update_state(&self, central: &AnyObject) {
                let state: isize = unsafe { msg_send![central, state] };
                match state {
                    5 => {
                        if self.ivars().want_scan.load(Ordering::SeqCst) {
                            Self::begin_scan_on_central(central);
                            let _ = self.ivars().tx.send(BleEvent::Scanning);
                        }
                    }
                    4 => {
                        let _ = self
                            .ivars()
                            .tx
                            .send(BleEvent::Unavailable("系统蓝牙当前已关闭".to_string()));
                    }
                    3 => {
                        let _ = self
                            .ivars()
                            .tx
                            .send(BleEvent::Unavailable("系统蓝牙权限未授权".to_string()));
                    }
                    2 => {
                        let _ = self
                            .ivars()
                            .tx
                            .send(BleEvent::Unavailable("当前设备不支持 BLE".to_string()));
                    }
                    _ => {}
                }
            }

            #[unsafe(method(centralManager:didDiscoverPeripheral:advertisementData:RSSI:))]
            fn did_discover_peripheral(
                &self,
                central: &AnyObject,
                peripheral: &AnyObject,
                adv_data: &AnyObject,
                _rssi: &AnyObject,
            ) {
                if self
                    .ivars()
                    .peripheral
                    .lock()
                    .ok()
                    .is_some_and(|g| g.is_some())
                {
                    return;
                }
                let periph_name = Self::extract_peripheral_name(peripheral, Some(adv_data));
                let service_uuids = Self::extract_adv_service_uuids(adv_data);
                if !matches_d3200_advertisement(periph_name.as_deref(), &service_uuids) {
                    return;
                }

                let display_name =
                    periph_name.unwrap_or_else(|| "Soundcore Work (D3200)".to_string());
                let Some(retained_periph) = (unsafe { Retained::retain(peripheral as *const AnyObject as *mut AnyObject) }) else {
                    return;
                };
                if let Ok(mut slot) = self.ivars().peripheral.lock() {
                    *slot = Some(retained_periph);
                }
                if let Ok(mut w_slot) = self.ivars().write_char.lock() {
                    *w_slot = None;
                }
                self.ivars().notify_ready.store(false, Ordering::SeqCst);
                self.ivars().gatt_announced.store(false, Ordering::SeqCst);
                self.ivars().want_scan.store(false, Ordering::SeqCst);

                unsafe {
                    let _: () = msg_send![peripheral, setDelegate: self];
                    let _: () = msg_send![central, stopScan];
                    let null_opts: Option<&AnyObject> = None;
                    let _: () =
                        msg_send![central, connectPeripheral: peripheral, options: null_opts];
                }
                let _ = self.ivars().tx.send(BleEvent::Connecting(display_name));
            }

            #[unsafe(method(centralManager:didConnectPeripheral:))]
            fn did_connect_peripheral(&self, _central: &AnyObject, peripheral: &AnyObject) {
                unsafe {
                    let _: () = msg_send![peripheral, setDelegate: self];
                    let null_services: Option<&AnyObject> = None;
                    let _: () = msg_send![peripheral, discoverServices: null_services];
                }
            }

            #[unsafe(method(centralManager:didFailToConnectPeripheral:error:))]
            fn did_fail_to_connect(
                &self,
                _central: &AnyObject,
                _peripheral: &AnyObject,
                _error: Option<&AnyObject>,
            ) {
                self.clear_connection_state();
                let _ = self
                    .ivars()
                    .tx
                    .send(BleEvent::Disconnected(Some("连接录音豆失败".to_string())));
            }

            #[unsafe(method(centralManager:didDisconnectPeripheral:error:))]
            fn did_disconnect_peripheral(
                &self,
                _central: &AnyObject,
                _peripheral: &AnyObject,
                _error: Option<&AnyObject>,
            ) {
                self.clear_connection_state();
                let _ = self.ivars().tx.send(BleEvent::Disconnected(None));
            }

            #[unsafe(method(peripheral:didDiscoverServices:))]
            fn did_discover_services(
                &self,
                peripheral: &AnyObject,
                _error: Option<&AnyObject>,
            ) {
                unsafe {
                    let services: Option<&AnyObject> = msg_send![peripheral, services];
                    let Some(services) = services else {
                        return;
                    };
                    let count: usize = msg_send![services, count];
                    for idx in 0..count {
                        let service: *const AnyObject = msg_send![services, objectAtIndex: idx];
                        if !service.is_null() {
                            let null_chars: Option<&AnyObject> = None;
                            let _: () = msg_send![
                                peripheral,
                                discoverCharacteristics: null_chars,
                                forService: &*service
                            ];
                        }
                    }
                }
            }

            #[unsafe(method(peripheral:didDiscoverCharacteristicsForService:error:))]
            fn did_discover_characteristics(
                &self,
                peripheral: &AnyObject,
                service: &AnyObject,
                _error: Option<&AnyObject>,
            ) {
                unsafe {
                    let chars: Option<&AnyObject> = msg_send![service, characteristics];
                    let Some(chars) = chars else {
                        return;
                    };
                    let count: usize = msg_send![chars, count];
                    for idx in 0..count {
                        let ch_ptr: *const AnyObject = msg_send![chars, objectAtIndex: idx];
                        if ch_ptr.is_null() {
                            continue;
                        }
                        let ch = &*ch_ptr;
                        let Some(uuid_str) = Self::extract_uuid_string(ch) else {
                            continue;
                        };
                        match classify_characteristic_uuid(&uuid_str) {
                            GattCharacteristicKind::WriteTx => {
                                if let Some(retained_ch) =
                                    Retained::retain(ch_ptr as *mut AnyObject)
                                {
                                    if let Ok(mut w_slot) = self.ivars().write_char.lock() {
                                        *w_slot = Some(retained_ch);
                                    }
                                }
                            }
                            GattCharacteristicKind::NotifyRx => {
                                let _: () = msg_send![
                                    peripheral,
                                    setNotifyValue: Bool::YES,
                                    forCharacteristic: ch
                                ];
                            }
                            GattCharacteristicKind::Other => {}
                        }
                    }
                }
                self.check_and_announce_gatt_ready(peripheral);
            }

            #[unsafe(method(peripheral:didUpdateNotificationStateForCharacteristic:error:))]
            fn did_update_notification_state(
                &self,
                peripheral: &AnyObject,
                characteristic: &AnyObject,
                error: Option<&AnyObject>,
            ) {
                if error.is_some() {
                    return;
                }
                if let Some(uuid_str) = Self::extract_uuid_string(characteristic) {
                    if classify_characteristic_uuid(&uuid_str) == GattCharacteristicKind::NotifyRx {
                        self.ivars().notify_ready.store(true, Ordering::SeqCst);
                        self.check_and_announce_gatt_ready(peripheral);
                    }
                }
            }

            #[unsafe(method(peripheral:didUpdateValueForCharacteristic:error:))]
            fn did_update_value(
                &self,
                _peripheral: &AnyObject,
                characteristic: &AnyObject,
                error: Option<&AnyObject>,
            ) {
                if error.is_some() {
                    return;
                }
                unsafe {
                    let value: Option<&NSData> = msg_send![characteristic, value];
                    if let Some(data) = value {
                        let bytes = data.to_vec();
                        if !bytes.is_empty() {
                            let _ = self.ivars().tx.send(BleEvent::Notification(bytes));
                        }
                    }
                }
            }
        }
    );

    impl KoeBleDelegate {
        fn new(tx: mpsc::Sender<BleEvent>) -> Retained<Self> {
            let this = Self::alloc().set_ivars(KoeBleDelegateIvars {
                tx,
                peripheral: Mutex::new(None),
                write_char: Mutex::new(None),
                notify_ready: AtomicBool::new(false),
                gatt_announced: AtomicBool::new(false),
                want_scan: AtomicBool::new(false),
            });
            unsafe { msg_send![super(this), init] }
        }

        fn begin_scan_on_central(central: &AnyObject) {
            unsafe {
                let null_services: Option<&AnyObject> = None;
                let null_options: Option<&AnyObject> = None;
                let _: () = msg_send![
                    central,
                    scanForPeripheralsWithServices: null_services,
                    options: null_options
                ];
            }
        }

        fn clear_connection_state(&self) {
            if let Ok(mut p) = self.ivars().peripheral.lock() {
                *p = None;
            }
            if let Ok(mut w) = self.ivars().write_char.lock() {
                *w = None;
            }
            self.ivars().notify_ready.store(false, Ordering::SeqCst);
            self.ivars().gatt_announced.store(false, Ordering::SeqCst);
        }

        fn check_and_announce_gatt_ready(&self, peripheral: &AnyObject) {
            let has_write = self
                .ivars()
                .write_char
                .lock()
                .ok()
                .is_some_and(|w| w.is_some());
            if has_write
                && self.ivars().notify_ready.load(Ordering::SeqCst)
                && !self.ivars().gatt_announced.swap(true, Ordering::SeqCst)
            {
                let name = Self::extract_peripheral_name(peripheral, None)
                    .unwrap_or_else(|| "Soundcore Work (D3200)".to_string());
                let _ = self.ivars().tx.send(BleEvent::GattReady(name));
            }
        }

        fn extract_uuid_string(obj: &AnyObject) -> Option<String> {
            unsafe {
                let uuid_obj: Option<&AnyObject> = msg_send![obj, UUID];
                let uuid_obj = uuid_obj?;
                let uuid_ns: Option<&NSString> = msg_send![uuid_obj, UUIDString];
                uuid_ns.map(ToString::to_string)
            }
        }

        fn extract_peripheral_name(
            peripheral: &AnyObject,
            adv_data: Option<&AnyObject>,
        ) -> Option<String> {
            unsafe {
                let name_ns: Option<&NSString> = msg_send![peripheral, name];
                if let Some(s) = name_ns {
                    let text = s.to_string();
                    if !text.trim().is_empty() {
                        return Some(text);
                    }
                }
                if let Some(adv) = adv_data {
                    let key = ns_string!("kCBAdvDataLocalName");
                    let val: Option<&NSString> = msg_send![adv, objectForKey: key];
                    if let Some(s) = val {
                        let text = s.to_string();
                        if !text.trim().is_empty() {
                            return Some(text);
                        }
                    }
                }
            }
            None
        }

        fn extract_adv_service_uuids(adv_data: &AnyObject) -> Vec<String> {
            let mut out = Vec::new();
            unsafe {
                let key = ns_string!("kCBAdvDataServiceUUIDs");
                let arr: Option<&AnyObject> = msg_send![adv_data, objectForKey: key];
                let Some(arr) = arr else {
                    return out;
                };
                let count: usize = msg_send![arr, count];
                for idx in 0..count {
                    let item: *const AnyObject = msg_send![arr, objectAtIndex: idx];
                    if !item.is_null() {
                        let uuid_ns: Option<&NSString> = msg_send![&*item, UUIDString];
                        if let Some(s) = uuid_ns {
                            out.push(s.to_string());
                        }
                    }
                }
            }
            out
        }
    }

    /// Stateful macOS `CoreBluetooth` controller for scanning and talking to a D3200 bean.
    pub struct MacBleController {
        delegate: Retained<KoeBleDelegate>,
        central: Option<Retained<AnyObject>>,
    }

    impl MacBleController {
        /// Creates an unstarted BLE controller and its event receiver channel.
        #[must_use]
        pub fn new() -> (Self, mpsc::Receiver<BleEvent>) {
            let (tx, rx) = mpsc::channel();
            let delegate = KoeBleDelegate::new(tx);
            (
                Self {
                    delegate,
                    central: None,
                },
                rx,
            )
        }

        /// Starts (or restarts) CoreBluetooth scanning for a Soundcore Work (`D3200`) bean.
        pub fn start_scan(&mut self) {
            self.delegate.ivars().want_scan.store(true, Ordering::SeqCst);
            self.delegate.clear_connection_state();
            if self.central.is_none() {
                let central: Option<Retained<AnyObject>> = unsafe {
                    let cls = class!(CBCentralManager);
                    let null_queue: Option<&AnyObject> = None;
                    msg_send![
                        msg_send![cls, alloc],
                        initWithDelegate: &*self.delegate,
                        queue: null_queue
                    ]
                };
                self.central = central;
            }
            if let Some(ref central) = self.central {
                let state: isize = unsafe { msg_send![&**central, state] };
                if state == 5 {
                    KoeBleDelegate::begin_scan_on_central(central);
                    let _ = self.delegate.ivars().tx.send(BleEvent::Scanning);
                } else {
                    let _ = self.delegate.ivars().tx.send(BleEvent::Scanning);
                }
            } else {
                let _ = self
                    .delegate
                    .ivars()
                    .tx
                    .send(BleEvent::Unavailable("无法初始化 CoreBluetooth".to_string()));
            }
        }

        /// Writes an encoded D3200 TX frame (`0x08 0xEE ...`) to GATT characteristic `0x7777`
        /// using `CBCharacteristicWriteWithoutResponse` (`1`).
        pub fn send_frame(&self, frame: &[u8]) -> bool {
            let Ok(periph_guard) = self.delegate.ivars().peripheral.lock() else {
                return false;
            };
            let Ok(write_guard) = self.delegate.ivars().write_char.lock() else {
                return false;
            };
            let (Some(ref peripheral), Some(ref write_char)) = (&*periph_guard, &*write_guard)
            else {
                return false;
            };
            let data = NSData::with_bytes(frame);
            unsafe {
                let write_without_response: isize = 1;
                let _: () = msg_send![
                    &**peripheral,
                    writeValue: &*data,
                    forCharacteristic: &**write_char,
                    type: write_without_response
                ];
            }
            true
        }
    }
}

#[cfg(target_os = "macos")]
pub use macos::MacBleController;

#[cfg(not(target_os = "macos"))]
/// Fallback BLE controller stub on non-macOS targets.
pub struct MacBleController {
    tx: mpsc::Sender<BleEvent>,
}

#[cfg(not(target_os = "macos"))]
impl MacBleController {
    /// Creates a new stub controller and receiver.
    #[must_use]
    pub fn new() -> (Self, mpsc::Receiver<BleEvent>) {
        let (tx, rx) = mpsc::channel();
        (Self { tx }, rx)
    }

    /// Reports BLE unavailability on non-macOS targets.
    pub fn start_scan(&mut self) {
        let _ = self
            .tx
            .send(BleEvent::Unavailable("仅 macOS 支持 CoreBluetooth".to_string()));
    }

    /// Returns `false` on non-macOS targets.
    pub fn send_frame(&self, _frame: &[u8]) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_d3200_advertisement_by_uuid_or_name() {
        assert!(matches_d3200_advertisement(
            None,
            &[D3200_SERVICE_UUID.to_string()]
        ));
        assert!(matches_d3200_advertisement(
            None,
            &["f5da".to_string()]
        ));
        assert!(matches_d3200_advertisement(
            Some("Soundcore Work"),
            &[]
        ));
        assert!(matches_d3200_advertisement(
            Some("Anker D3200 Bean"),
            &[]
        ));
        assert!(!matches_d3200_advertisement(
            Some("Magic Mouse"),
            &["180A".to_string()]
        ));
    }

    #[test]
    fn classifies_gatt_characteristic_uuids() {
        assert_eq!(
            classify_characteristic_uuid(D3200_WRITE_UUID),
            GattCharacteristicKind::WriteTx
        );
        assert_eq!(
            classify_characteristic_uuid("7777"),
            GattCharacteristicKind::WriteTx
        );
        assert_eq!(
            classify_characteristic_uuid(D3200_NOTIFY_UUID),
            GattCharacteristicKind::NotifyRx
        );
        assert_eq!(
            classify_characteristic_uuid("8888"),
            GattCharacteristicKind::NotifyRx
        );
        assert_eq!(
            classify_characteristic_uuid("2A29"),
            GattCharacteristicKind::Other
        );
    }

    #[test]
    fn mac_ble_controller_constructs_cleanly_without_connected_bean() {
        let (controller, _rx) = MacBleController::new();
        assert!(!controller.send_frame(&[0x08, 0xEE]));
    }
}
