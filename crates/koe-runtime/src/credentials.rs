//! Secure platform I/O; credential values never enter product snapshots.
use std::collections::BTreeMap;

/// Sanitized failure at the secure storage boundary.
#[derive(Debug, Clone, Copy)]
pub struct CredentialError;

/// Platform-owned secure storage with immutable, independently addressed items.
pub trait CredentialStore: Send {
    /// Whether this adapter is isolated from the user's system credentials.
    fn isolated(&self) -> bool;
    /// Reads one immutable item, distinguishing missing from inaccessible.
    fn read(&mut self, reference: &str) -> Result<Option<String>, CredentialError>;
    /// Allocates a fresh unique reference without touching storage, so the
    /// workspace can record ownership before the item exists.
    fn prepare(&mut self, secret: &str) -> Result<String, CredentialError>;
    /// Allocates a fresh unique reference for a named provider slot (`"qwen"` or `"deepseek"`).
    fn prepare_for_slot(&mut self, _slot: &str, secret: &str) -> Result<String, CredentialError> {
        self.prepare(secret)
    }
    /// Creates a new item at a reference returned by `prepare`.
    fn create(&mut self, reference: &str, secret: &str) -> Result<(), CredentialError>;
    /// Deletes one previously created item. Missing is successful.
    fn delete(&mut self, reference: &str) -> Result<(), CredentialError>;
    /// Reads the old engines-v1 JSON item without modifying it.
    fn read_legacy(&mut self) -> Result<Option<String>, CredentialError> {
        Ok(None)
    }
    /// Explicit user request to authorize access; never called automatically.
    fn authorize(&mut self, _reference: Option<&str>) -> Result<(), CredentialError> {
        Ok(())
    }
}

/// Session-only adapter used by CLI, tests and unsigned development hosts.
#[derive(Default)]
pub struct IsolatedCredentials {
    items: BTreeMap<String, String>,
    next: u64,
}
impl CredentialStore for IsolatedCredentials {
    fn isolated(&self) -> bool {
        true
    }
    fn read(&mut self, reference: &str) -> Result<Option<String>, CredentialError> {
        Ok(self.items.get(reference).cloned())
    }
    fn prepare(&mut self, _secret: &str) -> Result<String, CredentialError> {
        self.next += 1;
        Ok(format!(
            "isolated-{}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_err(|_| CredentialError)?
                .as_nanos(),
            self.next
        ))
    }
    fn create(&mut self, reference: &str, secret: &str) -> Result<(), CredentialError> {
        self.items.insert(reference.into(), secret.into());
        Ok(())
    }
    fn delete(&mut self, reference: &str) -> Result<(), CredentialError> {
        self.items.remove(reference);
        Ok(())
    }
}
