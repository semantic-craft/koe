use std::collections::{HashMap, HashSet, VecDeque};
use std::fmt::Debug;
use std::hash::Hash;

pub trait ProtocolModel {
    type State: Hash + Eq + Clone + Debug;
    type Action: Clone + Debug;

    fn init(&self) -> Vec<Self::State>;
    fn actions(&self, state: &Self::State) -> Vec<Self::Action>;
    fn step(&self, state: &Self::State, action: &Self::Action) -> Vec<Self::State>;
    fn check_invariants(
        &self,
        prev: Option<&Self::State>,
        action: Option<&Self::Action>,
        next: &Self::State,
    ) -> Result<(), String>;

    fn is_live_goal(&self, _state: &Self::State) -> bool {
        true
    }

    fn is_fair_edge(&self, _state: &Self::State, _action: &Self::Action, _next: &Self::State) -> bool {
        true
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TraceStep<S, A> {
    pub action: Option<A>,
    pub state: S,
}

pub enum ModelOutcome<M: ProtocolModel> {
    Pass {
        states_explored: usize,
        transitions_explored: usize,
    },
    InvariantViolation {
        states_explored: usize,
        violation: String,
        trace: Vec<TraceStep<M::State, M::Action>>,
    },
    StateSpaceExceeded {
        max_states: usize,
    },
}

impl<M: ProtocolModel> Debug for ModelOutcome<M> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Pass {
                states_explored,
                transitions_explored,
            } => f
                .debug_struct("Pass")
                .field("states_explored", states_explored)
                .field("transitions_explored", transitions_explored)
                .finish(),
            Self::InvariantViolation {
                states_explored,
                violation,
                trace,
            } => f
                .debug_struct("InvariantViolation")
                .field("states_explored", states_explored)
                .field("violation", violation)
                .field("trace", trace)
                .finish(),
            Self::StateSpaceExceeded { max_states } => f
                .debug_struct("StateSpaceExceeded")
                .field("max_states", max_states)
                .finish(),
        }
    }
}

pub enum LivenessOutcome<M: ProtocolModel> {
    Pass {
        states_explored: usize,
        scc_count: usize,
        terminal_sccs: usize,
    },
    TrappedScc {
        states_explored: usize,
        scc_size: usize,
        trace_to_trap: Vec<TraceStep<M::State, M::Action>>,
        trap_states: Vec<M::State>,
    },
    StateSpaceExceeded {
        max_states: usize,
    },
}

impl<M: ProtocolModel> Debug for LivenessOutcome<M> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Pass {
                states_explored,
                scc_count,
                terminal_sccs,
            } => f
                .debug_struct("Pass")
                .field("states_explored", states_explored)
                .field("scc_count", scc_count)
                .field("terminal_sccs", terminal_sccs)
                .finish(),
            Self::TrappedScc {
                states_explored,
                scc_size,
                trace_to_trap,
                trap_states,
            } => f
                .debug_struct("TrappedScc")
                .field("states_explored", states_explored)
                .field("scc_size", scc_size)
                .field("trace_to_trap", trace_to_trap)
                .field("trap_states", trap_states)
                .finish(),
            Self::StateSpaceExceeded { max_states } => f
                .debug_struct("StateSpaceExceeded")
                .field("max_states", max_states)
                .finish(),
        }
    }
}

pub fn format_trace<S: Debug, A: Debug>(trace: &[TraceStep<S, A>]) -> String {
    let mut out = String::new();
    for (idx, step) in trace.iter().enumerate() {
        if let Some(action) = &step.action {
            out.push_str(&format!("  [{idx}] --({action:?})--> {:?}\n", step.state));
        } else {
            out.push_str(&format!("  [{idx}] INIT {:?}\n", step.state));
        }
    }
    out
}

fn reconstruct_trace<S: Clone, A: Clone>(
    states: &[S],
    parents: &[Option<(usize, A)>],
    mut idx: usize,
) -> Vec<TraceStep<S, A>> {
    let mut rev = Vec::new();
    loop {
        match &parents[idx] {
            Some((parent, action)) => {
                rev.push(TraceStep {
                    action: Some(action.clone()),
                    state: states[idx].clone(),
                });
                idx = *parent;
            }
            None => {
                rev.push(TraceStep {
                    action: None,
                    state: states[idx].clone(),
                });
                break;
            }
        }
    }
    rev.reverse();
    rev
}

