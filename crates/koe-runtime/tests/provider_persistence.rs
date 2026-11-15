use koe_runtime::KoeRuntime;
use serde_json::{json, Value};
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
struct Sandbox(PathBuf);
impl Sandbox {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "koe-provider-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn send(runtime: &mut KoeRuntime, command: Value) -> Value {
    serde_json::from_str(&runtime.dispatch_json(&command.to_string(), 100)).unwrap()
}
#[test]
fn non_sensitive_configuration_survives_restart() {
    let root = Sandbox::new();
    let mut runtime = KoeRuntime::open(&root.0).unwrap();
    let response = send(
        &mut runtime,
        json!({"type":"configure_provider","apiKey":"fixture-secret","model":"fixture-model","chatEndpoint":"http://127.0.0.1:9000/chat","asrEndpoint":"ws://127.0.0.1:9001/asr"}),
    );
    assert!(response["error"].is_null());
    drop(runtime);
    let runtime = KoeRuntime::open(&root.0).unwrap();
    assert_eq!(runtime.snapshot(100)["provider"]["model"], "fixture-model");
}
#[test]
fn explicit_clear_removes_active_credential() {
    let root = Sandbox::new();
    let mut runtime = KoeRuntime::open(&root.0).unwrap();
    send(
        &mut runtime,
        json!({"type":"configure_provider","apiKey":"fixture-secret","model":"fixture-model"}),
    );
    let response = send(&mut runtime, json!({"type":"clear_provider_credential"}));
    assert!(response["error"].is_null());
    assert_eq!(response["provider"]["configured"], false);
}

