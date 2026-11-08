#![forbid(unsafe_code)]

pub mod theme;

use gpui_kit::base::Disableable;
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::*;
use koe_desktop_core::{
    CicadaEvent, ConnectionPhaseTag, DesktopBeanHost, MarkJumpDirection, McpPairingMode,
    MeetingMinutesV2, MinutePoint, MinuteTopic, MinutesEvent, PAIRING_TICKET_PREFIX, ScoringMode,
    TodoStatus, filter_open_mine_todos, sort_context_timeline, validate_calculation_grounding,
};
use std::fs::{self, File};
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use theme::{AppColors, AppFontSizes, AppRadii};

struct AudioPlayer {
    _stream: rodio::OutputStream,
    sink: rodio::Sink,
}

impl AudioPlayer {
    fn play(path: &Path) -> anyhow::Result<Self> {
        let source = rodio::Decoder::try_from(File::open(path)?)?;
        let stream = rodio::OutputStreamBuilder::open_default_stream()?;
        let sink = rodio::Sink::connect_new(stream.mixer());
        sink.append(source);
        Ok(Self {
            _stream: stream,
            sink,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WorkspaceTab {
    Today,
    Library,
    LiveCicada,
    AskContext,
    McpAcp,
}

impl WorkspaceTab {
    const ALL: [Self; 5] = [
        Self::Today,
        Self::Library,
        Self::LiveCicada,
        Self::AskContext,
        Self::McpAcp,
    ];

    const fn label(self) -> &'static str {
        match self {
            Self::Today => "今日记录",
            Self::Library => "录音与资料包",
            Self::LiveCicada => "双语同传与纪要",
            Self::AskContext => "离线双字检索",
            Self::McpAcp => "外部 AI 协议",
        }
    }
}

enum LaunchTarget {
    Gui(Option<PathBuf>),
    Pack(PathBuf),
    Smoke(Option<PathBuf>),
    VerifySelf,
    McpStdio(Option<PathBuf>),
}

struct KoeDesktopApp {
    host: DesktopBeanHost,
    active_tab: WorkspaceTab,
    player: Option<AudioPlayer>,
    playback_task: Option<Task<()>>,
    search_query: String,
    search_results: Vec<(usize, String)>,
    last_jsonrpc_response: String,
    status: String,
    smoke: bool,
    smoke_failed: bool,
    smoke_scheduled: bool,
}

impl KoeDesktopApp {
    fn new(export_dir: PathBuf, smoke: bool) -> Self {
        let _ = fs::create_dir_all(&export_dir);
        let mut host = DesktopBeanHost::new(&export_dir);
        let loaded_exports = host.load_existing_exports().unwrap_or(0);
        let loaded_packs = host.load_existing_packs().unwrap_or(0);
        let mut app = Self {
            host,
            active_tab: WorkspaceTab::Today,
            player: None,
            playback_task: None,
            search_query: "海外渠道".to_string(),
            search_results: Vec::new(),
            last_jsonrpc_response: String::new(),
            status: format!(
                "已载入本机目录，录音 {} 条，资料包 {} 份",
                loaded_exports, loaded_packs
            ),
            smoke,
            smoke_failed: false,
            smoke_scheduled: false,
        };
        app.seed_workspace_sample(loaded_exports == 0, loaded_packs == 0);
        app
    }

    fn now_epoch_sec() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(1_762_560_000, |d| d.as_secs())
    }

    fn ensure_mcp_ready(&mut self, now: u64) {
        if !self.host.mcp_acp().mcp_ready {
            let _ = self.host.dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#,
                now,
            );
            let _ = self.host.dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                now,
            );
        }
    }

    fn active_exported_recordings(&self) -> Vec<koe_desktop_core::DesktopExportedRecording> {
        let exported = self.host.exported_recordings();
        self.host
            .library()
            .entries
            .iter()
            .filter_map(|entry| exported.iter().find(|rec| rec.entry.id == entry.id).cloned())
            .collect()
    }

