use std::collections::BTreeSet;

use koe_engine::product::{ProductRecord, ProductWorkspace};

use crate::{
    command::{Location, Page, Playback},
    live_minutes::LiveMinutesScope,
};

#[derive(Default)]
pub(super) struct WorkspaceSelection {
    pub location: Location,
    pub back: Vec<Location>,
    pub playback: Playback,
    pub selected_quick_note_record: Option<String>,
    pub selected_all_day_date: Option<String>,
    pub selected_live_minutes_record: Option<String>,
    pub live_minutes_scope: Option<LiveMinutesScope>,
}

impl WorkspaceSelection {
    pub(super) fn go(&mut self, location: Location) {
        self.back.push(self.location.clone());
        if self.back.len() > 32 {
            self.back.remove(0);
        }
        self.set_location(location);
    }

    pub(super) fn set_location(&mut self, location: Location) {
        if self.playback.record != location.record {
            self.playback.record = location.record.clone();
            self.playback.lane = None;
            self.playback.request_id = self.playback.request_id.saturating_add(1);
            self.playback.position_ms = 0;
            self.playback.playing = false;
        }
        self.location = location;
    }

    pub(super) fn pop_back(&mut self) {
        if let Some(location) = self.back.pop() {
            self.set_location(location);
        }
    }

    pub(super) fn detach_records(
        &mut self,
        removed_ids: &BTreeSet<String>,
        workspace: &ProductWorkspace,
        all_day_active_run: Option<&str>,
    ) {
        if self
            .selected_quick_note_record
            .as_ref()
            .is_some_and(|id| removed_ids.contains(id))
        {
            self.selected_quick_note_record = None;
        }
        if self
            .selected_live_minutes_record
            .as_ref()
            .is_some_and(|id| removed_ids.contains(id))
        {
            self.selected_live_minutes_record = None;
        }
        let clear_live_minutes = match &self.live_minutes_scope {
            Some(LiveMinutesScope::Record(id)) => {
                removed_ids.contains(id)
                    || !workspace.record(id).is_some_and(ProductRecord::is_live)
            }
            Some(LiveMinutesScope::AllDay(run_id)) => {
                all_day_active_run != Some(run_id.as_str())
                    && !workspace.records().values().any(|record| {
                        record.is_live()
                            && record
                                .all_day
                                .as_ref()
                                .is_some_and(|segment| &segment.run_id == run_id)
                    })
            }
            Some(LiveMinutesScope::BeanStarting) | None => false,
        };
        if clear_live_minutes {
            self.live_minutes_scope = None;
        }
        if self
            .playback
            .record
            .as_ref()
            .is_some_and(|id| removed_ids.contains(id))
        {
            self.playback.record = None;
            self.playback.lane = None;
            self.playback.position_ms = 0;
            self.playback.playing = false;
            self.playback.request_id = self.playback.request_id.saturating_add(1);
        }
        let mut cleaned_back = Vec::with_capacity(self.back.len());
        for mut loc in std::mem::take(&mut self.back) {
            let dead_record = loc.record.as_ref().is_some_and(|id| {
                removed_ids.contains(id)
                    || !workspace.record(id).is_some_and(ProductRecord::is_live)
            });
            if dead_record {
                if loc.page == Page::Detail {
                    continue;
                }
                loc.record = None;
                loc.segment = None;
            }
            if cleaned_back.last() != Some(&loc) {
                cleaned_back.push(loc);
            }
        }
        self.back = cleaned_back;

        if self
            .location
            .record
            .as_ref()
            .is_some_and(|id| removed_ids.contains(id))
        {
            if self.location.page == Page::Detail {
                let fallback = self.back.pop().unwrap_or(Location {
                    page: Page::Records,
                    record: None,
                    segment: None,
                });
                self.set_location(fallback);
            } else {
                self.location.record = None;
                self.location.segment = None;
            }
        }
        while self.back.last() == Some(&self.location) {
            self.back.pop();
        }
    }
}