use koe_runtime::credentials::{CredentialError, CredentialStore};
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};
#[derive(Default)]
struct Vault {
    items: BTreeMap<String, String>,
    next: u64,
    legacy: Option<String>,
    fail_read: bool,
    fail_write: bool,
    fail_delete: bool,
    denied_deletes: std::collections::BTreeSet<String>,
    fail_authorize: bool,
    panic_after_create: bool,
    mismatch: bool,
    authorize_deletion: bool,
    authorized: Vec<Option<String>>,
}
#[derive(Clone, Default)]
struct Adapter(Arc<Mutex<Vault>>);
impl CredentialStore for Adapter {
    fn isolated(&self) -> bool {
        false
    }
    fn read(&mut self, reference: &str) -> Result<Option<String>, CredentialError> {
        let v = self.0.lock().unwrap();
        if v.fail_read {
            Err(CredentialError)
        } else if v.mismatch {
            Ok(Some("wrong-fixture".into()))
        } else {
            Ok(v.items.get(reference).cloned())
        }
    }
    fn prepare(&mut self, _secret: &str) -> Result<String, CredentialError> {
        let mut v = self.0.lock().unwrap();
        v.next += 1;
        Ok(format!("fixture-{}", v.next))
    }
    fn create(&mut self, reference: &str, secret: &str) -> Result<(), CredentialError> {
        let mut v = self.0.lock().unwrap();
        if v.fail_write {
            return Err(CredentialError);
        }
        v.items.insert(reference.into(), secret.into());
        if v.panic_after_create {
            drop(v);
            panic!("simulated termination after secure item creation");
        }
        Ok(())
    }
    fn delete(&mut self, reference: &str) -> Result<(), CredentialError> {
        let mut v = self.0.lock().unwrap();
        if v.fail_delete || v.denied_deletes.contains(reference) {
            return Err(CredentialError);
        }
        v.items.remove(reference);
        Ok(())
    }
    fn authorize(&mut self, reference: Option<&str>) -> Result<(), CredentialError> {
        let mut v = self.0.lock().unwrap();
        v.authorized.push(reference.map(str::to_owned));
        if v.fail_authorize {
            return Err(CredentialError);
        }
        if v.authorize_deletion {
            if let Some(reference) = reference {
                v.denied_deletes.remove(reference);
            }
        }
        if v.authorize_deletion && reference.is_some_and(|r| v.items.contains_key(r)) {
            v.fail_delete = false;
        }
        Ok(())
    }
    fn read_legacy(&mut self) -> Result<Option<String>, CredentialError> {
        let v = self.0.lock().unwrap();
        if v.fail_read {
            Err(CredentialError)
        } else {
            Ok(v.legacy.clone())
        }
    }
}
fn open(root: &Sandbox, adapter: &Adapter) -> KoeRuntime {
    KoeRuntime::open_with_credentials(&root.0, Box::new(adapter.clone())).unwrap()
}
fn configure(runtime: &mut KoeRuntime, key: &str) -> Value {
    send(
        runtime,
        json!({"type":"configure_provider","apiKey":key,"model":"fixture-model"}),
    )
}
#[test]
fn secure_credential_survives_restart_without_leaking() {
    let root = Sandbox::new();
    let adapter = Adapter::default();
    let mut runtime = open(&root, &adapter);
    assert!(configure(&mut runtime, "fixture-sensitive-value")["error"].is_null());
    drop(runtime);
    let runtime = open(&root, &adapter);
    let snapshot = runtime.snapshot(100);
    assert_eq!(snapshot["provider"]["configured"], true);
    assert!(!snapshot.to_string().contains("fixture-sensitive-value"));
    assert!(!fs::read_to_string(root.0.join("product-workspace.json"))
        .unwrap()
        .contains("fixture-sensitive-value"));
}
#[test]
fn storage_write_failure_does_not_replace_working_configuration() {
    let root = Sandbox::new();
    let adapter = Adapter::default();
    let mut runtime = open(&root, &adapter);
    configure(&mut runtime, "old-fixture");
    adapter.0.lock().unwrap().fail_write = true;
    let response = configure(&mut runtime, "new-fixture");
    assert!(!response["error"].is_null());
    drop(runtime);
    adapter.0.lock().unwrap().fail_write = false;
    let runtime = open(&root, &adapter);
    assert_eq!(runtime.snapshot(100)["provider"]["configured"], true);
    assert!(adapter
        .0
        .lock()
        .unwrap()
        .items
        .values()
        .any(|v| v == "old-fixture"));
}
#[test]
fn read_failure_is_distinct_from_missing_and_blocks_overwrite() {
    let root = Sandbox::new();
    let adapter = Adapter::default();
    adapter.0.lock().unwrap().fail_read = true;
    let mut runtime = open(&root, &adapter);
    assert_eq!(
        runtime.snapshot(100)["provider"]["credentialState"],
        "unavailable"
    );
    assert!(!configure(&mut runtime, "new-fixture")["error"].is_null());
    assert!(adapter.0.lock().unwrap().items.is_empty());
}
#[test]
fn clear_tombstone_survives_delete_failure_and_legacy_cannot_resurrect() {
    let root = Sandbox::new();
    let adapter = Adapter::default();
    adapter.0.lock().unwrap().legacy =
        Some(r#"{"qwen":"old-fixture","doubao":"preserve-fixture"}"#.into());
    let mut runtime = open(&root, &adapter);
    assert_eq!(runtime.snapshot(100)["provider"]["configured"], true);
    adapter.0.lock().unwrap().fail_delete = true;
    let response = send(&mut runtime, json!({"type":"clear_provider_credential"}));
    assert_eq!(response["provider"]["configured"], false);
    assert!(!response["error"].is_null());
    drop(runtime);
    adapter.0.lock().unwrap().fail_delete = false;
    let runtime = open(&root, &adapter);
    assert_eq!(runtime.snapshot(100)["provider"]["configured"], false);
    assert!(adapter.0.lock().unwrap().items.is_empty());
    assert!(adapter
        .0
        .lock()
        .unwrap()
        .legacy
        .as_ref()
        .unwrap()
        .contains("preserve-fixture"));
}
#[test]
fn metadata_failure_keeps_old_reference_and_discards_uncommitted_secret() {
    let root = Sandbox::new();
    let adapter = Adapter::default();
    let mut runtime = open(&root, &adapter);
    send(
        &mut runtime,
        json!({"type":"create_note","title":"Persistence fixture","text":"A stored record."}),
    );
    configure(&mut runtime, "old-fixture");
    let path = root.0.join("product-workspace.json");
    let saved = root.0.join("saved.json");
    fs::rename(&path, &saved).unwrap();
    fs::create_dir(&path).unwrap();
    let response = configure(&mut runtime, "new-fixture");
    assert!(!response["error"].is_null());
    assert_eq!(response["provider"]["configured"], true);
    assert_eq!(
        adapter
            .0
            .lock()
            .unwrap()
            .items
            .values()
            .cloned()
            .collect::<Vec<_>>(),
        vec!["old-fixture"]
    );
    fs::remove_dir(&path).unwrap();
    fs::rename(&saved, &path).unwrap();
    drop(runtime);
    let runtime = open(&root, &adapter);
    assert_eq!(runtime.snapshot(100)["provider"]["configured"], true);
}
#[test]
fn readback_mismatch_does_not_publish_or_keep_new_secret() {
    let root = Sandbox::new();
    let adapter = Adapter::default();
    let mut runtime = open(&root, &adapter);
    adapter.0.lock().unwrap().mismatch = true;
    assert!(!configure(&mut runtime, "new-fixture")["error"].is_null());
    assert_eq!(runtime.snapshot(100)["provider"]["configured"], false);
    assert!(adapter.0.lock().unwrap().items.is_empty());
}
#[test]
fn missing_saved_item_never_falls_back_to_legacy() {
    let root = Sandbox::new();
    let adapter = Adapter::default();
    let mut runtime = open(&root, &adapter);
    configure(&mut runtime, "new-fixture");
    drop(runtime);
    {
        let mut v = adapter.0.lock().unwrap();
        v.items.clear();
        v.legacy = Some(r#"{"qwen":"old-fixture"}"#.into());
    }
    let runtime = open(&root, &adapter);
    assert_eq!(
        runtime.snapshot(100)["provider"]["credentialState"],
        "missing_saved"
    );
    assert_eq!(runtime.snapshot(100)["provider"]["configured"], false);
}
#[test]
fn configuration_only_update_keeps_secret_and_endpoint_reset_is_explicit() {
    let root = Sandbox::new();
    let adapter = Adapter::default();
    let mut runtime = open(&root, &adapter);
    configure(&mut runtime, "fixture-secret");
    let response = send(
        &mut runtime,
        json!({"type":"configure_provider","model":"updated-model","chatEndpoint":"http://127.0.0.1:9000/chat"}),
    );
    assert!(response["error"].is_null());
    assert_eq!(response["provider"]["configured"], true);
    let response = send(
        &mut runtime,
        json!({"type":"configure_provider","model":"updated-model","chatEndpoint":""}),
    );
    assert_eq!(
        response["provider"]["chatEndpoint"],
        "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
    );
    drop(runtime);
    let runtime = open(&root, &adapter);
    assert_eq!(runtime.snapshot(100)["provider"]["model"], "updated-model");
    assert_eq!(adapter.0.lock().unwrap().items.len(), 1);
}
#[test]
fn endpoint_embedded_secrets_are_rejected_before_any_storage_write() {
    let root = Sandbox::new();
    let adapter = Adapter::default();
    let mut runtime = open(&root, &adapter);
    for endpoint in [
        "https://user:secret@example.org/chat",
        "https://example.org/chat?token=secret",
        "https://example.org/chat#secret",
    ] {
        let response = send(
            &mut runtime,
            json!({"type":"configure_provider","model":"fixture","apiKey":"new-fixture","chatEndpoint":endpoint}),
        );
        assert!(!response["error"].is_null());
    }
    assert!(adapter.0.lock().unwrap().items.is_empty());
    assert!(!root.0.join("product-workspace.json").exists());
}
#[test]
fn replacement_cleanup_is_retried_without_losing_current_secret() {
    let root = Sandbox::new();
    let adapter = Adapter::default();
    let mut runtime = open(&root, &adapter);
    configure(&mut runtime, "old-fixture");
    adapter.0.lock().unwrap().fail_delete = true;
    let response = configure(&mut runtime, "new-fixture");
    assert!(!response["error"].is_null());
    assert_eq!(response["provider"]["configured"], true);
    drop(runtime);
    adapter.0.lock().unwrap().fail_delete = false;
    let runtime = open(&root, &adapter);
    assert_eq!(runtime.snapshot(100)["provider"]["configured"], true);
    assert_eq!(
        adapter
            .0
            .lock()
            .unwrap()
            .items
            .values()
            .cloned()
            .collect::<Vec<_>>(),
        vec!["new-fixture"]
    );
}

#[test]
fn isolated_cli_does_not_acknowledge_deletion_of_system_items() {
    let root = Sandbox::new();
    let adapter = Adapter::default();
    let mut runtime = open(&root, &adapter);
    configure(&mut runtime, "old-fixture");
    adapter.0.lock().unwrap().fail_delete = true;
    configure(&mut runtime, "new-fixture");
    drop(runtime);
    let isolated = KoeRuntime::open(&root.0).unwrap();
    assert!(!isolated.snapshot(100)["provider"]["configured"]
        .as_bool()
        .unwrap());
    drop(isolated);
    adapter.0.lock().unwrap().fail_delete = false;
    let runtime = open(&root, &adapter);
    assert_eq!(runtime.snapshot(100)["provider"]["configured"], true);
    assert_eq!(
        adapter
            .0
            .lock()
            .unwrap()
            .items
            .values()
            .cloned()
            .collect::<Vec<_>>(),
        vec!["new-fixture"]
    );
}

#[cfg(unix)]
#[test]
fn uncertain_clear_requires_reopen_and_retry_cannot_restore_old_secret() {
    use std::os::unix::fs::PermissionsExt;
    let root = Sandbox::new();
    let adapter = Adapter::default();
    let mut runtime = open(&root, &adapter);
    configure(&mut runtime, "old-fixture");
    let permissions = fs::metadata(&root.0).unwrap().permissions();
    fs::set_permissions(&root.0, fs::Permissions::from_mode(0o300)).unwrap();
    let response = send(&mut runtime, json!({"type":"clear_provider_credential"}));
    fs::set_permissions(&root.0, permissions).unwrap();
    assert!(response["error"]
        .as_str()
        .unwrap()
        .contains("无法确认保存结果"));
    let retried = send(&mut runtime, json!({"type":"retry_provider_credentials"}));
    assert_eq!(retried["provider"]["configured"], false);
    assert_eq!(retried["provider"]["credentialState"], "reopen_required");
    drop(runtime);
    let runtime = open(&root, &adapter);
    assert_eq!(
        runtime.snapshot(100)["provider"]["credentialState"],
        "cleared"
    );
}

#[test]
fn clear_retry_authorizes_only_retired_item_and_does_not_restore_legacy() {
    let root = Sandbox::new();
    let adapter = Adapter::default();
    let mut runtime = open(&root, &adapter);
    configure(&mut runtime, "old-fixture");
    {
        let mut v = adapter.0.lock().unwrap();
        v.fail_delete = true;
        v.authorize_deletion = true;
    }
    let cleared = send(&mut runtime, json!({"type":"clear_provider_credential"}));
    assert!(!cleared["error"].is_null());
    let response = send(
        &mut runtime,
        json!({"type":"retry_provider_credentials","authorize":true}),
    );
    assert!(response["error"].is_null());
    assert_eq!(response["provider"]["configured"], false);
    let v = adapter.0.lock().unwrap();
    assert!(v.items.is_empty());
    assert_eq!(v.authorized, vec![Some("fixture-1".into())]);
}

#[test]
fn cleanup_advances_past_deleted_items_to_authorize_remaining_item() {
    let root = Sandbox::new();
    let adapter = Adapter::default();
    let mut runtime = open(&root, &adapter);
    configure(&mut runtime, "first-fixture");
    adapter.0.lock().unwrap().fail_delete = true;
    configure(&mut runtime, "second-fixture");
    configure(&mut runtime, "third-fixture");
    {
        let mut v = adapter.0.lock().unwrap();
        v.fail_delete = false;
        v.denied_deletes.insert("fixture-2".into());
        v.authorize_deletion = true;
    }
    send(&mut runtime, json!({"type":"retry_provider_credentials"}));
    let response = send(
        &mut runtime,
        json!({"type":"retry_provider_credentials","authorize":true}),
    );
    assert!(response["error"].is_null());
    assert_eq!(
        adapter.0.lock().unwrap().authorized,
        vec![Some("fixture-2".into())]
    );
    assert_eq!(
        adapter
            .0
            .lock()
            .unwrap()
            .items
            .values()
            .cloned()
            .collect::<Vec<_>>(),
        vec!["third-fixture"]
    );
}
#[test]
fn failed_retired_authorization_does_not_disable_current_credential() {
    let root = Sandbox::new();
    let adapter = Adapter::default();
    let mut runtime = open(&root, &adapter);
    configure(&mut runtime, "first-fixture");
    {
        let mut v = adapter.0.lock().unwrap();
        v.fail_delete = true;
        v.fail_authorize = true;
    }
    configure(&mut runtime, "second-fixture");
    let response = send(
        &mut runtime,
        json!({"type":"retry_provider_credentials","authorize":true}),
    );
    assert!(!response["error"].is_null());
    assert_eq!(response["provider"]["configured"], true);
    assert_eq!(response["provider"]["credentialState"], "ready");
}

#[test]
fn pending_orphan_delete_failure_retries_with_explicit_authorization() {
    let root = Sandbox::new();
    let adapter = Adapter::default();
    let mut runtime = open(&root, &adapter);
    configure(&mut runtime, "old-fixture");
    adapter.0.lock().unwrap().panic_after_create = true;
    let crashed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
        configure(&mut runtime, "new-fixture");
    }));
    assert!(crashed.is_err());
    {
        let mut v = adapter.0.lock().unwrap();
        v.panic_after_create = false;
        assert_eq!(
            v.items.get("fixture-2").map(String::as_str),
            Some("new-fixture")
        );
        v.denied_deletes.insert("fixture-2".into());
        v.authorize_deletion = true;
    }
    let mut runtime = open(&root, &adapter);
    assert_eq!(runtime.snapshot(100)["provider"]["configured"], true);
    let response = send(
        &mut runtime,
        json!({"type":"retry_provider_credentials","authorize":true}),
    );
    assert!(response["error"].is_null());
    assert_eq!(response["provider"]["configured"], true);
    let v = adapter.0.lock().unwrap();
    assert_eq!(v.authorized, vec![Some("fixture-2".into())]);
    assert_eq!(
        v.items.values().cloned().collect::<Vec<_>>(),
        vec!["old-fixture"]
    );
}

