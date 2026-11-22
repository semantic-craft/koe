#![forbid(unsafe_code)]

mod bridge_client;
mod mcp;
mod protocol;

use bridge_client::BridgeClient;
use koe_engine::product::SearchScope;
use koe_runtime::KoeRuntime;
use mcp::McpBackend;
use serde_json::{json, Value};
use std::{
    env,
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
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
                "--" => {
                    if options.command.is_empty() {
                        if let Some(cmd) = args.next() {
                            options.command = cmd;
                        }
                    }
                    options.words.extend(args.by_ref());
                    break;
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
        Ok(PathBuf::from(home).join(
            "Library/Containers/com.anker.ankerRecorder/Data/Library/Application Support/KoeWorkspace",
        ))
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
                json!({
                    "name": "koe",
                    "version": koe_engine::KOE_APP_VERSION,
                    "build": koe_engine::KOE_APP_BUILD
                })
            );
            return Ok(());
        }
        "verify-protocol" => {
            println!("{}", protocol::verify()?);
            return Ok(());
        }
        "parity" => {
            let vectors = (0..20)
                .map(protocol::run_parity_seed)
                .collect::<Result<Vec<_>, _>>()?;
            println!("[{}]", vectors.join(","));
            return Ok(());
        }
        "benchmark" => {
            protocol::run_benchmark(!options.safe)?;
            return Ok(());
        }
        "status" | "doctor" | "search" | "ask" | "edit-segment" | "set-speaker"
        | "rename-speaker" | "mcp-stdio" => {}
        other => return Err(format!("未知命令：{other}；运行 koe --help 查看用法")),
    }

    let workspace_path = options.path()?;
    if let Some(mut client) = BridgeClient::try_connect(&workspace_path)? {
        let output = match options.command.as_str() {
            "status" => client.status()?,
            "doctor" => client.doctor()?,
            "search" => run_search(
                &options.words.join(" "),
                &options.scope(),
                options.limit,
                |name, args| client.call_tool_value(name, args),
            )?,
            "ask" => run_ask(&options.words.join(" "), &options.scope(), |name, args| {
                client.call_tool_value(name, args)
            })?,
            "edit-segment" => {
                run_edit_segment(options.record.as_deref(), &options.words, |name, args| {
                    client.call_tool_value(name, args)
                })?
            }
            "set-speaker" => {
                run_set_speaker(options.record.as_deref(), &options.words, |name, args| {
                    client.call_tool_value(name, args)
                })?
            }
            "rename-speaker" => {
                run_rename_speaker(options.record.as_deref(), &options.words, |name, args| {
                    client.call_tool_value(name, args)
                })?
            }
            "mcp-stdio" => {
                return mcp::serve(McpBackend::Online {
                    client: &mut client,
                    workspace: &workspace_path,
                });
            }
            _ => unreachable!(),
        };
        println!("{output}");
        return Ok(());
    }

    let mut runtime = KoeRuntime::open(workspace_path)?;
    runtime.poll_timers(0, now());
    let output = match options.command.as_str() {
        "status" => runtime.snapshot(now()),
        "doctor" => runtime.doctor_snapshot(now()),
        "search" => run_search(
            &options.words.join(" "),
            &options.scope(),
            options.limit,
            |name, args| call_offline_value(&mut runtime, name, args),
        )?,
        "ask" => run_ask(&options.words.join(" "), &options.scope(), |name, args| {
            call_offline_value(&mut runtime, name, args)
        })?,
        "edit-segment" => {
            run_edit_segment(options.record.as_deref(), &options.words, |name, args| {
                call_offline_value(&mut runtime, name, args)
            })?
        }
        "set-speaker" => {
            run_set_speaker(options.record.as_deref(), &options.words, |name, args| {
                call_offline_value(&mut runtime, name, args)
            })?
        }
        "rename-speaker" => {
            run_rename_speaker(options.record.as_deref(), &options.words, |name, args| {
                call_offline_value(&mut runtime, name, args)
            })?
        }
        "mcp-stdio" => return mcp::serve(McpBackend::Offline(&mut runtime)),
        _ => unreachable!(),
    };
    println!("{output}");
    Ok(())
}

fn call_offline_value(runtime: &mut KoeRuntime, name: &str, args: Value) -> Result<Value, String> {
    match mcp::call_offline_tool(runtime, name, &args) {
        Ok(result) => result,
        Err(err) => Err(err.message),
    }
}

