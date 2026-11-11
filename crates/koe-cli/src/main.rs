//! Native-workspace queries and MCP stdio backed by the same Rust runtime as Koe.app.
#![forbid(unsafe_code)]

mod mcp;
mod protocol;

use koe_engine::product::{Evidence, SearchScope};
use koe_runtime::KoeRuntime;
use serde_json::{json, Value};
use std::{
    env,
    path::PathBuf,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

struct Options {
    command: String,
    words: Vec<String>,
    workspace: Option<PathBuf>,
    record: Option<String>,
    limit: usize,
    safe: bool,
}

impl Options {
    fn parse() -> Result<Self, String> {
        let mut args = env::args().skip(1);
        let mut options = Self {
            command: String::new(),
            words: Vec::new(),
            workspace: None,
            record: None,
            limit: 10,
            safe: false,
        };
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--workspace" | "--export-dir" => {
                    options.workspace = Some(PathBuf::from(args.next().ok_or("缺少工作区路径")?))
                }
                "--record" => options.record = Some(args.next().ok_or("缺少记录 ID")?),
                "--limit" => {
                    options.limit = args
                        .next()
                        .ok_or("缺少结果数量")?
                        .parse()
                        .map_err(|_| "结果数量必须是整数")?;
                    if !(1..=100).contains(&options.limit) {
                        return Err("结果数量必须在 1 到 100 之间".into());
                    }
                }
                "--safe" => options.safe = true,
                "-h" | "--help" => options.command = "help".into(),
                "-V" | "--version" => options.command = "version".into(),
                "--mcp-stdio" => options.command = "mcp-stdio".into(),
                "--verify-protocol" => options.command = "verify-protocol".into(),
                "--parity" => options.command = "parity".into(),
                "--bench-soa" => options.command = "benchmark".into(),
                "--bench-safe" => {
                    options.command = "benchmark".into();
                    options.safe = true;
                }
                _ if arg.starts_with('-') => return Err(format!("未知参数：{arg}")),
                _ if options.command.is_empty() => options.command = arg,
                _ => options.words.push(arg),
            }
        }
        Ok(options)
    }

    fn path(&self) -> Result<PathBuf, String> {
        if let Some(path) = &self.workspace {
            return Ok(path.clone());
        }
        let home = env::var_os("HOME")
            .filter(|s| !s.is_empty())
            .ok_or("无法确定用户目录，请传入 --workspace")?;
        Ok(PathBuf::from(home).join("Library/Containers/com.anker.ankerRecorder/Data/Library/Application Support/KoeWorkspace"))
    }

    fn scope(&self) -> SearchScope {
        self.record
            .clone()
            .map_or(SearchScope::All, SearchScope::Record)
    }
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{}", json!({"error":error}));
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let options = Options::parse()?;
    match options.command.as_str() {
        "" | "help" => {
            help();
            return Ok(());
        }
        "version" => {
            println!(
                "{}",
                json!({"name":"koe","version":env!("CARGO_PKG_VERSION")})
            );
            return Ok(());
        }
        "verify-protocol" => {
            println!("{}", protocol::verify()?);
            return Ok(());
        }
        "parity" => {
            println!(
                "[{}]",
                (0..20)
                    .map(protocol::run_parity_seed)
                    .collect::<Vec<_>>()
                    .join(",")
            );
            return Ok(());
        }
        "benchmark" => {
            protocol::run_benchmark(!options.safe);
            return Ok(());
        }
        "status" | "doctor" | "search" | "ask" | "mcp-stdio" => {}
        other => return Err(format!("未知命令：{other}；运行 koe --help 查看用法")),
    }
    let mut runtime = KoeRuntime::open(options.path()?)?;
    runtime.poll_timers(0, now());
    let output = match options.command.as_str() {
        "status" => runtime.snapshot(now()),
        "doctor" => {
            let snapshot = runtime.snapshot(now());
            json!({"workspaceReadable":true,"generation":snapshot["generation"],
                "device":snapshot["device"],"provider":snapshot["provider"],"error":snapshot["error"]})
        }
        "search" => search(
            &runtime,
            &options.words.join(" "),
            &options.scope(),
            options.limit,
        )?,
        "ask" => ask(&mut runtime, &options.words.join(" "), &options.scope())?,
        "mcp-stdio" => return mcp::serve(&mut runtime),
        _ => unreachable!(),
    };
    println!("{output}");
    Ok(())
}

