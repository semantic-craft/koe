//! Structured meeting minutes grounding validator (`S1..Sn` evidence checks)
//! and prompt/JSON codec.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

mod codec;
mod grounding;
mod json;
mod prompt;
#[cfg(test)]
mod tests;

pub use codec::{
    encode_meeting_minutes_json, parse_meeting_minutes_json, parse_persisted_meeting_minutes_json,
};
pub use grounding::{
    validate_minutes_citations, validate_minutes_grounding, MinutesValidationError,
};
pub use json::{extract_json_object, JsonValue};
pub use prompt::build_meeting_minutes_prompt;