fn run_search(
    query: &str,
    scope: &SearchScope,
    limit: usize,
    mut exec: impl FnMut(&str, Value) -> Result<Value, String>,
) -> Result<Value, String> {
    if query.trim().is_empty() {
        return Err("请输入搜索内容".into());
    }
    let mut args = json!({
        "query": query,
        "limit": limit,
    });
    if let SearchScope::Record(id) = scope {
        args["record_id"] = json!(id);
    }
    exec("search", args)
}

fn run_ask(
    question: &str,
    scope: &SearchScope,
    mut exec: impl FnMut(&str, Value) -> Result<Value, String>,
) -> Result<Value, String> {
    if question.trim().is_empty() {
        return Err("请输入问题".into());
    }
    let mut args = json!({ "question": question });
    if let SearchScope::Record(id) = scope {
        args["record_id"] = json!(id);
    }
    exec("ask", args)
}

fn run_edit_segment(
    record_id: Option<&str>,
    words: &[String],
    mut exec: impl FnMut(&str, Value) -> Result<Value, String>,
) -> Result<Value, String> {
    let record_id = record_id.ok_or("缺少 --record <ID>")?;
    let segment_id = words.first().ok_or("缺少片段 ID")?;
    if words.len() < 2 {
        return Err("缺少要更新的原文内容".into());
    }
    exec(
        "edit_transcript",
        json!({
            "record_id": record_id,
            "action": "edit_segment",
            "segment_id": segment_id,
            "text": words[1..].join(" "),
        }),
    )?;
    exec("get_record", json!({ "record_id": record_id }))
}

fn run_set_speaker(
    record_id: Option<&str>,
    words: &[String],
    mut exec: impl FnMut(&str, Value) -> Result<Value, String>,
) -> Result<Value, String> {
    let record_id = record_id.ok_or("缺少 --record <ID>")?;
    let segment_id = words.first().ok_or("缺少片段 ID")?;
    let speaker = (words.len() > 1).then(|| words[1..].join(" "));
    exec(
        "edit_transcript",
        json!({
            "record_id": record_id,
            "action": "set_speaker",
            "segment_id": segment_id,
            "speaker": speaker,
        }),
    )?;
    exec("get_record", json!({ "record_id": record_id }))
}

fn run_rename_speaker(
    record_id: Option<&str>,
    words: &[String],
    mut exec: impl FnMut(&str, Value) -> Result<Value, String>,
) -> Result<Value, String> {
    let record_id = record_id.ok_or("缺少 --record <ID>")?;
    if words.len() != 2 {
        return Err("用法：koe rename-speaker --record <ID> \"<原说话人>\" \"<新说话人>\"".into());
    }
    exec(
        "edit_transcript",
        json!({
            "record_id": record_id,
            "action": "rename_speaker",
            "from_speaker": words[0],
            "to_speaker": words[1],
        }),
    )?;
    exec("get_record", json!({ "record_id": record_id }))
}

fn help() {
    println!("Koe {}\n\n用法：koe <命令> [参数]\n\n命令：\n  status                  查看与原生应用同源的工作区快照\n  doctor                  查看工作区、设备与模型状态\n  search <内容>           搜索真实记录及来源\n  ask <问题>              查询记录；未配置模型时返回本地来源\n  edit-segment <片段> <词> 修改指定记录的单段原文（需配合 --record）\n  set-speaker <片段> [人]  设置或清空指定片段说话人（需配合 --record）\n  rename-speaker <原> <新> 批量重命名或合并说话人（需配合 --record）\n  mcp-stdio               提供全部 16 个工作区与设备 MCP 工具\n  verify-protocol         在内存中验证协议与编解码\n  benchmark [--safe]      运行协议和音频封装基准\n  version                 查看版本与构建号（或 --version / -V）\n\n参数：\n  --workspace <目录>      工作区（--export-dir 为兼容别名）\n  --record <ID>           限定 search/ask 或指定要编辑的记录\n  --limit <1..100>        搜索结果数量\n\n默认工作区：~/Library/Containers/com.anker.ankerRecorder/Data/Library/Application Support/KoeWorkspace\nKoe.app 运行时自动经本地桥访问活体会话；未运行时直接打开本地工作区。", koe_engine::KOE_APP_VERSION);
}