/// Secure storage shared by several workspaces through one file, so a child
/// process can be killed between item creation and the workspace commit.
#[cfg(unix)]
#[derive(Clone)]
struct FileVault {
    path: PathBuf,
    kill_on_create: bool,
}
#[cfg(unix)]
impl FileVault {
    fn load(&self) -> Value {
        fs::read_to_string(&self.path)
            .map(|raw| serde_json::from_str(&raw).unwrap())
            .unwrap_or_else(|_| json!({"items":{},"next":0}))
    }
    fn save(&self, value: &Value) {
        use std::io::Write;
        let mut file = fs::File::create(&self.path).unwrap();
        file.write_all(value.to_string().as_bytes()).unwrap();
        file.sync_all().unwrap();
    }
    fn items(&self) -> BTreeMap<String, String> {
        serde_json::from_value(self.load()["items"].clone()).unwrap()
    }
    fn insert(&mut self, reference: &str, secret: &str) {
        let mut value = self.load();
        value["items"][reference] = json!(secret);
        self.save(&value);
        if self.kill_on_create {
            let _ = std::process::Command::new("kill")
                .args(["-KILL", &std::process::id().to_string()])
                .status();
            loop {
                std::thread::sleep(std::time::Duration::from_secs(1));
            }
        }
    }
}
#[cfg(unix)]
impl CredentialStore for FileVault {
    fn isolated(&self) -> bool {
        false
    }
    fn read(&mut self, reference: &str) -> Result<Option<String>, CredentialError> {
        Ok(self.items().get(reference).cloned())
    }
    fn prepare(&mut self, _secret: &str) -> Result<String, CredentialError> {
        let mut value = self.load();
        let next = value["next"].as_u64().unwrap() + 1;
        value["next"] = json!(next);
        self.save(&value);
        Ok(format!("vault-{next}"))
    }
    fn create(&mut self, reference: &str, secret: &str) -> Result<(), CredentialError> {
        self.insert(reference, secret);
        Ok(())
    }
    fn delete(&mut self, reference: &str) -> Result<(), CredentialError> {
        let mut value = self.load();
        value["items"].as_object_mut().unwrap().remove(reference);
        self.save(&value);
        Ok(())
    }
    fn read_legacy(&mut self) -> Result<Option<String>, CredentialError> {
        Ok(self.load()["engines-v1"].as_str().map(str::to_owned))
    }
}

