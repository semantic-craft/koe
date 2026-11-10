use std::env;

fn main() {
    for name in [
        "LIBOPUS_NO_PKG",
        "LIBOPUS_LIB_DIR",
        "OPUS_LIB_DIR",
        "MACOSX_DEPLOYMENT_TARGET",
    ] {
        println!("cargo:rerun-if-env-changed={name}");
    }
    assert!(
        env::var_os("LIBOPUS_NO_PKG").is_some(),
        "Koe requires bundled libopus; build from the repository root so .cargo/config.toml is loaded"
    );
    for name in ["LIBOPUS_LIB_DIR", "OPUS_LIB_DIR"] {
        assert!(
            env::var_os(name).is_none(),
            "Koe requires bundled libopus; unset {name} to avoid linking an external archive"
        );
    }
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        assert_eq!(
            env::var("MACOSX_DEPLOYMENT_TARGET").as_deref(),
            Ok("14.0"),
            "Rust and C objects must target macOS 14.0, matching the native host"
        );
    }
}