    fn seed_workspace_sample(&mut self, seed_recording: bool, seed_pack: bool) {
        let now = Self::now_epoch_sec();
        if seed_recording {
            let _ = self.host.simulate_realtime_pipeline(now);
        }
        let s1 = self
            .host
            .ingest_utterance_with_context(
                "下周三前把海外渠道合同发给法务审阅。",
                0,
                2_400,
                "zh",
                "qwen",
                now,
            )
            .expect("S1 must append");
        let s2 = self
            .host
            .ingest_utterance_with_context(
                "核心固件采用纯 Rust 内核并默认开启竹青界面令牌。",
                2_400,
                5_200,
                "zh",
                "qwen",
                now + 3,
            )
            .expect("S2 must append");

        let _ = self.host.spine_mut().set_translation(
            s1,
            "Send the overseas channel contract to legal for review by next Wednesday.",
            "en",
        );
        let _ = self.host.spine_mut().set_translation(
            s2,
            "The core firmware uses a pure Rust kernel with Bamboo Green UI tokens enabled by default.",
            "en",
        );
        let _ = self.host.reduce_cicada(CicadaEvent::SyncTranslations);

        let _ = self
            .host
            .sync_qwennote_hotwords(&["海外渠道", "心力豆", "竹青"], &[("张总", "张伟")]);

        let grounded_minutes = MeetingMinutesV2 {
            version: 2,
            spine_revision: self.host.spine().revision(),
            title: "海外渠道与纯 Rust 内核收口纪要".to_string(),
            overview: "确认下周三前完成海外渠道合同法务审阅，并启用纯 Rust 内核与竹青界面令牌。"
                .to_string(),
            topics: vec![MinuteTopic {
                title: "合同审阅与内核收口".to_string(),
                summary: "法务审阅海外渠道合同，桌面端切换纯 Rust GPUI 架构。".to_string(),
                citations: vec![s1, s2],
                points: Vec::new(),
                fishbone: None,
            }],
            decisions: vec![MinutePoint {
                claim: "核心固件采用纯 Rust 内核并默认开启竹青界面令牌。".to_string(),
                speaker: None,
                owner: None,
                due: None,
                citations: vec![s2],
            }],
            actions: vec![MinutePoint {
                claim: "下周三前把海外渠道合同发给法务审阅。".to_string(),
                speaker: None,
                owner: None,
                due: None,
                citations: vec![s1],
            }],
            questions: Vec::new(),
            fishbones: Vec::new(),
            terms: Vec::new(),
            custom_sections: Vec::new(),
            review_items: Vec::new(),
        };
        let _ = self
            .host
            .reduce_minutes(MinutesEvent::CandidateReceived(grounded_minutes));
        let _ = self.host.refresh_live_publication(now + 5);
        if seed_pack {
            let _ = self
                .host
                .export_koepack_v2_to_disk("海外渠道与纯Rust收口", "2026-11-08T11:30:00Z");
        }
        self.run_bm25_query("海外渠道");
        let rec_count = self.host.snapshot().library.entry_count;
        self.status = format!(
            "已就绪，录音 {} 条，句子主干 S1..S{}",
            rec_count,
            self.host.spine().len()
        );
    }

    fn run_bm25_query(&mut self, query: &str) {
        self.search_query = query.to_string();
        let hits = self
            .host
            .search_index()
            .search(query, 5, ScoringMode::default());
        let segments = self.host.spine().segments();
        self.search_results = hits
            .into_iter()
            .map(|hit| {
                let text = segments.get(hit.doc_index).map_or_else(
                    || format!("文档 #{}", hit.doc_index),
                    |s| format!("[{}] {}", s.id, s.text),
                );
                (hit.doc_index, format!("得分 {:.2}  {}", hit.score, text))
            })
            .collect();
    }

    fn ingest_pack_file(&mut self, path: &Path) -> bool {
        match fs::read(path) {
            Ok(bytes) => match koe_desktop_core::cicada::decode_koepack_v2(&bytes) {
                Ok(decoded) => match self
                    .host
                    .put_sync_pack(&decoded.material.content_hash, &bytes)
                {
                    Ok(summary) => {
                        self.active_tab = WorkspaceTab::Library;
                        self.status = format!(
                            "已载入资料包 {}（导出于 {}，共 {} 字节）",
                            summary.title,
                            summary.exported_at_iso,
                            bytes.len()
                        );
                        true
                    }
                    Err(err) => {
                        self.smoke_failed = true;
                        self.status = format!("资料包校验未通过：{err:?}");
                        false
                    }
                },
                Err(err) => {
                    self.smoke_failed = true;
                    self.status = format!("资料包解码未通过：{err:?}");
                    false
                }
            },
            Err(err) => {
                self.smoke_failed = true;
                self.status = format!("无法读取资料包文件：{err}");
                false
            }
        }
    }

    fn format_mm_ss(ms: u64) -> String {
        let total_sec = ms / 1_000;
        format!("时长 {:02}:{:02}", total_sec / 60, total_sec % 60)
    }

    fn connection_badge_text(&self) -> String {
        let snap = self.host.snapshot();
        let phase_label = match snap.connection_phase {
            ConnectionPhaseTag::Disconnected => "未连接录音豆",
            ConnectionPhaseTag::Scanning => "正在搜索录音豆",
            ConnectionPhaseTag::Connecting => "正在连接录音豆",
            ConnectionPhaseTag::Handshaking => "正在协商加密会话",
            ConnectionPhaseTag::Connected => "录音豆已连接",
        };
        if let Some(tel) = snap.telemetry {
            format!("{phase_label}  电量 {}%", tel.battery.unwrap_or(100))
        } else {
            phase_label.to_string()
        }
    }

