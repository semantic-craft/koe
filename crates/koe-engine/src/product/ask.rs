use super::*;
use crate::context::{
    cited_labels, AskRole, AskScope, AskStatus, AskStepOutcome, SourceLine, SourcePointer,
};
use crate::domain::UtteranceSegment;

fn ask_source_text(segment: &UtteranceSegment) -> String {
    match segment
        .speaker
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        Some(spk) => format!("{spk}：{}", segment.text),
        None => segment.text.clone(),
    }
}

impl ProductWorkspace {
    /// Current durable conversation, including original source pointers.
    #[must_use]
    pub fn ask_session(&self) -> &AskSession {
        &self.ask_session
    }

    /// Currently selected question scope.
    #[must_use]
    pub fn ask_scope(&self) -> &SearchScope {
        &self.ask_scope
    }

    /// Pending immutable request, if a provider response is outstanding.
    #[must_use]
    pub fn pending_ask(&self) -> Option<&AskRequest> {
        self.pending_ask.as_ref()
    }

    /// Changes the next question's scope without changing an in-flight request's evidence.
    pub fn set_ask_scope(&mut self, scope: SearchScope) -> Result<(), ProductError> {
        self.validate_scope(&scope)?;
        if self.ask_scope != scope {
            self.ask_scope = scope;
            self.changed();
        }
        Ok(())
    }

    /// Searches a real corpus and persists a pending question before any network request.
    pub fn begin_ask(
        &mut self,
        scope: SearchScope,
        question: &str,
        now: u64,
    ) -> Result<Option<AskRequest>, ProductError> {
        self.validate_scope(&scope)?;
        let question = nonempty(question)?;
        if self.pending_ask.is_some() || self.ask_session.in_flight {
            return Err(ProductError::Busy);
        }
        let corpus = self.corpus(&scope);
        let lines: Vec<SourceLine> = corpus
            .iter()
            .enumerate()
            .map(|(index, evidence)| {
                let record = &self.records[&evidence.source.record_id];
                let seg = record.aggregate.spine.get(evidence.source.segment_id);
                SourceLine {
                    label: format!("S{}", index + 1),
                    title: evidence.title.clone(),
                    text: seg.map_or_else(|| evidence.quote.clone(), ask_source_text),
                    source: SourcePointer {
                        recording_key: evidence.source.record_id.clone(),
                        path: None,
                        start_ms: evidence.start_ms,
                        end_ms: seg.map(|s| s.end_ms),
                        segment_id: evidence.source.segment_id,
                    },
                    at_epoch_sec: if record.aggregate.created_at_epoch_sec == 0 {
                        None
                    } else {
                        Some(
                            record
                                .aggregate
                                .created_at_epoch_sec
                                .saturating_add(evidence.start_ms / 1000),
                        )
                    },
                }
            })
            .collect();
        let selected: Vec<_> = self
            .records
            .iter()
            .filter(|(id, record)| {
                record.is_live()
                    && (matches!(&scope, SearchScope::All)
                        || matches!(&scope, SearchScope::Record(wanted) if *id == wanted))
            })
            .collect();
        let stats = AskScope {
            with_text: selected
                .iter()
                .filter(|(_, r)| !r.aggregate.spine.is_empty())
                .count(),
            without_text: selected
                .iter()
                .filter(|(_, r)| r.aggregate.spine.is_empty())
                .count(),
            processing: selected
                .iter()
                .filter(|(_, r)| {
                    r.aggregate.spine.is_empty()
                        && matches!(r.analysis, AnalysisState::Pending { .. })
                })
                .count(),
        };
        self.ask_scope = scope.clone();
        let result = self
            .ask_session
            .submit_question(&question, false, now, &lines, stats);
        let request = if let AskStepOutcome::DispatchLlm(plan) = result {
            let evidence: Result<Vec<_>, _> = plan
                .candidate_sources
                .iter()
                .map(|line| {
                    let mut ev = self.resolve_live_source(&source_ref(line))?;
                    ev.quote.clone_from(&line.text);
                    Ok(ev)
                })
                .collect();
            let request = AskRequest {
                operation: self.operation(),
                scope,
                question,
                system_prompt: plan.system_prompt,
                source_text: plan.source_text,
                instruction: plan.instruction,
                evidence: evidence?,
            };
            self.pending_ask = Some(request.clone());
            Some(request)
        } else {
            None
        };
        self.changed();
        Ok(request)
    }

