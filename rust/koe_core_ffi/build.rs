use std::env;
use std::path::Path;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=LIBOPUS_LIB_DIR");

    if let Ok(dir) = env::var("LIBOPUS_LIB_DIR") {
        if !dir.is_empty() {
            println!("cargo:rustc-link-search=native={dir}");
            println!("cargo:rustc-link-lib=static=opus");
            return;
        }
    }

    for candidate in ["/opt/homebrew/opt/opus/lib", "/usr/local/opt/opus/lib"] {
        if Path::new(candidate).join("libopus.a").exists() {
            println!("cargo:rustc-link-search=native={candidate}");
            println!("cargo:rustc-link-lib=static=opus");
            return;
        }
    }

    println!("cargo:rustc-link-lib=opus");
}
