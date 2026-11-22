#![allow(clippy::unwrap_used, clippy::expect_used)]

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
        json!({"type":"configure_provider","apiKey":"fixture-secret","deepseekApiKey":"ds-fixture-secret","model":"deepseek-flash"}),
    );
    let response = send(&mut runtime, json!({"type":"clear_provider_credential"}));
    assert!(response["error"].is_null());
    assert_eq!(response["provider"]["qwenConfigured"], false);
    assert_eq!(response["provider"]["asrConfigured"], false);
    assert_eq!(response["provider"]["deepseekConfigured"], true);
    assert_eq!(response["provider"]["configured"], true);
    let ds_cleared = send(
        &mut runtime,
        json!({"type":"clear_provider_credential","provider":"deepseek"}),
    );
    assert!(ds_cleared["error"].is_null());
    assert_eq!(ds_cleared["provider"]["deepseekConfigured"], false);
    assert_eq!(ds_cleared["provider"]["configured"], false);
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
    assert_eq!(snapshot["provider"]["qwenConfigured"], true);
    assert_eq!(snapshot["provider"]["asrConfigured"], true);
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
    assert_eq!(runtime.snapshot(100)["provider"]["qwenConfigured"], true);
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
    assert_eq!(runtime.snapshot(100)["provider"]["qwenConfigured"], true);
    assert_eq!(runtime.snapshot(100)["provider"]["asrConfigured"], true);
    adapter.0.lock().unwrap().fail_delete = true;
    let response = send(&mut runtime, json!({"type":"clear_provider_credential"}));
    assert_eq!(response["provider"]["qwenConfigured"], false);
    assert!(!response["error"].is_null());
    drop(runtime);
    adapter.0.lock().unwrap().fail_delete = false;
    let runtime = open(&root, &adapter);
    assert_eq!(runtime.snapshot(100)["provider"]["qwenConfigured"], false);
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
    assert_eq!(response["provider"]["qwenConfigured"], true);
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
    assert_eq!(runtime.snapshot(100)["provider"]["qwenConfigured"], true);
}
#[test]
fn readback_mismatch_does_not_publish_or_keep_new_secret() {
    let root = Sandbox::new();
    let adapter = Adapter::default();
    let mut runtime = open(&root, &adapter);
    adapter.0.lock().unwrap().mismatch = true;
    assert!(!configure(&mut runtime, "new-fixture")["error"].is_null());
    assert_eq!(runtime.snapshot(100)["provider"]["qwenConfigured"], false);
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
    assert_eq!(runtime.snapshot(100)["provider"]["qwenConfigured"], false);
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
        "https://api.deepseek.com/chat/completions"
    );
    assert_eq!(response["provider"]["llmProvider"], "deepseek");
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
    assert_eq!(response["provider"]["qwenConfigured"], true);
    drop(runtime);
    adapter.0.lock().unwrap().fail_delete = false;
    let runtime = open(&root, &adapter);
    assert_eq!(runtime.snapshot(100)["provider"]["qwenConfigured"], true);
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
    assert!(!isolated.snapshot(100)["provider"]["qwenConfigured"]
        .as_bool()
        .unwrap());
    drop(isolated);
    adapter.0.lock().unwrap().fail_delete = false;
    let runtime = open(&root, &adapter);
    assert_eq!(runtime.snapshot(100)["provider"]["qwenConfigured"], true);
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
    assert_eq!(response["provider"]["qwenConfigured"], true);
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
    assert_eq!(runtime.snapshot(100)["provider"]["qwenConfigured"], true);
    let response = send(
        &mut runtime,
        json!({"type":"retry_provider_credentials","authorize":true}),
    );
    assert!(response["error"].is_null());
    assert_eq!(response["provider"]["qwenConfigured"], true);
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
    crash(&ws_a, Some("new-secret"));
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
        assert_eq!(snapshot["provider"]["qwenConfigured"], true, "{snapshot}");
        assert_eq!(snapshot["provider"]["asrConfigured"], true, "{snapshot}");
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