#[cfg(unix)]
fn saved_reference(root: &Sandbox) -> String {
    let raw = fs::read_to_string(root.0.join("product-workspace.json")).unwrap();
    let value: Value = serde_json::from_str(&raw).unwrap();
    value["provider"]["credential"]["reference"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[cfg(unix)]
#[test]
fn real_sigkill_after_create_reclaims_orphan_without_touching_other_workspace_or_legacy() {
    const TEST: &str =
        "real_sigkill_after_create_reclaims_orphan_without_touching_other_workspace_or_legacy";
    if let Ok(workspace) = std::env::var("KOE_TEST_CRASH_WORKSPACE") {
        let vault = FileVault {
            path: std::env::var("KOE_TEST_CRASH_VAULT").unwrap().into(),
            kill_on_create: true,
        };
        let mut runtime =
            KoeRuntime::open_with_credentials(PathBuf::from(workspace), Box::new(vault)).unwrap();
        if let Ok(key) = std::env::var("KOE_TEST_CRASH_KEY") {
            configure(&mut runtime, &key);
        }
        return;
    }
    use std::os::unix::process::ExitStatusExt;
    let vault_dir = Sandbox::new();
    let vault = FileVault {
        path: vault_dir.0.join("vault.json"),
        kill_on_create: false,
    };
    let (ws_a, ws_b, ws_c) = (Sandbox::new(), Sandbox::new(), Sandbox::new());
    for (root, key) in [(&ws_a, "old-secret"), (&ws_b, "b-secret")] {
        let mut runtime =
            KoeRuntime::open_with_credentials(&root.0, Box::new(vault.clone())).unwrap();
        assert!(configure(&mut runtime, key)["error"].is_null());
    }
    let legacy = r#"{"qwen":"legacy-secret","doubao":"legacy-doubao"}"#;
    let mut value = vault.load();
    value["engines-v1"] = json!(legacy);
    vault.save(&value);
    let (ref_a, ref_b) = (saved_reference(&ws_a), saved_reference(&ws_b));
    let workspace_b = fs::read(ws_b.0.join("product-workspace.json")).unwrap();
    let crash = |root: &Sandbox, key: Option<&str>| {
        let mut child = std::process::Command::new(std::env::current_exe().unwrap());
        child
            .args([TEST, "--exact", "--nocapture", "--test-threads=1"])
            .env("KOE_TEST_CRASH_WORKSPACE", &root.0)
            .env("KOE_TEST_CRASH_VAULT", &vault.path);
        if let Some(key) = key {
            child.env("KOE_TEST_CRASH_KEY", key);
        }
        let status = child.status().unwrap();
        assert_eq!(status.signal(), Some(libc::SIGKILL), "{status:?}");
    };
    // Configured workspace: explicit replacement killed after the item exists.
    crash(&ws_a, Some("new-secret"));
    // Unconfigured workspace: first-launch legacy import killed the same way.
    crash(&ws_c, None);
    let orphaned = vault.items();
    assert!(orphaned.values().any(|v| v == "new-secret"));
    assert_eq!(
        orphaned.values().filter(|v| *v == "legacy-secret").count(),
        1
    );

    for root in [&ws_a, &ws_c] {
        let runtime = KoeRuntime::open_with_credentials(&root.0, Box::new(vault.clone())).unwrap();
        let snapshot = runtime.snapshot(100);
        assert_eq!(snapshot["provider"]["configured"], true, "{snapshot}");
        assert!(snapshot["error"].is_null(), "{snapshot}");
    }
    let ref_c = saved_reference(&ws_c);
    let expected = BTreeMap::from([
        (ref_a.clone(), "old-secret".to_owned()),
        (ref_b, "b-secret".to_owned()),
        (ref_c, "legacy-secret".to_owned()),
    ]);
    assert_eq!(vault.items(), expected);
    assert_eq!(saved_reference(&ws_a), ref_a);
    assert_eq!(
        fs::read(ws_b.0.join("product-workspace.json")).unwrap(),
        workspace_b
    );
    assert_eq!(vault.load()["engines-v1"], json!(legacy));
}
