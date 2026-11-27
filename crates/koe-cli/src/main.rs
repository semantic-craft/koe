#![forbid(unsafe_code)]

mod bridge_client;
mod mcp;
mod protocol;

use bridge_client::{BridgeClient, BridgeOnlyClient, BRIDGE_OFFLINE_ERROR_MESSAGE};
use koe_client_base::atomic_fs::write_atomic_private;
use koe_engine::product::SearchScope;
use koe_runtime::{DiagnosticsBundle, KoeRuntime};
use mcp::McpBackend;
use serde_json::{json, Value};
use std::{
    env,
    fs::{self, File},
    io::Read,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

const MAX_REPLAY_BUNDLE_BYTES: u64 = 16 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum BridgeConnectionPolicy {
    AutoFallback,
    BridgeOnly,
}

enum WorkspaceBackend<'a> {
    Offline(&'a mut KoeRuntime),
    Online {
        client: &'a mut BridgeClient,
        workspace: &'a Path,
    },
}

enum DoctorMode {
    Snapshot,
    Bundle(Option<PathBuf>),
    Replay(PathBuf),
}

struct Options {
    command: String,
    words: Vec<String>,
    workspace: Option<PathBuf>,
    record: Option<String>,
    limit: usize,
    safe: bool,
    bridge_policy: BridgeConnectionPolicy,
    doctor_mode: DoctorMode,
}

impl Options {
    fn parse() -> Result<Self, String> {
        Self::parse_from(env::args().skip(1))
    }

    fn parse_from<I, S>(iter: I) -> Result<Self, String>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let mut args = iter.into_iter().map(Into::into).peekable();
        let mut options = Self {
            command: String::new(),
            words: Vec::new(),
            workspace: None,
            record: None,
            limit: 10,
            safe: false,
            bridge_policy: BridgeConnectionPolicy::AutoFallback,
            doctor_mode: DoctorMode::Snapshot,
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
                "--bundle" => {
                    if !matches!(options.doctor_mode, DoctorMode::Snapshot) {
                        return Err("--bundle 与 --replay 不能同时使用".into());
                    }
                    let path = if !options.command.is_empty()
                        && args.peek().is_some_and(|next| !next.starts_with('-'))
                    {
                        args.next().map(PathBuf::from)
                    } else {
                        None
                    };
                    options.doctor_mode = DoctorMode::Bundle(path);
                }
                "--replay" => {
                    if !matches!(options.doctor_mode, DoctorMode::Snapshot) {
                        return Err("--bundle 与 --replay 不能同时使用".into());
                    }
                    let path = PathBuf::from(args.next().ok_or("缺少诊断包文件路径")?);
                    options.doctor_mode = DoctorMode::Replay(path);
                }
                "--bridge-only" => options.bridge_policy = BridgeConnectionPolicy::BridgeOnly,
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
    run_with_options(options)
}

fn run_with_options(options: Options) -> Result<(), String> {
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

    if options.command != "doctor" && !matches!(options.doctor_mode, DoctorMode::Snapshot) {
        return Err("--bundle 和 --replay 仅支持用于 doctor 命令".into());
    }
    if let DoctorMode::Replay(bundle_path) = &options.doctor_mode {
        let report = run_doctor_replay(bundle_path)?;
        println!("{report}");
        return Ok(());
    }

    let workspace_path = options.path()?;
    if options.bridge_policy == BridgeConnectionPolicy::BridgeOnly
        && options.command == "mcp-stdio"
    {
        return mcp::serve(McpBackend::BridgeOnly(BridgeOnlyClient::new(
            workspace_path,
        )));
    }
    if let Some(mut client) = BridgeClient::try_connect(&workspace_path)? {
        return dispatch_workspace_command(
            &options,
            WorkspaceBackend::Online {
                client: &mut client,
                workspace: &workspace_path,
            },
        );
    }
    if options.bridge_policy == BridgeConnectionPolicy::BridgeOnly {
        return Err(BRIDGE_OFFLINE_ERROR_MESSAGE.into());
    }

    let mut runtime = KoeRuntime::open(workspace_path)?;
    runtime.poll_timers(0, now());
    dispatch_workspace_command(&options, WorkspaceBackend::Offline(&mut runtime))
}

fn call_backend_tool(
    backend: &mut WorkspaceBackend<'_>,
    name: &str,
    args: Value,
) -> Result<Value, String> {
    match backend {
        WorkspaceBackend::Online { client, .. } => client.call_tool_value(name, args),
        WorkspaceBackend::Offline(runtime) => match mcp::call_offline_tool(runtime, name, &args) {
            Ok(result) => result,
            Err(err) => Err(err.message),
        },
    }
}

fn dispatch_workspace_command(
    options: &Options,
    mut backend: WorkspaceBackend<'_>,
) -> Result<(), String> {
    let output = match options.command.as_str() {
        "status" => match &mut backend {
            WorkspaceBackend::Online { client, .. } => client.status()?,
            WorkspaceBackend::Offline(runtime) => runtime.snapshot(now()),
        },
        "doctor" => match &options.doctor_mode {
            DoctorMode::Snapshot => match &mut backend {
                WorkspaceBackend::Online { client, .. } => client.doctor()?,
                WorkspaceBackend::Offline(runtime) => runtime.doctor_snapshot(now()),
            },
            DoctorMode::Bundle(target_path) => {
                let bundle = match &mut backend {
                    WorkspaceBackend::Online { client, .. } => client.diagnostics()?,
                    WorkspaceBackend::Offline(runtime) => {
                        serde_json::to_value(runtime.export_diagnostics_bundle(now()))
                            .map_err(|e| format!("序列化诊断包失败：{e}"))?
                    }
                };
                if let Some(path) = target_path {
                    let serialized = serde_json::to_string_pretty(&bundle)
                        .map_err(|e| format!("格式化诊断包失败：{e}"))?;
                    write_atomic_private(path, serialized.as_bytes())
                        .map_err(|e| format!("写入诊断包失败：{e}"))?;
                    json!({
                        "written": true,
                        "path": path.to_string_lossy(),
                        "bundleVersion": bundle["bundleVersion"],
                        "entries": bundle["flightRecorder"]["entries"].as_array().map_or(0, Vec::len),
                    })
                } else {
                    bundle
                }
            }
            DoctorMode::Replay(bundle_path) => run_doctor_replay(bundle_path)?,
        },
        "search" => run_search(
            &options.words.join(" "),
            &options.scope(),
            options.limit,
            |name, args| call_backend_tool(&mut backend, name, args),
        )?,
        "ask" => run_ask(&options.words.join(" "), &options.scope(), |name, args| {
            call_backend_tool(&mut backend, name, args)
        })?,
        "edit-segment" => {
            run_edit_segment(options.record.as_deref(), &options.words, |name, args| {
                call_backend_tool(&mut backend, name, args)
            })?
        }
        "set-speaker" => {
            run_set_speaker(options.record.as_deref(), &options.words, |name, args| {
                call_backend_tool(&mut backend, name, args)
            })?
        }
        "rename-speaker" => {
            run_rename_speaker(options.record.as_deref(), &options.words, |name, args| {
                call_backend_tool(&mut backend, name, args)
            })?
        }
        "mcp-stdio" => {
            let mcp_backend = match backend {
                WorkspaceBackend::Offline(runtime) => McpBackend::Offline(runtime),
                WorkspaceBackend::Online { client, workspace } => {
                    McpBackend::Online { client, workspace }
                }
            };
            return mcp::serve(mcp_backend);
        }
        other => return Err(format!("未知命令：{other}；运行 koe --help 查看用法")),
    };
    println!("{output}");
    Ok(())
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

struct TempReplayDir(PathBuf);

impl TempReplayDir {
    fn create() -> Result<Self, String> {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let dir = env::temp_dir().join(format!(
            "koe-cli-replay-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&dir).map_err(|e| format!("创建临时回放目录失败：{e}"))?;
        Ok(Self(dir))
    }
}

impl Drop for TempReplayDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn run_doctor_replay(bundle_path: &Path) -> Result<Value, String> {
    let file = File::open(bundle_path).map_err(|e| format!("无法打开诊断包文件：{e}"))?;
    let mut raw = Vec::new();
    file.take(MAX_REPLAY_BUNDLE_BYTES + 1)
        .read_to_end(&mut raw)
        .map_err(|e| format!("读取诊断包失败：{e}"))?;
    if raw.len() as u64 > MAX_REPLAY_BUNDLE_BYTES {
        return Err("诊断包文件超过 16 MiB 上限".into());
    }
    let bundle: DiagnosticsBundle =
        serde_json::from_slice(&raw).map_err(|e| format!("解析诊断包失败：{e}"))?;
    let temp_dir = TempReplayDir::create()?;
    let report = KoeRuntime::replay_bundle(&temp_dir.0, &bundle)?;
    serde_json::to_value(report).map_err(|e| format!("序列化回放结果失败：{e}"))
}

fn help() {
    println!("Koe {}\n\n用法：koe <命令> [参数]\n\n命令：\n  status                  查看与原生应用同源的工作区快照\n  doctor                  查看工作区、设备与模型状态\n  doctor --bundle [路径]  导出脱敏后的诊断包（默认输出到标准输出）\n  doctor --replay <文件>  在临时隔离工作区确定性回放诊断包\n  search <内容>           搜索真实记录及来源\n  ask <问题>              查询记录；未配置模型时返回本地来源\n  edit-segment <片段> <词> 修改指定记录的单段原文（需配合 --record）\n  set-speaker <片段> [人]  设置或清空指定片段说话人（需配合 --record）\n  rename-speaker <原> <新> 批量重命名或合并说话人（需配合 --record）\n  mcp-stdio               提供全部 16 个工作区与设备 MCP 工具\n  verify-protocol         在内存中验证协议与编解码\n  benchmark [--safe]      运行协议和音频封装基准\n  version                 查看版本与构建号（或 --version / -V）\n\n参数：\n  --workspace <目录>      工作区（--export-dir 为兼容别名）\n  --bridge-only           仅通过 Koe.app 本地桥访问，不获取本地工作区排他锁\n  --record <ID>           限定 search/ask 或指定要编辑的记录\n  --limit <1..100>        搜索结果数量\n\n默认工作区：~/Library/Containers/com.anker.ankerRecorder/Data/Library/Application Support/KoeWorkspace\nKoe.app 运行时自动经本地桥访问活体会话；未运行时默认打开本地工作区，传入 --bridge-only 时不抢锁。", koe_engine::KOE_APP_VERSION);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn options_parse_bridge_only_for_mcp_and_subcommands() {
        let default_opts = Options::parse_from(["mcp-stdio"]).unwrap();
        assert_eq!(default_opts.command, "mcp-stdio");
        assert_eq!(
            default_opts.bridge_policy,
            BridgeConnectionPolicy::AutoFallback
        );

        let flag_opts = Options::parse_from(["--mcp-stdio", "--bridge-only"]).unwrap();
        assert_eq!(flag_opts.command, "mcp-stdio");
        assert_eq!(flag_opts.bridge_policy, BridgeConnectionPolicy::BridgeOnly);

        let sub_opts = Options::parse_from(["--bridge-only", "status"]).unwrap();
        assert_eq!(sub_opts.command, "status");
        assert_eq!(sub_opts.bridge_policy, BridgeConnectionPolicy::BridgeOnly);
    }

    #[test]
    fn cli_subcommand_with_bridge_only_fails_fast_without_locking_workspace() {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let dir = env::temp_dir().join(format!(
            "kcli-bo-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&dir).unwrap();
        let lock_path = dir.join(".koe-workspace.lock");

        let opts = Options::parse_from([
            "status",
            "--bridge-only",
            "--workspace",
            dir.to_str().unwrap(),
        ])
        .unwrap();
        let err = run_with_options(opts).expect_err("offline bridge-only status must fail fast");
        assert_eq!(err, BRIDGE_OFFLINE_ERROR_MESSAGE);
        assert!(!lock_path.exists());

        let _ = fs::remove_dir_all(&dir);
    }
}