#[test]
fn dual_provider_credentials_and_hybrid_qwen_deepseek_config_persist_independently() {
    let root = Sandbox::new();
    let vault = Adapter::default();
    let mut runtime = KoeRuntime::open_with_credentials(&root.0, Box::new(vault.clone())).unwrap();

    let initial = runtime.snapshot(100);
    assert_eq!(initial["provider"]["model"], "deepseek-flash");
    assert_eq!(initial["provider"]["asrModel"], "qwen-audio-3.1-asr-flash-streaming");
    assert_eq!(initial["provider"]["asrProvider"], "qwen");
    assert_eq!(initial["provider"]["llmProvider"], "deepseek");
    assert_eq!(initial["provider"]["chatEndpoint"], "https://api.deepseek.com/chat/completions");
    assert_eq!(initial["provider"]["enableThinking"], false);
    assert_eq!(initial["provider"]["asrIsRealtime"], true);

    let saved = send(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "apiKey": "qwen-secret-key",
            "deepseekApiKey": "deepseek-secret-key",
            "asrProvider": "qwen",
            "asrModel": "qwen-audio-3.1-asr-flash-streaming",
            "llmProvider": "deepseek",
            "model": "deepseek-flash",
            "enableThinking": true,
            "qwenWorkspaceId": "ws-bj-123"
        }),
    );
    assert!(saved["error"].is_null(), "{saved}");
    assert_eq!(saved["provider"]["qwenConfigured"], true);
    assert_eq!(saved["provider"]["deepseekConfigured"], true);
    assert_eq!(saved["provider"]["asrConfigured"], true);
    assert_eq!(saved["provider"]["configured"], true);
    assert_eq!(saved["provider"]["asrEndpoint"], "wss://ws-bj-123.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference");
    assert_eq!(saved["provider"]["chatEndpoint"], "https://api.deepseek.com/chat/completions");
    assert_eq!(saved["provider"]["enableThinking"], true);
    assert_eq!(saved["provider"]["qwenWorkspaceId"], "ws-bj-123");
    drop(runtime);

    let mut reopened = KoeRuntime::open_with_credentials(&root.0, Box::new(vault.clone())).unwrap();
    let snap = reopened.snapshot(101);
    assert_eq!(snap["provider"]["qwenConfigured"], true);
    assert_eq!(snap["provider"]["deepseekConfigured"], true);
    assert_eq!(snap["provider"]["llmProvider"], "deepseek");
    assert_eq!(snap["provider"]["model"], "deepseek-flash");
    assert_eq!(snap["provider"]["enableThinking"], true);

    let cleared_ds = send(
        &mut reopened,
        json!({"type": "clear_provider_credential", "provider": "deepseek"}),
    );
    assert!(cleared_ds["error"].is_null(), "{cleared_ds}");
    assert_eq!(cleared_ds["provider"]["qwenConfigured"], true);
    assert_eq!(cleared_ds["provider"]["deepseekConfigured"], false);
    assert_eq!(cleared_ds["provider"]["deepseekCredentialState"], "cleared");
    assert_eq!(cleared_ds["provider"]["asrConfigured"], true);
    assert_eq!(cleared_ds["provider"]["configured"], false);

    let ft_snap = send(
        &mut reopened,
        json!({
            "type": "configure_provider",
            "deepseekApiKey": "deepseek-secret-key-2",
            "asrProvider": "qwen",
            "asrModel": "qwen-audio-3.1-asr-flash-filetrans",
            "llmProvider": "deepseek",
            "model": "deepseek-v4-pro",
            "qwenWorkspaceId": "ws-bj-123"
        }),
    );
    assert!(ft_snap["error"].is_null(), "{ft_snap}");
    assert_eq!(ft_snap["provider"]["asrIsRealtime"], false);
    assert_eq!(
        ft_snap["provider"]["asrEndpoint"],
        "https://ws-bj-123.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/asr/transcription"
    );
    assert_eq!(
        ft_snap["provider"]["chatEndpoint"],
        "https://api.deepseek.com/chat/completions"
    );
    assert_eq!(ft_snap["provider"]["model"], "deepseek-v4-pro");
    assert_eq!(ft_snap["provider"]["configured"], true);
}

