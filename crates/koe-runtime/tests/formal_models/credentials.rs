use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, Mutex,
};

use koe_client_services::product_store::{ProductStore, StoreError, PRODUCT_WORKSPACE_FILE};
use koe_engine::product::CredentialBinding;
use koe_runtime::credentials::{CredentialError, CredentialStore};
use koe_runtime::KoeRuntime;
use serde_json::{json, Value};

use crate::checker::{
    check_liveness, explore_bfs, format_trace, LivenessOutcome, ModelOutcome, ProtocolModel,
};

const MAX_ITEMS: u8 = 3;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum Slot {
    Qwen,
    DeepSeek,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum SlotBinding {
    Uninitialized,
    Saved(u8),
    Cleared,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum SaveOp {
    Idle,
    Prepared { slot: Slot, id: u8 },
    PendingCommitted { slot: Slot, id: u8 },
    Created { slot: Slot, id: u8 },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct CredState {
    qwen: SlotBinding,
    deepseek: SlotBinding,
    pending: u8,
    retired: u8,
    keystore: u8,
    next_id: u8,
    op: SaveOp,
    uncertain: bool,
    qwen_unavailable: bool,
    ds_unavailable: bool,
    legacy_present: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum CredAction {
    SaveStart(Slot),
    CommitPending,
    CreateItem,
    CommitBindingOk,
    CommitBindingUncertain,
    ClearSlot(Slot),
    CleanupAllOk,
    CleanupPartialFailure,
    AuthorizeRetiredFails,
    RetryCredentials,
    CrashAndReopen,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CredMutant {
    Clean,
    Pr714CreateBeforePendingCommit,
    Pr605RetryBypassesRequiresReopen,
    Pr605CleanupSkipsPartialCommit,
    Pr605RetiredAuthFailureDisablesActiveSlot,
    Pr605LegacyResurrectsClearedSlot,
}

struct CredentialsModel {
    mutant: CredMutant,
}

fn bit(id: u8) -> u8 {
    1u8 << id
}

impl CredState {
    fn tracked_mask(&self) -> u8 {
        let mut mask = self.pending | self.retired;
        if let SlotBinding::Saved(id) = self.qwen {
            mask |= bit(id);
        }
        if let SlotBinding::Saved(id) = self.deepseek {
            mask |= bit(id);
        }
        mask
    }

    fn binding(&self, slot: Slot) -> SlotBinding {
        match slot {
            Slot::Qwen => self.qwen,
            Slot::DeepSeek => self.deepseek,
        }
    }

    fn set_binding(&mut self, slot: Slot, binding: SlotBinding) {
        match slot {
            Slot::Qwen => self.qwen = binding,
            Slot::DeepSeek => self.deepseek = binding,
        }
    }
}

impl ProtocolModel for CredentialsModel {
    type State = CredState;
    type Action = CredAction;

    fn init(&self) -> Vec<CredState> {
        vec![CredState {
            qwen: SlotBinding::Uninitialized,
            deepseek: SlotBinding::Uninitialized,
            pending: 0,
            retired: 0,
            keystore: 0,
            next_id: 0,
            op: SaveOp::Idle,
            uncertain: false,
            qwen_unavailable: false,
            ds_unavailable: false,
            legacy_present: true,
        }]
    }

    fn actions(&self, s: &CredState) -> Vec<CredAction> {
        let mut acts = Vec::new();
        match s.op {
            SaveOp::Idle => {
                if !s.uncertain && s.next_id < MAX_ITEMS {
                    acts.push(CredAction::SaveStart(Slot::Qwen));
                    acts.push(CredAction::SaveStart(Slot::DeepSeek));
                }
                if !s.uncertain && matches!(s.qwen, SlotBinding::Saved(_)) {
                    acts.push(CredAction::ClearSlot(Slot::Qwen));
                }
                if !s.uncertain && matches!(s.deepseek, SlotBinding::Saved(_)) {
                    acts.push(CredAction::ClearSlot(Slot::DeepSeek));
                }
                if !s.uncertain && (s.retired | s.pending) != 0 {
                    acts.push(CredAction::CleanupAllOk);
                    if (s.retired | s.pending).count_ones() >= 2 {
                        acts.push(CredAction::CleanupPartialFailure);
                    }
                    acts.push(CredAction::AuthorizeRetiredFails);
                }
                if s.uncertain || s.qwen_unavailable || s.ds_unavailable {
                    acts.push(CredAction::RetryCredentials);
                }
                if s.uncertain
                    || (s.retired | s.pending) != 0
                    || matches!(s.qwen, SlotBinding::Cleared | SlotBinding::Uninitialized)
                {
                    acts.push(CredAction::CrashAndReopen);
                }
            }
            SaveOp::Prepared { .. } => {
                if self.mutant == CredMutant::Pr714CreateBeforePendingCommit {
                    acts.push(CredAction::CreateItem);
                } else {
                    acts.push(CredAction::CommitPending);
                }
                acts.push(CredAction::CrashAndReopen);
            }
            SaveOp::PendingCommitted { .. } => {
                acts.push(CredAction::CreateItem);
                acts.push(CredAction::CrashAndReopen);
            }
            SaveOp::Created { .. } => {
                acts.push(CredAction::CommitBindingOk);
                acts.push(CredAction::CommitBindingUncertain);
                acts.push(CredAction::CrashAndReopen);
            }
        }
        acts
    }

    fn step(&self, s: &CredState, action: &CredAction) -> Vec<CredState> {
        let mut next = *s;

        match *action {
            CredAction::SaveStart(slot) => {
                if s.uncertain || s.op != SaveOp::Idle || s.next_id >= MAX_ITEMS {
                    return vec![];
                }
                let id = s.next_id;
                next.next_id += 1;
                next.op = SaveOp::Prepared { slot, id };
                vec![next]
            }
            CredAction::CommitPending => {
                let SaveOp::Prepared { slot, id } = s.op else {
                    return vec![];
                };
                next.pending |= bit(id);
                next.op = SaveOp::PendingCommitted { slot, id };
                vec![next]
            }
            CredAction::CreateItem => match s.op {
                SaveOp::PendingCommitted { slot, id } => {
                    next.keystore |= bit(id);
                    next.op = SaveOp::Created { slot, id };
                    vec![next]
                }
                SaveOp::Prepared { slot, id }
                    if self.mutant == CredMutant::Pr714CreateBeforePendingCommit =>
                {
                    next.keystore |= bit(id);
                    next.op = SaveOp::Created { slot, id };
                    vec![next]
                }
                _ => vec![],
            },
            CredAction::CommitBindingOk => {
                let SaveOp::Created { slot, id } = s.op else {
                    return vec![];
                };
                if let SlotBinding::Saved(prev_id) = next.binding(slot) {
                    next.retired |= bit(prev_id);
                }
                next.set_binding(slot, SlotBinding::Saved(id));
                next.pending &= !bit(id);
                next.op = SaveOp::Idle;
                match slot {
                    Slot::Qwen => next.qwen_unavailable = false,
                    Slot::DeepSeek => next.ds_unavailable = false,
                }
                vec![next]
            }
            CredAction::CommitBindingUncertain => {
                let SaveOp::Created { .. } = s.op else {
                    return vec![];
                };
                next.uncertain = true;
                next.qwen_unavailable = true;
                next.ds_unavailable = true;
                next.op = SaveOp::Idle;
                vec![next]
            }
            CredAction::ClearSlot(slot) => {
                if s.uncertain || s.op != SaveOp::Idle {
                    return vec![];
                }
                if let SlotBinding::Saved(prev_id) = next.binding(slot) {
                    next.retired |= bit(prev_id);
                }
                next.set_binding(slot, SlotBinding::Cleared);
                match slot {
                    Slot::Qwen => next.qwen_unavailable = false,
                    Slot::DeepSeek => next.ds_unavailable = false,
                }
                vec![next]
            }
            CredAction::CleanupAllOk => {
                if s.uncertain || s.op != SaveOp::Idle {
                    return vec![];
                }
                let mask = next.retired | next.pending;
                next.keystore &= !mask;
                next.retired = 0;
                next.pending = 0;
                vec![next]
            }
            CredAction::CleanupPartialFailure => {
                if s.uncertain || s.op != SaveOp::Idle {
                    return vec![];
                }
                let combined = next.retired | next.pending;
                if combined.count_ones() < 2 {
                    return vec![];
                }
                let first_bit = 1u8 << combined.trailing_zeros();
                next.keystore &= !first_bit;
                if self.mutant != CredMutant::Pr605CleanupSkipsPartialCommit {
                    next.retired &= !first_bit;
                    next.pending &= !first_bit;
                }
                vec![next]
            }
            CredAction::AuthorizeRetiredFails => {
                if s.uncertain || s.op != SaveOp::Idle || (s.retired | s.pending) == 0 {
                    return vec![];
                }
                if self.mutant == CredMutant::Pr605RetiredAuthFailureDisablesActiveSlot {
                    next.qwen_unavailable = true;
                    next.ds_unavailable = true;
                }
                vec![next]
            }
            CredAction::RetryCredentials => {
                if s.op != SaveOp::Idle {
                    return vec![];
                }
                if s.uncertain {
                    if self.mutant == CredMutant::Pr605RetryBypassesRequiresReopen {
                        next.uncertain = false;
                        next.qwen_unavailable = false;
                        next.ds_unavailable = false;
                    }
                    return vec![next];
                }
                next.qwen_unavailable = false;
                next.ds_unavailable = false;
                vec![next]
            }
            CredAction::CrashAndReopen => {
                next.op = SaveOp::Idle;
                next.uncertain = false;
                next.qwen_unavailable = false;
                next.ds_unavailable = false;
                let reclaimable = next.retired | next.pending;
                next.keystore &= !reclaimable;
                next.retired = 0;
                next.pending = 0;
                if next.legacy_present && next.next_id < MAX_ITEMS {
                    let should_migrate = match next.qwen {
                        SlotBinding::Uninitialized => true,
                        SlotBinding::Cleared => {
                            self.mutant == CredMutant::Pr605LegacyResurrectsClearedSlot
                        }
                        SlotBinding::Saved(_) => false,
                    };
                    if should_migrate {
                        let id = next.next_id;
                        next.next_id += 1;
                        next.keystore |= bit(id);
                        next.qwen = SlotBinding::Saved(id);
                    }
                }
                vec![next]
            }
        }
    }

    fn check_invariants(
        &self,
        prev: Option<&CredState>,
        action: Option<&CredAction>,
        next: &CredState,
    ) -> Result<(), String> {
        if next.op == SaveOp::Idle && (next.keystore & !next.tracked_mask()) != 0 {
            return Err(format!(
                "no_orphaned_secrets: keystore={:#05b} has untraceable items outside tracked={:#05b}",
                next.keystore,
                next.tracked_mask()
            ));
        }

        if let (Some(p), Some(act)) = (prev, action) {
            if p.uncertain
                && *act != CredAction::CrashAndReopen
                && (!next.uncertain
                    || !next.qwen_unavailable
                    || !next.ds_unavailable
                    || next.qwen != p.qwen
                    || next.deepseek != p.deepseek)
            {
                return Err(format!(
                    "monotonic_uncertain_latch: action {act:?} bypassed uncertain latch"
                ));
            }

            if p.qwen == SlotBinding::Cleared
                && matches!(act, CredAction::CrashAndReopen | CredAction::RetryCredentials)
                && next.qwen != SlotBinding::Cleared
            {
                return Err("tombstone_non_resurrection: cleared qwen slot resurrected".into());
            }
            if p.deepseek == SlotBinding::Cleared
                && matches!(act, CredAction::CrashAndReopen | CredAction::RetryCredentials)
                && next.deepseek != SlotBinding::Cleared
            {
                return Err("tombstone_non_resurrection: cleared deepseek slot resurrected".into());
            }

            if *act == CredAction::AuthorizeRetiredFails
                && ((matches!(p.qwen, SlotBinding::Saved(_))
                    && !p.qwen_unavailable
                    && next.qwen_unavailable)
                    || (matches!(p.deepseek, SlotBinding::Saved(_))
                        && !p.ds_unavailable
                        && next.ds_unavailable))
            {
                return Err(
                    "slot_isolation_on_retired_failure: retired auth failure disabled active slot"
                        .into(),
                );
            }

            if *act == CredAction::CleanupPartialFailure {
                let prev_reclaimable = (p.retired | p.pending).count_ones();
                let next_reclaimable = (next.retired | next.pending).count_ones();
                if next_reclaimable >= prev_reclaimable {
                    return Err(
                        "retired_cleanup_progress: partial cleanup did not commit deleted items"
                            .into(),
                    );
                }
            }
        }

        Ok(())
    }

    fn is_live_goal(&self, state: &CredState) -> bool {
        state.op == SaveOp::Idle
            && !state.uncertain
            && state.pending == 0
            && state.retired == 0
            && !state.qwen_unavailable
            && !state.ds_unavailable
    }

    fn is_fair_edge(&self, _state: &CredState, action: &CredAction, _next: &CredState) -> bool {
        matches!(
            action,
            CredAction::CommitPending
                | CredAction::CreateItem
                | CredAction::CommitBindingOk
                | CredAction::CleanupAllOk
                | CredAction::RetryCredentials
                | CredAction::CrashAndReopen
        )
    }
}

struct Sandbox(PathBuf);

impl Sandbox {
    fn new(tag: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "koe-fm-cred-{tag}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(&self.0, fs::Permissions::from_mode(0o700));
        }
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[derive(Default)]
struct SharedKeystore {
    items: BTreeMap<String, String>,
    next: u64,
    legacy_json: Option<String>,
    fail_delete: BTreeSet<String>,
    fail_authorize: BTreeSet<String>,
    fail_create_after_insert: bool,
    workspace_path: Option<PathBuf>,
    pending_observed_before_create: Vec<String>,
}

struct MockKeystore(Arc<Mutex<SharedKeystore>>);

impl CredentialStore for MockKeystore {
    fn isolated(&self) -> bool {
        false
    }

    fn read(&mut self, reference: &str) -> Result<Option<String>, CredentialError> {
        Ok(self.0.lock().unwrap().items.get(reference).cloned())
    }

    fn prepare(&mut self, _secret: &str) -> Result<String, CredentialError> {
        let mut g = self.0.lock().unwrap();
        g.next += 1;
        Ok(format!("kc-ref-{}", g.next))
    }

    fn create(&mut self, reference: &str, secret: &str) -> Result<(), CredentialError> {
        let mut g = self.0.lock().unwrap();
        if let Some(path) = &g.workspace_path {
            if let Ok(raw) = fs::read_to_string(path) {
                if let Ok(v) = serde_json::from_str::<Value>(&raw) {
                    if let Some(arr) = v["provider"]["pending_credentials"].as_array() {
                        if arr.iter().any(|x| x.as_str() == Some(reference)) {
                            g.pending_observed_before_create.push(reference.to_owned());
                        }
                    }
                }
            }
        }
        g.items.insert(reference.to_owned(), secret.to_owned());
        if g.fail_create_after_insert {
            g.fail_create_after_insert = false;
            return Err(CredentialError);
        }
        Ok(())
    }

    fn delete(&mut self, reference: &str) -> Result<(), CredentialError> {
        let mut g = self.0.lock().unwrap();
        if g.fail_delete.contains(reference) {
            return Err(CredentialError);
        }
        g.items.remove(reference);
        Ok(())
    }

    fn read_legacy(&mut self) -> Result<Option<String>, CredentialError> {
        Ok(self.0.lock().unwrap().legacy_json.clone())
    }

    fn authorize(&mut self, reference: Option<&str>) -> Result<(), CredentialError> {
        let g = self.0.lock().unwrap();
        if let Some(r) = reference {
            if g.fail_authorize.contains(r) {
                return Err(CredentialError);
            }
        }
        Ok(())
    }
}

fn send(runtime: &mut KoeRuntime, cmd: Value) -> Value {
    serde_json::from_str(&runtime.dispatch_json(&cmd.to_string(), 1_800_000_000)).unwrap()
}

#[test]
fn credentials_model_clean_bfs_and_liveness() {
    let model = CredentialsModel {
        mutant: CredMutant::Clean,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::Pass {
            states_explored,
            transitions_explored,
        } => {
            println!(
                "[MODEL] credentials CLEAN BFS: states={states_explored} transitions={transitions_explored}"
            );
            assert!(
                states_explored >= 100,
                "expected non-trivial state space, got {states_explored}"
            );
            assert!(transitions_explored > states_explored);
        }
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => panic!("clean credentials model failed: {violation}\n{}", format_trace(&trace)),
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
                "[MODEL] credentials CLEAN LIVENESS: states={states_explored} sccs={scc_count} terminal_sccs={terminal_sccs}"
            );
            assert!(states_explored >= 100);
            assert!(terminal_sccs >= 1);
        }
        LivenessOutcome::TrappedScc { trace_to_trap, .. } => {
            panic!("clean credentials liveness failed:\n{}", format_trace(&trace_to_trap));
        }
        LivenessOutcome::StateSpaceExceeded { max_states } => {
            panic!("liveness state space exceeded {max_states}");
        }
    }
}

#[test]
fn credentials_mutant_pr714_create_before_pending_commit() {
    let model = CredentialsModel {
        mutant: CredMutant::Pr714CreateBeforePendingCommit,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr714_create_before_pending_commit -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("no_orphaned_secrets"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
            assert!(trace.len() >= 3);
        }
        other => panic!("expected no_orphaned_secrets violation, got {other:?}"),
    }
}

#[test]
fn credentials_mutant_pr605_retry_bypasses_requires_reopen() {
    let model = CredentialsModel {
        mutant: CredMutant::Pr605RetryBypassesRequiresReopen,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr605_retry_bypasses_requires_reopen -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("monotonic_uncertain_latch"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected monotonic_uncertain_latch violation, got {other:?}"),
    }
}

#[test]
fn credentials_mutant_pr605_cleanup_skips_partial_commit() {
    let model = CredentialsModel {
        mutant: CredMutant::Pr605CleanupSkipsPartialCommit,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr605_cleanup_skips_partial_commit -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("retired_cleanup_progress"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected retired_cleanup_progress violation, got {other:?}"),
    }
}

#[test]
fn credentials_mutant_pr605_retired_auth_failure_disables_active_slot() {
    let model = CredentialsModel {
        mutant: CredMutant::Pr605RetiredAuthFailureDisablesActiveSlot,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr605_retired_auth_failure_disables_active_slot -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("slot_isolation_on_retired_failure"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected slot_isolation_on_retired_failure violation, got {other:?}"),
    }
}

#[test]
fn credentials_mutant_pr605_legacy_resurrects_cleared_slot() {
    let model = CredentialsModel {
        mutant: CredMutant::Pr605LegacyResurrectsClearedSlot,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr605_legacy_resurrects_cleared_slot -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("tombstone_non_resurrection"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected tombstone_non_resurrection violation, got {other:?}"),
    }
}

#[test]
fn credentials_real_code_trace_replay() {
    let dir = Sandbox::new("replay");
    let shared = Arc::new(Mutex::new(SharedKeystore {
        legacy_json: Some(json!({"qwen": "legacy-secret-0"}).to_string()),
        workspace_path: Some(dir.0.join(PRODUCT_WORKSPACE_FILE)),
        ..SharedKeystore::default()
    }));

    let mut rt = KoeRuntime::open_with_credentials(&dir.0, Box::new(MockKeystore(shared.clone())))
        .unwrap();
    assert_eq!(rt.snapshot(100)["provider"]["credentialState"], "ready");
    assert!(
        shared
            .lock()
            .unwrap()
            .pending_observed_before_create
            .contains(&"kc-ref-1".to_string()),
        "PR #714 invariant: pending reference must commit to disk before create()"
    );

    shared.lock().unwrap().fail_delete.insert("kc-ref-1".into());
    let rot1 = send(
        &mut rt,
        json!({"type":"configure_provider","apiKey":"secret-2","model":"deepseek-chat"}),
    );
    assert!(rot1["error"].is_string());
    assert_eq!(rot1["provider"]["credentialState"], "ready");
    assert_eq!(
        rt.workspace().provider_configuration().retired_credentials,
        vec!["kc-ref-1".to_string()]
    );

    shared.lock().unwrap().fail_authorize.insert("kc-ref-1".into());
    let auth_fail = send(
        &mut rt,
        json!({"type":"retry_provider_credentials","authorize":true}),
    );
    assert!(auth_fail["error"].is_string());
    assert_eq!(
        auth_fail["provider"]["credentialState"], "ready",
        "PR #605 invariant: retired auth failure must not disable active slot"
    );

    shared.lock().unwrap().fail_delete.insert("kc-ref-2".into());
    let _ = send(
        &mut rt,
        json!({"type":"configure_provider","apiKey":"secret-3","model":"deepseek-chat"}),
    );
    assert_eq!(
        rt.workspace().provider_configuration().retired_credentials,
        vec!["kc-ref-1".to_string(), "kc-ref-2".to_string()]
    );
    shared.lock().unwrap().fail_delete.remove("kc-ref-1");
    let partial = send(
        &mut rt,
        json!({"type":"retry_provider_credentials","authorize":false}),
    );
    assert!(partial["error"].is_string());
    assert_eq!(
        rt.workspace().provider_configuration().retired_credentials,
        vec!["kc-ref-2".to_string()],
        "PR #605 invariant: partial cleanup must commit already-deleted retired ref"
    );
    assert!(!shared.lock().unwrap().items.contains_key("kc-ref-1"));

    shared.lock().unwrap().fail_delete.clear();
    shared.lock().unwrap().fail_create_after_insert = true;
    shared.lock().unwrap().fail_delete.insert("kc-ref-4".into());
    let crash_sim = send(
        &mut rt,
        json!({"type":"configure_provider","apiKey":"secret-4","model":"deepseek-chat"}),
    );
    assert!(crash_sim["error"].is_string());
    assert!(
        rt.workspace()
            .provider_configuration()
            .pending_credentials
            .contains(&"kc-ref-4".to_string()),
        "failed create with blocked discard keeps ref recorded for reopen reclamation"
    );
    drop(rt);

    shared.lock().unwrap().fail_delete.clear();
    let mut rt = KoeRuntime::open_with_credentials(&dir.0, Box::new(MockKeystore(shared.clone())))
        .unwrap();
    assert!(rt.workspace().provider_configuration().pending_credentials.is_empty());
    assert!(rt.workspace().provider_configuration().retired_credentials.is_empty());
    assert!(!shared.lock().unwrap().items.contains_key("kc-ref-4"));
    assert!(!shared.lock().unwrap().items.contains_key("kc-ref-2"));
    assert!(shared.lock().unwrap().items.contains_key("kc-ref-3"));

    let cleared = send(&mut rt, json!({"type":"clear_provider_credential"}));
    assert!(cleared["error"].is_null());
    assert_eq!(cleared["provider"]["credentialState"], "cleared");
    assert_eq!(
        rt.workspace().provider_configuration().credential,
        CredentialBinding::Cleared
    );
    drop(rt);

    let rt = KoeRuntime::open_with_credentials(&dir.0, Box::new(MockKeystore(shared.clone())))
        .unwrap();
    assert_eq!(
        rt.snapshot(100)["provider"]["credentialState"],
        "cleared",
        "tombstone_non_resurrection: legacy secret must not resurrect cleared slot"
    );
    assert!(shared.lock().unwrap().items.is_empty());
    drop(rt);

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let latch_dir = Sandbox::new("latch");
        let mut store = ProductStore::open(&latch_dir.0).unwrap();
        assert!(!store.requires_reopen());
        fs::set_permissions(&latch_dir.0, fs::Permissions::from_mode(0o300)).unwrap();
        let err = store.transact(|w| {
            w.insert_record(
                "rec-1".into(),
                "Latch".into(),
                koe_engine::product::RecordOrigin::Note,
                0,
                100,
                0,
            )
        });
        assert!(matches!(err, Err(StoreError::CommitUncertain(_))), "{err:?}");
        assert!(store.requires_reopen());
        fs::set_permissions(&latch_dir.0, fs::Permissions::from_mode(0o700)).unwrap();
        let second = store.transact(|w| w.rename_record("rec-1", "Blocked"));
        assert!(matches!(second, Err(StoreError::Unavailable)), "{second:?}");
        assert!(store.requires_reopen());
        drop(store);
        let reopened = ProductStore::open(&latch_dir.0).unwrap();
        assert!(!reopened.requires_reopen());
        assert!(reopened.workspace().record("rec-1").is_some());
    }
}
