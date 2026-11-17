//! Chinese bigram + Latin stem BM25/IDF offline retrieval, numbered source citations,
//! and multi-turn cited Q&A (`#141`).

#![forbid(unsafe_code)]
#![deny(missing_docs)]

mod ask;
mod citations;
mod index;
#[cfg(test)]
mod tests;

pub use ask::{
    is_delegation_request, is_followup_question, AskMessage, AskPromptPlan, AskRole, AskScope,
    AskSession, AskStatus, AskStepOutcome, ASK_MAX_CORPUS_CHARS, ASK_SYSTEM_PROMPT,
    ASK_TOP_K_LIMIT, DELEGATION_CLOSED_NOTICE,
};
pub use citations::{
    cited_labels, relabel_citations, render_source_lines, SourceLine, SourcePointer,
};
pub use index::{rank_texts, ContextSearchIndex, ScoringMode, SearchHit};
