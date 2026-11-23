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
pub struct IsolatedCredentials {
    items: BTreeMap<String, String>,
    next: u64,
    instance_id: u64,
    clock: crate::observability::env::RuntimeClock,
}

impl Default for IsolatedCredentials {
    fn default() -> Self {
        Self {
            items: BTreeMap::new(),
            next: 0,
            instance_id: u64::from(std::process::id()),
            clock: crate::observability::env::RuntimeClock::system(),
        }
    }
}

impl IsolatedCredentials {
    /// Creates an isolated in-memory credential store with deterministic reference allocation.
    #[must_use]
    pub fn deterministic(seed: u64) -> Self {
        Self {
            items: BTreeMap::new(),
            next: 0,
            instance_id: seed,
            clock: crate::observability::env::RuntimeClock::deterministic(seed % 1_000_000_000),
        }
    }

    /// Creates an isolated credential store backed by an injected [`crate::RuntimeClock`].
    #[must_use]
    pub fn with_clock(clock: crate::observability::env::RuntimeClock, instance_id: u64) -> Self {
        Self {
            items: BTreeMap::new(),
            next: 0,
            instance_id,
            clock,
        }
    }
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
        let nonce = self.clock.now_nanos().map_err(|_| CredentialError)?;
        Ok(format!("isolated-{}-{nonce}-{}", self.instance_id, self.next))
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