#[test]
fn non_realtime_deepseek_asr_defers_live_capture_and_transcribes_saved_audio() {
    use std::io::{Read, Write};
    use std::time::{Duration, Instant};

    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = format!("http://{}/v1/tools/asr", listener.local_addr().unwrap());
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut raw = Vec::new();
        let mut buf = [0u8; 4096];
        let header_end = loop {
            let n = stream.read(&mut buf).unwrap();
            assert!(n > 0);
            raw.extend_from_slice(&buf[..n]);
            if let Some(pos) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
                break pos + 4;
            }
        };
        let head = String::from_utf8_lossy(&raw[..header_end]);
        let cl = head
            .lines()
            .find_map(|l| {
                let (k, v) = l.split_once(':')?;
                k.eq_ignore_ascii_case("content-length")
                    .then(|| v.trim().parse::<usize>().ok())
                    .flatten()
            })
            .unwrap_or(0);
        while raw.len() < header_end + cl {
            let n = stream.read(&mut buf).unwrap();
            assert!(n > 0);
            raw.extend_from_slice(&buf[..n]);
        }
        let body = json!({"text": "DeepSeek 静音切段转写结果"}).to_string();
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        )
        .unwrap();
    });

    let root = Sandbox::new();
    let mut runtime = KoeRuntime::open(&root.0).unwrap();
    send(&mut runtime, json!({"type": "set_meeting_audio_policy", "policy": "cloud_allowed"}));
    send(&mut runtime, json!({"type": "configure_speech", "engine": "cloud"}));
    let cfg = send(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "deepseekApiKey": "ds-live-test",
            "asrProvider": "deepseek",
            "asrEndpoint": endpoint,
            "llmProvider": "deepseek",
            "model": "deepseek-flash"
        }),
    );
    assert!(cfg["error"].is_null(), "{cfg}");
    assert_eq!(cfg["provider"]["asrIsRealtime"], false);

    let started = send(&mut runtime, json!({"type": "start_microphone", "inputId": ""}));
    assert!(started["error"].is_null(), "{started}");
    let rec_id = started["microphone"]["recordId"].as_str().unwrap().to_owned();
    let sess_id = started["microphone"]["sessionId"].as_str().unwrap().to_owned();
    send(
        &mut runtime,
        json!({"type": "microphone_started", "recordId": rec_id, "sessionId": sess_id, "lane": "microphone", "sampleRate": 16000}),
    );
    let samples = vec![1000i16; 8000];
    let r1 = runtime.ingest_microphone_pcm(koe_runtime::MicrophonePcmChunk {
        record_id: &rec_id,
        session_id: &sess_id,
        lane: "microphone",
        sequence: 0,
        samples: &samples,
        timing: None,
        now: 100,
    });
    assert_eq!(r1.status, koe_runtime::PcmIngestStatus::Accepted);
    let cap_snap = runtime.snapshot(100);
    assert!(cap_snap["liveCaption"]["status"].as_str().unwrap().contains("非实时"));
    send(&mut runtime, json!({"type": "stop_microphone"}));
    send(
        &mut runtime,
        json!({"type": "microphone_stopped", "recordId": rec_id, "sessionId": sess_id, "lane": "microphone", "sequence": 1}),
    );

    let deadline = Instant::now() + Duration::from_secs(5);
    let mut transcribed = false;
    while Instant::now() < deadline {
        runtime.poll_timers(50, 105);
        if runtime
            .workspace()
            .record(&rec_id)
            .is_some_and(|r| r.aggregate.spine.segments().iter().any(|s| s.text == "DeepSeek 静音切段转写结果"))
        {
            transcribed = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(transcribed, "deferred DeepSeek ASR must transcribe saved audio after capture ends");
    server.join().unwrap();
}

#[test]
fn dual_key_retry_authorizes_both_slots_and_custom_provider_validation_is_strict() {
    let root = Sandbox::new();
    let vault = Adapter::default();
    let mut runtime = KoeRuntime::open_with_credentials(&root.0, Box::new(vault.clone())).unwrap();

    let saved = send(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "apiKey": "qwen-secret",
            "deepseekApiKey": "deepseek-secret",
            "asrProvider": "deepseek",
            "asrModel": "",
            "llmProvider": "deepseek",
            "model": "deepseek-flash"
        }),
    );
    assert!(saved["error"].is_null(), "{saved}");

    let back_to_qwen = send(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "asrProvider": "qwen",
            "asrModel": "",
            "llmProvider": "deepseek",
            "model": "deepseek-v4-pro"
        }),
    );
    assert!(back_to_qwen["error"].is_null(), "{back_to_qwen}");
    assert_eq!(
        back_to_qwen["provider"]["asrModel"],
        "qwen-audio-3.1-asr-flash-streaming"
    );

    let bad_custom = send(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "llmProvider": "custom",
            "model": "ollama-qwen",
            "chatEndpoint": ""
        }),
    );
    assert!(
        bad_custom["error"]
            .as_str()
            .is_some_and(|e| e.contains("对话接口地址")),
        "{bad_custom}"
    );

    let custom_path_trick = send(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "model": "custom-model",
            "chatEndpoint": "https://proxy.example.com/api.deepseek.com/chat/completions"
        }),
    );
    assert!(custom_path_trick["error"].is_null(), "{custom_path_trick}");
    assert_eq!(custom_path_trick["provider"]["llmProvider"], "custom");
    drop(runtime);

    vault.0.lock().unwrap().fail_read = true;
    let mut locked = KoeRuntime::open_with_credentials(&root.0, Box::new(vault.clone())).unwrap();
    let locked_snap = locked.snapshot(101);
    assert_eq!(locked_snap["provider"]["credentialState"], "unavailable");
    assert_eq!(
        locked_snap["provider"]["deepseekCredentialState"],
        "unavailable"
    );

    vault.0.lock().unwrap().fail_read = false;
    let retried = send(
        &mut locked,
        json!({"type": "retry_provider_credentials", "authorize": true}),
    );
    assert!(retried["error"].is_null(), "{retried}");
    assert_eq!(retried["provider"]["qwenConfigured"], true);
    assert_eq!(retried["provider"]["deepseekConfigured"], true);
    let authorized = vault.0.lock().unwrap().authorized.clone();
    assert_eq!(
        authorized.len(),
        2,
        "expected both Qwen and DeepSeek references to be authorized in one retry, got: {authorized:?}"
    );
}