fn search(
    runtime: &KoeRuntime,
    query: &str,
    scope: &SearchScope,
    limit: usize,
) -> Result<Value, String> {
    if query.trim().is_empty() {
        return Err("请输入搜索内容".into());
    }
    let evidence = runtime
        .workspace()
        .search(scope, query, limit)
        .map_err(|e| e.to_string())?;
    Ok(json!({"query":query,"sources":evidence.iter().map(evidence_json).collect::<Vec<_>>()}))
}

fn evidence_json(evidence: &Evidence) -> Value {
    json!({"recordId":evidence.source.record_id,"segmentId":evidence.source.segment_id.to_string(),
        "title":evidence.title,"quote":evidence.quote,"startMs":evidence.start_ms})
}

fn ask(runtime: &mut KoeRuntime, question: &str, scope: &SearchScope) -> Result<Value, String> {
    if question.trim().is_empty() {
        return Err("请输入问题".into());
    }
    let (scope_name, record_id) = match scope {
        SearchScope::All => ("all", None),
        SearchScope::Record(id) => ("record", Some(id)),
    };
    let command = json!({"type":"ask","question":question,"scope":scope_name,"recordId":record_id});
    let mut snapshot: Value =
        serde_json::from_str(&runtime.dispatch_json(&command.to_string(), now()))
            .map_err(|_| "问答返回了无效状态")?;
    let deadline = Instant::now() + Duration::from_secs(190);
    let mut previous = Instant::now();
    while snapshot["ask"]["phase"] == "pending" {
        if Instant::now() >= deadline {
            return Err("问答未在期限内完成".into());
        }
        std::thread::sleep(Duration::from_millis(25));
        let current = Instant::now();
        runtime.poll_timers(current.duration_since(previous).as_millis() as u64, now());
        previous = current;
        snapshot = runtime.snapshot(now());
    }
    if let Some(error) = snapshot["error"].as_str() {
        return Err(error.into());
    }
    if snapshot["ask"]["phase"] == "failed" {
        return Err("问答处理失败，原始记录已保留".into());
    }
    Ok(snapshot["ask"].clone())
}

fn get_record(runtime: &mut KoeRuntime, id: &str) -> Result<Value, String> {
    let command = json!({"type":"select_record","recordId":id});
    let snapshot: Value = serde_json::from_str(&runtime.dispatch_json(&command.to_string(), now()))
        .map_err(|_| "记录返回了无效状态")?;
    if let Some(error) = snapshot["error"].as_str() {
        return Err(error.into());
    }
    if snapshot["detail"].is_null() {
        return Err("记录不存在".into());
    }
    Ok(snapshot["detail"].clone())
}

fn help() {
    println!("Koe {}\n\n用法：koe <命令> [参数]\n\n命令：\n  status                  查看与原生应用同源的工作区快照\n  doctor                  查看工作区、设备与模型状态\n  search <内容>           搜索真实记录及来源\n  ask <问题>              查询记录；未配置模型时返回本地来源\n  mcp-stdio               提供 search/get_record/ask 三个 MCP 工具\n  verify-protocol         在内存中验证协议与编解码\n  benchmark [--safe]      运行协议和音频封装基准\n  version                 查看版本\n\n参数：\n  --workspace <目录>      工作区（--export-dir 为兼容别名）\n  --record <ID>           限定 search/ask 的记录\n  --limit <1..100>        搜索结果数量\n\n默认工作区：~/Library/Containers/com.anker.ankerRecorder/Data/Library/Application Support/KoeWorkspace\n工作区被 Koe.app 或其他进程占用时，命令会明确失败。", env!("CARGO_PKG_VERSION"));
}
