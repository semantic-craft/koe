use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use koe_engine::{
    crypto::DeviceCrypto,
    frame::{ProtocolFrame, RX_MAGIC},
    session::{ConnectionPhaseTag, TransportSession},
};
use koe_runtime::KoeRuntime;
use serde_json::{json, Value};

use crate::checker::{
    check_liveness, explore_bfs, format_trace, LivenessOutcome, ModelOutcome, ProtocolModel,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum ConnPhase {
    Disconnected,
    Handshaking,
    Connected,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum AllDayPhase {
    Off,
    Active,
    Stopping,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum QuitPhase {
    Running,
    Draining,
    Blocked,
    Ready,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct BleState {
    conn: ConnPhase,
    explicit_disconnect: bool,
    file_decryption_ready: bool,
    device_recording: bool,
    active_realtime: bool,
    has_slices: bool,
    quiet_drain: Option<u8>,
    awaiting_stop: bool,
    stop_tx_pending: bool,
    all_day: AllDayPhase,
    quitting: bool,
    quit_phase: QuitPhase,
    started_budget: u8,
    drop_budget: u8,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum BleAction {
    ConnectStart,
    HandshakeComplete,
    StartRealtime { with_all_day: bool },
    ReceiveSlice,
    StopRecording,
    RetryStop,
    DeviceAckStop,
    QuietDrainTick,
    FinalizeTransfer,
    LinkDrop,
    ExplicitDisconnect,
    OrphanSliceAfterDisconnect,
    RequestQuit,
    ReconcileAllDay,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum BleMutant {
    Clean,
    Pr613MissingStopRetryOnReconnect,
    Pr613RetryStopResetsQuietDrain,
    Pr650OrphanSliceFabricatesFileIdAfterDisconnect,
    Pr676FinalizeClearsFileDecryption,
    Pr704DisconnectLeavesAllDayTrapped,
}

struct BleSessionModel {
    mutant: BleMutant,
}

impl BleState {
    fn compute_quit_phase(&self) -> QuitPhase {
        if !self.quitting {
            return QuitPhase::Running;
        }
        if self.awaiting_stop && self.conn != ConnPhase::Connected {
            return QuitPhase::Blocked;
        }
        let owned = self.active_realtime
            || self.device_recording
            || self.awaiting_stop
            || self.has_slices
            || self.all_day != AllDayPhase::Off;
        if owned {
            QuitPhase::Draining
        } else {
            QuitPhase::Ready
        }
    }

    fn refresh_quit(&mut self) {
        self.quit_phase = self.compute_quit_phase();
    }
}

impl ProtocolModel for BleSessionModel {
    type State = BleState;
    type Action = BleAction;

    fn init(&self) -> Vec<BleState> {
        vec![BleState {
            conn: ConnPhase::Connected,
            explicit_disconnect: false,
            file_decryption_ready: false,
            device_recording: false,
            active_realtime: false,
            has_slices: false,
            quiet_drain: None,
            awaiting_stop: false,
            stop_tx_pending: false,
            all_day: AllDayPhase::Off,
            quitting: false,
            quit_phase: QuitPhase::Running,
            started_budget: 2,
            drop_budget: 1,
        }]
    }

    fn actions(&self, s: &BleState) -> Vec<BleAction> {
        let mut acts = Vec::new();
        match s.conn {
            ConnPhase::Disconnected => {
                if s.explicit_disconnect {
                    acts.push(BleAction::OrphanSliceAfterDisconnect);
                }
                if !s.explicit_disconnect || s.awaiting_stop || s.quitting {
                    acts.push(BleAction::ConnectStart);
                }
            }
            ConnPhase::Handshaking => {
                acts.push(BleAction::HandshakeComplete);
            }
            ConnPhase::Connected => {
                if !s.quitting
                    && !s.active_realtime
                    && !s.device_recording
                    && !s.awaiting_stop
                    && s.all_day == AllDayPhase::Off
                    && s.started_budget > 0
                {
                    acts.push(BleAction::StartRealtime { with_all_day: false });
                    acts.push(BleAction::StartRealtime { with_all_day: true });
                }
                if s.active_realtime && !s.has_slices {
                    acts.push(BleAction::ReceiveSlice);
                }
                if (s.device_recording || s.active_realtime) && !s.awaiting_stop {
                    acts.push(BleAction::StopRecording);
                }
                if s.awaiting_stop {
                    acts.push(BleAction::RetryStop);
                }
                if s.stop_tx_pending {
                    acts.push(BleAction::DeviceAckStop);
                }
                if let Some(d) = s.quiet_drain {
                    if d < 2 {
                        acts.push(BleAction::QuietDrainTick);
                    }
                }
                if s.active_realtime && s.has_slices && s.quiet_drain.is_none() {
                    acts.push(BleAction::FinalizeTransfer);
                }
                if s.drop_budget > 0 {
                    acts.push(BleAction::LinkDrop);
                    if !s.quitting {
                        acts.push(BleAction::ExplicitDisconnect);
                    }
                }
                if !s.quitting && (s.active_realtime || s.awaiting_stop) {
                    acts.push(BleAction::RequestQuit);
                }
            }
        }
        if s.all_day != AllDayPhase::Off {
            acts.push(BleAction::ReconcileAllDay);
        }
        acts
    }

    fn step(&self, s: &BleState, action: &BleAction) -> Vec<BleState> {
        let mut next = *s;

        match *action {
            BleAction::ConnectStart => {
                next.explicit_disconnect = false;
                next.conn = ConnPhase::Handshaking;
                next.file_decryption_ready = false;
                next.stop_tx_pending = false;
            }
            BleAction::HandshakeComplete => {
                next.conn = ConnPhase::Connected;
                if next.awaiting_stop
                    && self.mutant != BleMutant::Pr613MissingStopRetryOnReconnect
                {
                    next.stop_tx_pending = true;
                }
            }
            BleAction::StartRealtime { with_all_day } => {
                next.started_budget -= 1;
                next.device_recording = true;
                next.active_realtime = true;
                next.file_decryption_ready = true;
                next.quiet_drain = None;
                next.has_slices = false;
                if with_all_day {
                    next.all_day = AllDayPhase::Active;
                }
            }
            BleAction::ReceiveSlice => {
                next.has_slices = true;
            }
            BleAction::StopRecording => {
                next.awaiting_stop = true;
                next.device_recording = false;
                next.stop_tx_pending = true;
                if next.active_realtime && next.quiet_drain.is_none() {
                    next.quiet_drain = Some(0);
                }
                if next.all_day == AllDayPhase::Active {
                    next.all_day = AllDayPhase::Stopping;
                }
            }
            BleAction::RetryStop => {
                next.stop_tx_pending = true;
                if self.mutant == BleMutant::Pr613RetryStopResetsQuietDrain
                    && next.quiet_drain.is_some()
                {
                    next.quiet_drain = Some(0);
                }
            }
            BleAction::DeviceAckStop => {
                next.stop_tx_pending = false;
                next.awaiting_stop = false;
                next.device_recording = false;
                if next.active_realtime && next.quiet_drain.is_none() {
                    next.quiet_drain = Some(0);
                }
            }
            BleAction::QuietDrainTick => {
                if let Some(d) = next.quiet_drain {
                    if d + 1 >= 2 {
                        next.active_realtime = false;
                        next.has_slices = false;
                        next.quiet_drain = None;
                        if self.mutant == BleMutant::Pr676FinalizeClearsFileDecryption {
                            next.file_decryption_ready = false;
                        }
                    } else {
                        next.quiet_drain = Some(d + 1);
                    }
                }
            }
            BleAction::FinalizeTransfer => {
                next.active_realtime = false;
                next.has_slices = false;
                next.quiet_drain = None;
                next.device_recording = false;
                if self.mutant == BleMutant::Pr676FinalizeClearsFileDecryption {
                    next.file_decryption_ready = false;
                }
            }
            BleAction::LinkDrop => {
                next.drop_budget -= 1;
                next.conn = ConnPhase::Disconnected;
                next.file_decryption_ready = false;
                next.device_recording = false;
                next.active_realtime = false;
                next.has_slices = false;
                next.quiet_drain = None;
                next.stop_tx_pending = false;
            }
            BleAction::ExplicitDisconnect => {
                next.drop_budget -= 1;
                next.conn = ConnPhase::Disconnected;
                next.explicit_disconnect = true;
                next.file_decryption_ready = false;
                next.device_recording = false;
                next.active_realtime = false;
                next.has_slices = false;
                next.quiet_drain = None;
                next.awaiting_stop = false;
                next.stop_tx_pending = false;
            }
            BleAction::OrphanSliceAfterDisconnect => {
                if self.mutant == BleMutant::Pr650OrphanSliceFabricatesFileIdAfterDisconnect {
                    next.active_realtime = true;
                }
            }
            BleAction::RequestQuit => {
                next.quitting = true;
                if next.device_recording || (next.active_realtime && next.quiet_drain.is_none()) {
                    next.awaiting_stop = true;
                    next.device_recording = false;
                    next.stop_tx_pending = true;
                    if next.active_realtime {
                        next.quiet_drain = Some(0);
                    }
                }
                if next.all_day == AllDayPhase::Active {
                    next.all_day = AllDayPhase::Stopping;
                }
            }
            BleAction::ReconcileAllDay => {
                if self.mutant == BleMutant::Pr704DisconnectLeavesAllDayTrapped {
                    if next.all_day == AllDayPhase::Stopping
                        && !next.active_realtime
                        && !next.device_recording
                        && !next.awaiting_stop
                    {
                        next.all_day = AllDayPhase::Off;
                    }
                } else {
                    if next.all_day == AllDayPhase::Active
                        && !next.device_recording
                        && !next.active_realtime
                    {
                        next.all_day = AllDayPhase::Stopping;
                    }
                    if next.all_day == AllDayPhase::Stopping
                        && !next.active_realtime
                        && !next.device_recording
                        && !next.awaiting_stop
                    {
                        next.all_day = AllDayPhase::Off;
                    }
                }
            }
        }
        next.refresh_quit();
        vec![next]
    }

    fn check_invariants(
        &self,
        prev: Option<&BleState>,
        action: Option<&BleAction>,
        next: &BleState,
    ) -> Result<(), String> {
        if next.explicit_disconnect && next.active_realtime {
            return Err(
                "explicit_disconnect_orphan_fence: orphan slice fabricated active file after disconnect"
                    .into(),
            );
        }

        if let (Some(p), Some(act)) = (prev, action) {
            if *act == BleAction::OrphanSliceAfterDisconnect && *next != *p {
                return Err(
                    "explicit_disconnect_orphan_fence: orphan slice mutated state after disconnect"
                        .into(),
                );
            }
            if *act == BleAction::RetryStop
                && p.quiet_drain.is_some()
                && next.quiet_drain != p.quiet_drain
            {
                return Err(
                    "stop_confirm_and_quiet_drain_independence: retry stop reset quiet drain timer"
                        .into(),
                );
            }
            if *act == BleAction::QuietDrainTick && p.awaiting_stop && !next.awaiting_stop {
                return Err(
                    "stop_confirm_and_quiet_drain_independence: quiet drain cleared awaiting_stop"
                        .into(),
                );
            }
            if matches!(act, BleAction::FinalizeTransfer | BleAction::QuietDrainTick)
                && p.conn == ConnPhase::Connected
                && p.file_decryption_ready
                && !next.file_decryption_ready
            {
                return Err(
                    "connection_scoped_decryption_context: finalize cleared file decryption key while connected"
                        .into(),
                );
            }
        }

        if next.conn != ConnPhase::Connected && next.file_decryption_ready {
            return Err(
                "connection_scoped_decryption_context: file decryption leaked across disconnect"
                    .into(),
            );
        }

        if next.quit_phase == QuitPhase::Ready
            && (!next.quitting
                || next.awaiting_stop
                || next.device_recording
                || next.active_realtime
                || next.has_slices
                || next.all_day != AllDayPhase::Off)
        {
            return Err("durable_quit_veto: quit became ready with durable work remaining".into());
        }

        Ok(())
    }

    fn is_live_goal(&self, state: &BleState) -> bool {
        let quit_ok = !state.quitting || state.quit_phase == QuitPhase::Ready;
        let stop_ok = !state.awaiting_stop;
        let all_day_ok = state.all_day == AllDayPhase::Off;
        quit_ok && stop_ok && all_day_ok && !state.active_realtime
    }

    fn is_fair_edge(&self, _state: &BleState, action: &BleAction, _next: &BleState) -> bool {
        matches!(
            action,
            BleAction::ConnectStart
                | BleAction::HandshakeComplete
                | BleAction::StopRecording
                | BleAction::DeviceAckStop
                | BleAction::QuietDrainTick
                | BleAction::FinalizeTransfer
                | BleAction::ReconcileAllDay
        )
    }
}

struct Sandbox(PathBuf);

impl Sandbox {
    fn new(tag: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "koe-fm-ble-{tag}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

const FILE_KEY: [u8; 32] = [0x5A; 32];
const FILE_NONCE: [u8; 16] = [0x11; 16];
const NOW: u64 = 1_800_000_000;

fn rx_cmd(cmd_type: u8, cmd_id: u8, payload: &[u8]) -> Vec<u8> {
    let mut pkt = RX_MAGIC.to_vec();
    pkt.extend_from_slice(&[0x01, cmd_type, cmd_id]);
    let total = u16::try_from(10 + payload.len()).unwrap().to_le_bytes();
    pkt.extend_from_slice(&total);
    pkt.extend_from_slice(payload);
    let csum = ProtocolFrame::checksum(&pkt);
    pkt.push(csum);
    pkt
}

fn telemetry_rx(recording_status: u8) -> Vec<u8> {
    let mut pkt = RX_MAGIC.to_vec();
    pkt.extend_from_slice(&[0x01, 0x01, 0x01, 0x00, 0x00]);
    pkt.push(1);
    pkt.push(8);
    pkt.push(recording_status);
    pkt.extend_from_slice(b"04.92");
    pkt.extend_from_slice(b"D3200MODEL000001");
    pkt.extend_from_slice(&(64u32 * 1024 * 1024).to_le_bytes());
    pkt.extend_from_slice(&(60u32 * 1024 * 1024).to_le_bytes());
    pkt.push(0);
    pkt.extend_from_slice(b"2.1.0");
    pkt.push(9);
    pkt.extend_from_slice(&[0xAA, 0xBB, 0xCC, 0xDD, 0x63, 0x9D]);
    pkt.extend_from_slice(&[0, 0, 0, 0, 0]);
    pkt.push(0);
    pkt.extend_from_slice(b"1.0.0");
    let total = u16::try_from(pkt.len() + 1).unwrap().to_le_bytes();
    pkt[7] = total[0];
    pkt[8] = total[1];
    let csum = ProtocolFrame::checksum(&pkt);
    pkt.push(csum);
    pkt
}

fn wrapped_file_head_rx(session_key: &[u8; 32], file_id: u32, file_size: u32) -> Vec<u8> {
    let session_nonce = [0x33; 16];
    let mut key_material = b"soundcored3200".to_vec();
    key_material.extend_from_slice(&FILE_KEY);
    let wrapped =
        DeviceCrypto::aes_ctr_decrypt(&key_material, session_key, &session_nonce).unwrap();
    let mut payload = Vec::with_capacity(87);
    payload.extend_from_slice(&file_id.to_le_bytes());
    payload.extend_from_slice(&file_size.to_le_bytes());
    payload.extend_from_slice(&FILE_NONCE);
    payload.extend_from_slice(&wrapped);
    payload.extend_from_slice(&session_nonce);
    payload.push(0);
    rx_cmd(0x1A, 0x07, &payload)
}

fn short_file_head_rx(file_id: u32, file_size: u32) -> Vec<u8> {
    let mut payload = Vec::with_capacity(9);
    payload.extend_from_slice(&file_id.to_le_bytes());
    payload.extend_from_slice(&file_size.to_le_bytes());
    payload.push(0);
    rx_cmd(0x1A, 0x07, &payload)
}

fn encrypted_slice_rx(seq: u32) -> Vec<u8> {
    let dec = koe_engine::crypto::AesCtrStreamDecrypt::new(&FILE_KEY, &FILE_NONCE).unwrap();
    let mut plain = [0u8; 160];
    plain[0..3].copy_from_slice(&[0xF8, 0xFF, 0xFE]);
    let cipher = dec.decrypt_chunk(&plain, seq);
    let mut payload = Vec::with_capacity(166);
    payload.extend_from_slice(&seq.to_le_bytes());
    payload.extend_from_slice(&cipher);
    payload.extend_from_slice(&[0u8, 0u8]);
    rx_cmd(0x1A, 0x08, &payload)
}

fn connect_runtime_bean(rt: &mut KoeRuntime, conn_id: &str) -> [u8; 32] {
    rt.dispatch_json(
        &json!({"type":"device_event","event":"connecting","connectionId":conn_id,"deviceName":"Soundcore Work"})
            .to_string(),
        NOW,
    );
    rt.dispatch_json(
        &json!({"type":"device_event","event":"ready","connectionId":conn_id,"deviceName":"Soundcore Work"})
            .to_string(),
        NOW,
    );
    let tx = rt.drain_outbound_ble_frames();
    let ecdh = tx
        .iter()
        .find(|f| f.len() >= 75 && f[5] == 0x2E && f[6] == 0x01)
        .expect("2E/01 public key frame");
    let bean_priv = [0x24u8; 32];
    let bean_pub = DeviceCrypto::p256_public_key(&bean_priv).unwrap();
    let shared = DeviceCrypto::p256_ecdh_shared_secret(&bean_priv, &ecdh[9..74]).unwrap();
    let mut payload = Vec::with_capacity(97);
    payload.extend_from_slice(&bean_pub);
    payload.extend_from_slice(&shared);
    rt.ingest_ble_chunk(&rx_cmd(0x2E, 0x01, &payload), NOW);
    rt.ingest_ble_chunk(&telemetry_rx(0), NOW);
    rt.ingest_ble_chunk(&rx_cmd(0x1B, 0x0E, &[0, 0]), NOW);
    rt.drain_outbound_ble_frames();
    let derived = DeviceCrypto::hkdf_sha256(&shared, &[1, 2, 3], &[1, 2, 3], 32);
    let mut sk = [0u8; 32];
    sk.copy_from_slice(&derived);
    sk
}

#[test]
fn ble_session_model_clean_bfs_and_liveness() {
    let model = BleSessionModel {
        mutant: BleMutant::Clean,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::Pass {
            states_explored,
            transitions_explored,
        } => {
            println!(
                "[MODEL] ble_session CLEAN BFS: states={states_explored} transitions={transitions_explored}"
            );
            assert!(
                states_explored >= 150,
                "expected non-trivial state space, got {states_explored}"
            );
            assert!(transitions_explored > states_explored);
        }
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => panic!("clean ble_session model failed: {violation}\n{}", format_trace(&trace)),
        ModelOutcome::StateSpaceExceeded { max_states } => {
            panic!("state space exceeded {max_states}");
        }
    }
    match check_liveness(&model, 50_000) {
        LivenessOutcome::Pass {
            states_explored,
            scc_count,
            terminal_sccs,
        } => {
            println!(
                "[MODEL] ble_session CLEAN LIVENESS: states={states_explored} sccs={scc_count} terminal_sccs={terminal_sccs}"
            );
            assert!(states_explored >= 150);
            assert!(terminal_sccs >= 1);
        }
        LivenessOutcome::TrappedScc { trace_to_trap, .. } => {
            panic!("clean ble_session liveness failed:\n{}", format_trace(&trace_to_trap));
        }
        LivenessOutcome::StateSpaceExceeded { max_states } => {
            panic!("liveness state space exceeded {max_states}");
        }
    }
}

#[test]
fn ble_session_mutant_pr613_missing_stop_retry_on_reconnect() {
    let model = BleSessionModel {
        mutant: BleMutant::Pr613MissingStopRetryOnReconnect,
    };
    match check_liveness(&model, 50_000) {
        LivenessOutcome::TrappedScc {
            scc_size,
            trace_to_trap,
            trap_states,
            ..
        } => {
            println!(
                "[MUTANT] pr613_missing_stop_retry_on_reconnect -> TrappedScc(size={scc_size})\n{}",
                format_trace(&trace_to_trap)
            );
            assert!(
                trap_states.iter().any(|s| s.awaiting_stop),
                "expected trap awaiting stop:\n{}",
                format_trace(&trace_to_trap)
            );
        }
        other => panic!("expected TrappedScc for pr613 missing stop retry, got {other:?}"),
    }
}

#[test]
fn ble_session_mutant_pr613_retry_stop_resets_quiet_drain() {
    let model = BleSessionModel {
        mutant: BleMutant::Pr613RetryStopResetsQuietDrain,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr613_retry_stop_resets_quiet_drain -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("stop_confirm_and_quiet_drain_independence"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected stop_confirm_and_quiet_drain_independence violation, got {other:?}"),
    }
}

#[test]
fn ble_session_mutant_pr650_orphan_slice_fabricates_file_id_after_disconnect() {
    let model = BleSessionModel {
        mutant: BleMutant::Pr650OrphanSliceFabricatesFileIdAfterDisconnect,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr650_orphan_slice_fabricates_file_id_after_disconnect -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("explicit_disconnect_orphan_fence"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected explicit_disconnect_orphan_fence violation, got {other:?}"),
    }
}

#[test]
fn ble_session_mutant_pr676_finalize_clears_file_decryption() {
    let model = BleSessionModel {
        mutant: BleMutant::Pr676FinalizeClearsFileDecryption,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr676_finalize_clears_file_decryption -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("connection_scoped_decryption_context"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected connection_scoped_decryption_context violation, got {other:?}"),
    }
}

#[test]
fn ble_session_mutant_pr704_disconnect_leaves_all_day_trapped() {
    let model = BleSessionModel {
        mutant: BleMutant::Pr704DisconnectLeavesAllDayTrapped,
    };
    match check_liveness(&model, 50_000) {
        LivenessOutcome::TrappedScc {
            scc_size,
            trace_to_trap,
            trap_states,
            ..
        } => {
            println!(
                "[MUTANT] pr704_disconnect_leaves_all_day_trapped -> TrappedScc(size={scc_size})\n{}",
                format_trace(&trace_to_trap)
            );
            assert!(
                trap_states.iter().any(|s| s.all_day == AllDayPhase::Active),
                "expected trap in all_day active:\n{}",
                format_trace(&trace_to_trap)
            );
        }
        other => panic!("expected TrappedScc for pr704 all_day trap, got {other:?}"),
    }
}

#[test]
fn ble_session_real_code_trace_replay() {
    let mut session = TransportSession::new();
    let priv_key = [0x17u8; 32];
    let tx = session.on_gatt_ready(priv_key).unwrap();
    let client_pub = &tx[0][9..74];
    let bean_priv = [0x24u8; 32];
    let bean_pub = DeviceCrypto::p256_public_key(&bean_priv).unwrap();
    let shared = DeviceCrypto::p256_ecdh_shared_secret(&bean_priv, client_pub).unwrap();
    let mut ecdh_payload = Vec::with_capacity(97);
    ecdh_payload.extend_from_slice(&bean_pub);
    ecdh_payload.extend_from_slice(&shared);
    let out = session.ingest_ble_chunk(&rx_cmd(0x2E, 0x01, &ecdh_payload), NOW);
    assert!(out.session_key_established);
    session.ingest_ble_chunk(&telemetry_rx(0), NOW);
    assert_eq!(session.connection_phase, ConnectionPhaseTag::Connected);
    let sk = session.session_key.unwrap();

    session.ingest_ble_chunk(&wrapped_file_head_rx(&sk, 42, u32::MAX), NOW);
    assert!(session.active_file_key.is_some());
    session.ingest_ble_chunk(&encrypted_slice_rx(0), NOW);
    assert!(session.finalize_active_transfer(NOW).is_some());

    session.ingest_ble_chunk(&short_file_head_rx(42, 166), NOW);
    assert!(
        session.active_file_key.is_some(),
        "PR #676: connection-scoped decryption key must survive finalize on same BLE link"
    );
    session.on_disconnected();
    session.ingest_ble_chunk(&short_file_head_rx(42, 166), NOW);
    assert!(
        session.active_file_key.is_none(),
        "decryption key must clear on disconnect"
    );

    let dir = Sandbox::new("orphan-and-quit");
    let mut rt = KoeRuntime::open(&dir.0).unwrap();
    rt.dispatch_json(r#"{"type":"set_ble_auto_connect","enabled":false}"#, NOW);
    let sk = connect_runtime_bean(&mut rt, "conn-1");
    rt.ingest_ble_chunk(&rx_cmd(0x1A, 0x06, &77u32.to_le_bytes()), NOW);
    rt.ingest_ble_chunk(&wrapped_file_head_rx(&sk, 77, u32::MAX), NOW);
    rt.ingest_ble_chunk(&encrypted_slice_rx(0), NOW);
    rt.drain_outbound_ble_frames();

    rt.dispatch_json(r#"{"type":"request_quit"}"#, NOW);
    assert_eq!(rt.snapshot(NOW)["lifecycle"]["quitPhase"], "draining");
    rt.poll_timers(1_000, NOW + 1);
    rt.dispatch_json(r#"{"type":"device_stop"}"#, NOW + 1);
    let retry_tx = rt.drain_outbound_ble_frames();
    assert!(
        retry_tx.iter().any(|f| f.len() >= 10 && f[5] == 0x18 && f[6] == 0x82),
        "PR #613: retry stop must emit 18/82 pause_record frame"
    );
    rt.poll_timers(1_000, NOW + 2);
    assert_eq!(
        rt.snapshot(NOW + 2)["lifecycle"]["quitPhase"],
        "draining",
        "PR #613: quiet drain completion must not clear awaiting_stop before device ack"
    );
    rt.dispatch_json(
        r#"{"type":"device_event","event":"disconnected","connectionId":"conn-1"}"#,
        NOW + 2,
    );
    assert_eq!(rt.snapshot(NOW + 2)["lifecycle"]["quitPhase"], "blocked");
    rt.dispatch_json(
        r#"{"type":"device_event","event":"connecting","connectionId":"conn-2"}"#,
        NOW + 3,
    );
    rt.dispatch_json(
        r#"{"type":"device_event","event":"ready","connectionId":"conn-2"}"#,
        NOW + 3,
    );
    let re_tx = rt.drain_outbound_ble_frames();
    let ecdh = re_tx
        .iter()
        .find(|f| f.len() >= 75 && f[5] == 0x2E && f[6] == 0x01)
        .unwrap();
    let bean_priv = [0x24u8; 32];
    let bean_pub = DeviceCrypto::p256_public_key(&bean_priv).unwrap();
    let shared = DeviceCrypto::p256_ecdh_shared_secret(&bean_priv, &ecdh[9..74]).unwrap();
    let mut ecdh_payload = Vec::with_capacity(97);
    ecdh_payload.extend_from_slice(&bean_pub);
    ecdh_payload.extend_from_slice(&shared);
    rt.ingest_ble_chunk(&rx_cmd(0x2E, 0x01, &ecdh_payload), NOW + 3);
    let after_reconnect = rt.drain_outbound_ble_frames();
    assert!(
        after_reconnect
            .iter()
            .any(|f| f.len() >= 10 && f[5] == 0x18 && f[6] == 0x82),
        "PR #613: reconnect while awaiting_stop must re-emit 18/82 stop frame"
    );
    rt.ingest_ble_chunk(&rx_cmd(0x18, 0x82, &[0x02]), NOW + 3);
    rt.poll_timers(100, NOW + 4);
    assert_eq!(rt.snapshot(NOW + 4)["lifecycle"]["quitPhase"], "ready");

    let dir2 = Sandbox::new("disconnect-fence");
    let mut rt2 = KoeRuntime::open(&dir2.0).unwrap();
    rt2.dispatch_json(r#"{"type":"set_ble_auto_connect","enabled":false}"#, NOW);
    connect_runtime_bean(&mut rt2, "conn-a");
    let started: Value =
        serde_json::from_str(&rt2.dispatch_json(r#"{"type":"start_all_day","source":"bean"}"#, NOW))
            .unwrap();
    assert!(started["error"].is_null(), "{started}");
    rt2.dispatch_json(r#"{"type":"device_disconnect"}"#, NOW + 1);
    let gen_before_orphan = rt2.generation();
    rt2.ingest_ble_chunk(&encrypted_slice_rx(0), NOW + 2);
    assert_eq!(
        rt2.generation(),
        gen_before_orphan,
        "PR #650: explicit disconnect must reject orphan slices without bumping generation"
    );
    assert!(rt2.workspace().records().is_empty());
    rt2.poll_timers(100, NOW + 3);
    let snap = rt2.snapshot(NOW + 3);
    assert_eq!(
        snap["workspaces"]["allDay"]["isActive"], false,
        "PR #704: explicit disconnect must not leave all_day trapped active: {snap}"
    );
    assert!(snap["activeCapture"].is_null());

    connect_runtime_bean(&mut rt2, "conn-drop");
    let started_drop: Value = serde_json::from_str(
        &rt2.dispatch_json(r#"{"type":"start_all_day","source":"bean"}"#, NOW + 4),
    )
    .unwrap();
    assert!(started_drop["error"].is_null(), "{started_drop}");
    rt2.dispatch_json(
        r#"{"type":"device_event","event":"disconnected","connectionId":"conn-drop"}"#,
        NOW + 5,
    );
    rt2.poll_timers(100, NOW + 6);
    let snap_drop = rt2.snapshot(NOW + 6);
    assert_eq!(
        snap_drop["workspaces"]["allDay"]["isActive"], false,
        "PR #704: unexpected link drop must reconcile all_day to inactive: {snap_drop}"
    );
}
