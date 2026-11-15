use super::*;

/// Original legacy analysis text, kept separate from source-validated native minutes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportedSummary {
    /// Imported recording owning this analysis.
    pub record_id: String,
    /// Original summary, analysis, or template slot.
    pub slot: String,
    /// Original text, without invented evidence references.
    pub text: String,
}

/// Durable result of a bounded import. Preserved files are immutable evidence, not a second workspace.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MigrationReceipt {
    /// Hash of the exact imported metadata and audio bytes.
    pub fingerprint: String,
    /// Relative directory of preserved originals inside the workspace.
    pub archive: String,
    /// Imported recording identities.
    pub record_ids: Vec<String>,
    /// Material preserved without native domain support.
    pub pending: Vec<String>,
    /// Legacy analysis visible as unverified imported text.
    pub summaries: Vec<ImportedSummary>,
}

impl ProductWorkspace {
    /// Completed imports and their explicit incomplete-domain inventory.
    pub fn migrations(&self) -> &[MigrationReceipt] {
        &self.migrations
    }

    pub(super) fn validate_migration(
        &self,
        receipt: &MigrationReceipt,
    ) -> Result<(), ProductError> {
        if receipt.fingerprint.len() != 64
            || !receipt.fingerprint.bytes().all(|b| b.is_ascii_hexdigit())
            || receipt.archive != format!("legacy-imports/{}", receipt.fingerprint)
        {
            return Err(ProductError::InvalidEvidence);
        }
        for id in &receipt.record_ids {
            if !self.records.contains_key(id) {
                return Err(ProductError::UnknownRecord);
            }
        }
        for summary in &receipt.summaries {
            if !receipt.record_ids.contains(&summary.record_id)
                || summary.slot.is_empty()
                || summary.text.trim().is_empty()
            {
                return Err(ProductError::InvalidEvidence);
            }
        }
        Ok(())
    }
}
