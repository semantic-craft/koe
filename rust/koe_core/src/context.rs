//! Personal context timeline (`ContextItem`), action items (`TodoItem`), and offline
//! Q&A retrieval scaffold for Slice M (Sweetpea / 心力豆).

#![forbid(unsafe_code)]
#![deny(missing_docs)]

use std::cmp::Reverse;

use crate::domain::{
    AiProviderCommand, ContextItem, TodoItem, TodoKind, TodoStatus, UtteranceSpine,
};

/// Returns `items` sorted in reverse chronological order (`created_at_epoch_sec` descending,
/// tie-breaking by `id` ascending).
#[must_use]
pub fn sort_context_timeline(mut items: Vec<ContextItem>) -> Vec<ContextItem> {
    items.sort_by(|a, b| {
        Reverse(a.created_at_epoch_sec)
            .cmp(&Reverse(b.created_at_epoch_sec))
            .then_with(|| a.id.cmp(&b.id))
    });
    items
}

/// Filters `todos` to open action items owned by the user (`TodoKind::Mine` + `TodoStatus::Open`).
#[must_use]
pub fn filter_open_mine_todos(todos: &[TodoItem]) -> Vec<TodoItem> {
    todos
        .iter()
        .filter(|t| t.kind == TodoKind::Mine && t.status == TodoStatus::Open)
        .cloned()
        .collect()
}

/// Pure state for the personal context timeline and action-item subsystem (Slice M).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ContextState {
    /// Reverse-chronological context timeline items.
    pub timeline: Vec<ContextItem>,
    /// Personal and delegated action items.
    pub todos: Vec<TodoItem>,
}

/// Input events for [`ContextReducer`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ContextEvent {
    /// Ingest a [`ContextItem`] and maintain reverse-chronological ordering.
    IngestContextItem(ContextItem),
    /// Ingest a [`TodoItem`].
    IngestTodoItem(TodoItem),
    /// Request context and todo extraction from the current [`UtteranceSpine`].
    RequestExtract,
}

/// Pure output from [`ContextReducer::reduce`].
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ContextOutcome {
    /// Outbound AI provider commands to execute.
    pub commands: Vec<AiProviderCommand>,
}

/// Pure reducer contract for the personal context and todo subsystem.
pub trait ContextReducer {
    /// Applies `event` to `state` against `spine` without side effects.
    fn reduce(
        state: &mut ContextState,
        spine: &UtteranceSpine,
        event: ContextEvent,
    ) -> ContextOutcome;
}

impl ContextReducer for ContextState {
    fn reduce(
        state: &mut ContextState,
        spine: &UtteranceSpine,
        event: ContextEvent,
    ) -> ContextOutcome {
        match event {
            ContextEvent::IngestContextItem(item) => {
                state.timeline.retain(|existing| existing.id != item.id);
                state.timeline.push(item);
                state.timeline = sort_context_timeline(std::mem::take(&mut state.timeline));
                ContextOutcome::default()
            }
            ContextEvent::IngestTodoItem(todo) => {
                state.todos.retain(|existing| existing.id != todo.id);
                state.todos.push(todo);
                ContextOutcome::default()
            }
            ContextEvent::RequestExtract => {
                if spine.is_empty() {
                    return ContextOutcome::default();
                }
                ContextOutcome {
                    commands: vec![AiProviderCommand::ExtractContext {
                        session_id: spine.session_id().to_string(),
                        spine_revision: spine.revision(),
                    }],
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{ContextKind, ContextSource, SegmentId};

    #[test]
    fn context_timeline_sorts_descending_and_filters_open_mine_todos() {
        let mut state = ContextState::default();
        let spine = UtteranceSpine::new("ctx-1");

        let _ = ContextState::reduce(
            &mut state,
            &spine,
            ContextEvent::IngestContextItem(ContextItem {
                id: "c1".to_string(),
                kind: ContextKind::QuickNote,
                source: ContextSource::ManualEntry,
                created_at_epoch_sec: 1_000,
                title: "Earlier".to_string(),
                summary: "A".to_string(),
                project_id: None,
                place_label: None,
                citations: Vec::new(),
            }),
        );
        let _ = ContextState::reduce(
            &mut state,
            &spine,
            ContextEvent::IngestContextItem(ContextItem {
                id: "c2".to_string(),
                kind: ContextKind::Commitment,
                source: ContextSource::AiSynthesis,
                created_at_epoch_sec: 2_000,
                title: "Later".to_string(),
                summary: "B".to_string(),
                project_id: None,
                place_label: None,
                citations: vec![SegmentId::new(1).unwrap()],
            }),
        );
        assert_eq!(state.timeline.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), vec!["c2", "c1"]);

        let _ = ContextState::reduce(
            &mut state,
            &spine,
            ContextEvent::IngestTodoItem(TodoItem {
                id: "t1".to_string(),
                title: "发周报".to_string(),
                kind: TodoKind::Mine,
                status: TodoStatus::Open,
                created_at_epoch_sec: 1_500,
                due_at_epoch_sec: None,
                assignee: None,
                citations: vec![SegmentId::new(1).unwrap()],
            }),
        );
        let _ = ContextState::reduce(
            &mut state,
            &spine,
            ContextEvent::IngestTodoItem(TodoItem {
                id: "t2".to_string(),
                title: "等李工确认接口".to_string(),
                kind: TodoKind::Delegated,
                status: TodoStatus::Open,
                created_at_epoch_sec: 1_600,
                due_at_epoch_sec: None,
                assignee: Some("李工".to_string()),
                citations: Vec::new(),
            }),
        );

        let mine = filter_open_mine_todos(&state.todos);
        assert_eq!(mine.len(), 1);
        assert_eq!(mine[0].id, "t1");
    }
}