#[test]
fn deepseek_only_queued_work_holds_keep_awake() {
    let root = Sandbox::new();
    let mut runtime = KoeRuntime::open(&root.0).unwrap();
    send(
        &mut runtime,
        json!({"type": "set_meeting_audio_policy", "policy": "cloud_allowed"}),
    );
    send(&mut runtime, json!({"type": "configure_speech", "engine": "cloud"}));
    let cfg = send(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "deepseekApiKey": "ds-only-key",
            "asrProvider": "deepseek",
            "asrEndpoint": "https://api.deepseek.com/v1/tools/asr",
            "llmProvider": "deepseek",
            "model": "deepseek-flash"
        }),
    );
    assert!(cfg["error"].is_null(), "{cfg}");
    assert_eq!(cfg["provider"]["qwenConfigured"], false);
    assert_eq!(cfg["provider"]["deepseekConfigured"], true);

    let started = send(&mut runtime, json!({"type": "start_microphone", "inputId": ""}));
    let rec_id = started["microphone"]["recordId"].as_str().unwrap().to_owned();
    let sess_id = started["microphone"]["sessionId"].as_str().unwrap().to_owned();
    send(
        &mut runtime,
        json!({"type": "microphone_started", "recordId": rec_id, "sessionId": sess_id, "lane": "microphone", "sampleRate": 16000}),
    );
    let _ = runtime.ingest_microphone_pcm(koe_runtime::MicrophonePcmChunk {
        record_id: &rec_id,
        session_id: &sess_id,
        lane: "microphone",
        sequence: 0,
        samples: &[800i16; 4000],
        timing: None,
        now: 100,
    });
    send(&mut runtime, json!({"type": "stop_microphone"}));
    let after_stop = send(
        &mut runtime,
        json!({"type": "microphone_stopped", "recordId": rec_id, "sessionId": sess_id, "lane": "microphone", "sequence": 1}),
    );
    assert_eq!(
        after_stop["lifecycle"]["keepAwake"], true,
        "DeepSeek-only queued auto_transcribe must hold keepAwake: {after_stop}"
    );
}

