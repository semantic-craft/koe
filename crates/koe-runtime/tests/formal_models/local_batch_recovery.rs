use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use koe_client_services::recording_assets;
use koe_engine::product::{AnalysisStage, AnalysisState, RecordOrigin, SpeechEngine};
use koe_runtime::{KoeRuntime, LocalAsrEffect};
use serde_json::{json, Value};

use crate::checker::{
    check_liveness, explore_bfs, format_trace, LivenessOutcome, ModelOutcome, ProtocolModel,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum EngineMode {
    Local,
    Cloud,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum RecordStatus {
    IdleBean,
    PendingLocal { resumed_partial: bool },
    FailedLocal,
    PendingCloudAsr { cloud_bound: bool },
    InterruptedLocal { resumed_partial: bool },
    InterruptedCloudAsr { cloud_bound: bool },
    Transcribed,
    PendingSummary,
    InterruptedSummary,
    Summarized,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct BatchState {
    engine: EngineMode,
    expects_local_drain: bool,
    records: [RecordStatus; 3],
    auto_transcribe: u8,
    auto_summarize: u8,
    active_local_sessions: u8,
    worker_outstanding: u8,
    summary_inflight: u8,
    crash_budget: u8,
    switch_budget: u8,
    fail_budget: u8,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum BatchAction {
    DriveQueue,
    CompleteLocal(usize),
    FailLocal(usize),
    DrainWorkerSlots,
    RetryFailedWithCloud(usize),
    CompleteCloudAsr(usize),
    CompleteSummary(usize),
    CrashAndRestart,
    SwitchEngine(EngineMode),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum BatchMutant {
    Clean,
    UnboundedLocalAdmission,
    IgnoreWorkerSlotLeak,
    RetryCloudOnRestart,
    ForgetCloudBindOnRetry,
    DropIdleBeanOnRestart,
    DropBoundLocalOnCloudSwitch,
    DropSecondInterruptedLocal,
}

struct LocalBatchRecoveryModel {
    mutant: BatchMutant,
}

const WINDOWS_PER_FILE: u8 = 3;
const WORKER_MAX_OUTSTANDING: u8 = 4;

impl BatchState {
    fn has_cloud_asr_inflight(&self) -> bool {
        self.records
            .iter()
            .any(|r| matches!(r, RecordStatus::PendingCloudAsr { .. }))
    }

    fn has_any_inflight(&self) -> bool {
        self.active_local_sessions > 0
            || self.worker_outstanding > 0
            || self.summary_inflight > 0
            || self.has_cloud_asr_inflight()
    }
}

impl ProtocolModel for LocalBatchRecoveryModel {
    type State = BatchState;
    type Action = BatchAction;

    fn init(&self) -> Vec<BatchState> {
        vec![
            BatchState {
                engine: EngineMode::Local,
                expects_local_drain: true,
                records: [
                    RecordStatus::IdleBean,
                    RecordStatus::IdleBean,
                    RecordStatus::IdleBean,
                ],
                auto_transcribe: 0b111,
                auto_summarize: 0,
                active_local_sessions: 0,
                worker_outstanding: 0,
                summary_inflight: 0,
                crash_budget: 1,
                switch_budget: 1,
                fail_budget: 1,
            },
            BatchState {
                engine: EngineMode::Cloud,
                expects_local_drain: false,
                records: [
                    RecordStatus::IdleBean,
                    RecordStatus::PendingCloudAsr { cloud_bound: true },
                    RecordStatus::PendingSummary,
                ],
                auto_transcribe: 0b001,
                auto_summarize: 0,
                active_local_sessions: 0,
                worker_outstanding: 0,
                summary_inflight: 1,
                crash_budget: 1,
                switch_budget: 1,
                fail_budget: 0,
            },
            BatchState {
                engine: EngineMode::Cloud,
                expects_local_drain: false,
                records: [
                    RecordStatus::FailedLocal,
                    RecordStatus::IdleBean,
                    RecordStatus::Transcribed,
                ],
                auto_transcribe: 0,
                auto_summarize: 0,
                active_local_sessions: 0,
                worker_outstanding: 0,
                summary_inflight: 0,
                crash_budget: 1,
                switch_budget: 1,
                fail_budget: 0,
            },
            BatchState {
                engine: EngineMode::Local,
                expects_local_drain: true,
                records: [
                    RecordStatus::PendingLocal {
                        resumed_partial: false,
                    },
                    RecordStatus::IdleBean,
                    RecordStatus::Transcribed,
                ],
                auto_transcribe: 0b010,
                auto_summarize: 0,
                active_local_sessions: 1,
                worker_outstanding: WINDOWS_PER_FILE,
                summary_inflight: 0,
                crash_budget: 2,
                switch_budget: 1,
                fail_budget: 0,
            },
        ]
    }

    fn actions(&self, s: &BatchState) -> Vec<BatchAction> {
        let mut acts = Vec::new();
        let can_admit_local = match self.mutant {
            BatchMutant::UnboundedLocalAdmission => true,
            BatchMutant::IgnoreWorkerSlotLeak => s.active_local_sessions == 0,
            _ => s.active_local_sessions == 0 && s.worker_outstanding == 0,
        };
        let can_drive_summary = s.summary_inflight == 0 && s.auto_summarize != 0;
        let can_drive_transcribe = (0..3).any(|idx| {
            if (s.auto_transcribe & (1 << idx)) == 0 {
                return false;
            }
            match s.records[idx] {
                RecordStatus::InterruptedLocal { .. } => can_admit_local,
                RecordStatus::InterruptedCloudAsr { .. } => !s.has_cloud_asr_inflight(),
                RecordStatus::InterruptedSummary => true,
                _ => match s.engine {
                    EngineMode::Cloud => !s.has_cloud_asr_inflight(),
                    EngineMode::Local => can_admit_local,
                },
            }
        });
        if can_drive_summary || can_drive_transcribe {
            acts.push(BatchAction::DriveQueue);
        }
        if s.active_local_sessions == 0 && s.worker_outstanding > 0 {
            acts.push(BatchAction::DrainWorkerSlots);
        }
        for (idx, status) in s.records.iter().enumerate() {
            match status {
                RecordStatus::PendingLocal { .. } => {
                    acts.push(BatchAction::CompleteLocal(idx));
                    if s.fail_budget > 0 {
                        acts.push(BatchAction::FailLocal(idx));
                    }
                }
                RecordStatus::FailedLocal
                    if s.engine == EngineMode::Cloud && !s.has_cloud_asr_inflight() =>
                {
                    acts.push(BatchAction::RetryFailedWithCloud(idx));
                }
                RecordStatus::PendingCloudAsr { .. } => {
                    acts.push(BatchAction::CompleteCloudAsr(idx));
                }
                RecordStatus::PendingSummary => acts.push(BatchAction::CompleteSummary(idx)),
                _ => {}
            }
        }
        if s.crash_budget > 0 && (s.has_any_inflight() || s.auto_transcribe != 0) {
            acts.push(BatchAction::CrashAndRestart);
        }
        if s.switch_budget > 0 && s.summary_inflight == 0 {
            let idle_switch = s.active_local_sessions == 0 && s.worker_outstanding == 0;
            let cloud_switch_while_local_active = s.engine == EngineMode::Local
                && s.records
                    .iter()
                    .any(|r| matches!(r, RecordStatus::PendingLocal { .. }));
            if idle_switch || cloud_switch_while_local_active {
                let other = match s.engine {
                    EngineMode::Local => EngineMode::Cloud,
                    EngineMode::Cloud => EngineMode::Local,
                };
                acts.push(BatchAction::SwitchEngine(other));
            }
        }
        acts
    }

    fn step(&self, s: &BatchState, action: &BatchAction) -> Vec<BatchState> {
        let mut next = *s;
        match *action {
            BatchAction::DriveQueue => {
                if next.summary_inflight == 0 {
                    if let Some(idx) = (0..3).find(|i| (next.auto_summarize & (1 << i)) != 0) {
                        next.auto_summarize &= !(1 << idx);
                        if next.records[idx] == RecordStatus::Transcribed {
                            next.records[idx] = RecordStatus::PendingSummary;
                            next.summary_inflight += 1;
                        }
                    }
                }
                let can_admit_local = match self.mutant {
                    BatchMutant::UnboundedLocalAdmission => true,
                    BatchMutant::IgnoreWorkerSlotLeak => next.active_local_sessions == 0,
                    _ => next.active_local_sessions == 0 && next.worker_outstanding == 0,
                };
                let candidate = (0..3).find(|&idx| {
                    if (next.auto_transcribe & (1 << idx)) == 0 {
                        return false;
                    }
                    match next.records[idx] {
                        RecordStatus::InterruptedLocal { .. } => can_admit_local,
                        RecordStatus::InterruptedCloudAsr { .. } => !next.has_cloud_asr_inflight(),
                        RecordStatus::InterruptedSummary => true,
                        _ => match next.engine {
                            EngineMode::Cloud => !next.has_cloud_asr_inflight(),
                            EngineMode::Local => can_admit_local,
                        },
                    }
                });
                if let Some(idx) = candidate {
                    next.auto_transcribe &= !(1 << idx);
                    match next.records[idx] {
                        RecordStatus::InterruptedLocal { .. } => {
                            next.records[idx] = RecordStatus::PendingLocal {
                                resumed_partial: true,
                            };
                            next.active_local_sessions += 1;
                            next.worker_outstanding += WINDOWS_PER_FILE;
                        }
                        RecordStatus::IdleBean => {
                            if next.engine == EngineMode::Local {
                                next.records[idx] = RecordStatus::PendingLocal {
                                    resumed_partial: false,
                                };
                                next.active_local_sessions += 1;
                                next.worker_outstanding += WINDOWS_PER_FILE;
                            } else {
                                next.records[idx] =
                                    RecordStatus::PendingCloudAsr { cloud_bound: true };
                            }
                        }
                        RecordStatus::InterruptedCloudAsr { cloud_bound } => {
                            next.records[idx] = RecordStatus::PendingCloudAsr { cloud_bound };
                        }
                        RecordStatus::InterruptedSummary => {
                            next.records[idx] = RecordStatus::PendingSummary;
                            next.summary_inflight += 1;
                        }
                        _ => {}
                    }
                }
            }
            BatchAction::CompleteLocal(idx) => {
                if matches!(next.records[idx], RecordStatus::PendingLocal { .. }) {
                    next.records[idx] = RecordStatus::Transcribed;
                    next.active_local_sessions = next.active_local_sessions.saturating_sub(1);
                    next.worker_outstanding =
                        next.worker_outstanding.saturating_sub(WINDOWS_PER_FILE);
                    next.auto_summarize |= 1 << idx;
                }
            }
            BatchAction::FailLocal(idx) => {
                if matches!(next.records[idx], RecordStatus::PendingLocal { .. })
                    && next.fail_budget > 0
                {
                    next.fail_budget -= 1;
                    next.records[idx] = RecordStatus::FailedLocal;
                    next.active_local_sessions = next.active_local_sessions.saturating_sub(1);
                }
            }
            BatchAction::DrainWorkerSlots => {
                if next.active_local_sessions == 0 {
                    next.worker_outstanding = 0;
                }
            }
            BatchAction::RetryFailedWithCloud(idx) => {
                if next.records[idx] == RecordStatus::FailedLocal
                    && next.engine == EngineMode::Cloud
                    && !next.has_cloud_asr_inflight()
                {
                    let cloud_bound = self.mutant != BatchMutant::ForgetCloudBindOnRetry;
                    next.records[idx] = RecordStatus::PendingCloudAsr { cloud_bound };
                }
            }
            BatchAction::CompleteCloudAsr(idx) => {
                if matches!(next.records[idx], RecordStatus::PendingCloudAsr { .. }) {
                    next.records[idx] = RecordStatus::Transcribed;
                    next.auto_summarize |= 1 << idx;
                }
            }
            BatchAction::CompleteSummary(idx) => {
                if next.records[idx] == RecordStatus::PendingSummary {
                    next.records[idx] = RecordStatus::Summarized;
                    next.summary_inflight = next.summary_inflight.saturating_sub(1);
                }
            }
            BatchAction::CrashAndRestart => {
                next.crash_budget -= 1;
                next.expects_local_drain = next.engine == EngineMode::Local;
                next.auto_transcribe = 0;
                next.auto_summarize = 0;
                next.active_local_sessions = 0;
                next.worker_outstanding = 0;
                next.summary_inflight = 0;
                for status in &mut next.records {
                    *status = match *status {
                        RecordStatus::PendingLocal { resumed_partial } => {
                            RecordStatus::InterruptedLocal { resumed_partial }
                        }
                        RecordStatus::PendingCloudAsr { cloud_bound } => {
                            RecordStatus::InterruptedCloudAsr { cloud_bound }
                        }
                        RecordStatus::PendingSummary => RecordStatus::InterruptedSummary,
                        other => other,
                    };
                }
                for (idx, status) in next.records.iter().enumerate() {
                    let recover = match self.mutant {
                        BatchMutant::RetryCloudOnRestart => matches!(
                            status,
                            RecordStatus::InterruptedLocal { .. }
                                | RecordStatus::InterruptedCloudAsr { .. }
                                | RecordStatus::InterruptedSummary
                        ) || (next.engine == EngineMode::Local
                            && *status == RecordStatus::IdleBean),
                        BatchMutant::DropIdleBeanOnRestart => {
                            matches!(status, RecordStatus::InterruptedLocal { .. })
                        }
                        BatchMutant::DropBoundLocalOnCloudSwitch => {
                            next.engine == EngineMode::Local
                                && matches!(
                                    status,
                                    RecordStatus::IdleBean
                                        | RecordStatus::InterruptedLocal { .. }
                                        | RecordStatus::InterruptedCloudAsr { cloud_bound: false }
                                )
                        }
                        BatchMutant::DropSecondInterruptedLocal => {
                            matches!(
                                status,
                                RecordStatus::InterruptedLocal {
                                    resumed_partial: false
                                } | RecordStatus::InterruptedCloudAsr { cloud_bound: false }
                            ) || (next.engine == EngineMode::Local
                                && *status == RecordStatus::IdleBean)
                        }
                        BatchMutant::Clean
                        | BatchMutant::UnboundedLocalAdmission
                        | BatchMutant::IgnoreWorkerSlotLeak
                        | BatchMutant::ForgetCloudBindOnRetry => {
                            matches!(
                                status,
                                RecordStatus::InterruptedLocal { .. }
                                    | RecordStatus::InterruptedCloudAsr { cloud_bound: false }
                            ) || (next.engine == EngineMode::Local
                                && *status == RecordStatus::IdleBean)
                        }
                    };
                    if recover {
                        next.auto_transcribe |= 1 << idx;
                    }
                }
            }
            BatchAction::SwitchEngine(engine) => {
                next.switch_budget -= 1;
                next.engine = engine;
                if engine == EngineMode::Cloud {
                    next.expects_local_drain = false;
                }
            }
        }
        vec![next]
    }

    fn check_invariants(
        &self,
        prev: Option<&BatchState>,
        action: Option<&BatchAction>,
        next: &BatchState,
    ) -> Result<(), String> {
        if next.active_local_sessions > 1 || next.worker_outstanding > WORKER_MAX_OUTSTANDING {
            return Err(format!(
                "single_flight_local_file_admission: active_local_sessions={} worker_outstanding={}",
                next.active_local_sessions, next.worker_outstanding
            ));
        }
        if next.summary_inflight > 1 {
            return Err(format!(
                "single_slot_summary_lane: summary_inflight={}",
                next.summary_inflight
            ));
        }
        if let (Some(p), Some(act)) = (prev, action) {
            if *act == BatchAction::CrashAndRestart {
                for (idx, status) in next.records.iter().enumerate() {
                    if matches!(
                        status,
                        RecordStatus::PendingLocal { .. }
                            | RecordStatus::PendingCloudAsr { .. }
                            | RecordStatus::PendingSummary
                    ) {
                        return Err(format!(
                            "no_silent_paid_retry_on_restart: pending status {status:?} survived restart"
                        ));
                    }
                    if matches!(
                        status,
                        RecordStatus::InterruptedCloudAsr { .. } | RecordStatus::InterruptedSummary
                    ) && ((next.auto_transcribe & (1 << idx)) != 0
                        || (next.auto_summarize & (1 << idx)) != 0)
                    {
                        return Err(format!(
                            "no_silent_paid_retry_on_restart: {status:?} auto-enqueued on restart"
                        ));
                    }
                    if next.engine == EngineMode::Cloud
                        && (next.auto_transcribe & (1 << idx)) != 0
                        && !matches!(status, RecordStatus::InterruptedLocal { .. })
                    {
                        return Err(format!(
                            "no_silent_paid_retry_on_restart: non-bound-local {status:?} enqueued under Cloud engine"
                        ));
                    }
                }
            }
            for idx in 0..3 {
                if matches!(
                    p.records[idx],
                    RecordStatus::InterruptedCloudAsr { .. } | RecordStatus::InterruptedSummary
                ) && next.records[idx] != p.records[idx]
                {
                    return Err(format!(
                        "no_silent_paid_retry_on_restart: {:?} silently transitioned to {:?}",
                        p.records[idx], next.records[idx]
                    ));
                }
                if matches!(p.records[idx], RecordStatus::InterruptedLocal { .. })
                    && matches!(next.records[idx], RecordStatus::PendingCloudAsr { .. })
                {
                    return Err(format!(
                        "no_silent_paid_retry_on_restart: bound local {:?} escalated to {:?}",
                        p.records[idx], next.records[idx]
                    ));
                }
            }
        }
        Ok(())
    }

    fn is_live_goal(&self, state: &BatchState) -> bool {
        let bound_local_stranded = state.records.iter().any(|status| {
            matches!(
                status,
                RecordStatus::PendingLocal { .. } | RecordStatus::InterruptedLocal { .. }
            )
        });
        let idle_bean_stranded =
            state.expects_local_drain && state.records.contains(&RecordStatus::IdleBean);
        !bound_local_stranded
            && !idle_bean_stranded
            && state.auto_transcribe == 0
            && state.active_local_sessions == 0
            && state.worker_outstanding == 0
            && state.summary_inflight == 0
            && state.auto_summarize == 0
            && !state.has_cloud_asr_inflight()
    }

    fn is_fair_edge(
        &self,
        _state: &BatchState,
        action: &BatchAction,
        _next: &BatchState,
    ) -> bool {
        matches!(
            action,
            BatchAction::DriveQueue
                | BatchAction::CompleteLocal(_)
                | BatchAction::DrainWorkerSlots
                | BatchAction::CompleteCloudAsr(_)
                | BatchAction::CompleteSummary(_)
        )
    }
}

struct Sandbox(PathBuf);

impl Sandbox {
    fn new(tag: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "koe-fm-batch-{tag}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn send(runtime: &mut KoeRuntime, value: Value) -> Value {
    serde_json::from_str(&runtime.dispatch_json(&value.to_string(), 1_800_000_000)).unwrap()
}

#[test]
fn local_batch_recovery_model_clean_bfs_and_liveness() {
    let model = LocalBatchRecoveryModel {
        mutant: BatchMutant::Clean,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::Pass {
            states_explored,
            transitions_explored,
        } => {
            println!(
                "[MODEL] local_batch_recovery CLEAN BFS: states={states_explored} transitions={transitions_explored}"
            );
            assert!(
                states_explored >= 100,
                "expected non-trivial state space, got {states_explored}"
            );
            assert!(transitions_explored > states_explored);
        }
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => panic!(
            "clean local_batch_recovery model failed: {violation}\n{}",
            format_trace(&trace)
        ),
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
                "[MODEL] local_batch_recovery CLEAN LIVENESS: states={states_explored} sccs={scc_count} terminal_sccs={terminal_sccs}"
            );
            assert!(states_explored >= 100);
            assert!(terminal_sccs >= 1);
        }
        LivenessOutcome::TrappedScc { trace_to_trap, .. } => {
            panic!(
                "clean local_batch_recovery liveness failed:\n{}",
                format_trace(&trace_to_trap)
            );
        }
        LivenessOutcome::StateSpaceExceeded { max_states } => {
            panic!("liveness state space exceeded {max_states}");
        }
    }
}

#[test]
fn local_batch_recovery_mutant_unbounded_local_admission() {
    let model = LocalBatchRecoveryModel {
        mutant: BatchMutant::UnboundedLocalAdmission,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] unbounded_local_admission -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("single_flight_local_file_admission"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected single_flight_local_file_admission violation, got {other:?}"),
    }
}

#[test]
fn local_batch_recovery_mutant_ignore_worker_slot_leak() {
    let model = LocalBatchRecoveryModel {
        mutant: BatchMutant::IgnoreWorkerSlotLeak,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] ignore_worker_slot_leak -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("single_flight_local_file_admission"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected single_flight_local_file_admission violation, got {other:?}"),
    }
}

#[test]
fn local_batch_recovery_mutant_retry_cloud_on_restart() {
    let model = LocalBatchRecoveryModel {
        mutant: BatchMutant::RetryCloudOnRestart,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] retry_cloud_on_restart -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("no_silent_paid_retry_on_restart"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected no_silent_paid_retry_on_restart violation, got {other:?}"),
    }
}

#[test]
fn local_batch_recovery_mutant_forget_cloud_bind_on_retry() {
    let model = LocalBatchRecoveryModel {
        mutant: BatchMutant::ForgetCloudBindOnRetry,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] forget_cloud_bind_on_retry -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("no_silent_paid_retry_on_restart"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected no_silent_paid_retry_on_restart violation, got {other:?}"),
    }
}

#[test]
fn local_batch_recovery_mutant_drop_idle_bean_on_restart() {
    let model = LocalBatchRecoveryModel {
        mutant: BatchMutant::DropIdleBeanOnRestart,
    };
    match check_liveness(&model, 50_000) {
        LivenessOutcome::TrappedScc {
            scc_size,
            trace_to_trap,
            trap_states,
            ..
        } => {
            println!(
                "[MUTANT] drop_idle_bean_on_restart -> TrappedScc(size={scc_size})\n{}",
                format_trace(&trace_to_trap)
            );
            assert!(
                trap_states.iter().any(|s| {
                    s.engine == EngineMode::Local
                        && s.records.contains(&RecordStatus::IdleBean)
                }),
                "expected stranded IdleBean trap:\n{}",
                format_trace(&trace_to_trap)
            );
        }
        other => panic!("expected TrappedScc for drop_idle_bean_on_restart, got {other:?}"),
    }
}

#[test]
fn local_batch_recovery_mutant_drop_bound_local_on_cloud_switch() {
    let model = LocalBatchRecoveryModel {
        mutant: BatchMutant::DropBoundLocalOnCloudSwitch,
    };
    match check_liveness(&model, 50_000) {
        LivenessOutcome::TrappedScc {
            scc_size,
            trace_to_trap,
            trap_states,
            ..
        } => {
            println!(
                "[MUTANT] drop_bound_local_on_cloud_switch -> TrappedScc(size={scc_size})\n{}",
                format_trace(&trace_to_trap)
            );
            assert!(
                trap_states.iter().any(|s| {
                    s.engine == EngineMode::Cloud
                        && s.records
                            .iter()
                            .any(|r| matches!(r, RecordStatus::InterruptedLocal { .. }))
                }),
                "expected stranded bound InterruptedLocal under Cloud engine:\n{}",
                format_trace(&trace_to_trap)
            );
        }
        other => panic!("expected TrappedScc for drop_bound_local_on_cloud_switch, got {other:?}"),
    }
}

#[test]
fn local_batch_recovery_mutant_drop_second_interrupted_local() {
    let model = LocalBatchRecoveryModel {
        mutant: BatchMutant::DropSecondInterruptedLocal,
    };
    match check_liveness(&model, 50_000) {
        LivenessOutcome::TrappedScc {
            scc_size,
            trace_to_trap,
            trap_states,
            ..
        } => {
            println!(
                "[MUTANT] drop_second_interrupted_local -> TrappedScc(size={scc_size})\n{}",
                format_trace(&trace_to_trap)
            );
            assert!(
                trap_states.iter().any(|s| {
                    s.records.contains(&RecordStatus::InterruptedLocal {
                        resumed_partial: true,
                    })
                }),
                "expected stranded resumed_partial InterruptedLocal trap:\n{}",
                format_trace(&trace_to_trap)
            );
        }
        other => panic!("expected TrappedScc for drop_second_interrupted_local, got {other:?}"),
    }
}

#[test]
fn local_batch_recovery_real_code_trace_replay() {
    let dir = Sandbox::new("trace-replay");
    {
        let mut store = koe_client_services::product_store::ProductStore::open(&dir.0).unwrap();
        store
            .transact(|ws| {
                let mut cfg = ws.provider_configuration().clone();
                cfg.speech_engine = SpeechEngine::AppleSpeech;
                ws.configure_provider(cfg)?;
                for idx in 1..=3 {
                    let id = format!("bean-{idx}");
                    ws.insert_record(
                        id,
                        format!("Bean {idx}"),
                        RecordOrigin::Bean,
                        idx,
                        1_800_000_000 + u64::from(idx),
                        1_000,
                    )?;
                }
                ws.bind_speech_engine("bean-1", SpeechEngine::AppleSpeech)?;
                ws.begin_analysis("bean-1", AnalysisStage::Transcribing)?;

                ws.insert_record(
                    "cloud-interrupted".into(),
                    "Cloud".into(),
                    RecordOrigin::Bean,
                    9,
                    1_800_000_009,
                    1_000,
                )?;
                ws.bind_speech_engine("cloud-interrupted", SpeechEngine::Cloud)?;
                ws.begin_analysis("cloud-interrupted", AnalysisStage::Transcribing)?;
                Ok(())
            })
            .unwrap();
        let mut wav = koe_engine::wav::OpusWave::wav_header_with_rate(640, 16_000).to_vec();
        wav.extend(vec![16u8; 640]);
        for id in ["bean-1", "bean-2", "bean-3", "cloud-interrupted"] {
            recording_assets::save_audio(&dir.0, id, &wav).unwrap();
        }
    }

    let mut rt = KoeRuntime::open(&dir.0).unwrap();
    assert!(
        send(
            &mut rt,
            json!({"type": "local_asr_readiness", "state": "ready", "message": "ready"}),
        )["error"]
            .is_null()
    );

    for expected_id in ["bean-1", "bean-2", "bean-3"] {
        rt.poll_timers(0, 1_800_000_010);
        rt.poll_timers(0, 1_800_000_010);
        let jobs = rt.active_local_speech_jobs();
        assert_eq!(jobs.len(), 1, "local concurrency exceeded 1: {jobs:?}");
        assert_eq!(jobs[0].record_id, expected_id);
        let op = rt
            .drain_local_asr_effects()
            .into_iter()
            .find_map(|effect| match effect {
                LocalAsrEffect::Start { operation_id, .. } => Some(operation_id),
                _ => None,
            })
            .unwrap();
        assert!(
            send(
                &mut rt,
                json!({
                    "type": "local_asr_result",
                    "operationId": op,
                    "text": format!("Replayed {expected_id}"),
                    "startMs": 0,
                    "endMs": 40,
                    "isFinal": true
                }),
            )["error"]
                .is_null()
        );
        assert!(
            send(
                &mut rt,
                json!({"type": "local_asr_finished", "operationId": op}),
            )["error"]
                .is_null()
        );
    }

    rt.poll_timers(0, 1_800_000_011);
    assert!(rt.active_local_speech_jobs().is_empty());
    assert!(matches!(
        rt.workspace().record("cloud-interrupted").unwrap().analysis,
        AnalysisState::Interrupted { .. }
    ));
}