    /// Validates request identity and every cited source before accepting a model answer.
    pub fn complete_ask(&mut self, operation: u64, answer: &str) -> Result<(), ProductError> {
        self.finish_ask(operation, answer, false)
    }

    /// Returns clearly labeled local evidence snippets when no language-model request is made.
    pub fn complete_retrieval(&mut self, operation: u64) -> Result<(), ProductError> {
        let request = self
            .pending_ask
            .as_ref()
            .filter(|r| r.operation == operation)
            .ok_or(ProductError::StaleRequest)?;
        self.validate_request_evidence(request)?;
        let mut answer = "本地检索找到以下原话：\n".to_string();
        for (index, evidence) in request.evidence.iter().enumerate() {
            let quote = evidence.quote.replace('[', "［").replace(']', "］");
            answer.push_str(&format!("\n{quote} [S{}]\n", index + 1));
        }
        self.finish_ask(operation, &answer, true)
    }

    fn finish_ask(
        &mut self,
        operation: u64,
        answer: &str,
        notice: bool,
    ) -> Result<(), ProductError> {
        let answer = nonempty(answer)?;
        if self.last_ask_operation == Some(operation)
            && self.pending_ask.is_none()
            && self.ask_session.messages.last().is_some_and(|m| {
                m.role == AskRole::Koe && m.status == AskStatus::Done && m.text == answer
            })
        {
            return Ok(());
        }
        let request = self
            .pending_ask
            .as_ref()
            .filter(|r| r.operation == operation)
            .ok_or(ProductError::StaleRequest)?;
        self.validate_request_evidence(request)?;
        let cited = cited_labels(&answer);
        if cited.is_empty()
            || cited.iter().any(|label| {
                SegmentId::parse_citation(label)
                    .is_none_or(|id| id.ordinal() as usize > request.evidence.len())
            })
        {
            return Err(ProductError::InvalidEvidence);
        }
        let outcome = if notice {
            self.ask_session.complete_notice_answer(answer)
        } else {
            self.ask_session.complete_answer(answer)
        };
        if !matches!(outcome, AskStepOutcome::AnswerCompleted { .. }) {
            return Err(ProductError::InvalidTransition);
        }
        self.pending_ask = None;
        self.last_ask_operation = Some(operation);
        self.changed();
        Ok(())
    }

    /// Records a real request failure without substituting a fabricated answer.
    pub fn fail_ask(&mut self, operation: u64, message: &str) -> Result<(), ProductError> {
        if !self
            .pending_ask
            .as_ref()
            .is_some_and(|r| r.operation == operation)
        {
            return Err(ProductError::StaleRequest);
        }
        self.ask_session.fail_answer(Some(&nonempty(message)?));
        self.pending_ask = None;
        self.changed();
        Ok(())
    }

    pub(super) fn validate_request_evidence(
        &self,
        request: &AskRequest,
    ) -> Result<(), ProductError> {
        self.validate_scope(&request.scope)?;
        if request.evidence.is_empty() {
            return Err(ProductError::InvalidEvidence);
        }
        for evidence in &request.evidence {
            if matches!(&request.scope, SearchScope::Record(id) if id != &evidence.source.record_id)
            {
                return Err(ProductError::InvalidEvidence);
            }
            self.resolve_live_source(&evidence.source)?;
            let segment = self.records[&evidence.source.record_id]
                .aggregate
                .spine
                .get(evidence.source.segment_id)
                .ok_or(ProductError::InvalidSource)?;
            if ask_source_text(segment) != evidence.quote {
                return Err(ProductError::StaleRequest);
            }
        }
        Ok(())
    }
}

pub(super) fn source_ref(line: &SourceLine) -> SourceRef {
    SourceRef {
        record_id: line.source.recording_key.clone(),
        segment_id: line.source.segment_id,
    }
}