    fn render_sidebar(&self, cx: &mut Context<Self>) -> Div {
        let snap = self.host.snapshot();
        let can_undo = snap.library.last_trashed_id.is_some();

        div()
            .w(px(256.0))
            .flex()
            .flex_col()
            .gap_3()
            .p_4()
            .rounded(px(AppRadii::OUTER))
            .bg(rgb(AppColors::rgb24(AppColors::BG_PANEL)))
            .border_1()
            .border_color(rgb(AppColors::rgb24(AppColors::BORDER_SOFT)))
            .child(
                div()
                    .text_size(px(AppFontSizes::MD))
                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                    .child("Koe 录音豆工作台"),
            )
            .child(
                div()
                    .p_3()
                    .rounded(px(AppRadii::concentric(AppRadii::OUTER, 4.0)))
                    .bg(rgb(AppColors::rgb24(AppColors::SURFACE_1)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER_SOFT)))
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .text_size(px(AppFontSizes::SM))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child(self.connection_badge_text()),
                    )
                    .child(
                        div()
                            .text_size(px(AppFontSizes::XS))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                            .child(format!(
                                "本机录音 {} 条  资料包 {} 份",
                                snap.library.entry_count, snap.pack_count
                            )),
                    )
                    .child(
                        Button::new("connect-bean")
                            .primary()
                            .label("连接录音豆")
                            .on_click(cx.listener(|this, _, _, cx| {
                                let now = Self::now_epoch_sec();
                                let exported = this.host.simulate_realtime_pipeline(now);
                                this.status = format!(
                                    "录音豆已同步录音 #{}（{}，双击标记 {} 处）",
                                    exported.entry.id,
                                    Self::format_mm_ss(exported.entry.duration_ms),
                                    exported.entry.marks_ms.len()
                                );
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("start-recording")
                            .label("开始录音")
                            .on_click(cx.listener(|this, _, _, cx| {
                                let now = Self::now_epoch_sec();
                                let next_idx = this.host.spine().len() + 1;
                                if let Some(seg_id) = this.host.ingest_utterance_with_context(
                                    format!("第 {next_idx} 段实时会议发言与待办事项已记入主干。"),
                                    (next_idx as u64) * 2_000,
                                    (next_idx as u64 + 1) * 2_000,
                                    "zh",
                                    "qwen",
                                    now,
                                ) {
                                    let _ = this.host.refresh_live_publication(now);
                                    let q = this.search_query.clone();
                                    this.run_bm25_query(&q);
                                    this.status = format!(
                                        "已录制并写入句子主干 {seg_id}，实时租约代数 {}",
                                        this.host.snapshot().live_generation
                                    );
                                }
                                cx.notify();
                            })),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .children(WorkspaceTab::ALL.into_iter().map(|tab| {
                        let selected = self.active_tab == tab;
                        let btn = Button::new(("nav-tab", tab as usize)).label(tab.label());
                        let styled = if selected { btn.primary() } else { btn };
                        styled.on_click(cx.listener(move |this, _, _, cx| {
                            this.active_tab = tab;
                            this.status = format!("已切换至{}", tab.label());
                            cx.notify();
                        }))
                    })),
            )
            .child(
                div()
                    .mt_auto()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        Button::new("undo-trash")
                            .label("撤回删除")
                            .disabled(!can_undo)
                            .on_click(cx.listener(|this, _, _, cx| {
                                if this.host.undo_trash() {
                                    this.status = "已从回收站恢复最近删除的录音".to_string();
                                    cx.notify();
                                }
                            })),
                    )
                    .child(
                        div()
                            .text_size(px(AppFontSizes::XS))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                            .child(format!(
                                "索引文档 {} 条  MCP 调用 {} 次",
                                snap.indexed_context_docs, snap.mcp_handled_calls
                            )),
                    ),
            )
    }

    fn render_today_pane(&self, cx: &mut Context<Self>) -> Div {
        let items = sort_context_timeline(self.host.context().timeline.clone());
        let open_todos = filter_open_mine_todos(&self.host.context().todos);

        div()
            .flex()
            .flex_col()
            .gap_4()
            .child(
                div()
                    .text_size(px(AppFontSizes::LG))
                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                    .child("今日记录与承诺待办"),
            )
            .child(
                div()
                    .p_4()
                    .rounded(px(AppRadii::CARD))
                    .bg(rgb(AppColors::rgb24(AppColors::SURFACE_1)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .flex()
                            .justify_between()
                            .items_center()
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::MD))
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                                    .child(format!("待办承诺（共 {} 项）", open_todos.len())),
                            )
                            .child(
                                Button::new("add-note-context")
                                    .label("记一条随手记")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        let now = Self::now_epoch_sec();
                                        let _ = this.host.ingest_utterance_with_context(
                                            "周五前提交安克录音豆量产固件回归报告。",
                                            5_200,
                                            7_800,
                                            "zh",
                                            "manual",
                                            now,
                                        );
                                        let q = this.search_query.clone();
                                        this.run_bm25_query(&q);
                                        this.status = "已记入时间线并提取待办承诺".to_string();
                                        cx.notify();
                                    })),
                            ),
                    )
                    .children(open_todos.into_iter().map(|todo| {
                        let cites = todo
                            .citations
                            .iter()
                            .map(ToString::to_string)
                            .collect::<Vec<_>>()
                            .join(", ");
                        div()
                            .p_3()
                            .rounded(px(AppRadii::concentric(AppRadii::CARD, 4.0)))
                            .bg(rgb(AppColors::rgb24(AppColors::SURFACE_0)))
                            .border_1()
                            .border_color(rgb(AppColors::rgb24(AppColors::BORDER_SOFT)))
                            .flex()
                            .justify_between()
                            .items_center()
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::SM))
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                                    .child(todo.title),
                            )
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::XS))
                                    .text_color(rgb(AppColors::rgb24(AppColors::ACCENT)))
                                    .child(format!("出处 {cites}")),
                            )
                    })),
            )
            .child(
                div()
                    .p_4()
                    .rounded(px(AppRadii::CARD))
                    .bg(rgb(AppColors::rgb24(AppColors::SURFACE_1)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .text_size(px(AppFontSizes::MD))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child(format!("个人上下文时间线（共 {} 条）", items.len())),
                    )
                    .children(items.into_iter().map(|item| {
                        div()
                            .p_3()
                            .rounded(px(AppRadii::concentric(AppRadii::CARD, 4.0)))
                            .bg(rgb(AppColors::rgb24(AppColors::SURFACE_0)))
                            .border_1()
                            .border_color(rgb(AppColors::rgb24(AppColors::BORDER_SOFT)))
                            .flex()
                            .justify_between()
                            .items_center()
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::SM))
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                                    .child(format!("[{}] {}", item.title, item.summary)),
                            )
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::XS))
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                                    .child(format!("时间戳 {} 秒", item.created_at_epoch_sec)),
                            )
                    })),
            )
    }

    fn render_library_pane(&self, cx: &mut Context<Self>) -> Div {
        let snap = self.host.snapshot();
        let recordings = self.active_exported_recordings();
        let selected_id = snap.library.selected_id;

        div()
            .flex()
            .flex_col()
            .gap_4()
            .child(
                div()
                    .flex()
                    .justify_between()
                    .items_center()
                    .child(
                        div()
                            .text_size(px(AppFontSizes::LG))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child("本机录音与无音频资料包"),
                    )
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(
                                Button::new("prev-mark")
                                    .label("上一标记")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        let pos = this.host.jump_to_mark(MarkJumpDirection::Previous);
                                        this.status = format!("已跳至上一双击标记 {} 毫秒", pos);
                                        cx.notify();
                                    })),
                            )
                            .child(
                                Button::new("next-mark")
                                    .label("下一标记")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        let pos = this.host.jump_to_mark(MarkJumpDirection::Next);
                                        this.status = format!("已跳至下一双击标记 {} 毫秒", pos);
                                        cx.notify();
                                    })),
                            )
                            .child(
                                Button::new("export-pack-v2")
                                    .primary()
                                    .label("导出资料包")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        match this.host.export_koepack_v2_to_disk(
                                            "桌面端导出纪要包",
                                            "2026-11-08T12:00:00Z",
                                        ) {
                                            Ok((summary, path)) => {
                                                this.status = format!(
                                                    "已导出资料包 {} 至 {}",
                                                    summary.id,
                                                    path.display()
                                                );
                                            }
                                            Err(err) => {
                                                this.status = format!("导出资料包失败：{err:?}");
                                            }
                                        }
                                        cx.notify();
                                    })),
                            ),
                    ),
            )
            .child(
                div()
                    .text_size(px(AppFontSizes::SM))
                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_SECONDARY)))
                    .child(format!(
                        "当前播放游标 {} 毫秒  已归档资料包 {} 份  导出目录 {}",
                        snap.library.position_ms,
                        snap.pack_count,
                        self.host.export_dir().display()
                    )),
            )
            .children(recordings.into_iter().map(|rec| {
                let id = rec.entry.id;
                let wav_path = rec.wav_path.clone();
                let is_selected = selected_id == Some(id);
                let border_hex = if is_selected {
                    AppColors::BORDER_SELECTED
                } else {
                    AppColors::BORDER
                };
                let marks_desc = if rec.entry.marks_ms.is_empty() {
                    "无双击标记".to_string()
                } else {
                    format!("双击标记 {:?} 毫秒", rec.entry.marks_ms)
                };
                div()
                    .p_4()
                    .rounded(px(AppRadii::CARD))
                    .bg(rgb(AppColors::rgb24(AppColors::SURFACE_1)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(border_hex)))
                    .flex()
                    .justify_between()
                    .items_center()
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::MD))
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                                    .child(format!(
                                        "录音 #{id}  {}",
                                        Self::format_mm_ss(rec.entry.duration_ms)
                                    )),
                            )
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::XS))
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                                    .child(format!(
                                        "文件大小 {} 字节  {}",
                                        rec.entry.byte_count, marks_desc
                                    )),
                            ),
                    )
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(
                                Button::new(("play-wav", id as usize))
                                    .primary()
                                    .label("播放原声")
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        let _ = this.host.select_recording(id);
                                        this.player = None;
                                        match AudioPlayer::play(&wav_path) {
                                            Ok(player) => {
                                                this.player = Some(player);
                                                this.status = format!("正在播放录音 #{id}");
                                                this.playback_task = Some(cx.spawn(async |view, cx| {
                                                    loop {
                                                        cx.background_executor()
                                                            .timer(Duration::from_millis(200))
                                                            .await;
                                                        let keep = view.update(cx, |view, cx| {
                                                            if view
                                                                .player
                                                                .as_ref()
                                                                .is_some_and(|p| p.sink.empty())
                                                            {
                                                                view.player = None;
                                                                view.status = "播放结束".to_string();
                                                                cx.notify();
                                                            }
                                                            view.player.is_some()
                                                        });
                                                        if !matches!(keep, Ok(true)) {
                                                            break;
                                                        }
                                                    }
                                                }));
                                            }
                                            Err(err) => {
                                                this.status = format!("播放失败：{err}");
                                            }
                                        }
                                        cx.notify();
                                    })),
                            )
                            .child(
                                Button::new(("trash-rec", id as usize))
                                    .label("移到回收站")
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.player = None;
                                        if this.host.move_to_trash(id) {
                                            this.status = format!(
                                                "录音 #{id} 已移到回收站，可点左侧「撤回删除」立即恢复"
                                            );
                                            cx.notify();
                                        }
                                    })),
                            ),
                    )
            }))
    }

    fn render_live_cicada_pane(&self, _cx: &mut Context<Self>) -> Div {
        let segments = self.host.spine().segments().to_vec();
        let mins = self.host.minutes().latest_minutes.clone();

        div()
            .flex()
            .flex_col()
            .gap_4()
            .child(
                div()
                    .text_size(px(AppFontSizes::LG))
                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                    .child("双语同传字幕与千问防幻觉结构化纪要"),
            )
            .child(
                div()
                    .p_4()
                    .rounded(px(AppRadii::CARD))
                    .bg(rgb(AppColors::rgb24(AppColors::SURFACE_1)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .text_size(px(AppFontSizes::MD))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child(format!(
                                "统一句子主干 UtteranceSpine（修订号 {}，共 {} 句）",
                                self.host.spine().revision(),
                                segments.len()
                            )),
                    )
                    .children(segments.into_iter().map(|seg| {
                        let en_text = seg
                            .translation
                            .clone()
                            .unwrap_or_else(|| "待增量翻译".to_string());
                        div()
                            .p_3()
                            .rounded(px(AppRadii::concentric(AppRadii::CARD, 4.0)))
                            .bg(rgb(AppColors::rgb24(AppColors::SURFACE_0)))
                            .border_1()
                            .border_color(rgb(AppColors::rgb24(AppColors::BORDER_SOFT)))
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::SM))
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                                    .child(format!(
                                        "[{}] {} ms - {} ms  {}",
                                        seg.id, seg.start_ms, seg.end_ms, seg.text
                                    )),
                            )
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::XS))
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_SECONDARY)))
                                    .child(format!("译文：{en_text}")),
                            )
                    })),
            )
            .child(
                div()
                    .p_4()
                    .rounded(px(AppRadii::CARD))
                    .bg(rgb(AppColors::rgb24(AppColors::SURFACE_1)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .text_size(px(AppFontSizes::MD))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child(
                                mins.as_ref()
                                    .map_or_else(|| "结构化纪要".to_string(), |m| m.title.clone()),
                            ),
                    )
                    .child(
                        div()
                            .text_size(px(AppFontSizes::SM))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_SECONDARY)))
                            .child(mins.as_ref().map_or_else(
                                || "暂无纪要".to_string(),
                                |m| m.overview.clone(),
                            )),
                    )
                    .children(
                        mins.into_iter()
                            .flat_map(|m| m.decisions.into_iter().chain(m.actions))
                            .map(|pt| {
                                let cites = pt
                                    .citations
                                    .iter()
                                    .map(ToString::to_string)
                                    .collect::<Vec<_>>()
                                    .join(", ");
                                div()
                                    .text_size(px(AppFontSizes::XS))
                                    .text_color(rgb(AppColors::rgb24(AppColors::ACCENT)))
                                    .child(format!("{} [原句出处 {}]", pt.claim, cites))
                            }),
                    ),
            )
    }

    fn render_ask_context_pane(&self, cx: &mut Context<Self>) -> Div {
        div()
            .flex()
            .flex_col()
            .gap_4()
            .child(
                div()
                    .text_size(px(AppFontSizes::LG))
                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                    .child("心力豆中文双字与拉丁词根 BM25 离线检索"),
            )
            .child(
                div()
                    .flex()
                    .gap_2()
                    .child(
                        Button::new("query-overseas")
                            .primary()
                            .label("检索「海外渠道」")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.run_bm25_query("海外渠道");
                                this.status = "已完成「海外渠道」双字 BM25 检索".to_string();
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("query-rust")
                            .label("检索「竹青界面」")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.run_bm25_query("竹青界面");
                                this.status = "已完成「竹青界面」双字 BM25 检索".to_string();
                                cx.notify();
                            })),
                    ),
            )
            .child(
                div()
                    .p_4()
                    .rounded(px(AppRadii::CARD))
                    .bg(rgb(AppColors::rgb24(AppColors::SURFACE_1)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .text_size(px(AppFontSizes::MD))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child(format!(
                                "查询词「{}」命中 {} 条原句证据",
                                self.search_query,
                                self.search_results.len()
                            )),
                    )
                    .children(self.search_results.iter().map(|(_, line)| {
                        div()
                            .p_3()
                            .rounded(px(AppRadii::concentric(AppRadii::CARD, 4.0)))
                            .bg(rgb(AppColors::rgb24(AppColors::SURFACE_0)))
                            .border_1()
                            .border_color(rgb(AppColors::rgb24(AppColors::BORDER_SOFT)))
                            .text_size(px(AppFontSizes::SM))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child(line.clone())
                    })),
            )
    }

    fn render_mcp_acp_pane(&self, cx: &mut Context<Self>) -> Div {
        let snap = self.host.snapshot();
        div()
            .flex()
            .flex_col()
            .gap_4()
            .child(
                div()
                    .text_size(px(AppFontSizes::LG))
                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                    .child("原生 JSON-RPC 2.0 MCP 与 ACP 代理服务"),
            )
            .child(
                div()
                    .flex()
                    .gap_2()
                    .child(
                        Button::new("refresh-live-lease")
                            .primary()
                            .label("刷新 15 秒实时租约")
                            .on_click(cx.listener(|this, _, _, cx| {
                                let now = Self::now_epoch_sec();
                                match this.host.refresh_live_publication(now) {
                                    Ok(generation) => {
                                        this.status = format!("已发布 live.json 租约，代数 {generation}");
                                    }
                                    Err(err) => {
                                        this.status = format!("发布租约失败：{err:?}");
                                    }
                                }
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("dispatch-mcp-search")
                            .label("调用 MCP search_context")
                            .on_click(cx.listener(|this, _, _, cx| {
                                let now = Self::now_epoch_sec();
                                this.ensure_mcp_ready(now);
                                let req = r#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"search_context","arguments":{"query":"海外渠道","limit":3}}}"#;
                                if let Some(resp) = this.host.dispatch_jsonrpc(req, now) {
                                    this.last_jsonrpc_response = resp;
                                    this.status = "已完成原生 MCP search_context 调用".to_string();
                                }
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("dispatch-acp-task")
                            .label("派发 ACP 溯源任务")
                            .on_click(cx.listener(|this, _, _, cx| {
                                let now = Self::now_epoch_sec();
                                let req = r#"{"jsonrpc":"2.0","id":11,"method":"acp/task.send","params":{"prompt":"海外渠道合同"}}"#;
                                if let Some(resp) = this.host.dispatch_jsonrpc(req, now) {
                                    this.last_jsonrpc_response = resp;
                                    this.status = "已完成原生 ACP acp/task.send 调用".to_string();
                                }
                                cx.notify();
                            })),
                    ),
            )
            .child(
                div()
                    .p_4()
                    .rounded(px(AppRadii::CARD))
                    .bg(rgb(AppColors::rgb24(AppColors::SURFACE_1)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .text_size(px(AppFontSizes::MD))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child(format!(
                                "实时租约代数 {}  累计协议调用 {} 次  已同步资料包 {} 份",
                                snap.live_generation, snap.mcp_handled_calls, snap.pack_count
                            )),
                    )
                    .child(
                        div()
                            .p_3()
                            .rounded(px(AppRadii::concentric(AppRadii::CARD, 4.0)))
                            .bg(rgb(AppColors::rgb24(AppColors::SURFACE_0)))
                            .border_1()
                            .border_color(rgb(AppColors::rgb24(AppColors::BORDER_SOFT)))
                            .text_size(px(AppFontSizes::XS))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_SECONDARY)))
                            .child(if self.last_jsonrpc_response.is_empty() {
                                "点击上方按钮可直接在内存工作区执行 MCP 2025-11-25 或 ACP 2026-01-01 协议调用。"
                                    .to_string()
                            } else {
                                self.last_jsonrpc_response.clone()
                            }),
                    ),
            )
    }
}

impl Render for KoeDesktopApp {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.smoke && !self.smoke_scheduled {
            self.smoke_scheduled = true;
            let healthy = !self.smoke_failed
                && self.host.snapshot().library.entry_count > 0
                && !self.host.spine().is_empty();
            window.on_next_frame(move |_, cx| {
                cx.spawn(async move |cx| {
                    cx.background_executor()
                        .timer(Duration::from_millis(250))
                        .await;
                    std::process::exit(if healthy { 0 } else { 1 });
                })
                .detach();
            });
        }

        let main_pane = match self.active_tab {
            WorkspaceTab::Today => self.render_today_pane(cx),
            WorkspaceTab::Library => self.render_library_pane(cx),
            WorkspaceTab::LiveCicada => self.render_live_cicada_pane(cx),
            WorkspaceTab::AskContext => self.render_ask_context_pane(cx),
            WorkspaceTab::McpAcp => self.render_mcp_acp_pane(cx),
        };

        div()
            .flex()
            .flex_col()
            .size_full()
            .bg(rgb(AppColors::rgb24(AppColors::SURFACE_0)))
            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
            .p_5()
            .gap_4()
            .child(
                div()
                    .flex()
                    .flex_1()
                    .min_h_0()
                    .gap_5()
                    .child(self.render_sidebar(cx))
                    .child(
                        div()
                            .id("workspace-main")
                            .flex_1()
                            .min_w_0()
                            .min_h_0()
                            .overflow_y_scroll()
                            .child(main_pane),
                    ),
            )
            .child(
                div()
                    .p_3()
                    .rounded(px(AppRadii::CONTROL))
                    .bg(rgb(AppColors::rgb24(AppColors::SURFACE_1)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER_SOFT)))
                    .text_size(px(AppFontSizes::XS))
                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_SECONDARY)))
                    .child(self.status.clone()),
            )
    }
}

