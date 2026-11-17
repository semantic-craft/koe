use std::ffi::OsStr;
use std::path::{Path, PathBuf};

const MAX_UNIX_SOCKET_PATH_BYTES: usize = 103;

/// Resolves the canonical local bridge Unix domain socket path for `workspace`.
///
/// Honors `KOE_BRIDGE_SOCKET` (`""`, `"0"`, or `"off"` disables the socket), places App Sandbox
/// default container workspaces inside `<Data>/.koe/koe.sock` (`koe-dev.sock` for development)
/// to stay within the 104-byte `sun_path` kernel limit without altering entitlements, and falls
/// back to `<workspace>/koe.sock` for standalone directories.
#[must_use]
pub fn resolve_bridge_socket_path(workspace: &Path) -> Option<PathBuf> {
    resolve_bridge_socket_path_with_env(workspace, std::env::var_os("KOE_BRIDGE_SOCKET").as_deref())
}

pub(crate) fn resolve_bridge_socket_path_with_env(
    workspace: &Path,
    env_override: Option<&OsStr>,
) -> Option<PathBuf> {
    if let Some(raw) = env_override {
        if let Some(s) = raw.to_str() {
            let trimmed = s.trim();
            if trimmed.is_empty() || trimmed == "0" || trimmed.eq_ignore_ascii_case("off") {
                return None;
            }
            let candidate = PathBuf::from(trimmed);
            return (candidate.as_os_str().as_encoded_bytes().len() < MAX_UNIX_SOCKET_PATH_BYTES)
                .then_some(candidate);
        }
        if raw.is_empty() {
            return None;
        }
        let candidate = PathBuf::from(raw);
        return (candidate.as_os_str().as_encoded_bytes().len() < MAX_UNIX_SOCKET_PATH_BYTES)
            .then_some(candidate);
    }

    let canonical_workspace = workspace.ancestors().find_map(|ancestor| {
        if !ancestor.ends_with("Containers/com.anker.ankerRecorder/Data") {
            return None;
        }
        match workspace.strip_prefix(ancestor).ok()?.to_str()? {
            "Library/Application Support/KoeWorkspace" => Some((ancestor, "koe.sock")),
            "Library/Application Support/KoeWorkspaceDevelopment" => {
                Some((ancestor, "koe-dev.sock"))
            }
            _ => None,
        }
    });
    let candidate = if let Some((container_data, sock_name)) = canonical_workspace {
        container_data.join(".koe").join(sock_name)
    } else {
        workspace.join("koe.sock")
    };

    (candidate.as_os_str().as_encoded_bytes().len() < MAX_UNIX_SOCKET_PATH_BYTES)
        .then_some(candidate)
}
