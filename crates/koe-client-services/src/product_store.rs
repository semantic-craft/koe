//! Atomic persistence for the single product workspace; the codec is private.

#[path = "product_store_codec.rs"]
mod codec;

use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use koe_client_base::atomic_fs::{read_checked_string, write_atomic, WorkspaceLockGuard};
use koe_engine::product::{ProductError, ProductWorkspace};

/// Filename of the versioned product metadata snapshot.
pub const PRODUCT_WORKSPACE_FILE: &str = "product-workspace.json";

/// Storage failures remain distinct from rejected domain operations.
#[derive(Debug)]
pub enum StoreError {
    /// Filesystem or exclusive-lock failure before a confirmed commit.
    Io(io::Error),
    /// Existing data does not satisfy the supported schema or domain invariants.
    InvalidData(String),
    /// The requested product operation was rejected.
    Domain(ProductError),
    /// Rename succeeded but the durability barrier failed; this store stops writing.
    CommitUncertain(io::Error),
    /// A prior uncertain commit requires closing and reopening the store.
    Unavailable,
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(f, "无法保存或读取工作区：{error}"),
            Self::InvalidData(error) => write!(f, "工作区数据无效：{error}"),
            Self::Domain(error) => error.fmt(f),
            Self::CommitUncertain(error) => {
                write!(f, "无法确认保存结果，请重新打开工作区：{error}")
            }
            Self::Unavailable => f.write_str("保存结果尚未确认，请重新打开工作区"),
        }
    }
}

impl std::error::Error for StoreError {}
impl From<io::Error> for StoreError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}
impl From<ProductError> for StoreError {
    fn from(error: ProductError) -> Self {
        Self::Domain(error)
    }
}

/// Exclusive writer whose successful transactions are durable before becoming visible.
#[derive(Debug)]
pub struct ProductStore {
    path: PathBuf,
    workspace: ProductWorkspace,
    _lock: WorkspaceLockGuard,
    uncertain: bool,
}

impl ProductStore {
    /// Opens an existing valid snapshot or an empty workspace. Corrupt data is never replaced.
    pub fn open(directory: impl AsRef<Path>) -> Result<Self, StoreError> {
        let directory = directory.as_ref();
        let lock = WorkspaceLockGuard::acquire(directory)?;
        let path = directory.join(PRODUCT_WORKSPACE_FILE);
        let workspace = match read_checked_string(&path) {
            Ok(raw) => codec::decode(&raw)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => ProductWorkspace::new(),
            Err(error) => return Err(StoreError::Io(error)),
        };
        let mut store = Self {
            path,
            workspace,
            _lock: lock,
            uncertain: false,
        };
        if store.workspace.has_pending_work() {
            let mut recovered = store.workspace.clone();
            if recovered.interrupt_pending() {
                store.commit(recovered)?;
            }
        }
        Ok(store)
    }

    /// An uncertain durability barrier requires reopening before further operations.
    #[must_use]
    pub fn requires_reopen(&self) -> bool {
        self.uncertain
    }

    /// Immutable committed state; callers cannot mutate it outside a transaction.
    #[must_use]
    pub fn workspace(&self) -> &ProductWorkspace {
        &self.workspace
    }

    /// Validates a candidate, commits it atomically, then exposes the new state and result.
    pub fn transact<T>(
        &mut self,
        change: impl FnOnce(&mut ProductWorkspace) -> Result<T, ProductError>,
    ) -> Result<T, StoreError> {
        if self.uncertain {
            return Err(StoreError::Unavailable);
        }
        let mut candidate = self.workspace.clone();
        let output = change(&mut candidate)?;
        if candidate.revision() != self.workspace.revision() || candidate != self.workspace {
            self.commit(candidate)?;
        }
        Ok(output)
    }

    fn commit(&mut self, candidate: ProductWorkspace) -> Result<(), StoreError> {
        let raw = codec::encode(&candidate)?;
        write_atomic(&self.path, raw.as_bytes())?;
        let parent = self
            .path
            .parent()
            .ok_or_else(|| StoreError::InvalidData("工作区路径无父目录".to_string()))?;
        if let Err(error) = fs::File::open(parent)
            .and_then(|directory| directory.sync_all())
            .and_then(|()| {
                koe_client_base::fault_injection::check(
                    koe_client_base::fault_injection::FsFaultPoint::StoreDirSync,
                )
            })
        {
            self.uncertain = true;
            return Err(StoreError::CommitUncertain(error));
        }
        self.workspace = candidate;
        Ok(())
    }
}
