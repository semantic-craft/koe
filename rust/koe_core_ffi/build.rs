use std::env;
use std::fs;
use std::path::{Path, PathBuf};

fn stage_static_archive(archive_path: &Path) -> bool {
    let Ok(out_dir) = env::var("OUT_DIR") else {
        return false;
    };
    let staged = PathBuf::from(&out_dir).join("libopus_bundled.a");
    let _ = fs::remove_file(&staged);
    if fs::copy(archive_path, &staged).is_ok() {
        println!("cargo:rustc-link-search=native={out_dir}");
        println!("cargo:rustc-link-lib=static=opus_bundled");
        return true;
    }
    if let Some(parent) = archive_path.parent() {
        println!("cargo:rustc-link-search=native={}", parent.display());
        println!("cargo:rustc-link-lib=static=opus");
        return true;
    }
    false
}

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=LIBOPUS_LIB_DIR");

    if let Ok(dir) = env::var("LIBOPUS_LIB_DIR") {
        if !dir.is_empty() {
            let archive = Path::new(&dir).join("libopus.a");
            if archive.exists() && stage_static_archive(&archive) {
                return;
            }
            println!("cargo:rustc-link-search=native={dir}");
            println!("cargo:rustc-link-lib=static=opus");
            return;
        }
    }

    for candidate in ["/opt/homebrew/opt/opus/lib", "/usr/local/opt/opus/lib"] {
        let archive = Path::new(candidate).join("libopus.a");
        if archive.exists() && stage_static_archive(&archive) {
            return;
        }
    }

    println!("cargo:rustc-link-lib=opus");
}