fn run_self_check() -> anyhow::Result<()> {
    let temp_dir = std::env::temp_dir().join(format!("koe-gpui-self-check-{}", std::process::id()));
    let _ = fs::remove_dir_all(&temp_dir);
    fs::create_dir_all(&temp_dir)?;

    let mut app = KoeDesktopApp::new(temp_dir.clone(), false);
    let snap = app.host.snapshot();
    anyhow::ensure!(snap.library.entry_count >= 1, "expected seeded recording");
    anyhow::ensure!(app.host.spine().len() >= 2, "expected S1..S2 in spine");
    anyhow::ensure!(snap.pack_count >= 1, "expected exported .koepack v2");
    anyhow::ensure!(snap.live_generation >= 1, "expected live.json lease");
    anyhow::ensure!(!app.search_results.is_empty(), "expected BM25 search hits");

    let s1 = app.host.spine().segments()[0].id;
    let s2 = app.host.spine().segments()[1].id;
    anyhow::ensure!(
        validate_calculation_grounding("基本工资3910元乘以80%发放", &[s1, s2], app.host.spine())
            .is_err(),
        "cross-segment wage/percentage stitching must be rejected"
    );

    let ticket = app
        .host
        .issue_pairing_ticket(
            "https://koe.example.com/mcp",
            "koe-secret-token-32bytes-minimum",
            McpPairingMode::Vps,
            Some("owner@example.com"),
            Some(1_893_456_000),
        )
        .map_err(|e| anyhow::anyhow!("pairing ticket failed: {e:?}"))?;
    anyhow::ensure!(ticket.starts_with(PAIRING_TICKET_PREFIX));

    let now = KoeDesktopApp::now_epoch_sec();
    app.ensure_mcp_ready(now + 5);
    let mcp_resp = app
        .host
        .dispatch_jsonrpc(
            r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_context","arguments":{"query":"海外渠道","limit":5}}}"#,
            now + 6,
        )
        .ok_or_else(|| anyhow::anyhow!("missing MCP response"))?;
    anyhow::ensure!(mcp_resp.contains("海外渠道"), "mcp_resp: {mcp_resp}");

    let acp_resp = app
        .host
        .dispatch_jsonrpc(
            r#"{"jsonrpc":"2.0","id":2,"method":"acp/task.send","params":{"prompt":"海外渠道合同"}}"#,
            now + 7,
        )
        .ok_or_else(|| anyhow::anyhow!("missing ACP response"))?;
    anyhow::ensure!(acp_resp.contains("acp-task-1"), "acp_resp: {acp_resp}");

    let rec_id = app.active_exported_recordings()[0].entry.id;
    anyhow::ensure!(app.host.jump_to_mark(MarkJumpDirection::Next) == 300);
    anyhow::ensure!(app.host.move_to_trash(rec_id));
    anyhow::ensure!(app.active_exported_recordings().is_empty());
    anyhow::ensure!(app.host.undo_trash());
    anyhow::ensure!(app.active_exported_recordings().len() == 1);
    anyhow::ensure!(
        app.host.context().todos.iter().any(|t| t.status == TodoStatus::Open),
        "expected open commitment todo"
    );

    let custom_pack = temp_dir.join("demo-human-named.koepack");
    let (_, exported_pack_path) = app
        .host
        .export_koepack_v2_to_disk("自定义文件名资料包", "2026-11-08T12:00:00Z")
        .map_err(|e| anyhow::anyhow!("export pack failed: {e:?}"))?;
    fs::copy(&exported_pack_path, &custom_pack)?;

    let mut reopened = KoeDesktopApp::new(temp_dir.clone(), false);
    anyhow::ensure!(
        !reopened.host.spine().is_empty() && !reopened.search_results.is_empty(),
        "second launch on existing workspace must populate spine and BM25 index"
    );
    let init_resp = reopened
        .host
        .dispatch_jsonrpc(
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#,
            now + 8,
        )
        .ok_or_else(|| anyhow::anyhow!("missing stdio initialize response"))?;
    anyhow::ensure!(
        init_resp.contains("protocolVersion") && !init_resp.contains("error"),
        "fresh app must accept standard MCP initialize handshake: {init_resp}"
    );
    anyhow::ensure!(
        reopened.ingest_pack_file(&custom_pack) && !reopened.smoke_failed,
        "human-named .koepack file must ingest via content_hash"
    );

    let _ = fs::remove_dir_all(&temp_dir);
    println!(
        "PASS: koe-desktop pure-Rust GPUI + DesktopBeanHost self-check (spine={}, packs={}, mcp_calls={})",
        app.host.spine().len(),
        app.host.snapshot().pack_count,
        app.host.snapshot().mcp_handled_calls
    );
    Ok(())
}

