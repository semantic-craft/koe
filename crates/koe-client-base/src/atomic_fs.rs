//! Atomic file persistence (`.tmp` write + `rename`) and process-scoped advisory
//! lockfile guard preventing concurrent workspace corruption.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process;
use std::sync::atomic::{AtomicU64, Ordering};

static TMP_SEQ: AtomicU64 = AtomicU64::new(1);

/// Rejects `path` (or its immediate parent directory) if it is a symbolic link,
/// matching Vecta's `VectaRecordingStore` symlink-traversal boundary guard.
pub fn reject_symlink_path(path: &Path) -> io::Result<()> {
    if let Ok(meta) = fs::symlink_metadata(path) {
        if meta.file_type().is_symlink() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("refusing to follow symlink at {}", path.display()),
            ));
        }
    }
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            if let Ok(parent_meta) = fs::symlink_metadata(parent) {
                if parent_meta.file_type().is_symlink() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        format!("refusing to follow symlink parent at {}", parent.display()),
                    ));
                }
            }
        }
    }
    Ok(())
}

/// Reads a UTF-8 string from `target` after verifying neither `target` nor its parent is a symlink.
pub fn read_checked_string(target: &Path) -> io::Result<String> {
    reject_symlink_path(target)?;
    fs::read_to_string(target)
}

/// Writes `bytes` to a sibling temporary file in the same directory as `target`,
/// flushes via `sync_all` (`fsync`), and atomically renames it into place.
/// Rejects symbolic links on `target` or its parent directory.
pub fn write_atomic(target: &Path, bytes: &[u8]) -> io::Result<()> {
    reject_symlink_path(target)?;
    if let Some(parent) = target.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent)?;
        }
    }
    let seq = TMP_SEQ.fetch_add(1, Ordering::Relaxed);
    let pid = process::id();
    let file_name = target
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("koe.blob");
    let tmp_name = format!(".{file_name}.{pid}.{seq}.tmp");
    let tmp_path = target.with_file_name(tmp_name);
    {
        let mut f = fs::File::create(&tmp_path)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    if let Err(err) = fs::rename(&tmp_path, target) {
        let _ = fs::remove_file(&tmp_path);
        return Err(err);
    }
    Ok(())
}

/// Process-scoped advisory lockfile guard for a Koe workspace directory.
#[derive(Debug)]
pub struct WorkspaceLockGuard {
    lock_path: PathBuf,
    file: fs::File,
}

impl WorkspaceLockGuard {
    /// Acquires an exclusive OS advisory lock; a closed or crashed writer releases it.
    pub fn acquire(workspace_dir: &Path) -> io::Result<Self> {
        fs::create_dir_all(workspace_dir)?;
        let lock_path = workspace_dir.join(".koe-workspace.lock");
        reject_symlink_path(&lock_path)?;
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NOFOLLOW).mode(0o600);
        }
        let mut file = options.open(&lock_path)?;
        fs2::FileExt::try_lock_exclusive(&file).map_err(|error| {
            if error.kind() == io::ErrorKind::WouldBlock {
                io::Error::new(io::ErrorKind::WouldBlock, "工作区正被另一个 Koe 进程占用")
            } else {
                error
            }
        })?;
        file.set_len(0)?;
        write!(file, "{}", process::id())?;
        Ok(Self { lock_path, file })
    }

    /// Returns the path of the underlying lockfile.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.lock_path
    }
}

impl Drop for WorkspaceLockGuard {
    fn drop(&mut self) {
        // Keep the inode: unlinking lets another writer lock a different file.
        let _ = fs2::FileExt::unlock(&self.file);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_lock_excludes_another_writer_in_same_process() {
        let dir = std::env::temp_dir().join(format!("koe-exclusive-lock-{}", process::id()));
        let _ = fs::remove_dir_all(&dir);
        let first = WorkspaceLockGuard::acquire(&dir).expect("first writer");
        assert!(
            WorkspaceLockGuard::acquire(&dir).is_err(),
            "second writer must be rejected"
        );
        drop(first);
        let _second = WorkspaceLockGuard::acquire(&dir).expect("release permits next writer");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_atomic_persists_bytes_and_leaves_no_tmp_files() {
        let dir = std::env::temp_dir().join(format!("koe-base-atomic-{}", process::id()));
        let _ = fs::remove_dir_all(&dir);
        let target = dir.join("state.json");
        write_atomic(&target, b"{\"ok\":true}").expect("atomic write succeeds");
        assert_eq!(fs::read(&target).expect("read back"), b"{\"ok\":true}");
        let entries: Vec<_> = fs::read_dir(&dir)
            .expect("list dir")
            .filter_map(Result::ok)
            .collect();
        assert_eq!(entries.len(), 1);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn workspace_lock_guard_reuses_file_after_release() {
        let dir = std::env::temp_dir().join(format!("koe-base-lock-{}", process::id()));
        let _ = fs::remove_dir_all(&dir);
        let lock_file = dir.join(".koe-workspace.lock");
        {
            let guard = WorkspaceLockGuard::acquire(&dir).expect("acquire lock");
            assert!(guard.path().exists());
        }
        assert!(lock_file.exists());
        let _next = WorkspaceLockGuard::acquire(&dir).expect("reacquire released OS lock");
        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn write_atomic_and_read_checked_string_reject_symlinks() {
        use std::os::unix::fs::symlink;
        let dir = std::env::temp_dir().join(format!("koe-base-symlink-{}", process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("create temp dir");
        let real_file = dir.join("real.json");
        fs::write(&real_file, b"{\"secret\":1}").expect("write real file");
        let link_file = dir.join("link.json");
        symlink(&real_file, &link_file).expect("create symlink");

        let write_err = write_atomic(&link_file, b"{\"overwritten\":true}")
            .expect_err("must reject writing through a symlink");
        assert_eq!(write_err.kind(), io::ErrorKind::InvalidInput);
        assert_eq!(
            fs::read(&real_file).expect("read original"),
            b"{\"secret\":1}"
        );

        let read_err =
            read_checked_string(&link_file).expect_err("must reject reading through a symlink");
        assert_eq!(read_err.kind(), io::ErrorKind::InvalidInput);
        let _ = fs::remove_dir_all(&dir);
    }
}