pub fn explore_bfs<M: ProtocolModel>(model: &M, max_states: usize) -> ModelOutcome<M> {
    let mut states: Vec<M::State> = Vec::new();
    let mut index_of: HashMap<M::State, usize> = HashMap::new();
    let mut parents: Vec<Option<(usize, M::Action)>> = Vec::new();
    let mut queue: VecDeque<usize> = VecDeque::new();
    let mut transitions_explored = 0usize;

    for init_state in model.init() {
        if let Err(violation) = model.check_invariants(None, None, &init_state) {
            return ModelOutcome::InvariantViolation {
                states_explored: states.len() + 1,
                violation,
                trace: vec![TraceStep {
                    action: None,
                    state: init_state,
                }],
            };
        }
        if !index_of.contains_key(&init_state) {
            if states.len() >= max_states {
                return ModelOutcome::StateSpaceExceeded { max_states };
            }
            let idx = states.len();
            index_of.insert(init_state.clone(), idx);
            states.push(init_state);
            parents.push(None);
            queue.push_back(idx);
        }
    }

    while let Some(curr_idx) = queue.pop_front() {
        let curr = states[curr_idx].clone();
        for action in model.actions(&curr) {
            for next in model.step(&curr, &action) {
                transitions_explored += 1;
                if let Err(violation) =
                    model.check_invariants(Some(&curr), Some(&action), &next)
                {
                    let mut trace = reconstruct_trace(&states, &parents, curr_idx);
                    trace.push(TraceStep {
                        action: Some(action),
                        state: next,
                    });
                    return ModelOutcome::InvariantViolation {
                        states_explored: states.len(),
                        violation,
                        trace,
                    };
                }
                if !index_of.contains_key(&next) {
                    if states.len() >= max_states {
                        return ModelOutcome::StateSpaceExceeded { max_states };
                    }
                    let next_idx = states.len();
                    index_of.insert(next.clone(), next_idx);
                    states.push(next);
                    parents.push(Some((curr_idx, action.clone())));
                    queue.push_back(next_idx);
                }
            }
        }
    }

    ModelOutcome::Pass {
        states_explored: states.len(),
        transitions_explored,
    }
}