fn run_mcp_stdio(dir: Option<PathBuf>) -> anyhow::Result<()> {
    let export_dir = dir.unwrap_or_else(default_workspace_dir);
    let mut app = KoeDesktopApp::new(export_dir, false);
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let now = KoeDesktopApp::now_epoch_sec();
        if let Some(resp) = app.host.dispatch_jsonrpc(&line, now) {
            writeln!(stdout, "{resp}")?;
            stdout.flush()?;
        }
    }
    Ok(())
}

fn default_workspace_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("Library")
        .join("Application Support")
        .join("com.anker.ankerRecorder")
        .join("workspace")
}

fn parse_args() -> LaunchTarget {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [] => LaunchTarget::Gui(None),
        [flag] if flag == "--help" || flag == "-h" => {
            println!(
                "Koe 纯 Rust GPUI 桌面端\n用法：koe-desktop [--verify-self | --smoke-test [PATH] | --mcp-stdio [DIR] | --library DIR | --pack PATH]"
            );
            std::process::exit(0);
        }
        [flag] if flag == "--verify-self" => LaunchTarget::VerifySelf,
        [flag] if flag == "--smoke-test" => LaunchTarget::Smoke(None),
        [flag, path] if flag == "--smoke-test" => LaunchTarget::Smoke(Some(PathBuf::from(path))),
        [flag] if flag == "--mcp-stdio" => LaunchTarget::McpStdio(None),
        [flag, path] if flag == "--mcp-stdio" => LaunchTarget::McpStdio(Some(PathBuf::from(path))),
        [flag, path] if flag == "--library" => LaunchTarget::Gui(Some(PathBuf::from(path))),
        [flag, path] if flag == "--pack" => LaunchTarget::Pack(PathBuf::from(path)),
        _ => {
            eprintln!(
                "用法：koe-desktop [--verify-self | --smoke-test [PATH] | --mcp-stdio [DIR] | --library DIR | --pack PATH]"
            );
            std::process::exit(2);
        }
    }
}

