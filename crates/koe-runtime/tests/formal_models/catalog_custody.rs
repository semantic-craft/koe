use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use koe_engine::{
    crypto::DeviceCrypto,
    frame::{ProtocolFrame, RX_MAGIC},
    models::OfflineFileEntry,
    session::{CatalogLoadPhase, CustodyReceipt, TransportSession},
};
use koe_runtime::KoeRuntime;
use serde_json::{json, Value};

use crate::checker::{
    check_liveness, explore_bfs, format_trace, LivenessOutcome, ModelOutcome, ProtocolModel,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum CatPhase {
    Idle,
    AwaitingPage0,
    AwaitingPage1,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct CatalogCustodyState {
    cat_phase: CatPhase,
    cat_started_for_subscribe: bool,
    cat_refresh_queued: bool,
    pending_subscribe: bool,
    pre_start_has_f1: bool,
    device_recording: bool,
    active_file: Option<u8>,
    active_is_realtime: bool,
    queued_offline_f1: bool,
    aborted_live_f2_pending: bool,
    f1_saved_offline: bool,
    f2_tombstoned: bool,
    f1_disk_fsynced: bool,
    f1_hardware_deleted: bool,
    last_tx_len: Option<u8>,
    start_budget: u8,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum CatalogCustodyAction {
    StartCatalogRefresh,
    StartRealtimeSubscribe,
    ReceivePage0Full,
    ReceivePage1WithNewF2,
    ReceiveZeroSizeHeadForActive,
    ReceiveFileHeadBeforeCatalogDone,
    AbortedLiveF2Resolves,
    SaveQueuedOfflineF1,
    ConfirmDiskCustodyF1,
    RequestHardwareDeleteF1,
    FinishRealtime,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CatalogMutant {
    Clean,
    HardwareDeleteWithoutCustody,
    Pr649SinglePageTruncationSelectsStaleFile,
    Pr704AbortedLiveShellHijacksPull,
    Pr704AbortedLiveShellTombstonesFileId,
    Pr592ZeroSizeHeadClearsRealtimeFlag,
    Pr809EmitsEmptyCatalogTx,
    Pr809MissingSubscribeResetOnFileHead,
}

struct CatalogCustodyModel {
    mutant: CatalogMutant,
}

impl CatalogCustodyModel {
    fn build_catalog_tx_len(&self, already_loading: bool) -> Option<u8> {
        if already_loading {
            if self.mutant == CatalogMutant::Pr809EmitsEmptyCatalogTx {
                Some(0)
            } else {
                None
            }
        } else {
            Some(10)
        }
    }
}

impl ProtocolModel for CatalogCustodyModel {
    type State = CatalogCustodyState;
    type Action = CatalogCustodyAction;

    fn init(&self) -> Vec<CatalogCustodyState> {
        vec![CatalogCustodyState {
            cat_phase: CatPhase::Idle,
            cat_started_for_subscribe: false,
            cat_refresh_queued: false,
            pending_subscribe: false,
            pre_start_has_f1: true,
            device_recording: false,
            active_file: None,
            active_is_realtime: false,
            queued_offline_f1: true,
            aborted_live_f2_pending: true,
            f1_saved_offline: false,
            f2_tombstoned: false,
            f1_disk_fsynced: false,
            f1_hardware_deleted: false,
            last_tx_len: None,
            start_budget: 2,
        }]
    }

    fn actions(&self, s: &CatalogCustodyState) -> Vec<CatalogCustodyAction> {
        let mut acts = Vec::new();
        if s.cat_phase == CatPhase::Idle
            && !s.pending_subscribe
            && s.active_file.is_none()
            && s.start_budget > 0
        {
            acts.push(CatalogCustodyAction::StartCatalogRefresh);
        }
        if !s.device_recording
            && !s.pending_subscribe
            && s.active_file.is_none()
            && s.start_budget > 0
        {
            acts.push(CatalogCustodyAction::StartRealtimeSubscribe);
        }
        if s.cat_phase == CatPhase::AwaitingPage0 {
            acts.push(CatalogCustodyAction::ReceivePage0Full);
        }
        if s.cat_phase == CatPhase::AwaitingPage1 {
            acts.push(CatalogCustodyAction::ReceivePage1WithNewF2);
        }
        if s.pending_subscribe && s.cat_phase != CatPhase::Idle && s.active_file.is_none() {
            acts.push(CatalogCustodyAction::ReceiveFileHeadBeforeCatalogDone);
        }
        if s.active_file.is_some() && s.active_is_realtime {
            acts.push(CatalogCustodyAction::ReceiveZeroSizeHeadForActive);
            acts.push(CatalogCustodyAction::FinishRealtime);
        }
        if s.aborted_live_f2_pending {
            acts.push(CatalogCustodyAction::AbortedLiveF2Resolves);
        }
        if s.queued_offline_f1 {
            acts.push(CatalogCustodyAction::SaveQueuedOfflineF1);
        }
        if s.f1_saved_offline && !s.f1_disk_fsynced {
            acts.push(CatalogCustodyAction::ConfirmDiskCustodyF1);
        }
        if !s.f1_hardware_deleted {
            acts.push(CatalogCustodyAction::RequestHardwareDeleteF1);
        }
        acts
    }

    fn step(
        &self,
        s: &CatalogCustodyState,
        action: &CatalogCustodyAction,
    ) -> Vec<CatalogCustodyState> {
        let mut next = *s;
        next.last_tx_len = None;

        match *action {
            CatalogCustodyAction::StartCatalogRefresh => {
                next.last_tx_len = self.build_catalog_tx_len(next.cat_phase != CatPhase::Idle);
                next.cat_phase = CatPhase::AwaitingPage0;
                next.cat_started_for_subscribe = false;
            }
            CatalogCustodyAction::StartRealtimeSubscribe => {
                next.start_budget -= 1;
                next.device_recording = true;
                next.pending_subscribe = true;
                next.pre_start_has_f1 = true;
                let already_loading = next.cat_phase != CatPhase::Idle;
                next.last_tx_len = self.build_catalog_tx_len(already_loading);
                if already_loading {
                    next.cat_refresh_queued = true;
                    next.cat_started_for_subscribe = false;
                } else {
                    next.cat_phase = CatPhase::AwaitingPage0;
                    next.cat_started_for_subscribe = true;
                }
            }
            CatalogCustodyAction::ReceivePage0Full => {
                if self.mutant == CatalogMutant::Pr649SinglePageTruncationSelectsStaleFile {
                    next.cat_phase = CatPhase::Idle;
                    next.cat_started_for_subscribe = false;
                    if next.pending_subscribe {
                        next.pending_subscribe = false;
                        next.active_file = Some(1);
                        next.active_is_realtime = true;
                    }
                } else {
                    next.cat_phase = CatPhase::AwaitingPage1;
                    next.last_tx_len = Some(10);
                }
            }
            CatalogCustodyAction::ReceivePage1WithNewF2 => {
                next.cat_phase = CatPhase::Idle;
                next.cat_started_for_subscribe = false;
                if next.pending_subscribe {
                    next.cat_refresh_queued = false;
                    next.pending_subscribe = false;
                    next.active_file = Some(2);
                    next.active_is_realtime = true;
                } else if next.cat_refresh_queued {
                    next.cat_refresh_queued = false;
                    next.cat_phase = CatPhase::AwaitingPage0;
                    next.last_tx_len = Some(10);
                }
            }
            CatalogCustodyAction::ReceiveFileHeadBeforeCatalogDone => {
                next.pending_subscribe = false;
                next.active_file = Some(2);
                next.active_is_realtime = true;
                if next.cat_started_for_subscribe
                    && self.mutant != CatalogMutant::Pr809MissingSubscribeResetOnFileHead
                {
                    next.cat_phase = CatPhase::Idle;
                    next.cat_started_for_subscribe = false;
                    next.cat_refresh_queued = false;
                }
            }
            CatalogCustodyAction::ReceiveZeroSizeHeadForActive => {
                if self.mutant == CatalogMutant::Pr592ZeroSizeHeadClearsRealtimeFlag {
                    next.active_is_realtime = false;
                }
            }
            CatalogCustodyAction::AbortedLiveF2Resolves => {
                next.aborted_live_f2_pending = false;
                match self.mutant {
                    CatalogMutant::Pr704AbortedLiveShellHijacksPull => {
                        if next.queued_offline_f1 {
                            next.queued_offline_f1 = false;
                        }
                    }
                    CatalogMutant::Pr704AbortedLiveShellTombstonesFileId => {
                        next.f2_tombstoned = true;
                    }
                    _ => {}
                }
            }
            CatalogCustodyAction::SaveQueuedOfflineF1 => {
                next.queued_offline_f1 = false;
                next.f1_saved_offline = true;
            }
            CatalogCustodyAction::ConfirmDiskCustodyF1 => {
                next.f1_disk_fsynced = true;
            }
            CatalogCustodyAction::RequestHardwareDeleteF1 => {
                if next.f1_disk_fsynced
                    || self.mutant == CatalogMutant::HardwareDeleteWithoutCustody
                {
                    next.f1_hardware_deleted = true;
                }
            }
            CatalogCustodyAction::FinishRealtime => {
                next.device_recording = false;
                next.active_file = None;
                next.active_is_realtime = false;
                next.pending_subscribe = false;
            }
        }
        vec![next]
    }

    fn check_invariants(
        &self,
        prev: Option<&CatalogCustodyState>,
        action: Option<&CatalogCustodyAction>,
        next: &CatalogCustodyState,
    ) -> Result<(), String> {
        if next.f1_hardware_deleted && !next.f1_disk_fsynced {
            return Err(
                "custody_before_hardware_delete: 0x1A/0x10 delete permitted before disk fsync custody"
                    .into(),
            );
        }

        if next.active_is_realtime && next.active_file == Some(1) && next.pre_start_has_f1 {
            return Err(
                "multipage_prestart_isolation: single-page catalog truncation selected stale pre-start file"
                    .into(),
            );
        }

        if next.f2_tombstoned {
            return Err(
                "stream_queue_identity_isolation: aborted live shell tombstoned file id".into(),
            );
        }

        if let (Some(p), Some(act)) = (prev, action) {
            if p.queued_offline_f1 && !next.queued_offline_f1 && !next.f1_saved_offline {
                return Err(
                    "stream_queue_identity_isolation: aborted live shell hijacked queued offline pull"
                        .into(),
                );
            }
            if *act == CatalogCustodyAction::ReceiveZeroSizeHeadForActive
                && p.active_is_realtime
                && !next.active_is_realtime
            {
                return Err(
                    "zero_size_head_preserves_realtime: zero-size 1A/07 head cleared realtime flag"
                        .into(),
                );
            }
            if *act == CatalogCustodyAction::ReceiveFileHeadBeforeCatalogDone
                && p.cat_started_for_subscribe
                && (next.cat_phase != CatPhase::Idle || next.cat_started_for_subscribe)
            {
                return Err(
                    "catalog_subscribe_no_empty_tx_or_spin: file head failed to reset subscribe catalog state"
                        .into(),
                );
            }
        }

        if next.last_tx_len == Some(0) {
            return Err(
                "catalog_subscribe_no_empty_tx_or_spin: emitted empty 0-byte catalog TX frame"
                    .into(),
            );
        }

        Ok(())
    }

    fn is_live_goal(&self, state: &CatalogCustodyState) -> bool {
        state.cat_phase == CatPhase::Idle
            && !state.pending_subscribe
            && !state.queued_offline_f1
            && !state.aborted_live_f2_pending
            && state.f1_hardware_deleted
            && state.active_file.is_none()
    }

    fn is_fair_edge(
        &self,
        _state: &CatalogCustodyState,
        action: &CatalogCustodyAction,
        _next: &CatalogCustodyState,
    ) -> bool {
        !matches!(
            action,
            CatalogCustodyAction::ReceiveZeroSizeHeadForActive
                | CatalogCustodyAction::StartCatalogRefresh
        )
    }
}

struct Sandbox(PathBuf);

impl Sandbox {
    fn new(tag: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "koe-fm-cat-{tag}-{}-{}",
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

const FILE_KEY: [u8; 32] = [0x6B; 32];
const FILE_NONCE: [u8; 16] = [0x22; 16];
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
    pkt.extend_from_slice(b"D3200CAT00000001");
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

fn catalog_1b0e_rx(entries: &[OfflineFileEntry]) -> Vec<u8> {
    let mut payload = Vec::with_capacity(2 + entries.len() * 12);
    payload.extend_from_slice(&u16::try_from(entries.len()).unwrap().to_le_bytes());
    for e in entries {
        payload.extend_from_slice(&e.file_id.to_le_bytes());
        payload.extend_from_slice(&e.end_time.unwrap_or(0).to_le_bytes());
        payload.extend_from_slice(&e.duration_ms.to_le_bytes());
    }
    rx_cmd(0x1B, 0x0E, &payload)
}

fn wrapped_file_head_rx(session_key: &[u8; 32], file_id: u32, file_size: u32) -> Vec<u8> {
    let session_nonce = [0x44; 16];
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
        .unwrap();
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
fn catalog_custody_model_clean_bfs_and_liveness() {
    let model = CatalogCustodyModel {
        mutant: CatalogMutant::Clean,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::Pass {
            states_explored,
            transitions_explored,
        } => {
            println!(
                "[MODEL] catalog_custody CLEAN BFS: states={states_explored} transitions={transitions_explored}"
            );
            assert!(
                states_explored >= 150,
                "expected non-trivial state space, got {states_explored}"
            );
            assert!(transitions_explored > states_explored);
        }
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => panic!("clean catalog_custody model failed: {violation}\n{}", format_trace(&trace)),
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
                "[MODEL] catalog_custody CLEAN LIVENESS: states={states_explored} sccs={scc_count} terminal_sccs={terminal_sccs}"
            );
            assert!(states_explored >= 150);
            assert!(terminal_sccs >= 1);
        }
        LivenessOutcome::TrappedScc { trace_to_trap, .. } => {
            panic!("clean catalog_custody liveness failed:\n{}", format_trace(&trace_to_trap));
        }
        LivenessOutcome::StateSpaceExceeded { max_states } => {
            panic!("liveness state space exceeded {max_states}");
        }
    }
}

#[test]
fn catalog_custody_mutant_hardware_delete_without_custody() {
    let model = CatalogCustodyModel {
        mutant: CatalogMutant::HardwareDeleteWithoutCustody,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] hardware_delete_without_custody -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("custody_before_hardware_delete"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected custody_before_hardware_delete violation, got {other:?}"),
    }
}

#[test]
fn catalog_custody_mutant_pr649_single_page_truncation_selects_stale_file() {
    let model = CatalogCustodyModel {
        mutant: CatalogMutant::Pr649SinglePageTruncationSelectsStaleFile,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr649_single_page_truncation_selects_stale_file -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("multipage_prestart_isolation"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected multipage_prestart_isolation violation, got {other:?}"),
    }
}

#[test]
fn catalog_custody_mutant_pr704_aborted_live_shell_hijacks_pull() {
    let model = CatalogCustodyModel {
        mutant: CatalogMutant::Pr704AbortedLiveShellHijacksPull,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr704_aborted_live_shell_hijacks_pull -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("stream_queue_identity_isolation")
                    && violation.contains("hijacked"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected stream_queue_identity_isolation hijack violation, got {other:?}"),
    }
}

#[test]
fn catalog_custody_mutant_pr704_aborted_live_shell_tombstones_file_id() {
    let model = CatalogCustodyModel {
        mutant: CatalogMutant::Pr704AbortedLiveShellTombstonesFileId,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr704_aborted_live_shell_tombstones_file_id -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("stream_queue_identity_isolation")
                    && violation.contains("tombstoned"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => {
            panic!("expected stream_queue_identity_isolation tombstone violation, got {other:?}")
        }
    }
}

#[test]
fn catalog_custody_mutant_pr592_zero_size_head_clears_realtime_flag() {
    let model = CatalogCustodyModel {
        mutant: CatalogMutant::Pr592ZeroSizeHeadClearsRealtimeFlag,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr592_zero_size_head_clears_realtime_flag -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("zero_size_head_preserves_realtime"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected zero_size_head_preserves_realtime violation, got {other:?}"),
    }
}

#[test]
fn catalog_custody_mutant_pr809_emits_empty_catalog_tx() {
    let model = CatalogCustodyModel {
        mutant: CatalogMutant::Pr809EmitsEmptyCatalogTx,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr809_emits_empty_catalog_tx -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("catalog_subscribe_no_empty_tx_or_spin")
                    && violation.contains("empty 0-byte"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => {
            panic!("expected catalog_subscribe_no_empty_tx_or_spin empty TX violation, got {other:?}")
        }
    }
}

#[test]
fn catalog_custody_mutant_pr809_missing_subscribe_reset_on_file_head() {
    let model = CatalogCustodyModel {
        mutant: CatalogMutant::Pr809MissingSubscribeResetOnFileHead,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr809_missing_subscribe_reset_on_file_head -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("catalog_subscribe_no_empty_tx_or_spin")
                    && violation.contains("reset subscribe"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!(
            "expected catalog_subscribe_no_empty_tx_or_spin subscribe reset violation, got {other:?}"
        ),
    }
}

#[test]
fn catalog_custody_real_code_trace_replay() {
    let mut session = TransportSession::new();
    assert!(session.request_reclaim_bean_file(42).is_err());
    assert!(!session.confirm_disk_custody(CustodyReceipt {
        file_id: 42,
        byte_count: 0,
        sha256_hex: "a".repeat(64),
        fsynced_at_epoch_sec: NOW,
    }));
    assert!(session.request_reclaim_bean_file(42).is_err());
    let valid_receipt = CustodyReceipt {
        file_id: 42,
        byte_count: 1024,
        sha256_hex: "0123456789abcdef".repeat(4),
        fsynced_at_epoch_sec: NOW,
    };
    assert!(session.confirm_disk_custody(valid_receipt));
    let verified = session.custody_receipt(42).expect("verified custody receipt");
    assert_eq!(verified.file_id(), 42);
    let delete_frame = session.request_reclaim_bean_file(42).unwrap();
    assert_eq!(delete_frame[5], 0x1A);
    assert_eq!(delete_frame[6], 0x10);

    let pre_start_page0: Vec<OfflineFileEntry> = (100..110)
        .map(|fid| OfflineFileEntry {
            file_id: fid,
            end_time: Some(fid + 60),
            duration_ms: 5_000,
        })
        .collect();
    let tx_init = session.request_full_catalog();
    assert!(!tx_init.is_empty());
    let init_p0 = session.ingest_ble_chunk(&catalog_1b0e_rx(&pre_start_page0), NOW);
    assert_eq!(init_p0.outbound_tx_frames.len(), 1);
    session.ingest_ble_chunk(&catalog_1b0e_rx(&[]), NOW);
    assert!(session.has_complete_catalog());

    let start_out = session.start_realtime_recording(None, NOW * 1000);
    assert!(start_out.outbound_tx_frames.iter().all(|f| !f.is_empty()));
    assert!(session.catalog_started_for_subscribe);
    let page0_out = session.ingest_ble_chunk(&catalog_1b0e_rx(&pre_start_page0), NOW + 1);
    assert!(
        session.active_file_id.is_none(),
        "PR #649: full page 0 must paginate instead of selecting stale pre-start file"
    );
    assert_eq!(page0_out.outbound_tx_frames.len(), 1);

    let page1_new = vec![OfflineFileEntry {
        file_id: 200,
        end_time: Some(0),
        duration_ms: 0,
    }];
    let page1_out = session.ingest_ble_chunk(&catalog_1b0e_rx(&page1_new), NOW + 2);
    assert_eq!(
        session.active_file_id,
        Some(200),
        "PR #649: page 1 open entry 200 must be selected"
    );
    assert!(session.active_is_realtime);
    assert!(page1_out.outbound_tx_frames.iter().all(|f| !f.is_empty()));

    let mut zero_head_payload = Vec::with_capacity(9);
    zero_head_payload.extend_from_slice(&200u32.to_le_bytes());
    zero_head_payload.extend_from_slice(&0u32.to_le_bytes());
    zero_head_payload.push(0);
    session.ingest_ble_chunk(&rx_cmd(0x1A, 0x07, &zero_head_payload), NOW + 3);
    assert!(
        session.active_is_realtime,
        "PR #592: zero-size 1A/07 head must preserve active_is_realtime"
    );
    assert_eq!(session.active_file_id, Some(200));

    session.reset_active_transfer();
    session.device_recording_active = false;
    let first_tx = session.request_full_catalog();
    assert!(!first_tx.is_empty());
    let dup_tx = session.request_full_catalog();
    assert!(dup_tx.is_empty());
    let sub_while_loading = session.start_realtime_recording(None, (NOW + 4) * 1000);
    assert!(
        sub_while_loading.outbound_tx_frames.iter().all(|f| !f.is_empty()),
        "PR #809: never push empty TX frame when catalog is already loading"
    );

    session.catalog_load_phase = CatalogLoadPhase::Idle;
    session.catalog_refresh_queued = false;
    session.pending_realtime_subscribe = false;
    session.device_recording_active = false;
    let sub_fresh = session.start_realtime_recording(None, (NOW + 5) * 1000);
    assert!(sub_fresh.outbound_tx_frames.iter().all(|f| !f.is_empty()));
    assert!(session.catalog_started_for_subscribe);
    let mut head_201 = Vec::with_capacity(9);
    head_201.extend_from_slice(&201u32.to_le_bytes());
    head_201.extend_from_slice(&u32::MAX.to_le_bytes());
    head_201.push(0);
    session.ingest_ble_chunk(&rx_cmd(0x1A, 0x07, &head_201), NOW + 6);
    assert!(
        !session.is_catalog_loading() && !session.catalog_started_for_subscribe,
        "PR #809: 1A/07 realtime start must reset catalog_started_for_subscribe and catalog_load_phase"
    );

    let dir = Sandbox::new("pr704-queue");
    let mut rt = KoeRuntime::open(&dir.0).unwrap();
    let _: Value = serde_json::from_str(
        &rt.dispatch_json(r#"{"type":"set_ble_auto_connect","enabled":false}"#, NOW),
    )
    .unwrap();
    let sk = connect_runtime_bean(&mut rt, "conn-cat");
    let mut coalesced = Vec::new();
    coalesced.extend_from_slice(&rx_cmd(0x1A, 0x06, &951u32.to_le_bytes()));
    coalesced.extend_from_slice(&rx_cmd(0x1A, 0x0A, &951u32.to_le_bytes()));
    coalesced.extend_from_slice(&rx_cmd(0x1A, 0x06, &952u32.to_le_bytes()));
    coalesced.extend_from_slice(&wrapped_file_head_rx(&sk, 952, u32::MAX));
    coalesced.extend_from_slice(&encrypted_slice_rx(0));
    coalesced.extend_from_slice(&encrypted_slice_rx(1));
    coalesced.extend_from_slice(&rx_cmd(0x1A, 0x0A, &952u32.to_le_bytes()));
    rt.ingest_ble_chunk(&coalesced, NOW + 10);

    let ids: Vec<String> = rt.workspace().records().keys().cloned().collect();
    assert!(
        !ids.iter().any(|id| id.starts_with("live-951-")),
        "PR #704: empty aborted 951 shell must be purged: {ids:?}"
    );
    assert!(
        !rt.workspace().is_bean_file_purged(951),
        "PR #704: purging empty 951 shell must not tombstone file 951"
    );
    assert!(
        ids.iter().any(|id| id.starts_with("live-952-")),
        "PR #704: non-empty 952 must save under live-952-*: {ids:?}"
    );
}