#[test]
fn legacy_qwen_llm_workspace_migrates_to_deepseek_flash_while_preserving_qwen_asr() {
    let root = Sandbox::new();
    let vault = Adapter::default();
    let mut initial = open(&root, &vault);
    let _ = send(
        &mut initial,
        json!({
            "type": "configure_provider",
            "apiKey": "qwen-asr-key",
            "deepseekApiKey": "deepseek-llm-key",
            "asrProvider": "qwen",
            "asrModel": "qwen-audio-3.1-asr-flash-message",
            "qwenWorkspaceId": "ws-bj-legacy",
            "llmProvider": "deepseek",
            "model": "deepseek-flash"
        }),
    );
    drop(initial);

    let path = root.0.join("product-workspace.json");
    let mut disk: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    disk["provider"]["llm_provider"] = json!("qwen");
    disk["provider"]["model"] = json!("qwen3.8-flash");
    disk["provider"]["chat_endpoint"] =
        json!("https://ws-bj-legacy.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions");
    fs::write(&path, serde_json::to_string(&disk).unwrap()).unwrap();

    let reopened = open(&root, &vault);
    let snap = reopened.snapshot(200);
    assert_eq!(snap["provider"]["llmProvider"], "deepseek");
    assert_eq!(snap["provider"]["model"], "deepseek-flash");
    assert_eq!(
        snap["provider"]["chatEndpoint"],
        "https://api.deepseek.com/chat/completions"
    );
    assert_eq!(snap["provider"]["asrProvider"], "qwen");
    assert_eq!(
        snap["provider"]["asrModel"],
        "qwen-audio-3.1-asr-flash-message"
    );
    assert_eq!(
        snap["provider"]["asrEndpoint"],
        "wss://ws-bj-legacy.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference"
    );
    assert_eq!(snap["provider"]["qwenConfigured"], true);
    assert_eq!(snap["provider"]["deepseekConfigured"], true);
    assert_eq!(snap["provider"]["asrConfigured"], true);
    assert_eq!(snap["provider"]["configured"], true);
    drop(reopened);

    disk["provider"]
        .as_object_mut()
        .unwrap()
        .remove("llm_provider");
    disk["provider"]["model"] = json!("qwen-plus");
    disk["provider"]["chat_endpoint"] =
        json!("https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions");
    fs::write(&path, serde_json::to_string(&disk).unwrap()).unwrap();

    let pre_v25 = open(&root, &vault);
    let snap2 = pre_v25.snapshot(201);
    assert_eq!(snap2["provider"]["llmProvider"], "deepseek");
    assert_eq!(snap2["provider"]["model"], "deepseek-flash");
    assert_eq!(
        snap2["provider"]["chatEndpoint"],
        "https://api.deepseek.com/chat/completions"
    );
    assert_eq!(snap2["provider"]["asrProvider"], "qwen");
    drop(pre_v25);

    disk["provider"]["llm_provider"] = json!("   ");
    disk["provider"]["model"] = json!("qwen-plus");
    disk["provider"]["chat_endpoint"] =
        json!("https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions");
    fs::write(&path, serde_json::to_string(&disk).unwrap()).unwrap();

    let blank_provider = open(&root, &vault);
    let snap3 = blank_provider.snapshot(202);
    assert_eq!(snap3["provider"]["llmProvider"], "deepseek");
    assert_eq!(snap3["provider"]["model"], "deepseek-flash");
    assert_eq!(
        snap3["provider"]["chatEndpoint"],
        "https://api.deepseek.com/chat/completions"
    );
    assert_eq!(snap3["provider"]["asrProvider"], "qwen");
}

#[test]
fn qwen_llm_is_rejected_and_qwen_workspace_id_only_affects_asr_endpoint() {
    let root = Sandbox::new();
    let vault = Adapter::default();
    let mut runtime = open(&root, &vault);

    let rejected = send(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "llmProvider": "qwen",
            "model": "qwen3.8-flash"
        }),
    );
    assert!(
        rejected["error"].as_str().is_some(),
        "Qwen LLM must be rejected now that Qwen is ASR-only: {rejected}"
    );

    let updated = send(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "apiKey": "qwen-asr-key",
            "deepseekApiKey": "ds-llm-key",
            "asrProvider": "qwen",
            "asrModel": "qwen-audio-3.1-asr-flash-streaming",
            "qwenWorkspaceId": "ws-asr-only",
            "llmProvider": "deepseek",
            "model": "deepseek-flash"
        }),
    );
    assert!(updated["error"].is_null(), "{updated}");
    assert_eq!(
        updated["provider"]["asrEndpoint"],
        "wss://ws-asr-only.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference"
    );
    assert_eq!(
        updated["provider"]["chatEndpoint"],
        "https://api.deepseek.com/chat/completions"
    );

    let ds_custom_asr = send(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "asrProvider": "deepseek",
            "asrEndpoint": "http://127.0.0.1:19000/v1/tools/asr",
            "llmProvider": "deepseek",
            "model": "deepseek-flash"
        }),
    );
    assert!(ds_custom_asr["error"].is_null(), "{ds_custom_asr}");
    let ws_update = send(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "qwenWorkspaceId": "ws-bj-only",
            "model": "deepseek-flash"
        }),
    );
    assert!(ws_update["error"].is_null(), "{ws_update}");
    assert_eq!(ws_update["provider"]["asrProvider"], "deepseek");
    assert_eq!(
        ws_update["provider"]["asrEndpoint"],
        "http://127.0.0.1:19000/v1/tools/asr"
    );
}

