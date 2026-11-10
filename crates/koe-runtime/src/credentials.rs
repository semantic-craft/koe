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
    /// Creates a new item and returns its unique opaque reference.
    fn create(&mut self, secret: &str) -> Result<String, CredentialError>;
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
    fn create(&mut self, secret: &str) -> Result<String, CredentialError> {
        self.next += 1;
        let reference = format!(
            "isolated-{}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_err(|_| CredentialError)?
                .as_nanos(),
            self.next
        );
        self.items.insert(reference.clone(), secret.into());
        Ok(reference)
    }
    fn delete(&mut self, reference: &str) -> Result<(), CredentialError> {
        self.items.remove(reference);
        Ok(())
    }
}
