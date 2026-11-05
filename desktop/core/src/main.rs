use std::{
    fs::File,
    io::{self, Write},
    path::Path,
    process::ExitCode,
};

fn run() -> Result<(), String> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() == 2 && args[0] == "inspect" {
        let file = File::open(&args[1]).map_err(|e| format!("cannot open pack: {e}"))?;
        let pack = koe_core::read_pack(file)?;
        let mut out = io::stdout().lock();
        serde_json::to_writer(&mut out, &pack).map_err(|e| format!("cannot write JSON: {e}"))?;
        return writeln!(out).map_err(|e| format!("cannot write JSON: {e}"));
    }
    if args.len() == 3 && args[0] == "mcp" && args[1] == "--live-directory" {
        return koe_core::mcp::serve_live_stdio(Path::new(&args[2])).map_err(|e| e.to_string());
    }
    Err("usage: koe-pack inspect PATH | koe-pack mcp --live-directory PATH".into())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            let _ = writeln!(io::stderr().lock(), "koe-pack: {error}");
            ExitCode::from(1)
        }
    }
}