fn main() {
    let target = parse_args();
    match target {
        LaunchTarget::VerifySelf => {
            if let Err(err) = run_self_check() {
                eprintln!("self-check failed: {err:#}");
                std::process::exit(1);
            }
            return;
        }
        LaunchTarget::McpStdio(dir) => {
            if let Err(err) = run_mcp_stdio(dir) {
                eprintln!("mcp-stdio failed: {err:#}");
                std::process::exit(1);
            }
            return;
        }
        _ => {}
    }

    let smoke = matches!(target, LaunchTarget::Smoke(_));
    if smoke {
        std::thread::spawn(|| {
            std::thread::sleep(Duration::from_secs(30));
            eprintln!("smoke test timed out");
            std::process::exit(1);
        });
    }

    application().with_assets(assets::Assets).run(move |cx| {
        init(cx);
        cx.on_window_closed(move |cx, _| {
            if cx.windows().is_empty() {
                if smoke {
                    std::process::exit(1);
                }
                cx.quit();
            }
        })
        .detach();

        open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(1180.0), px(760.0)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                cx.new(|_cx| match &target {
                    LaunchTarget::Gui(Some(dir)) => KoeDesktopApp::new(dir.clone(), false),
                    LaunchTarget::Gui(None) => KoeDesktopApp::new(default_workspace_dir(), false),
                    LaunchTarget::Pack(pack_path) => {
                        let mut app = KoeDesktopApp::new(default_workspace_dir(), false);
                        app.ingest_pack_file(pack_path);
                        app
                    }
                    LaunchTarget::Smoke(Some(path)) => {
                        if path.is_dir() {
                            KoeDesktopApp::new(path.clone(), true)
                        } else {
                            let temp = std::env::temp_dir()
                                .join(format!("koe-gpui-smoke-{}", std::process::id()));
                            let mut app = KoeDesktopApp::new(temp, true);
                            app.ingest_pack_file(path);
                            app
                        }
                    }
                    LaunchTarget::Smoke(None) => {
                        let temp = std::env::temp_dir()
                            .join(format!("koe-gpui-smoke-{}", std::process::id()));
                        KoeDesktopApp::new(temp, true)
                    }
                    LaunchTarget::VerifySelf | LaunchTarget::McpStdio(_) => unreachable!(),
                })
            },
        )
        .expect("无法打开 Koe GPUI 窗口");
        cx.activate(true);
    });
}

#[cfg(test)]
mod tests {
    use super::run_self_check;

    #[core::prelude::v1::test]
    fn self_check_verifies_full_desktop_bean_host_and_gpui_state() {
        run_self_check().expect("pure-Rust GPUI + DesktopBeanHost self-check must pass");
    }
}
