use koe_client_services::capture_asset::CaptureAsset;
use std::{fs, path::PathBuf, process::Command};
struct Sandbox(PathBuf);
impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[cfg(unix)]
#[test]
fn failed_first_write_can_be_cancelled_and_restarted() {
    if let Ok(root) = std::env::var("KOE_CAPTURE_LIMIT_CHILD") {
        let mut asset = CaptureAsset::create(std::path::Path::new(&root), "mic-limit", 16000)
            .expect("reserving a stream must not strand a partial header on write failure");
        assert!(asset.append(&[1; 32]).is_err());
        asset.discard().unwrap();
        return;
    }
    let root =
        Sandbox(std::env::temp_dir().join(format!("koe-capture-limit-{}", std::process::id())));
    fs::create_dir_all(&root.0).unwrap();
    let script="import os,resource,signal,sys\nsignal.signal(signal.SIGXFSZ,signal.SIG_IGN)\nresource.setrlimit(resource.RLIMIT_FSIZE,(16,resource.getrlimit(resource.RLIMIT_FSIZE)[1]))\nos.execv(sys.argv[1],[sys.argv[1],'--exact','failed_first_write_can_be_cancelled_and_restarted','--nocapture'])";
    let result = Command::new("python3")
        .arg("-c")
        .arg(script)
        .arg(std::env::current_exe().unwrap())
        .env("KOE_CAPTURE_LIMIT_CHILD", &root.0)
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
    let mut asset = CaptureAsset::create(&root.0, "mic-limit", 16000).unwrap();
    asset.append(&[7; 160]).unwrap();
    asset.publish().unwrap();
    let bytes = fs::read(root.0.join("audio/mic-limit.wav")).unwrap();
    assert_eq!(bytes.len(), 364);
}
