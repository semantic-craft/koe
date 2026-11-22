use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use koe_client_services::capture_asset::CaptureAsset;
use koe_runtime::{KoeRuntime, MicrophonePcmChunk, PcmIngestStatus};
use serde_json::{json, Value};

use crate::checker::{
    check_liveness, explore_bfs, format_trace, LivenessOutcome, ModelOutcome, ProtocolModel,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum CapturePhase {
    Recording,
    Pausing,
    Paused,
    Stopping,
    Saved,
    CrashedWithSpool,
    RecoveredUncommitted,
    RecoveredCommitted,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct LaneState {
    paused: bool,
    stopped: bool,
    has_audio: bool,
    interruption: bool,
    pending_retry: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct DualCaptureState {
    phase: CapturePhase,
    epoch: u8,
    mic: LaneState,
    sys: LaneState,
    spool_present: bool,
    wav_published: bool,
    metadata_committed: bool,
    pause_budget: u8,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum DualCaptureAction {
    ChunkMic,
    ChunkSys,
    MicAppendError,
    RetryMicChunk,
    RequestPause,
    LanePausedMic,
    LanePausedSys,
    Resume,
    StaleOrUntaggedTerminalCallback,
    FailSysLane,
    StopMic,
    StopSys,
    SaveSession,
    CrashBeforeSave,
    RecoverSpool,
    CommitRecoveredMetadata,
    ReleaseRecoveredSpool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DualCaptureMutant {
    Clean,
    Pr624UntaggedOrOldEpochTerminalKillsCapture,
    Pr621ChunkRetryClearsInterruption,
    Pr715SingleLaneFailureKillsSiblingLane,
    Pr663ReleaseRecoveredBeforeCommit,
}

struct DualCaptureModel {
    mutant: DualCaptureMutant,
}

impl DualCaptureState {
    fn all_lanes_failed_or_stopped(&self) -> bool {
        (self.mic.stopped || self.mic.interruption) && (self.sys.stopped || self.sys.interruption)
    }

    fn all_lanes_paused(&self) -> bool {
        (self.mic.paused || self.mic.stopped) && (self.sys.paused || self.sys.stopped)
    }
}

impl ProtocolModel for DualCaptureModel {
    type State = DualCaptureState;
    type Action = DualCaptureAction;

    fn init(&self) -> Vec<DualCaptureState> {
        let lane = LaneState {
            paused: false,
            stopped: false,
            has_audio: false,
            interruption: false,
            pending_retry: false,
        };
        vec![DualCaptureState {
            phase: CapturePhase::Recording,
            epoch: 0,
            mic: lane,
            sys: lane,
            spool_present: true,
            wav_published: false,
            metadata_committed: false,
            pause_budget: 1,
        }]
    }

    fn actions(&self, s: &DualCaptureState) -> Vec<DualCaptureAction> {
        let mut acts = Vec::new();
        match s.phase {
            CapturePhase::Recording => {
                if !s.mic.stopped && !s.mic.has_audio {
                    acts.push(DualCaptureAction::ChunkMic);
                }
                if !s.sys.stopped && !s.sys.has_audio {
                    acts.push(DualCaptureAction::ChunkSys);
                }
                if !s.mic.stopped && !s.mic.interruption && !s.mic.pending_retry {
                    acts.push(DualCaptureAction::MicAppendError);
                }
                if !s.mic.stopped && s.mic.pending_retry {
                    acts.push(DualCaptureAction::RetryMicChunk);
                }
                if s.pause_budget > 0 && !s.mic.stopped {
                    acts.push(DualCaptureAction::RequestPause);
                }
                if s.epoch > 0 {
                    acts.push(DualCaptureAction::StaleOrUntaggedTerminalCallback);
                }
                if !s.sys.stopped && !s.sys.interruption {
                    acts.push(DualCaptureAction::FailSysLane);
                }
                if !s.mic.stopped && s.mic.has_audio {
                    acts.push(DualCaptureAction::StopMic);
                }
                if !s.sys.stopped && (s.sys.has_audio || s.sys.interruption) {
                    acts.push(DualCaptureAction::StopSys);
                }
                if s.mic.has_audio && s.spool_present {
                    acts.push(DualCaptureAction::CrashBeforeSave);
                }
            }
            CapturePhase::Pausing => {
                if !s.mic.paused && !s.mic.stopped {
                    acts.push(DualCaptureAction::LanePausedMic);
                }
                if !s.sys.paused && !s.sys.stopped {
                    acts.push(DualCaptureAction::LanePausedSys);
                }
            }
            CapturePhase::Paused => {
                acts.push(DualCaptureAction::Resume);
            }
            CapturePhase::Stopping => {
                if !s.mic.stopped && s.mic.pending_retry {
                    acts.push(DualCaptureAction::RetryMicChunk);
                }
                if !s.mic.stopped {
                    acts.push(DualCaptureAction::StopMic);
                }
                if !s.sys.stopped {
                    acts.push(DualCaptureAction::StopSys);
                }
                if s.mic.stopped && s.sys.stopped {
                    acts.push(DualCaptureAction::SaveSession);
                }
            }
            CapturePhase::CrashedWithSpool => {
                acts.push(DualCaptureAction::RecoverSpool);
            }
            CapturePhase::RecoveredUncommitted => {
                acts.push(DualCaptureAction::CommitRecoveredMetadata);
                acts.push(DualCaptureAction::CrashBeforeSave);
            }
            CapturePhase::RecoveredCommitted => {
                if s.spool_present {
                    acts.push(DualCaptureAction::ReleaseRecoveredSpool);
                }
            }
            CapturePhase::Saved => {}
        }
        acts
    }

    fn step(&self, s: &DualCaptureState, action: &DualCaptureAction) -> Vec<DualCaptureState> {
        let mut next = *s;

        match *action {
            DualCaptureAction::ChunkMic => {
                next.mic.has_audio = true;
            }
            DualCaptureAction::ChunkSys => {
                next.sys.has_audio = true;
            }
            DualCaptureAction::MicAppendError => {
                next.mic.interruption = true;
                next.mic.pending_retry = true;
                next.phase = CapturePhase::Stopping;
            }
            DualCaptureAction::RetryMicChunk => {
                next.mic.has_audio = true;
                next.mic.pending_retry = false;
                if self.mutant == DualCaptureMutant::Pr621ChunkRetryClearsInterruption {
                    next.mic.interruption = false;
                }
            }
            DualCaptureAction::RequestPause => {
                next.pause_budget -= 1;
                next.phase = CapturePhase::Pausing;
            }
            DualCaptureAction::LanePausedMic => {
                next.mic.paused = true;
                if next.all_lanes_paused() {
                    next.phase = CapturePhase::Paused;
                }
            }
            DualCaptureAction::LanePausedSys => {
                next.sys.paused = true;
                if next.all_lanes_paused() {
                    next.phase = CapturePhase::Paused;
                }
            }
            DualCaptureAction::Resume => {
                next.epoch += 1;
                next.phase = CapturePhase::Recording;
                if !next.mic.stopped {
                    next.mic.paused = false;
                }
                if !next.sys.stopped {
                    next.sys.paused = false;
                }
            }
            DualCaptureAction::StaleOrUntaggedTerminalCallback => {
                if self.mutant == DualCaptureMutant::Pr624UntaggedOrOldEpochTerminalKillsCapture {
                    next.mic.stopped = true;
                    next.phase = CapturePhase::Stopping;
                }
            }
            DualCaptureAction::FailSysLane => {
                next.sys.interruption = true;
                if self.mutant == DualCaptureMutant::Pr715SingleLaneFailureKillsSiblingLane
                    || next.all_lanes_failed_or_stopped()
                {
                    next.phase = CapturePhase::Stopping;
                }
            }
            DualCaptureAction::StopMic => {
                next.mic.stopped = true;
                if next.all_lanes_failed_or_stopped() {
                    next.phase = CapturePhase::Stopping;
                }
            }
            DualCaptureAction::StopSys => {
                next.sys.stopped = true;
                if next.all_lanes_failed_or_stopped() {
                    next.phase = CapturePhase::Stopping;
                }
            }
            DualCaptureAction::SaveSession => {
                next.wav_published = next.mic.has_audio || next.sys.has_audio;
                next.metadata_committed = true;
                next.spool_present = false;
                next.phase = CapturePhase::Saved;
            }
            DualCaptureAction::CrashBeforeSave => {
                next.phase = CapturePhase::CrashedWithSpool;
            }
            DualCaptureAction::RecoverSpool => {
                next.wav_published = true;
                if self.mutant == DualCaptureMutant::Pr663ReleaseRecoveredBeforeCommit {
                    next.spool_present = false;
                }
                next.phase = CapturePhase::RecoveredUncommitted;
            }
            DualCaptureAction::CommitRecoveredMetadata => {
                next.metadata_committed = true;
                next.phase = CapturePhase::RecoveredCommitted;
            }
            DualCaptureAction::ReleaseRecoveredSpool => {
                next.spool_present = false;
            }
        }
        vec![next]
    }

    fn check_invariants(
        &self,
        prev: Option<&DualCaptureState>,
        action: Option<&DualCaptureAction>,
        next: &DualCaptureState,
    ) -> Result<(), String> {
        if next.phase == CapturePhase::Paused && !next.all_lanes_paused() {
            return Err("pause_fence_completeness: entered Paused before all lanes paused".into());
        }

        if let (Some(p), Some(act)) = (prev, action) {
            if *act == DualCaptureAction::StaleOrUntaggedTerminalCallback && *next != *p {
                return Err(
                    "epoch_isolation_on_terminal_callbacks: stale or untagged callback mutated capture state"
                        .into(),
                );
            }
            if *act == DualCaptureAction::Resume
                && (p.phase != CapturePhase::Paused || next.epoch != p.epoch + 1)
            {
                return Err("pause_fence_completeness: invalid resume transition".into());
            }
            if *act == DualCaptureAction::FailSysLane
                && !p.mic.stopped
                && !p.mic.interruption
                && next.phase == CapturePhase::Stopping
            {
                return Err(
                    "partial_lane_survival: single lane failure killed healthy sibling lane".into(),
                );
            }
            if *act == DualCaptureAction::RetryMicChunk && p.mic.interruption && !next.mic.interruption
            {
                return Err(
                    "interruption_preserved_on_retry: chunk retry wiped recorded interruption"
                        .into(),
                );
            }
        }

        if matches!(
            next.phase,
            CapturePhase::CrashedWithSpool | CapturePhase::RecoveredUncommitted
        ) && !next.metadata_committed
            && !next.spool_present
        {
            return Err(
                "commit_before_release_recovery: .capture spool removed before metadata commit"
                    .into(),
            );
        }

        Ok(())
    }

    fn is_live_goal(&self, state: &DualCaptureState) -> bool {
        matches!(
            state.phase,
            CapturePhase::Saved | CapturePhase::RecoveredCommitted
        ) && state.metadata_committed
            && !state.spool_present
    }

    fn is_fair_edge(
        &self,
        _state: &DualCaptureState,
        action: &DualCaptureAction,
        _next: &DualCaptureState,
    ) -> bool {
        !matches!(
            action,
            DualCaptureAction::CrashBeforeSave | DualCaptureAction::StaleOrUntaggedTerminalCallback
        )
    }
}

struct Sandbox(PathBuf);

impl Sandbox {
    fn new(tag: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "koe-fm-dual-{tag}-{}-{}",
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

fn send(r: &mut KoeRuntime, v: Value) -> Value {
    serde_json::from_str(&r.dispatch_json(&v.to_string(), 1_800_000_000)).unwrap()
}

fn lane_event(r: &mut KoeRuntime, mic: &Value, lane: &str, mut v: Value) -> Value {
    v["recordId"] = mic["recordId"].clone();
    v["sessionId"] = mic["sessionId"].clone();
    v["lane"] = json!(lane);
    send(r, v)
}

#[test]
fn dual_capture_model_clean_bfs_and_liveness() {
    let model = DualCaptureModel {
        mutant: DualCaptureMutant::Clean,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::Pass {
            states_explored,
            transitions_explored,
        } => {
            println!(
                "[MODEL] dual_capture CLEAN BFS: states={states_explored} transitions={transitions_explored}"
            );
            assert!(
                states_explored >= 150,
                "expected non-trivial state space, got {states_explored}"
            );
            assert!(transitions_explored > states_explored);
        }
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => panic!("clean dual_capture model failed: {violation}\n{}", format_trace(&trace)),
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
                "[MODEL] dual_capture CLEAN LIVENESS: states={states_explored} sccs={scc_count} terminal_sccs={terminal_sccs}"
            );
            assert!(states_explored >= 150);
            assert!(terminal_sccs >= 1);
        }
        LivenessOutcome::TrappedScc { trace_to_trap, .. } => {
            panic!("clean dual_capture liveness failed:\n{}", format_trace(&trace_to_trap));
        }
        LivenessOutcome::StateSpaceExceeded { max_states } => {
            panic!("liveness state space exceeded {max_states}");
        }
    }
}

#[test]
fn dual_capture_mutant_pr624_untagged_or_old_epoch_terminal_kills_capture() {
    let model = DualCaptureModel {
        mutant: DualCaptureMutant::Pr624UntaggedOrOldEpochTerminalKillsCapture,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr624_untagged_or_old_epoch_terminal_kills_capture -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("epoch_isolation_on_terminal_callbacks"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected epoch_isolation_on_terminal_callbacks violation, got {other:?}"),
    }
}

#[test]
fn dual_capture_mutant_pr621_chunk_retry_clears_interruption() {
    let model = DualCaptureModel {
        mutant: DualCaptureMutant::Pr621ChunkRetryClearsInterruption,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr621_chunk_retry_clears_interruption -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("interruption_preserved_on_retry"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected interruption_preserved_on_retry violation, got {other:?}"),
    }
}

#[test]
fn dual_capture_mutant_pr715_single_lane_failure_kills_sibling_lane() {
    let model = DualCaptureModel {
        mutant: DualCaptureMutant::Pr715SingleLaneFailureKillsSiblingLane,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr715_single_lane_failure_kills_sibling_lane -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("partial_lane_survival"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected partial_lane_survival violation, got {other:?}"),
    }
}

#[test]
fn dual_capture_mutant_pr663_release_recovered_before_commit() {
    let model = DualCaptureModel {
        mutant: DualCaptureMutant::Pr663ReleaseRecoveredBeforeCommit,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr663_release_recovered_before_commit -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("commit_before_release_recovery"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected commit_before_release_recovery violation, got {other:?}"),
    }
}

#[test]
fn dual_capture_real_code_trace_replay() {
    let dir = Sandbox::new("epochs-and-faults");
    let mut rt = KoeRuntime::open(&dir.0).unwrap();
    let started = send(
        &mut rt,
        json!({"type":"start_microphone","inputId":"mic-1","includeSystem":true,"clockNs":1_000_000_000u64}),
    );
    assert!(started["error"].is_null(), "{started}");
    let mic = started["microphone"].clone();
    let record_id = mic["recordId"].as_str().unwrap().to_string();
    let session_id = mic["sessionId"].as_str().unwrap().to_string();

    lane_event(
        &mut rt,
        &mic,
        "microphone",
        json!({"type":"microphone_started","sampleRate":16000}),
    );
    lane_event(
        &mut rt,
        &mic,
        "system",
        json!({"type":"microphone_started","sampleRate":16000}),
    );

    let samples = vec![500i16; 160];
    let r0 = rt.ingest_microphone_pcm(MicrophonePcmChunk {
        record_id: &record_id,
        session_id: &session_id,
        lane: "microphone",
        sequence: 0,
        samples: &samples,
        timing: Some((0, 1_000_000_000)),
        now: 1_800_000_000,
    });
    assert_eq!(r0.status, PcmIngestStatus::Accepted);
    let r1 = rt.ingest_microphone_pcm(MicrophonePcmChunk {
        record_id: &record_id,
        session_id: &session_id,
        lane: "system",
        sequence: 0,
        samples: &samples,
        timing: Some((0, 1_000_000_000)),
        now: 1_800_000_000,
    });
    assert_eq!(r1.status, PcmIngestStatus::Accepted);

    send(&mut rt, json!({"type":"pause_microphone"}));
    lane_event(
        &mut rt,
        &mic,
        "microphone",
        json!({"type":"microphone_paused","sequence":1,"epoch":0}),
    );
    assert_eq!(rt.snapshot(1_800_000_000)["microphone"]["phase"], "pausing");
    lane_event(
        &mut rt,
        &mic,
        "system",
        json!({"type":"microphone_paused","sequence":1,"epoch":0}),
    );
    assert_eq!(rt.snapshot(1_800_000_000)["microphone"]["phase"], "paused");

    let resumed = send(
        &mut rt,
        json!({"type":"resume_microphone","clockNs":3_000_000_000u64}),
    );
    assert_eq!(resumed["microphone"]["phase"], "recording");
    assert_eq!(resumed["microphone"]["epoch"], 1);

    lane_event(
        &mut rt,
        &mic,
        "microphone",
        json!({"type":"microphone_failed","message":"stale-epoch-0","epoch":0}),
    );
    lane_event(
        &mut rt,
        &mic,
        "microphone",
        json!({"type":"microphone_stopped","sequence":1}),
    );
    assert_eq!(
        rt.snapshot(1_800_000_000)["microphone"]["phase"],
        "recording",
        "PR #624: stale epoch 0 and untagged terminal callbacks must be ignored"
    );

    lane_event(
        &mut rt,
        &mic,
        "system",
        json!({"type":"microphone_failed","message":"system-audio-lost","epoch":1}),
    );
    lane_event(
        &mut rt,
        &mic,
        "system",
        json!({"type":"microphone_stopped","sequence":1,"epoch":1}),
    );
    assert_eq!(
        rt.snapshot(1_800_000_000)["microphone"]["phase"],
        "recording",
        "PR #715: single lane failure must not kill healthy microphone lane"
    );

    let r2 = rt.ingest_microphone_pcm(MicrophonePcmChunk {
        record_id: &record_id,
        session_id: &session_id,
        lane: "microphone",
        sequence: 1,
        samples: &samples,
        timing: Some((1, 3_000_000_000)),
        now: 1_800_000_001,
    });
    assert_eq!(r2.status, PcmIngestStatus::Accepted);

    lane_event(
        &mut rt,
        &mic,
        "microphone",
        json!({"type":"microphone_failed","message":"transient-mic-warn","epoch":1}),
    );
    let r3 = rt.ingest_microphone_pcm(MicrophonePcmChunk {
        record_id: &record_id,
        session_id: &session_id,
        lane: "microphone",
        sequence: 2,
        samples: &samples,
        timing: Some((1, 3_010_000_000)),
        now: 1_800_000_001,
    });
    assert_eq!(r3.status, PcmIngestStatus::Accepted);
    assert_eq!(
        rt.snapshot(1_800_000_001)["microphone"]["lanes"]["microphone"]["interruption"],
        "transient-mic-warn",
        "PR #621: subsequent chunk write must preserve lane interruption"
    );

    lane_event(
        &mut rt,
        &mic,
        "microphone",
        json!({"type":"microphone_stopped","sequence":3,"epoch":1}),
    );
    assert!(rt.snapshot(1_800_000_001)["microphone"].is_null());
    let rec = rt.workspace().record(&record_id).unwrap();
    assert_eq!(rec.capture_lanes.len(), 2);
    assert!(dir.0.join("audio").join(format!("{record_id}.wav")).exists());
    drop(rt);

    let rec_dir = Sandbox::new("recovery");
    let mut rt_rec = KoeRuntime::open(&rec_dir.0).unwrap();
    let note = send(
        &mut rt_rec,
        json!({"type":"create_note","title":"Crash spool","text":"initial line"}),
    );
    let crashed_id = note["selectedRecordId"].as_str().unwrap().to_string();
    drop(rt_rec);

    let mut asset = CaptureAsset::create(&rec_dir.0, &crashed_id, 16_000).unwrap();
    asset.append(&[100i16; 320]).unwrap();
    drop(asset);
    let staging = rec_dir.0.join("audio").join(format!("{crashed_id}.capture"));
    let target = rec_dir.0.join("audio").join(format!("{crashed_id}.wav"));
    assert!(staging.exists());
    assert!(!target.exists());

    let recovered_ms = CaptureAsset::recover(&rec_dir.0, &crashed_id).unwrap();
    assert_eq!(recovered_ms, Some(20));
    assert!(target.exists());
    assert!(
        staging.exists(),
        "PR #663: CaptureAsset::recover must leave .capture intact until workspace metadata commits"
    );

    let reopened = KoeRuntime::open(&rec_dir.0).unwrap();
    assert_eq!(
        reopened
            .workspace()
            .record(&crashed_id)
            .unwrap()
            .aggregate
            .duration_ms,
        20
    );
    assert!(
        !staging.exists(),
        "PR #663: KoeRuntime::open releases .capture only after committing duration"
    );
}