#[test]
fn hybrid_qwen_asr_and_deepseek_flash_llm_route_distinct_keys_and_thinking_wire_format() {
    use std::io::{Read, Write};
    use std::time::{Duration, Instant};

    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let chat_endpoint = format!("http://{}/chat/completions", listener.local_addr().unwrap());
    let server = std::thread::spawn(move || {
        let mut observed = Vec::new();
        for _ in 0..2 {
            let (mut stream, _) = listener.accept().unwrap();
            let mut raw = Vec::new();
            let mut buf = [0u8; 4096];
            let header_end = loop {
                let n = stream.read(&mut buf).unwrap();
                assert!(n > 0);
                raw.extend_from_slice(&buf[..n]);
                if let Some(pos) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
                    break pos + 4;
                }
            };
            let head = String::from_utf8_lossy(&raw[..header_end]).into_owned();
            let auth = head
                .lines()
                .find_map(|line| {
                    let (k, v) = line.split_once(':')?;
                    k.eq_ignore_ascii_case("authorization")
                        .then(|| v.trim().to_owned())
                })
                .unwrap_or_default();
            let cl = head
                .lines()
                .find_map(|line| {
                    let (k, v) = line.split_once(':')?;
                    k.eq_ignore_ascii_case("content-length")
                        .then(|| v.trim().parse::<usize>().ok())
                        .flatten()
                })
                .unwrap_or(0);
            while raw.len() < header_end + cl {
                let n = stream.read(&mut buf).unwrap();
                assert!(n > 0);
                raw.extend_from_slice(&buf[..n]);
            }
            let payload: Value =
                serde_json::from_slice(&raw[header_end..header_end + cl]).unwrap();
            observed.push((auth, payload));
            let body = json!({
                "choices": [{
                    "finish_reason": "stop",
                    "message": { "content": "DeepSeek 回答 [S1]" }
                }]
            })
            .to_string();
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            )
            .unwrap();
        }
        observed
    });

    let root = Sandbox::new();
    let mut runtime = KoeRuntime::open(&root.0).unwrap();
    let note = send(
        &mut runtime,
        json!({"type": "create_note", "title": "Hybrid", "text": "下周发布 DeepSeek 4.1 Flash 默认文本模型。"}),
    );
    let record_id = note["selectedRecordId"].as_str().unwrap().to_owned();

    let cfg = send(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "apiKey": "qwen-asr-only-key",
            "deepseekApiKey": "deepseek-llm-only-key",
            "asrProvider": "qwen",
            "llmProvider": "deepseek",
            "model": "deepseek-flash",
            "enableThinking": false,
            "chatEndpoint": chat_endpoint
        }),
    );
    assert!(cfg["error"].is_null(), "{cfg}");
    assert_eq!(cfg["provider"]["llmProvider"], "deepseek");
    assert_eq!(cfg["provider"]["model"], "deepseek-flash");

    let ask1 = send(
        &mut runtime,
        json!({"type": "ask", "question": "下周发布什么", "scope": "record", "recordId": record_id}),
    );
    assert!(ask1["error"].is_null(), "{ask1}");
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        runtime.poll_timers(50, 200);
        if runtime.snapshot(200)["ask"]["phase"] == "ready" {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(runtime.snapshot(200)["ask"]["phase"], "ready");

    let cfg2 = send(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "llmProvider": "deepseek",
            "model": "deepseek-v4-pro",
            "enableThinking": true,
            "chatEndpoint": chat_endpoint
        }),
    );
    assert!(cfg2["error"].is_null(), "{cfg2}");
    let ask2 = send(
        &mut runtime,
        json!({"type": "ask", "question": "再确认下周发布计划", "scope": "record", "recordId": record_id}),
    );
    assert!(ask2["error"].is_null(), "{ask2}");
    let deadline2 = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline2 {
        runtime.poll_timers(50, 205);
        if runtime.snapshot(205)["ask"]["phase"] == "ready" {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(runtime.snapshot(205)["ask"]["phase"], "ready");

    let observed = server.join().unwrap();
    assert_eq!(observed.len(), 2);
    assert_eq!(observed[0].0, "Bearer deepseek-llm-only-key");
    assert_eq!(observed[0].1["model"], "deepseek-flash");
    assert_eq!(observed[0].1["thinking"]["type"], "disabled");
    assert!(observed[0].1.get("enable_thinking").is_none());

    assert_eq!(observed[1].0, "Bearer deepseek-llm-only-key");
    assert_eq!(observed[1].1["model"], "deepseek-v4-pro");
    assert_eq!(observed[1].1["thinking"]["type"], "enabled");
    assert!(observed[1].1.get("enable_thinking").is_none());
}