pub fn check_liveness<M: ProtocolModel>(model: &M, max_states: usize) -> LivenessOutcome<M> {
    let mut states: Vec<M::State> = Vec::new();
    let mut index_of: HashMap<M::State, usize> = HashMap::new();
    let mut parents: Vec<Option<(usize, M::Action)>> = Vec::new();
    let mut fair_adj: Vec<Vec<usize>> = Vec::new();
    let mut queue: VecDeque<usize> = VecDeque::new();

    for init_state in model.init() {
        if !index_of.contains_key(&init_state) {
            if states.len() >= max_states {
                return LivenessOutcome::StateSpaceExceeded { max_states };
            }
            let idx = states.len();
            index_of.insert(init_state.clone(), idx);
            states.push(init_state);
            parents.push(None);
            fair_adj.push(Vec::new());
            queue.push_back(idx);
        }
    }

    while let Some(curr_idx) = queue.pop_front() {
        let curr = states[curr_idx].clone();
        let mut seen_fair: HashSet<usize> = HashSet::new();
        for action in model.actions(&curr) {
            for next in model.step(&curr, &action) {
                let next_idx = if let Some(&existing) = index_of.get(&next) {
                    existing
                } else {
                    if states.len() >= max_states {
                        return LivenessOutcome::StateSpaceExceeded { max_states };
                    }
                    let idx = states.len();
                    index_of.insert(next.clone(), idx);
                    states.push(next.clone());
                    parents.push(Some((curr_idx, action.clone())));
                    fair_adj.push(Vec::new());
                    queue.push_back(idx);
                    idx
                };
                if model.is_fair_edge(&curr, &action, &next) && seen_fair.insert(next_idx) {
                    fair_adj[curr_idx].push(next_idx);
                }
            }
        }
    }

    let n = states.len();
    let mut dfs_index: Vec<Option<usize>> = vec![None; n];
    let mut lowlink: Vec<usize> = vec![0; n];
    let mut on_stack: Vec<bool> = vec![false; n];
    let mut tarjan_stack: Vec<usize> = Vec::new();
    let mut scc_of: Vec<usize> = vec![usize::MAX; n];
    let mut sccs: Vec<Vec<usize>> = Vec::new();
    let mut next_dfs_id = 0usize;
    let mut call_stack: Vec<(usize, usize)> = Vec::new();

    for start in 0..n {
        if dfs_index[start].is_some() {
            continue;
        }
        dfs_index[start] = Some(next_dfs_id);
        lowlink[start] = next_dfs_id;
        next_dfs_id += 1;
        tarjan_stack.push(start);
        on_stack[start] = true;
        call_stack.push((start, 0));

        while let Some((v, edge_idx)) = call_stack.last_mut() {
            let v = *v;
            if *edge_idx < fair_adj[v].len() {
                let w = fair_adj[v][*edge_idx];
                *edge_idx += 1;
                if dfs_index[w].is_none() {
                    dfs_index[w] = Some(next_dfs_id);
                    lowlink[w] = next_dfs_id;
                    next_dfs_id += 1;
                    tarjan_stack.push(w);
                    on_stack[w] = true;
                    call_stack.push((w, 0));
                } else if on_stack[w] {
                    if let Some(w_idx) = dfs_index[w] {
                        if w_idx < lowlink[v] {
                            lowlink[v] = w_idx;
                        }
                    }
                }
            } else {
                call_stack.pop();
                if let Some(&(parent, _)) = call_stack.last() {
                    if lowlink[v] < lowlink[parent] {
                        lowlink[parent] = lowlink[v];
                    }
                }
                if dfs_index[v] == Some(lowlink[v]) {
                    let scc_id = sccs.len();
                    let mut members = Vec::new();
                    while let Some(u) = tarjan_stack.pop() {
                        on_stack[u] = false;
                        scc_of[u] = scc_id;
                        members.push(u);
                        if u == v {
                            break;
                        }
                    }
                    sccs.push(members);
                }
            }
        }
    }

    let mut terminal_sccs = 0usize;
    let mut best_trap: Option<(usize, Vec<usize>)> = None;

    for (scc_id, members) in sccs.iter().enumerate() {
        let is_terminal = members
            .iter()
            .all(|&u| fair_adj[u].iter().all(|&w| scc_of[w] == scc_id));
        if !is_terminal {
            continue;
        }
        terminal_sccs += 1;
        let has_goal = members.iter().any(|&u| model.is_live_goal(&states[u]));
        if !has_goal {
            let entry = *members.iter().min().unwrap();
            match &best_trap {
                Some((best_entry, _)) if entry >= *best_entry => {}
                _ => best_trap = Some((entry, members.clone())),
            }
        }
    }

    if let Some((entry, members)) = best_trap {
        let trace_to_trap = reconstruct_trace(&states, &parents, entry);
        let trap_states = members.iter().map(|&u| states[u].clone()).collect();
        return LivenessOutcome::TrappedScc {
            states_explored: n,
            scc_size: members.len(),
            trace_to_trap,
            trap_states,
        };
    }

    LivenessOutcome::Pass {
        states_explored: n,
        scc_count: sccs.len(),
        terminal_sccs,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct ShortestBugModel;

    #[derive(Clone, Debug, PartialEq, Eq, Hash)]
    struct Node(u8);

    #[derive(Clone, Debug, PartialEq, Eq)]
    enum Edge {
        Long,
        Short,
        Step,
    }

    impl ProtocolModel for ShortestBugModel {
        type State = Node;
        type Action = Edge;

        fn init(&self) -> Vec<Node> {
            vec![Node(0)]
        }

        fn actions(&self, state: &Node) -> Vec<Edge> {
            match state.0 {
                0 => vec![Edge::Long, Edge::Short],
                1..=4 | 10 => vec![Edge::Step],
                _ => vec![],
            }
        }

        fn step(&self, state: &Node, action: &Edge) -> Vec<Node> {
            match (state.0, action) {
                (0, Edge::Long) => vec![Node(1)],
                (0, Edge::Short) => vec![Node(10)],
                (1, Edge::Step) => vec![Node(2)],
                (2, Edge::Step) => vec![Node(3)],
                (3, Edge::Step) => vec![Node(4)],
                (4, Edge::Step) => vec![Node(99)],
                (10, Edge::Step) => vec![Node(99)],
                _ => vec![],
            }
        }

        fn check_invariants(
            &self,
            _prev: Option<&Node>,
            _action: Option<&Edge>,
            next: &Node,
        ) -> Result<(), String> {
            if next.0 == 99 {
                Err("reached forbidden node 99".into())
            } else {
                Ok(())
            }
        }
    }

    struct BlowupModel;

    impl ProtocolModel for BlowupModel {
        type State = u32;
        type Action = ();

        fn init(&self) -> Vec<u32> {
            vec![0]
        }

        fn actions(&self, _state: &u32) -> Vec<()> {
            vec![()]
        }

        fn step(&self, state: &u32, _action: &()) -> Vec<u32> {
            vec![state + 1]
        }

        fn check_invariants(
            &self,
            _prev: Option<&u32>,
            _action: Option<&()>,
            _next: &u32,
        ) -> Result<(), String> {
            Ok(())
        }
    }

    struct TrapCycleModel {
        allow_escape: bool,
    }

    #[derive(Clone, Debug, PartialEq, Eq, Hash)]
    enum TrapState {
        Start,
        Goal,
        CycleA,
        CycleB,
    }

    #[derive(Clone, Debug, PartialEq, Eq)]
    enum TrapAction {
        ToGoal,
        EnterTrap,
        Bounce,
        Escape,
    }

    impl ProtocolModel for TrapCycleModel {
        type State = TrapState;
        type Action = TrapAction;

        fn init(&self) -> Vec<TrapState> {
            vec![TrapState::Start]
        }

        fn actions(&self, state: &TrapState) -> Vec<TrapAction> {
            match state {
                TrapState::Start => vec![TrapAction::ToGoal, TrapAction::EnterTrap],
                TrapState::Goal => vec![],
                TrapState::CycleA => vec![TrapAction::Bounce],
                TrapState::CycleB => {
                    if self.allow_escape {
                        vec![TrapAction::Bounce, TrapAction::Escape]
                    } else {
                        vec![TrapAction::Bounce]
                    }
                }
            }
        }

        fn step(&self, state: &TrapState, action: &TrapAction) -> Vec<TrapState> {
            match (state, action) {
                (TrapState::Start, TrapAction::ToGoal) => vec![TrapState::Goal],
                (TrapState::Start, TrapAction::EnterTrap) => vec![TrapState::CycleA],
                (TrapState::CycleA, TrapAction::Bounce) => vec![TrapState::CycleB],
                (TrapState::CycleB, TrapAction::Bounce) => vec![TrapState::CycleA],
                (TrapState::CycleB, TrapAction::Escape) => vec![TrapState::Goal],
                _ => vec![],
            }
        }

        fn check_invariants(
            &self,
            _prev: Option<&TrapState>,
            _action: Option<&TrapAction>,
            _next: &TrapState,
        ) -> Result<(), String> {
            Ok(())
        }

        fn is_live_goal(&self, state: &TrapState) -> bool {
            matches!(state, TrapState::Goal)
        }
    }

    #[test]
    fn bfs_finds_shortest_counterexample() {
        match explore_bfs(&ShortestBugModel, 100) {
            ModelOutcome::InvariantViolation {
                violation, trace, ..
            } => {
                assert!(violation.contains("99"), "{violation}");
                assert_eq!(trace.len(), 3, "{}", format_trace(&trace));
                assert_eq!(trace[0].state, Node(0));
                assert_eq!(trace[1].state, Node(10));
                assert_eq!(trace[2].state, Node(99));
            }
            other => panic!("expected shortest invariant violation, got {other:?}"),
        }
    }

    #[test]
    fn bfs_fails_when_state_space_exceeded() {
        match explore_bfs(&BlowupModel, 5) {
            ModelOutcome::StateSpaceExceeded { max_states } => assert_eq!(max_states, 5),
            other => panic!("expected StateSpaceExceeded, got {other:?}"),
        }
    }

    #[test]
    fn tarjan_detects_non_goal_trap_cycle() {
        match check_liveness(&TrapCycleModel { allow_escape: false }, 100) {
            LivenessOutcome::TrappedScc {
                scc_size,
                trace_to_trap,
                trap_states,
                ..
            } => {
                assert_eq!(scc_size, 2);
                assert_eq!(trace_to_trap.len(), 2, "{}", format_trace(&trace_to_trap));
                assert_eq!(trace_to_trap[0].state, TrapState::Start);
                assert_eq!(trace_to_trap[1].state, TrapState::CycleA);
                assert!(trap_states.contains(&TrapState::CycleA));
                assert!(trap_states.contains(&TrapState::CycleB));
            }
            other => panic!("expected TrappedScc, got {other:?}"),
        }
    }

    #[test]
    fn tarjan_passes_when_every_terminal_scc_reaches_goal() {
        match check_liveness(&TrapCycleModel { allow_escape: true }, 100) {
            LivenessOutcome::Pass {
                states_explored,
                terminal_sccs,
                ..
            } => {
                assert_eq!(states_explored, 4);
                assert_eq!(terminal_sccs, 1);
            }
            other => panic!("expected liveness Pass, got {other:?}"),
        }
    }
}
