use std::fs;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicU64, AtomicUsize, Ordering},
    mpsc, Arc,
};
use std::thread;
use std::time::{Duration, Instant};

use koe_client_services::product_store::ProductStore;
use koe_engine::{
    minutes::parse_meeting_minutes_json,
    product::{AnalysisStage, AnalysisState, ProductError, ProductWorkspace, RecordOrigin, SourceRef},
};
use koe_runtime::KoeRuntime;
use serde_json::{json, Value};

use crate::checker::{
    check_liveness, explore_bfs, format_trace, LivenessOutcome, ModelOutcome, ProtocolModel,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum SlotStatus {
    Idle,
    Pending { rev: u8, attempt: u8 },
    Ready { rev: u8, attempt: u8 },
    Interrupted,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum LaneJob {
    Summary { rev: u8, attempt: u8 },
    LiveSummary { rev: u8, attempt: u8, prefix_intact: bool },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct CloudState {
    record_live: bool,
    content_rev: u8,
    analysis: SlotStatus,
    live_summary: SlotStatus,
    lane_job: Option<LaneJob>,
    completed_job: Option<LaneJob>,
    minutes_rev: Option<u8>,
    minutes_attempt: Option<u8>,
    attempt_budget: u8,
    edit_budget: u8,
    io_fail_budget: u8,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum CloudAction {
    StartSummary,
    StartLiveSummary,
    EditTranscript,
    AppendTranscript,
    ReclaimStaleSummary,
    WorkerReturns,
    CommitCompletedOk,
    CommitCompletedStoreError,
    TrashRecord,
    CrashAndRestart,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CloudMutant {
    Clean,
    Pr587ConsumeCompletedBeforeCommit,
    Pr638SummaryIgnoresContentRevision,
    Pr809TrashIgnoresLiveSummaryPending,
    Pr681StaleSummaryDeadlocksSummaryLane,
}

struct CloudAnalysisModel {
    mutant: CloudMutant,
}

impl CloudState {
    fn is_lane_job_stale(&self) -> bool {
        match self.lane_job {
            Some(LaneJob::Summary { rev, attempt }) => {
                !self.record_live
                    || self.content_rev != rev
                    || !matches!(
                        self.analysis,
                        SlotStatus::Pending { rev: r, attempt: a } if r == rev && a == attempt
                    )
            }
            Some(LaneJob::LiveSummary { .. }) => !self.record_live,
            None => false,
        }
    }

    fn any_busy(&self) -> bool {
        matches!(self.analysis, SlotStatus::Pending { .. })
            || matches!(self.live_summary, SlotStatus::Pending { .. })
            || self.lane_job.is_some()
            || self.completed_job.is_some()
    }
}

impl ProtocolModel for CloudAnalysisModel {
    type State = CloudState;
    type Action = CloudAction;

    fn init(&self) -> Vec<CloudState> {
        vec![CloudState {
            record_live: true,
            content_rev: 1,
            analysis: SlotStatus::Idle,
            live_summary: SlotStatus::Idle,
            lane_job: None,
            completed_job: None,
            minutes_rev: None,
            minutes_attempt: None,
            attempt_budget: 2,
            edit_budget: 1,
            io_fail_budget: 1,
        }]
    }

    fn actions(&self, s: &CloudState) -> Vec<CloudAction> {
        let mut acts = Vec::new();
        if s.record_live {
            if s.lane_job.is_none()
                && s.completed_job.is_none()
                && s.attempt_budget > 0
                && !matches!(s.analysis, SlotStatus::Pending { .. })
            {
                acts.push(CloudAction::StartSummary);
            }
            if s.lane_job.is_none()
                && s.completed_job.is_none()
                && s.attempt_budget > 0
                && !matches!(s.live_summary, SlotStatus::Pending { .. })
            {
                acts.push(CloudAction::StartLiveSummary);
            }
            if s.edit_budget > 0 {
                acts.push(CloudAction::EditTranscript);
                acts.push(CloudAction::AppendTranscript);
            }
            if self.mutant == CloudMutant::Pr809TrashIgnoresLiveSummaryPending {
                if !matches!(s.analysis, SlotStatus::Pending { .. }) {
                    acts.push(CloudAction::TrashRecord);
                }
            } else if !s.any_busy() {
                acts.push(CloudAction::TrashRecord);
            }
        }
        if s.is_lane_job_stale() && self.mutant != CloudMutant::Pr681StaleSummaryDeadlocksSummaryLane
        {
            acts.push(CloudAction::ReclaimStaleSummary);
        }
        if s.lane_job.is_some() && s.completed_job.is_none() {
            acts.push(CloudAction::WorkerReturns);
        }
        if s.completed_job.is_some() {
            acts.push(CloudAction::CommitCompletedOk);
            if s.io_fail_budget > 0 {
                acts.push(CloudAction::CommitCompletedStoreError);
            }
        }
        if s.any_busy() {
            acts.push(CloudAction::CrashAndRestart);
        }
        acts
    }

    fn step(&self, s: &CloudState, action: &CloudAction) -> Vec<CloudState> {
        let mut next = *s;

        match *action {
            CloudAction::StartSummary => {
                let attempt = 3 - next.attempt_budget;
                next.attempt_budget -= 1;
                let rev = next.content_rev;
                next.analysis = SlotStatus::Pending { rev, attempt };
                next.live_summary = SlotStatus::Idle;
                next.lane_job = Some(LaneJob::Summary { rev, attempt });
            }
            CloudAction::StartLiveSummary => {
                let attempt = 3 - next.attempt_budget;
                next.attempt_budget -= 1;
                let rev = next.content_rev;
                next.live_summary = SlotStatus::Pending { rev, attempt };
                next.lane_job = Some(LaneJob::LiveSummary {
                    rev,
                    attempt,
                    prefix_intact: true,
                });
            }
            CloudAction::EditTranscript => {
                next.edit_budget -= 1;
                next.content_rev += 1;
                if matches!(next.analysis, SlotStatus::Pending { .. }) {
                    next.analysis = match (next.minutes_rev, next.minutes_attempt) {
                        (Some(rev), Some(attempt)) => SlotStatus::Ready { rev, attempt },
                        _ => SlotStatus::Idle,
                    };
                }
                if let Some(LaneJob::LiveSummary {
                    ref mut prefix_intact,
                    ..
                }) = next.lane_job
                {
                    *prefix_intact = false;
                }
                if let Some(LaneJob::LiveSummary {
                    ref mut prefix_intact,
                    ..
                }) = next.completed_job
                {
                    *prefix_intact = false;
                }
            }
            CloudAction::AppendTranscript => {
                next.edit_budget -= 1;
                next.content_rev += 1;
                if matches!(next.analysis, SlotStatus::Pending { .. }) {
                    next.analysis = match (next.minutes_rev, next.minutes_attempt) {
                        (Some(rev), Some(attempt)) => SlotStatus::Ready { rev, attempt },
                        _ => SlotStatus::Idle,
                    };
                }
            }
            CloudAction::ReclaimStaleSummary => {
                next.lane_job = None;
                next.completed_job = None;
            }
            CloudAction::WorkerReturns => {
                next.completed_job = next.lane_job;
            }
            CloudAction::CommitCompletedOk => {
                let Some(job) = next.completed_job else {
                    return vec![];
                };
                match job {
                    LaneJob::Summary { rev, attempt } => {
                        let rev_matches = rev == next.content_rev;
                        let slot_matches = matches!(
                            next.analysis,
                            SlotStatus::Pending { rev: r, attempt: a } if r == rev && a == attempt
                        );
                        if self.mutant == CloudMutant::Pr638SummaryIgnoresContentRevision
                            || (next.record_live && rev_matches && slot_matches)
                        {
                            next.minutes_rev = Some(rev);
                            next.minutes_attempt = Some(attempt);
                            next.analysis = SlotStatus::Ready { rev, attempt };
                        }
                    }
                    LaneJob::LiveSummary {
                        rev,
                        attempt,
                        prefix_intact,
                    } => {
                        let slot_matches = matches!(
                            next.live_summary,
                            SlotStatus::Pending { rev: r, attempt: a } if r == rev && a == attempt
                        );
                        let monotonic = next.minutes_rev.is_none_or(|m| rev >= m);
                        if next.record_live && slot_matches && prefix_intact && monotonic {
                            next.minutes_rev = Some(rev);
                            next.minutes_attempt = Some(attempt);
                            next.live_summary = SlotStatus::Ready { rev, attempt };
                        } else if slot_matches {
                            next.live_summary = SlotStatus::Idle;
                        }
                    }
                }
                next.completed_job = None;
                next.lane_job = None;
            }
            CloudAction::CommitCompletedStoreError => {
                next.io_fail_budget -= 1;
                if self.mutant == CloudMutant::Pr587ConsumeCompletedBeforeCommit {
                    next.completed_job = None;
                    next.lane_job = None;
                }
            }
            CloudAction::TrashRecord => {
                next.record_live = false;
            }
            CloudAction::CrashAndRestart => {
                if matches!(next.analysis, SlotStatus::Pending { .. }) {
                    next.analysis = SlotStatus::Interrupted;
                }
                if matches!(next.live_summary, SlotStatus::Pending { .. }) {
                    next.live_summary = SlotStatus::Interrupted;
                }
                next.lane_job = None;
                next.completed_job = None;
            }
        }
        vec![next]
    }

    fn check_invariants(
        &self,
        prev: Option<&CloudState>,
        action: Option<&CloudAction>,
        next: &CloudState,
    ) -> Result<(), String> {
        if let (Some(p), Some(act)) = (prev, action) {
            if *act == CloudAction::CommitCompletedStoreError
                && p.completed_job.is_some()
                && (next.completed_job != p.completed_job || next.lane_job != p.lane_job)
            {
                return Err(
                    "commit_before_consume: completed cloud response dropped on store IO error"
                        .into(),
                );
            }
            if *act == CloudAction::CommitCompletedOk {
                match p.completed_job {
                    Some(LaneJob::Summary { rev, .. })
                        if rev != p.content_rev
                            && (next.minutes_rev != p.minutes_rev
                                || next.minutes_attempt != p.minutes_attempt
                                || next.analysis != p.analysis) =>
                    {
                        return Err(
                            "revision_and_prefix_fencing: stale summary committed after transcript change"
                                .into(),
                        );
                    }
                    Some(LaneJob::LiveSummary {
                        rev,
                        attempt,
                        prefix_intact,
                    }) if (!prefix_intact || p.minutes_rev.is_some_and(|m| rev < m))
                        && (next.minutes_rev != p.minutes_rev
                            || next.minutes_attempt != p.minutes_attempt
                            || next.live_summary == (SlotStatus::Ready { rev, attempt })) =>
                    {
                        return Err(
                            "revision_and_prefix_fencing: stale live summary violated prefix or revision fence"
                                .into(),
                        );
                    }
                    _ => {}
                }
            }
            if *act == CloudAction::CrashAndRestart
                && (next.lane_job.is_some()
                    || next.completed_job.is_some()
                    || matches!(next.analysis, SlotStatus::Pending { .. })
                    || matches!(next.live_summary, SlotStatus::Pending { .. }))
            {
                return Err(
                    "no_silent_paid_retry_on_crash: pending cloud request survived restart".into(),
                );
            }
        }

        if !next.record_live && next.any_busy() {
            return Err(
                "trash_analysis_mutual_exclusion: record trashed while cloud analysis pending"
                    .into(),
            );
        }

        Ok(())
    }

    fn is_live_goal(&self, state: &CloudState) -> bool {
        !state.record_live || (state.lane_job.is_none() && state.completed_job.is_none())
    }

    fn is_fair_edge(
        &self,
        state: &CloudState,
        action: &CloudAction,
        _next: &CloudState,
    ) -> bool {
        match action {
            CloudAction::ReclaimStaleSummary | CloudAction::CommitCompletedOk => true,
            CloudAction::WorkerReturns => !state.is_lane_job_stale(),
            _ => false,
        }
    }
}

struct Sandbox(PathBuf);

impl Sandbox {
    fn new(tag: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "koe-fm-cloud-{tag}-{}-{}",
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

fn send(r: &mut KoeRuntime, v: Value) -> Value {
    serde_json::from_str(&r.dispatch_json(&v.to_string(), 1_800_000_000)).unwrap()
}

fn read_http_request(stream: &mut std::net::TcpStream) -> String {
    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        let n = stream.read(&mut chunk).unwrap();
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let hdrs = std::str::from_utf8(&buf[..pos]).unwrap();
            let len: usize = hdrs
                .lines()
                .find_map(|l| {
                    let (k, v) = l.split_once(':')?;
                    k.eq_ignore_ascii_case("content-length")
                        .then(|| v.trim().parse().unwrap())
                })
                .unwrap_or(0);
            if buf.len() >= pos + 4 + len {
                break;
            }
        }
    }
    String::from_utf8_lossy(&buf).into_owned()
}

#[test]
fn cloud_analysis_model_clean_bfs_and_liveness() {
    let model = CloudAnalysisModel {
        mutant: CloudMutant::Clean,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::Pass {
            states_explored,
            transitions_explored,
        } => {
            println!(
                "[MODEL] cloud_analysis CLEAN BFS: states={states_explored} transitions={transitions_explored}"
            );
            assert!(
                states_explored >= 100,
                "expected non-trivial state space, got {states_explored}"
            );
            assert!(transitions_explored > states_explored);
        }
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => panic!("clean cloud_analysis model failed: {violation}\n{}", format_trace(&trace)),
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
                "[MODEL] cloud_analysis CLEAN LIVENESS: states={states_explored} sccs={scc_count} terminal_sccs={terminal_sccs}"
            );
            assert!(states_explored >= 100);
            assert!(terminal_sccs >= 1);
        }
        LivenessOutcome::TrappedScc { trace_to_trap, .. } => {
            panic!("clean cloud_analysis liveness failed:\n{}", format_trace(&trace_to_trap));
        }
        LivenessOutcome::StateSpaceExceeded { max_states } => {
            panic!("liveness state space exceeded {max_states}");
        }
    }
}

#[test]
fn cloud_analysis_mutant_pr587_consume_completed_before_commit() {
    let model = CloudAnalysisModel {
        mutant: CloudMutant::Pr587ConsumeCompletedBeforeCommit,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr587_consume_completed_before_commit -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("commit_before_consume"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected commit_before_consume violation, got {other:?}"),
    }
}

#[test]
fn cloud_analysis_mutant_pr638_summary_ignores_content_revision() {
    let model = CloudAnalysisModel {
        mutant: CloudMutant::Pr638SummaryIgnoresContentRevision,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr638_summary_ignores_content_revision -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("revision_and_prefix_fencing"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected revision_and_prefix_fencing violation, got {other:?}"),
    }
}

#[test]
fn cloud_analysis_mutant_pr809_trash_ignores_live_summary_pending() {
    let model = CloudAnalysisModel {
        mutant: CloudMutant::Pr809TrashIgnoresLiveSummaryPending,
    };
    match explore_bfs(&model, 50_000) {
        ModelOutcome::InvariantViolation {
            violation, trace, ..
        } => {
            println!(
                "[MUTANT] pr809_trash_ignores_live_summary_pending -> {violation}\n{}",
                format_trace(&trace)
            );
            assert!(
                violation.contains("trash_analysis_mutual_exclusion"),
                "unexpected violation: {violation}\n{}",
                format_trace(&trace)
            );
        }
        other => panic!("expected trash_analysis_mutual_exclusion violation, got {other:?}"),
    }
}

#[test]
fn cloud_analysis_mutant_pr681_stale_summary_deadlocks_summary_lane() {
    let model = CloudAnalysisModel {
        mutant: CloudMutant::Pr681StaleSummaryDeadlocksSummaryLane,
    };
    match check_liveness(&model, 50_000) {
        LivenessOutcome::TrappedScc {
            scc_size,
            trace_to_trap,
            trap_states,
            ..
        } => {
            println!(
                "[MUTANT] pr681_stale_summary_deadlocks_summary_lane -> TrappedScc(size={scc_size})\n{}",
                format_trace(&trace_to_trap)
            );
            assert!(
                trap_states.iter().any(|s| s.is_lane_job_stale()),
                "expected stale summary trap:\n{}",
                format_trace(&trace_to_trap)
            );
        }
        other => panic!("expected TrappedScc for pr681 stale summary deadlock, got {other:?}"),
    }
}

#[test]
fn cloud_analysis_real_code_trace_replay() {
    let mut w = ProductWorkspace::new();
    w.insert_record(
        "rec-1".into(),
        "Design sync".into(),
        RecordOrigin::Note,
        0,
        1_800_000_000,
        0,
    )
    .unwrap();
    let seg1 = w
        .append_transcript("rec-1", "We decided to ship v2.7.", 0, 1_000, "note")
        .unwrap();

    let key1 = w.begin_analysis("rec-1", AnalysisStage::Summarizing).unwrap();
    let spine1 = w.record("rec-1").unwrap().aggregate.spine.clone();
    let minutes_json = json!({
        "schemaVersion": 2,
        "title": "Design sync",
        "overview": "We decided to ship v2.7.",
        "topics": [{"text": "Release", "summary": "We decided to ship v2.7.", "sources": ["S1"]}],
        "decisions": [{"text": "Ship v2.7", "sources": ["S1"]}],
        "actions": [],
        "questions": [],
        "terms": [],
        "reviewItems": []
    })
    .to_string();
    let minutes1 = parse_meeting_minutes_json(&minutes_json, &spine1).unwrap();

    w.edit_segment_text(
        &SourceRef {
            record_id: "rec-1".into(),
            segment_id: seg1,
        },
        "We decided to ship v2.8.",
    )
    .unwrap();
    assert_eq!(
        w.complete_summary(&key1, minutes1),
        Err(ProductError::StaleRequest),
        "PR #638: complete_summary must fence on content_revision"
    );

    let live_key1 = w.begin_live_summary("rec-1").unwrap();
    let snap_prefix = w.record("rec-1").unwrap().aggregate.spine.clone();
    assert_eq!(
        w.trash_record("rec-1", 1_800_000_000_000),
        Err(ProductError::Busy),
        "PR #809: trash_record must reject when live_summary is pending"
    );
    w.append_transcript("rec-1", "Follow-up owner is Mina.", 1_000, 2_000, "note")
        .unwrap();
    let live_minutes = parse_meeting_minutes_json(
        &json!({
            "schemaVersion": 2,
            "title": "Design sync",
            "overview": "We decided to ship v2.8.",
            "topics": [{"text": "Release", "summary": "We decided to ship v2.8.", "sources": ["S1"]}],
            "decisions": [],
            "actions": [],
            "questions": [],
            "terms": [],
            "reviewItems": []
        })
        .to_string(),
        &snap_prefix,
    )
    .unwrap();
    w.complete_live_summary(&live_key1, &snap_prefix, live_minutes)
        .unwrap();

    let live_key2 = w.begin_live_summary("rec-1").unwrap();
    let snap2 = w.record("rec-1").unwrap().aggregate.spine.clone();
    w.edit_segment_text(
        &SourceRef {
            record_id: "rec-1".into(),
            segment_id: seg1,
        },
        "We decided to ship v2.9.",
    )
    .unwrap();
    let live_minutes2 = parse_meeting_minutes_json(
        &json!({
            "schemaVersion": 2,
            "title": "Design sync",
            "overview": "We decided to ship v2.8.",
            "topics": [{"text": "Release", "summary": "We decided to ship v2.8.", "sources": ["S1"]}],
            "decisions": [],
            "actions": [],
            "questions": [],
            "terms": [],
            "reviewItems": []
        })
        .to_string(),
        &snap2,
    )
    .unwrap();
    assert_eq!(
        w.complete_live_summary(&live_key2, &snap2, live_minutes2),
        Err(ProductError::StaleRequest),
        "prefix fence must reject live summary after earlier segment edit"
    );

    let crash_dir = Sandbox::new("crash-interrupt");
    {
        let mut store = ProductStore::open(&crash_dir.0).unwrap();
        store
            .transact(|ws| {
                ws.insert_record("r1".into(), "Crash".into(), RecordOrigin::Note, 0, 100, 0)?;
                ws.append_transcript("r1", "line one", 0, 100, "note")?;
                ws.begin_analysis("r1", AnalysisStage::Summarizing)?;
                ws.begin_live_summary("r1")?;
                Ok(())
            })
            .unwrap();
    }
    let reopened = ProductStore::open(&crash_dir.0).unwrap();
    let rec = reopened.workspace().record("r1").unwrap();
    assert!(matches!(rec.analysis, AnalysisState::Interrupted { .. }));
    assert!(matches!(rec.live_summary, AnalysisState::Interrupted { .. }));
    drop(reopened);

    let rt_dir = Sandbox::new("pr681-reclaim");
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = format!("http://{}/chat/completions", listener.local_addr().unwrap());
    let (first_seen_tx, first_seen_rx) = mpsc::channel();
    let (release_first_tx, release_first_rx) = mpsc::channel();
    let req_count = Arc::new(AtomicUsize::new(0));
    let req_count_srv = req_count.clone();

    let server = thread::spawn(move || {
        for idx in 0..2 {
            let (mut stream, _) = listener.accept().unwrap();
            let body = read_http_request(&mut stream);
            req_count_srv.fetch_add(1, Ordering::SeqCst);
            if idx == 0 {
                first_seen_tx.send(body).unwrap();
                let _ = release_first_rx.recv_timeout(Duration::from_secs(5));
                let resp = json!({"choices":[{"message":{"content":json!({
                    "schemaVersion":2,"title":"Old","overview":"First text.",
                    "topics":[{"text":"Old","summary":"First text.","sources":["S1"]}],
                    "decisions":[],"actions":[],"questions":[],"terms":[],"reviewItems":[]
                }).to_string()}}]})
                .to_string();
                let _ = write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    resp.len(),
                    resp
                );
            } else {
                let resp = json!({"choices":[{"message":{"content":json!({
                    "schemaVersion":2,"title":"Fresh","overview":"Edited text.",
                    "topics":[{"text":"Fresh","summary":"Edited text.","sources":["S1"]}],
                    "decisions":[],"actions":[],"questions":[],"terms":[],"reviewItems":[]
                }).to_string()}}]})
                .to_string();
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    resp.len(),
                    resp
                )
                .unwrap();
            }
        }
    });

    let mut rt = KoeRuntime::open(&rt_dir.0).unwrap();
    send(
        &mut rt,
        json!({"type":"configure_provider","apiKey":"test-k","model":"test-m","chatEndpoint":endpoint}),
    );
    let created = send(
        &mut rt,
        json!({"type":"create_note","title":"Live edit","text":"First text."}),
    );
    let rid = created["selectedRecordId"].as_str().unwrap().to_string();
    let seg_id = created["detail"]["segments"][0]["id"]
        .as_str()
        .unwrap()
        .to_string();

    let s1 = send(&mut rt, json!({"type":"summarize","recordId":rid}));
    assert!(s1["error"].is_null(), "{s1}");
    let _ = first_seen_rx.recv_timeout(Duration::from_secs(5)).unwrap();

    let trash_busy = send(&mut rt, json!({"type":"trash_record","recordId":rid}));
    assert!(
        trash_busy["error"].is_string(),
        "trash must be rejected while summary is pending in-flight: {trash_busy}"
    );

    let edited = send(
        &mut rt,
        json!({"type":"edit_segment_text","recordId":rid,"segmentId":seg_id,"text":"Edited text."}),
    );
    assert!(edited["error"].is_null(), "{edited}");

    let s2 = send(&mut rt, json!({"type":"summarize","recordId":rid}));
    assert!(
        s2["error"].is_null(),
        "PR #681: stale summary must be reclaimed instead of deadlocking Summary lane: {s2}"
    );
    let _ = release_first_tx.send(());

    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        rt.poll_timers(10, 1_800_000_005);
        let rec = rt.workspace().record(&rid).unwrap();
        if matches!(rec.analysis, AnalysisState::Ready { input_revision } if input_revision == rec.content_revision)
        {
            assert_eq!(
                rec.aggregate.minutes.as_ref().unwrap().overview,
                "Edited text."
            );
            break;
        }
        assert!(Instant::now() < deadline, "fresh summary did not complete");
        thread::sleep(Duration::from_millis(5));
    }
    server.join().unwrap();
    assert_eq!(req_count.load(Ordering::SeqCst), 2);

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let retain_dir = Sandbox::new("pr587-retain");
        let retain_listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let retain_endpoint = format!(
            "http://{}/chat/completions",
            retain_listener.local_addr().unwrap()
        );
        let retain_requests = Arc::new(AtomicUsize::new(0));
        let retain_requests_srv = retain_requests.clone();
        let (resp_sent_tx, resp_sent_rx) = mpsc::channel();
        let retain_server = thread::spawn(move || {
            let (mut stream, _) = retain_listener.accept().unwrap();
            let _ = read_http_request(&mut stream);
            retain_requests_srv.fetch_add(1, Ordering::SeqCst);
            let resp = json!({"choices":[{"message":{"content":json!({
                "schemaVersion":2,"title":"Retained","overview":"Retained across disk failure.",
                "topics":[{"text":"Retained","summary":"Retained across disk failure.","sources":["S1"]}],
                "decisions":[],"actions":[],"questions":[],"terms":[],"reviewItems":[]
            }).to_string()}}]})
            .to_string();
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                resp.len(),
                resp
            )
            .unwrap();
            resp_sent_tx.send(()).unwrap();
        });

        let mut rt_retain = KoeRuntime::open(&retain_dir.0).unwrap();
        send(
            &mut rt_retain,
            json!({"type":"configure_provider","apiKey":"test-k","model":"test-m","chatEndpoint":retain_endpoint}),
        );
        let note = send(
            &mut rt_retain,
            json!({"type":"create_note","title":"Retained","text":"Retained across disk failure."}),
        );
        let retain_id = note["selectedRecordId"].as_str().unwrap().to_string();
        let started = send(&mut rt_retain, json!({"type":"summarize","recordId":retain_id}));
        assert!(started["error"].is_null(), "{started}");
        resp_sent_rx.recv_timeout(Duration::from_secs(5)).unwrap();

        fs::set_permissions(&retain_dir.0, fs::Permissions::from_mode(0o500)).unwrap();
        let fail_deadline = Instant::now() + Duration::from_secs(5);
        loop {
            rt_retain.poll_timers(10, 1_800_000_010);
            let snap = rt_retain.snapshot(1_800_000_010);
            if snap["error"]
                .as_str()
                .is_some_and(|e| e.contains("保留本次云端返回"))
            {
                break;
            }
            assert!(
                Instant::now() < fail_deadline,
                "expected retained store-error state, got: {snap}"
            );
            thread::sleep(Duration::from_millis(5));
        }
        assert!(matches!(
            rt_retain.workspace().record(&retain_id).unwrap().analysis,
            AnalysisState::Pending { .. }
        ));

        fs::set_permissions(&retain_dir.0, fs::Permissions::from_mode(0o700)).unwrap();
        let commit_deadline = Instant::now() + Duration::from_secs(5);
        loop {
            rt_retain.poll_timers(10, 1_800_000_015);
            let rec = rt_retain.workspace().record(&retain_id).unwrap();
            if matches!(rec.analysis, AnalysisState::Ready { .. }) {
                assert_eq!(
                    rec.aggregate.minutes.as_ref().unwrap().overview,
                    "Retained across disk failure."
                );
                break;
            }
            assert!(
                Instant::now() < commit_deadline,
                "retained cloud response did not commit after directory recovered"
            );
            thread::sleep(Duration::from_millis(5));
        }
        retain_server.join().unwrap();
        assert_eq!(
            retain_requests.load(Ordering::SeqCst),
            1,
            "PR #587: server must receive exactly 1 paid HTTP request across disk commit recovery"
        );
    }

    let mut w_idem = ProductWorkspace::new();
    w_idem
        .insert_record("i1".into(), "Idem".into(), RecordOrigin::Note, 0, 100, 0)
        .unwrap();
    w_idem
        .append_transcript("i1", "Commit before consume.", 0, 100, "note")
        .unwrap();
    let ikey = w_idem.begin_analysis("i1", AnalysisStage::Summarizing).unwrap();
    let ispine = w_idem.record("i1").unwrap().aggregate.spine.clone();
    let imin = parse_meeting_minutes_json(
        &json!({
            "schemaVersion": 2,
            "title": "Idem",
            "overview": "Commit before consume.",
            "topics": [{"text": "Idem", "summary": "Commit before consume.", "sources": ["S1"]}],
            "decisions": [],
            "actions": [],
            "questions": [],
            "terms": [],
            "reviewItems": []
        })
        .to_string(),
        &ispine,
    )
    .unwrap();
    w_idem.complete_summary(&ikey, imin.clone()).unwrap();
    w_idem.complete_summary(&ikey, imin).unwrap();
}
