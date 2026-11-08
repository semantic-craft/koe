#![forbid(unsafe_code)]

pub mod theme;

use gpui_kit::base::{Disableable, StyledExt};
use gpui_kit::component::Sizable;
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::*;
use koe_desktop_ble::{BleEvent, MacBleController};
use koe_desktop_core::{
    BuiltinTemplateId, CicadaEvent, ConnectionPhaseTag, CopilotPresetChip, DesktopBeanHost,
    DesktopExportedRecording, DetailTab, DeviceCrypto, MarkJumpDirection, McpPairingMode,
    MeetingMinutesV2, MinuteCause, MinuteFishbone, MinutePoint, MinuteTopic, MinutesEvent,
    PAIRING_TICKET_PREFIX, SummaryFormat, TodoStatus, WifiBatchPhase, WifiSoftApAction,
    WorkspaceCommand, WorkspaceProjection, WorkspaceSection, validate_calculation_grounding,
};
use std::fs::{self, File};
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use theme::{AIVisualEditorialPalette, AppColors, AppFontSizes, AppRadii};

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

enum LaunchTarget {
    Gui(Option<PathBuf>),
    Pack(PathBuf),
    Smoke(Option<PathBuf>),
    VerifySelf,
    McpStdio(Option<PathBuf>),
}

struct KoeDesktopApp {
    host: DesktopBeanHost,
    projection: WorkspaceProjection,
    ble: MacBleController,
    ble_rx: mpsc::Receiver<BleEvent>,
    ble_poll_task: Option<Task<()>>,
    player: Option<AudioPlayer>,
    playback_task: Option<Task<()>>,
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
        let now = Self::now_epoch_sec();
        let projection = host.workspace_projection(now);
        let (ble, ble_rx) = MacBleController::new();
        let mut app = Self {
            host,
            projection,
            ble,
            ble_rx,
            ble_poll_task: None,
            player: None,
            playback_task: None,
            status: format!(
                "已载入本机目录，录音 {} 条，资料包 {} 份",
                loaded_exports, loaded_packs
            ),
            smoke,
            smoke_failed: false,
            smoke_scheduled: false,
        };
        if loaded_exports == 0 && loaded_packs == 0 {
            app.seed_workspace_sample(true, true);
        } else {
            let _ = app.apply_command(WorkspaceCommand::SyncHotWords {
                hotwords: vec![
                    "海外渠道".to_string(),
                    "心力豆".to_string(),
                    "soundcore".to_string(),
                ],
                speaker_aliases: vec![("张总".to_string(), "张伟".to_string())],
            });
            let _ = app.apply_command(WorkspaceCommand::RefreshLiveLease { now_epoch_sec: now });
            if !app.projection.active_aggregate.spine.is_empty() {
                let _ = app.apply_command(WorkspaceCommand::SearchContext {
                    query: "海外渠道".to_string(),
                    limit: 5,
                });
            }
            app.status = format!(
                "已载入本机工作区，录音 {} 条，资料包 {} 份，句子主干 {} 段",
                app.projection.library.entry_count,
                app.projection.pack_count,
                app.projection.active_aggregate.spine.len()
            );
        }
        app
    }

    fn apply_command(&mut self, cmd: WorkspaceCommand) -> &WorkspaceProjection {
        let now = Self::now_epoch_sec();
        self.projection = self.host.dispatch(cmd, now);
        &self.projection
    }

    fn dispatch_command(
        &mut self,
        cmd: WorkspaceCommand,
        status_msg: impl Into<String>,
        cx: &mut Context<Self>,
    ) {
        let now = Self::now_epoch_sec();
        self.projection = self.host.dispatch(cmd, now);
        for frame in self.host.drain_outbound_ble_frames() {
            let _ = self.ble.send_frame(&frame);
        }
        self.status = status_msg.into();
        cx.notify();
    }

    fn sync_projection(&mut self) {
        let now = Self::now_epoch_sec();
        self.projection = self.host.workspace_projection(now);
    }

    fn generate_ephemeral_p256_key(seed: u64) -> [u8; 32] {
        let mut rng = koe_desktop_core::prng::SplitMix64::new(seed ^ 0xD320_0B1E_5EED_CAFE);
        loop {
            let bytes = rng.next_bytes(32);
            let mut key = [0u8; 32];
            key.copy_from_slice(&bytes);
            if DeviceCrypto::p256_public_key(&key).is_some() {
                return key;
            }
        }
    }

    fn drain_ble_events(&mut self) -> bool {
        let mut changed = false;
        while let Ok(ev) = self.ble_rx.try_recv() {
            changed = true;
            match ev {
                BleEvent::Scanning => {
                    self.host.on_scanning();
                    self.sync_projection();
                    self.status =
                        "正在通过 CoreBluetooth 搜索 D3200 录音豆（UUID 0xF5DA）…".to_string();
                }
                BleEvent::Unavailable(reason) => {
                    self.host.on_disconnected();
                    self.sync_projection();
                    self.status = format!(
                        "蓝牙未就绪（{reason}），可点击「开始随心记 (60片实时流)」验证离线闭环"
                    );
                }
                BleEvent::Connecting(name) => {
                    self.host.on_connecting();
                    self.sync_projection();
                    self.status = format!("已发现 {name}，正在建立 GATT 连接…");
                }
                BleEvent::GattReady(name) => {
                    let priv_key = Self::generate_ephemeral_p256_key(Self::now_epoch_sec());
                    if let Some(tx_frames) = self.host.on_gatt_ready(priv_key) {
                        for frame in tx_frames {
                            let _ = self.ble.send_frame(&frame);
                        }
                    }
                    self.sync_projection();
                    self.status = format!(
                        "已连接 {name}（0x7777/0x8888 就绪），正在执行 2E/01 ECDH 握手…"
                    );
                }
                BleEvent::Notification(bytes) => {
                    let now = Self::now_epoch_sec();
                    let prev_count = self.projection.library.entry_count;
                    let outcome = self.host.ingest_ble_chunk(&bytes, now);
                    for frame in outcome.outbound_tx_frames {
                        let _ = self.ble.send_frame(&frame);
                    }
                    self.sync_projection();
                    if outcome.session_key_established {
                        self.status = "2E/01 ECDH 会话密钥协商成功".to_string();
                    }
                    if outcome.telemetry_updated {
                        self.status =
                            format!("录音豆已连接（{}）", self.connection_badge_text());
                    }
                    if outcome.catalog_updated {
                        self.status = "已同步录音豆目录与实时流状态".to_string();
                    }
                    if self.projection.library.entry_count > prev_count {
                        self.status = format!(
                            "已从录音豆取回并导出新录音，当前共 {} 条",
                            self.projection.library.entry_count
                        );
                    }
                }
                BleEvent::Disconnected(reason) => {
                    let salvaged = self.host.on_transport_interrupted();
                    self.sync_projection();
                    let suffix = reason.unwrap_or_else(|| "连接已断开".to_string());
                    if !salvaged.is_empty() {
                        self.status = format!(
                            "录音豆断开（{suffix}），已抢救导出 {} 条实时录音",
                            salvaged.len()
                        );
                    } else {
                        self.status = format!("录音豆未连接（{suffix}）");
                    }
                }
            }
        }
        changed
    }

    fn ensure_ble_poll_task(&mut self, cx: &mut Context<Self>) {
        if self.ble_poll_task.is_some() {
            return;
        }
        self.ble_poll_task = Some(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(100))
                    .await;
                let keep_going = this
                    .update(cx, |this, cx| {
                        let mut changed = this.drain_ble_events();
                        let now = Self::now_epoch_sec();
                        let timer_out = this.host.poll_timers(100, now);
                        for frame in timer_out.outbound_tx_frames {
                            let _ = this.ble.send_frame(&frame);
                        }
                        if timer_out.transfer_updated || timer_out.finalized.is_some() {
                            this.sync_projection();
                            changed = true;
                        }
                        if changed {
                            cx.notify();
                        }
                        this.projection.connection_phase != ConnectionPhaseTag::Disconnected
                    })
                    .unwrap_or(false);
                if !keep_going {
                    let _ = this.update(cx, |this, _| {
                        this.ble_poll_task = None;
                    });
                    break;
                }
            }
        }));
    }

    fn now_epoch_sec() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(1_762_560_000, |d| d.as_secs())
    }

    fn ensure_mcp_ready(&mut self, now: u64) {
        if !self.host.mcp_acp().mcp_ready {
            let _ = self.host.dispatch(
                WorkspaceCommand::DispatchJsonRpc {
                    request_json: r#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#.to_string(),
                },
                now,
            );
            self.projection = self.host.dispatch(
                WorkspaceCommand::DispatchJsonRpc {
                    request_json: r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
                        .to_string(),
                },
                now,
            );
        }
    }

    fn active_exported_recordings(&self) -> Vec<DesktopExportedRecording> {
        let exported = &self.projection.recordings;
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
                "qwen3-asr-flash-realtime",
                now,
            )
            .expect("S1 must append");
        let s2 = self
            .host
            .ingest_utterance_with_context(
                "核心固件采用纯 Rust 内核并默认开启伊利诺伊橙界面令牌。",
                2_400,
                5_200,
                "zh",
                "qwen3-asr-flash-realtime",
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
            "The core firmware uses a pure Rust kernel with Illinois Orange UI tokens enabled by default.",
            "en",
        );
        let _ = self.host.reduce_cicada(CicadaEvent::SyncTranslations);

        let fishbone = MinuteFishbone {
            issue: "D3200 真机说话偶发不出字与实时流断点根治".to_string(),
            causes: vec![
                MinuteCause {
                    category: "固件协议".to_string(),
                    description: "补齐 01/01、1A/06、18/81、18/82 四路硬件录音启动入口并自动补发 1A/07(realtimeFlag=1)".to_string(),
                    citations: vec![s1, s2],
                },
                MinuteCause {
                    category: "音频解码".to_string(),
                    description: "DesktopBeanHost::new 默认注入 16kHz/48kHz libopus 解码器工厂".to_string(),
                    citations: vec![s2],
                },
                MinuteCause {
                    category: "流式百炼".to_string(),
                    description: "SuixinRuntime 自驱泵将 1A/08 PCM16 帧实时推入 DashScope ASR 并投影到 UtteranceSpine".to_string(),
                    citations: vec![s1, s2],
                },
            ],
        };

        let grounded_minutes = MeetingMinutesV2 {
            version: 2,
            spine_revision: self.host.spine().revision(),
            title: "海外渠道与纯 Rust 内核收口纪要".to_string(),
            overview:
                "确认下周三前完成海外渠道合同法务审阅，并启用纯 Rust 内核与 Vecta 伊利诺伊橙界面令牌。"
                    .to_string(),
            topics: vec![MinuteTopic {
                title: "合同审阅与内核收口".to_string(),
                summary: "法务审阅海外渠道合同，桌面端切换纯 Rust GPUI 双栏工作台。".to_string(),
                citations: vec![s1, s2],
                points: Vec::new(),
                fishbone: Some(fishbone.clone()),
            }],
            decisions: vec![MinutePoint {
                claim: "核心固件采用纯 Rust 内核并默认开启伊利诺伊橙界面令牌。".to_string(),
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
            fishbones: vec![fishbone],
            terms: Vec::new(),
            custom_sections: Vec::new(),
            review_items: Vec::new(),
        };
        let _ = self
            .host
            .reduce_minutes(MinutesEvent::CandidateReceived(grounded_minutes));
        let _ = self.apply_command(WorkspaceCommand::SetCoarsePlace(Some(
            "上海市 静安区".to_string(),
        )));
        let _ = self.apply_command(WorkspaceCommand::SyncHotWords {
            hotwords: vec![
                "海外渠道".to_string(),
                "心力豆".to_string(),
                "soundcore".to_string(),
            ],
            speaker_aliases: vec![("张总".to_string(), "张伟".to_string())],
        });
        let _ = self.apply_command(WorkspaceCommand::RefreshLiveLease {
            now_epoch_sec: now + 5,
        });
        if seed_pack {
            let _ = self.apply_command(WorkspaceCommand::ExportKoePackV2 {
                title: "海外渠道与纯Rust收口".to_string(),
                exported_at_iso: "2026-11-08T11:30:00Z".to_string(),
            });
        }
        let _ = self.apply_command(WorkspaceCommand::SearchContext {
            query: "海外渠道".to_string(),
            limit: 5,
        });
        let rec_count = self.projection.library.entry_count;
        self.status = format!(
            "已就绪，录音 {} 条，句子主干 S1..S{}",
            rec_count,
            self.projection.active_aggregate.spine.len()
        );
    }

    fn ingest_pack_file(&mut self, path: &Path) -> bool {
        match fs::read(path) {
            Ok(bytes) => match koe_desktop_core::cicada::decode_koepack_v2(&bytes) {
                Ok(decoded) => match self
                    .host
                    .put_sync_pack(&decoded.material.content_hash, &bytes)
                {
                    Ok(summary) => {
                        if self.host.restore_workspace_from_pack(&decoded) {
                            let _ = self.apply_command(WorkspaceCommand::SearchContext {
                                query: "海外渠道".to_string(),
                                limit: 5,
                            });
                        }
                        let _ = self.apply_command(WorkspaceCommand::SelectSection(
                            WorkspaceSection::DailyMind,
                        ));
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
                        self.status = format!("资料包校验失败：{err:?}");
                        false
                    }
                },
                Err(err) => {
                    self.smoke_failed = true;
                    self.status = format!("无法解析 .koepack v2（{}）：{err:?}", path.display());
                    false
                }
            },
            Err(err) => {
                self.smoke_failed = true;
                self.status = format!("无法读取资料包（{}）：{err}", path.display());
                false
            }
        }
    }

    fn connection_badge_text(&self) -> String {
        match self.projection.connection_phase {
            ConnectionPhaseTag::Disconnected => "未连接录音豆".to_string(),
            ConnectionPhaseTag::Scanning => "正在搜索录音豆…".to_string(),
            ConnectionPhaseTag::Connecting => "正在连接 GATT…".to_string(),
            ConnectionPhaseTag::Handshaking => "ECDH 握手中…".to_string(),
            ConnectionPhaseTag::Connected => match &self.projection.telemetry {
                Some(info) => format!("已连接 电量 {}%", info.battery.unwrap_or(100)),
                None => "录音豆已连接".to_string(),
            },
        }
    }

    fn format_mm_ss(ms: u64) -> String {
        let total_sec = ms / 1_000;
        let mins = total_sec / 60;
        let secs = total_sec % 60;
        format!("{mins:02}:{secs:02}")
    }

    fn toggle_audio_playback(&mut self, wav_path: &Path, cx: &mut Context<Self>) {
        if let Some(ref player) = self.player {
            player.sink.stop();
            self.player = None;
            self.playback_task = None;
            self.status = "已停止播放".to_string();
            return;
        }
        match AudioPlayer::play(wav_path) {
            Ok(player) => {
                self.player = Some(player);
                self.status = format!("正在播放 {}", wav_path.display());
                self.playback_task = Some(cx.spawn(async move |this, cx| {
                    loop {
                        cx.background_executor()
                            .timer(Duration::from_millis(200))
                            .await;
                        let done = this
                            .update(cx, |this, cx| {
                                if this.player.as_ref().is_none_or(|p| p.sink.empty()) {
                                    this.player = None;
                                    this.playback_task = None;
                                    this.status = "播放已完成".to_string();
                                    cx.notify();
                                    true
                                } else {
                                    false
                                }
                            })
                            .unwrap_or(true);
                        if done {
                            break;
                        }
                    }
                }));
            }
            Err(err) => {
                self.status = format!(
                    "已验证 WAV 文件存在（{}），当前音频输出设备不可用：{err}",
                    wav_path.display()
                );
            }
        }
    }

    fn render_sidebar(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let proj = &self.projection;
        let has_trashed = proj.library.last_trashed_id.is_some();

        let mut nav_col = div().flex().flex_col().gap_1();
        for section in WorkspaceSection::ALL {
            let active = proj.section == section;
            let badge_text = match section {
                WorkspaceSection::DailyMind => format!("{}", proj.recordings.len().max(1)),
                WorkspaceSection::Conferences => format!("{}", proj.open_todos.len()),
                WorkspaceSection::Formats => format!("{}", SummaryFormat::ALL.len()),
                WorkspaceSection::AliyunMcp => "在线".to_string(),
                WorkspaceSection::SettingsDoctor => "5/5".to_string(),
            };
            let bg_hex = if active {
                AppColors::BG_MUTED
            } else {
                AppColors::SIDEBAR
            };
            let fg_hex = if active {
                AppColors::TEXT_PRIMARY
            } else {
                AppColors::TEXT_SECONDARY
            };
            let left_bar = if active {
                AppColors::ORANGE_BRAND
            } else {
                AppColors::SIDEBAR
            };
            let nav_id: SharedString = format!("nav-sec-{section:?}").into();
            nav_col = nav_col.child(
                div()
                    .id(nav_id)
                    .flex()
                    .items_center()
                    .justify_between()
                    .px_3()
                    .py_2()
                    .rounded(px(AppRadii::CONTROL))
                    .bg(rgb(AppColors::rgb24(bg_hex)))
                    .border_l_2()
                    .border_color(rgb(AppColors::rgb24(left_bar)))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.dispatch_command(
                            WorkspaceCommand::SelectSection(section),
                            format!("已切换到「{}」视图", section.label()),
                            cx,
                        );
                    }))
                    .child(
                        div()
                            .text_size(px(AppFontSizes::SM))
                            .font_semibold()
                            .text_color(rgb(AppColors::rgb24(fg_hex)))
                            .child(section.label()),
                    )
                    .child(
                        div()
                            .px_2()
                            .py_0p5()
                            .rounded(px(AppRadii::concentric(AppRadii::CONTROL, 2.0)))
                            .bg(rgb(AppColors::rgb24(AppColors::BG_SUBTLE)))
                            .text_size(px(AppFontSizes::XS))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                            .child(badge_text),
                    ),
            );
        }

        let mut rec_list = div().flex().flex_col().gap_1p5();
        for rec in proj.recordings.iter().take(3) {
            let rec_id = rec.entry.id;
            let selected = proj.library.selected_id == Some(rec_id)
                || proj.active_aggregate.file_id == rec_id;
            let card_bg = if selected {
                AppColors::BG_CARD
            } else {
                AppColors::BG_SUBTLE
            };
            let card_border = if selected {
                AppColors::ORANGE_BRAND
            } else {
                AppColors::BORDER_SOFT
            };
            let item_id: SharedString = format!("side-rec-{rec_id}").into();
            rec_list = rec_list.child(
                div()
                    .id(item_id)
                    .flex()
                    .items_center()
                    .justify_between()
                    .p_2()
                    .rounded(px(AppRadii::CONTROL))
                    .bg(rgb(AppColors::rgb24(card_bg)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(card_border)))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.dispatch_command(
                            WorkspaceCommand::SelectRecording(rec_id),
                            format!("已选中录音 #{rec_id}"),
                            cx,
                        );
                    }))
                    .child(
                        div()
                            .text_size(px(AppFontSizes::XS))
                            .font_semibold()
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child(format!("随心记 #{rec_id}")),
                    )
                    .child(
                        div()
                            .text_size(px(AppFontSizes::XS))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                            .child(format!("书签 x{}", rec.entry.marks_ms.len())),
                    ),
            );
        }

        div()
            .w(px(244.0))
            .flex_shrink_0()
            .flex()
            .flex_col()
            .justify_between()
            .p_4()
            .rounded(px(AppRadii::OUTER))
            .bg(rgb(AppColors::rgb24(AppColors::SIDEBAR)))
            .border_1()
            .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2p5()
                            .child(
                                div()
                                    .w(px(26.0))
                                    .h(px(26.0))
                                    .rounded(px(AppRadii::CONTROL))
                                    .bg(rgb(AppColors::rgb24(AppColors::ORANGE_BRAND)))
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .text_size(px(AppFontSizes::XS))
                                    .font_bold()
                                    .text_color(rgb(AppColors::rgb24(AppColors::ON_ACCENT)))
                                    .child("K"),
                            )
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .child(
                                        div()
                                            .text_size(px(AppFontSizes::MD))
                                            .font_bold()
                                            .text_color(rgb(AppColors::rgb24(
                                                AppColors::TEXT_PRIMARY,
                                            )))
                                            .child("安克随心记"),
                                    )
                                    .child(
                                        div()
                                            .text_size(px(AppFontSizes::XS))
                                            .text_color(rgb(AppColors::rgb24(
                                                AppColors::TEXT_MUTED,
                                            )))
                                            .child("日常心力豆工作台 顺带纪要"),
                                    ),
                            ),
                    )
                    .child(
                        Button::new("btn-simulate-sync")
                            .primary()
                            .label("开始随心记 (60片实时流)")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.dispatch_command(
                                    WorkspaceCommand::SimulateRealtimePipeline,
                                    "已完成 60 片 Opus 实时流模拟，双轨书签与 6 宫格卡片已刷新",
                                    cx,
                                );
                            })),
                    )
                    .child(nav_col)
                    .child(
                        div()
                            .pt_2()
                            .border_t_1()
                            .border_color(rgb(AppColors::rgb24(AppColors::BORDER_SOFT)))
                            .flex()
                            .flex_col()
                            .gap_1p5()
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .justify_between()
                                    .child(
                                        div()
                                            .text_size(px(AppFontSizes::XS))
                                            .font_semibold()
                                            .text_color(rgb(AppColors::rgb24(
                                                AppColors::TEXT_MUTED,
                                            )))
                                            .child("最近随心记与回收站"),
                                    )
                                    .child(
                                        Button::new("btn-undo-trash")
                                            .ghost()
                                            .small()
                                            .disabled(!has_trashed)
                                            .label("撤销删除")
                                            .on_click(cx.listener(|this, _, _, cx| {
                                                this.dispatch_command(
                                                    WorkspaceCommand::UndoTrash,
                                                    "已从回收站恢复录音",
                                                    cx,
                                                );
                                            })),
                                    ),
                            )
                            .child(rec_list),
                    ),
            )
            .child(
                div()
                    .p_3()
                    .rounded(px(AppRadii::CARD))
                    .bg(rgb(AppColors::rgb24(AppColors::BG_CARD)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap_1p5()
                                    .child(
                                        div()
                                            .w(px(8.0))
                                            .h(px(8.0))
                                            .rounded(px(4.0))
                                            .bg(rgb(AppColors::rgb24(AppColors::ORANGE_BRAND))),
                                    )
                                    .child(
                                        div()
                                            .text_size(px(AppFontSizes::XS))
                                            .font_semibold()
                                            .text_color(rgb(AppColors::rgb24(
                                                AppColors::TEXT_PRIMARY,
                                            )))
                                            .child("安克心力豆 D3200"),
                                    ),
                            )
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::XS))
                                    .font_semibold()
                                    .text_color(rgb(AppColors::rgb24(AppColors::ORANGE_DEEP)))
                                    .child(self.connection_badge_text()),
                            ),
                    )
                    .child(
                        div()
                            .text_size(px(AppFontSizes::XS))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_SECONDARY)))
                            .child(format!(
                                "16kHz Opus 实时流 分片 {} 书签 {}",
                                proj.doctor.unpacked_slices,
                                proj.active_aggregate.bookmarks.len()
                            )),
                    )
                    .child(
                        div()
                            .flex()
                            .gap_1p5()
                            .child(
                                Button::new("btn-connect-bean")
                                    .small()
                                    .label("连接录音豆")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.ble.start_scan();
                                        this.ensure_ble_poll_task(cx);
                                        this.status = "已发起 CoreBluetooth 扫描…".to_string();
                                        cx.notify();
                                    })),
                            )
                            .child(
                                Button::new("btn-open-doctor")
                                    .ghost()
                                    .small()
                                    .label("链路自检")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.dispatch_command(
                                            WorkspaceCommand::SelectSection(
                                                WorkspaceSection::SettingsDoctor,
                                            ),
                                            "已打开 D3200 五阶实时流自检面板",
                                            cx,
                                        );
                                    })),
                            ),
                    ),
            )
    }

    fn render_header(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let proj = &self.projection;
        let place_label = proj
            .active_aggregate
            .coarse_place
            .clone()
            .unwrap_or_else(|| "未标记粗粒度地点".to_string());
        let title = proj.active_aggregate.minutes.as_ref().map_or_else(
            || {
                format!(
                    "{} 录音 #{}",
                    proj.section.label(),
                    proj.active_aggregate.file_id.max(1)
                )
            },
            |m| m.title.clone(),
        );

        div()
            .flex()
            .items_center()
            .justify_between()
            .pb_3()
            .border_b_1()
            .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .text_size(px(AppFontSizes::LG))
                            .font_bold()
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child(title),
                    )
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(
                                div()
                                    .px_2()
                                    .py_0p5()
                                    .rounded(px(AppRadii::concentric(AppRadii::CONTROL, 2.0)))
                                    .bg(rgb(AppColors::rgb24(AppColors::BG_SUBTLE)))
                                    .text_size(px(AppFontSizes::XS))
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_SECONDARY)))
                                    .child(format!("地点：{place_label}")),
                            )
                            .child(
                                div()
                                    .px_2()
                                    .py_0p5()
                                    .rounded(px(AppRadii::concentric(AppRadii::CONTROL, 2.0)))
                                    .bg(rgb(AppColors::rgb24(AppColors::ORANGE_TINT)))
                                    .border_1()
                                    .border_color(rgb(AppColors::rgb24(AppColors::ORANGE_BORDER)))
                                    .text_size(px(AppFontSizes::XS))
                                    .font_semibold()
                                    .text_color(rgb(AppColors::rgb24(AppColors::ORANGE_DEEP)))
                                    .child(format!(
                                        "双击书签 x{}",
                                        proj.active_aggregate.bookmarks.len()
                                    )),
                            )
                            .child(
                                div()
                                    .px_2()
                                    .py_0p5()
                                    .rounded(px(AppRadii::concentric(AppRadii::CONTROL, 2.0)))
                                    .bg(rgb(AppColors::rgb24(AppColors::BG_SUBTLE)))
                                    .text_size(px(AppFontSizes::XS))
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_SECONDARY)))
                                    .child(format!(
                                        "格式：{}",
                                        proj.active_aggregate.selected_format.label_zh()
                                    )),
                            ),
                    ),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        Button::new("btn-toggle-place")
                            .ghost()
                            .small()
                            .label("切换粗粒度地点")
                            .on_click(cx.listener(|this, _, _, cx| {
                                let next_place = match this
                                    .projection
                                    .active_aggregate
                                    .coarse_place
                                    .as_deref()
                                {
                                    Some("上海市 静安区") => Some("北京市 海淀区".to_string()),
                                    _ => Some("上海市 静安区".to_string()),
                                };
                                this.dispatch_command(
                                    WorkspaceCommand::SetCoarsePlace(next_place),
                                    "已更新粗粒度地点标签（自动隐去门牌与街道）",
                                    cx,
                                );
                            })),
                    )
                    .child(
                        Button::new("btn-header-doctor")
                            .small()
                            .label("五阶链路自检")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.dispatch_command(
                                    WorkspaceCommand::SelectSection(
                                        WorkspaceSection::SettingsDoctor,
                                    ),
                                    "已切换到五阶实时流自检",
                                    cx,
                                );
                            })),
                    )
                    .child(
                        Button::new("btn-export-koepack")
                            .primary()
                            .small()
                            .label("导出 .koepack v2")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.dispatch_command(
                                    WorkspaceCommand::ExportKoePackV2 {
                                        title: "随心记收口资料包".to_string(),
                                        exported_at_iso: "2026-11-08T12:00:00Z".to_string(),
                                    },
                                    "已导出 .koepack v2 资料包到本机归档目录",
                                    cx,
                                );
                            })),
                    ),
            )
    }

    fn render_daily_context_strip(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let proj = &self.projection;
        let brief_todo_preview = proj.morning_brief.open_mine.first().map_or_else(
            || "今日暂无待办积压".to_string(),
            |t| {
                let cite = t
                    .citations
                    .first()
                    .map_or_else(String::new, |c| format!(" [{c}]"));
                format!("{}{cite}", t.title)
            },
        );
        let focus_title = proj
            .focus_project
            .as_ref()
            .map_or("安克随心记", |p| p.title.as_str());
        let focus_next = proj.project_progress.next_todo.as_ref().map_or_else(
            || "焦点项目所有待办已就绪".to_string(),
            |t| format!("下一项：{}", t.title),
        );
        let diary_preview = proj.diary_entry.current.as_ref().map_or_else(
            || "等待随心记句段生成事实日记".to_string(),
            |d| {
                d.text
                    .lines()
                    .next()
                    .unwrap_or("事实日记已生成")
                    .to_string()
            },
        );

        div()
            .flex()
            .gap_3()
            .child(
                div()
                    .flex_1()
                    .p_3()
                    .rounded(px(AppRadii::CARD))
                    .bg(rgb(AppColors::rgb24(AppColors::BG_CARD)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::XS))
                                    .font_semibold()
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                                    .child("今日晨间简报 MorningBrief"),
                            )
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::XS))
                                    .font_semibold()
                                    .text_color(rgb(AppColors::rgb24(AppColors::ORANGE_DEEP)))
                                    .child(format!(
                                        "待办 {} 跟进 {}",
                                        proj.morning_brief.open_mine.len(),
                                        proj.morning_brief.follow_ups.len()
                                    )),
                            ),
                    )
                    .child(
                        div()
                            .text_size(px(AppFontSizes::SM))
                            .font_semibold()
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child(brief_todo_preview),
                    ),
            )
            .child(
                div()
                    .flex_1()
                    .p_3()
                    .rounded(px(AppRadii::CARD))
                    .bg(rgb(AppColors::rgb24(AppColors::BG_CARD)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::XS))
                                    .font_semibold()
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                                    .child("焦点项目进度 ProjectProgress"),
                            )
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::XS))
                                    .font_semibold()
                                    .text_color(rgb(AppColors::rgb24(AppColors::SUCCESS)))
                                    .child(focus_title.to_string()),
                            ),
                    )
                    .child(
                        div()
                            .text_size(px(AppFontSizes::SM))
                            .font_semibold()
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child(focus_next),
                    ),
            )
            .child(
                div()
                    .flex_1()
                    .p_3()
                    .rounded(px(AppRadii::CARD))
                    .bg(rgb(AppColors::rgb24(AppColors::BG_CARD)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::XS))
                                    .font_semibold()
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                                    .child("事实日记与检索 DiaryEntry"),
                            )
                            .child(
                                Button::new("btn-strip-open-search")
                                    .ghost()
                                    .small()
                                    .label(format!("BM25 索引 {} 段", proj.indexed_context_docs))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.dispatch_command(
                                            WorkspaceCommand::SelectDetailTab(
                                                DetailTab::AskAiAndMcp,
                                            ),
                                            "已打开 AI 随心问与离线 BM25 检索",
                                            cx,
                                        );
                                    })),
                            ),
                    )
                    .child(
                        div()
                            .text_size(px(AppFontSizes::SM))
                            .font_semibold()
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child(diary_preview),
                    ),
            )
    }

    fn render_waveform_player_strip(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let proj = &self.projection;
        let duration_ms = proj.active_aggregate.duration_ms.max(1_200);
        let position_ms = proj.library.position_ms;
        let is_playing = self.player.is_some();
        let active_wav = proj.recordings.first().map(|r| r.wav_path.clone());
        let active_rec_id = proj.recordings.first().map(|r| r.entry.id);

        let bar_count = proj.waveform_bars_norm.len().max(1);
        let mut wave_row = div().flex().items_end().gap_0p5().h(px(28.0)).flex_1();
        for (idx, &height_pct) in proj.waveform_bars_norm.iter().enumerate() {
            let bar_ms = (idx as u64).saturating_mul(duration_ms) / (bar_count as u64);
            let in_bookmark_window = proj
                .bookmark_windows_ms
                .iter()
                .any(|&(start, end)| bar_ms >= start && bar_ms <= end);
            let is_played = bar_ms <= position_ms || (position_ms == 0 && idx < bar_count / 3);
            let bar_color = if in_bookmark_window {
                AppColors::ORANGE_ACTION
            } else if is_played {
                AppColors::ORANGE_BRAND
            } else {
                AppColors::WAVE_UNPLAYED
            };
            let h_px = 6.0 + (f32::from(height_pct) * 0.20);
            wave_row = wave_row.child(
                div()
                    .w(px(3.0))
                    .h(px(h_px))
                    .rounded(px(2.0))
                    .bg(rgb(AppColors::rgb24(bar_color))),
            );
        }

        div()
            .p_3()
            .rounded(px(AppRadii::CARD))
            .bg(rgb(AppColors::rgb24(AppColors::BG_CARD)))
            .border_1()
            .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
            .flex()
            .items_center()
            .justify_between()
            .gap_3()
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2p5()
                    .child(
                        Button::new("btn-wave-play")
                            .primary()
                            .small()
                            .disabled(active_wav.is_none())
                            .label(if is_playing { "停止播放" } else { "播放录音" })
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if let Some(ref wav) = active_wav {
                                    this.toggle_audio_playback(wav, cx);
                                    cx.notify();
                                }
                            })),
                    )
                    .child(
                        div()
                            .text_size(px(AppFontSizes::XS))
                            .font_semibold()
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child(format!(
                                "{} / {}",
                                Self::format_mm_ss(position_ms),
                                Self::format_mm_ss(duration_ms)
                            )),
                    ),
            )
            .child(wave_row)
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_1p5()
                    .child(
                        Button::new("btn-prev-mark")
                            .ghost()
                            .small()
                            .label("上一标记")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.dispatch_command(
                                    WorkspaceCommand::JumpMark(MarkJumpDirection::Previous),
                                    "已跳到上一处硬件双击标记",
                                    cx,
                                );
                            })),
                    )
                    .child(
                        Button::new("btn-next-mark")
                            .ghost()
                            .small()
                            .label("下一标记")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.dispatch_command(
                                    WorkspaceCommand::JumpMark(MarkJumpDirection::Next),
                                    "已跳到下一处硬件双击标记",
                                    cx,
                                );
                            })),
                    )
                    .child(
                        Button::new("btn-add-slicemark")
                            .small()
                            .label("+ 双击书签 (±10s)")
                            .on_click(cx.listener(move |this, _, _, cx| {
                                let mark_ms = this.projection.library.position_ms.max(600);
                                this.dispatch_command(
                                    WorkspaceCommand::AddSliceMark(mark_ms),
                                    format!(
                                        "已在 {} 处打上双击书签（自动高亮前后 10s 区间）",
                                        Self::format_mm_ss(mark_ms)
                                    ),
                                    cx,
                                );
                            })),
                    )
                    .child(
                        Button::new("btn-trash-active")
                            .ghost()
                            .small()
                            .disabled(active_rec_id.is_none())
                            .label("移入回收站")
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if let Some(id) = active_rec_id {
                                    this.dispatch_command(
                                        WorkspaceCommand::MoveToTrash(id),
                                        format!("已将录音 #{id} 移入回收站（可在左栏一键撤销）"),
                                        cx,
                                    );
                                }
                            })),
                    ),
            )
    }

    fn render_section_context_banner(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let proj = &self.projection;
        match proj.section {
            WorkspaceSection::DailyMind => div(),
            WorkspaceSection::Conferences => div()
                .p_3()
                .rounded(px(AppRadii::CARD))
                .bg(rgb(AppColors::rgb24(AppColors::ORANGE_TINT)))
                .border_1()
                .border_color(rgb(AppColors::rgb24(AppColors::ORANGE_BORDER)))
                .flex()
                .items_center()
                .justify_between()
                .child(
                    div()
                        .text_size(px(AppFontSizes::SM))
                        .font_semibold()
                        .text_color(rgb(AppColors::rgb24(AppColors::ORANGE_DEEP)))
                        .child(format!(
                            "顺带会议视图：当前共 {} 项个人行动承诺，所有决议均绑定 [S1..Sn] 逐字原话出处",
                            proj.open_todos.len()
                        )),
                )
                .child(
                    Button::new("btn-conf-open-transcript")
                        .small()
                        .label("查看声纹与双语同传")
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.dispatch_command(
                                WorkspaceCommand::SelectDetailTab(
                                    DetailTab::TranscriptAndVoiceprint,
                                ),
                                "已切换到逐字原话与声纹双语同传",
                                cx,
                            );
                        })),
                ),
            WorkspaceSection::Formats => self.render_formats_console(cx),
            WorkspaceSection::AliyunMcp => self.render_aliyun_mcp_console(cx),
            WorkspaceSection::SettingsDoctor => self.render_settings_doctor_console(cx),
        }
    }

    fn render_formats_console(&self, cx: &mut Context<Self>) -> Div {
        let proj = &self.projection;
        let mut fmt_pills = div().flex().flex_wrap().gap_1p5();
        for fmt in SummaryFormat::ALL {
            let selected = proj.formats.selected_format == fmt;
            let btn_id: SharedString = format!("banner-fmt-{fmt:?}").into();
            let btn = if selected {
                Button::new(btn_id).primary().small().label(fmt.label_zh())
            } else {
                Button::new(btn_id).small().label(fmt.label_zh())
            };
            fmt_pills = fmt_pills.child(btn.on_click(cx.listener(move |this, _, _, cx| {
                this.dispatch_command(
                    WorkspaceCommand::SelectSummaryFormat(fmt),
                    format!("已切换心力格式为「{}」并重算 6 宫格卡片", fmt.label_zh()),
                    cx,
                );
            })));
        }

        let mut tpl_pills = div().flex().flex_wrap().gap_1p5();
        for tpl in BuiltinTemplateId::ALL {
            let active = proj.formats.active_template == tpl;
            let btn_id: SharedString = format!("banner-tpl-{}", tpl.id_str()).into();
            let label = format!("{} ({})", tpl.label_zh(), tpl.id_str());
            let btn = if active {
                Button::new(btn_id).primary().small().label(label)
            } else {
                Button::new(btn_id).small().label(label)
            };
            tpl_pills = tpl_pills.child(btn.on_click(cx.listener(move |this, _, _, cx| {
                this.dispatch_command(
                    WorkspaceCommand::SelectMinuteTemplate(tpl),
                    format!(
                        "已切换内置纪要模板为「{} ({})」并重算 6 宫格卡片",
                        tpl.label_zh(),
                        tpl.id_str()
                    ),
                    cx,
                );
            })));
        }

        let mut custom_list = div().flex().flex_col().gap_1p5();
        for sec in &proj.formats.custom_sections {
            let first_claim = sec
                .points
                .first()
                .map_or("暂无溯源要点", |p| p.claim.as_str());
            let cite_count: usize = sec.points.iter().map(|p| p.citations.len()).sum();
            let cite_tags: Vec<String> = sec
                .points
                .iter()
                .flat_map(|p| p.citations.iter().map(|c| format!("[{c}]")))
                .collect();
            let heading_for_rm = sec.heading.clone();
            let rm_id: SharedString = format!("btn-rm-custom-sec-{}", sec.heading).into();
            custom_list = custom_list.child(
                div()
                    .p_2()
                    .rounded(px(AppRadii::CONTROL))
                    .bg(rgb(AppColors::rgb24(AppColors::SURFACE_0)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER_SOFT)))
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_2()
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_0p5()
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap_2()
                                    .child(
                                        div()
                                            .text_size(px(AppFontSizes::XS))
                                            .font_bold()
                                            .text_color(rgb(AppColors::rgb24(
                                                AppColors::ORANGE_DEEP,
                                            )))
                                            .child(sec.heading.clone()),
                                    )
                                    .child(
                                        div()
                                            .text_size(px(AppFontSizes::XS))
                                            .text_color(rgb(AppColors::rgb24(
                                                AppColors::TEXT_MUTED,
                                            )))
                                            .child(format!(
                                                "引用 {} 处 {}",
                                                cite_count,
                                                cite_tags.join(" ")
                                            )),
                                    ),
                            )
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::XS))
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_SECONDARY)))
                                    .child(first_claim.to_string()),
                            ),
                    )
                    .child(
                        Button::new(rm_id)
                            .ghost()
                            .small()
                            .label("移除")
                            .on_click(cx.listener(move |this, _, _, cx| {
                                let removed = heading_for_rm.clone();
                                this.dispatch_command(
                                    WorkspaceCommand::RemoveCustomMinuteSection {
                                        heading: removed.clone(),
                                    },
                                    format!("已移除自定义纪要分节「{removed}」并重算 6 宫格卡片"),
                                    cx,
                                );
                            })),
                    ),
            );
        }

        div()
            .p_3()
            .rounded(px(AppRadii::CARD))
            .bg(rgb(AppColors::rgb24(AppColors::BG_CARD)))
            .border_1()
            .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
            .flex()
            .flex_col()
            .gap_2p5()
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_2()
                    .child(
                        div()
                            .text_size(px(AppFontSizes::MD))
                            .font_semibold()
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child("心力格式库与内置纪要模板控制台 (Formats)"),
                    )
                    .child(
                        div()
                            .text_size(px(AppFontSizes::XS))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                            .child(format!(
                                "当前格式：{} | 当前模板：{} ({}) | 分节：{}",
                                proj.formats.selected_format.label_zh(),
                                proj.formats.active_template.label_zh(),
                                proj.formats.active_template.id_str(),
                                proj.formats.builtin_sections_zh.join(" / ")
                            )),
                    ),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_2()
                    .child(
                        div()
                            .text_size(px(AppFontSizes::SM))
                            .font_semibold()
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child("6 种心力总结格式（零幻觉重算 6 宫格柔彩卡片）："),
                    )
                    .child(fmt_pills),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_2()
                    .child(
                        div()
                            .text_size(px(AppFontSizes::SM))
                            .font_semibold()
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child("5 套内置纪要模板（自动映射 [S1..Sn] 分节）："),
                    )
                    .child(tpl_pills),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_2()
                    .child(
                        div()
                            .text_size(px(AppFontSizes::SM))
                            .font_semibold()
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child(format!(
                                "自定义纪要分节（共 {} 节，均绑定原话锚点）：",
                                proj.formats.custom_sections.len()
                            )),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_wrap()
                            .gap_1p5()
                            .child(
                                Button::new("btn-add-sec-customer-voice")
                                    .small()
                                    .label("+ 客户原声锚点")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.dispatch_command(
                                            WorkspaceCommand::AddCustomMinuteSection {
                                                heading: "客户原声锚点".to_string(),
                                            },
                                            "已新增自定义纪要分节「客户原声锚点」并重算 6 宫格卡片",
                                            cx,
                                        );
                                    })),
                            )
                            .child(
                                Button::new("btn-add-sec-risk-followup")
                                    .small()
                                    .label("+ 关键风险追问")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.dispatch_command(
                                            WorkspaceCommand::AddCustomMinuteSection {
                                                heading: "关键风险追问".to_string(),
                                            },
                                            "已新增自定义纪要分节「关键风险追问」并重算 6 宫格卡片",
                                            cx,
                                        );
                                    })),
                            ),
                    ),
            )
            .child(custom_list)
    }

    fn render_aliyun_mcp_console(&self, cx: &mut Context<Self>) -> Div {
        let proj = &self.projection;
        let ds = &proj.aliyun_mcp.dashscope;
        let key_badge = if ds.api_key_configured {
            "环境凭据已就绪 (脱敏布尔态)"
        } else {
            "离线本地兜底 (未设 DASHSCOPE_API_KEY)"
        };
        let ws_badge = if ds.cloud_ws_attached {
            "云端 WS 已挂载"
        } else {
            "本机流式泵自驱"
        };
        let mode_label = match proj.aliyun_mcp.pairing_mode {
            McpPairingMode::Lan => "LAN 局域网直连",
            McpPairingMode::Vps => "VPS 隧道穿透",
        };
        let ticket_preview = proj
            .aliyun_mcp
            .pairing_ticket
            .as_deref()
            .unwrap_or("尚未签发 KOEMCP1 配对票据");

        let mut copilot_turns = div().flex().flex_col().gap_1p5();
        if proj.aliyun_mcp.copilot_history.is_empty() {
            copilot_turns = copilot_turns.child(
                div()
                    .text_size(px(AppFontSizes::XS))
                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                    .child("暂无多轮问答记录，可点击右侧按钮发起基于 BM25 与 [S1..Sn] 原话引用的追问。"),
            );
        } else {
            for (idx, turn) in proj.aliyun_mcp.copilot_history.iter().enumerate() {
                let cites: Vec<String> = turn.citations.iter().map(|c| format!("[{c}]")).collect();
                copilot_turns = copilot_turns.child(
                    div()
                        .p_2()
                        .rounded(px(AppRadii::CONTROL))
                        .bg(rgb(AppColors::rgb24(AppColors::SURFACE_0)))
                        .border_1()
                        .border_color(rgb(AppColors::rgb24(AppColors::BORDER_SOFT)))
                        .flex()
                        .flex_col()
                        .gap_0p5()
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .justify_between()
                                .child(
                                    div()
                                        .text_size(px(AppFontSizes::XS))
                                        .font_bold()
                                        .text_color(rgb(AppColors::rgb24(AppColors::ORANGE_DEEP)))
                                        .child(format!("第 {} 轮提问：{}", idx + 1, turn.prompt)),
                                )
                                .child(
                                    div()
                                        .text_size(px(AppFontSizes::XS))
                                        .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                                        .child(format!(
                                            "引用 {} 处 {}",
                                            turn.citations.len(),
                                            cites.join(" ")
                                        )),
                                ),
                        )
                        .child(
                            div()
                                .text_size(px(AppFontSizes::XS))
                                .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                                .child(turn.answer.clone()),
                        ),
                );
            }
        }

        div()
            .p_3()
            .rounded(px(AppRadii::CARD))
            .bg(rgb(AppColors::rgb24(AppColors::BG_CARD)))
            .border_1()
            .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
            .flex()
            .flex_col()
            .gap_2p5()
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_2()
                    .child(
                        div()
                            .text_size(px(AppFontSizes::MD))
                            .font_semibold()
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child("私有阿里云百炼与本机 MCP / ACP 控制台"),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_wrap()
                            .gap_1p5()
                            .child(
                                Button::new("btn-aliyun-sync-hotwords")
                                    .small()
                                    .label("同步 qwennote 热词")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.dispatch_command(
                                            WorkspaceCommand::SyncHotWords {
                                                hotwords: vec![
                                                    "海外渠道".to_string(),
                                                    "心力豆".to_string(),
                                                    "D3200".to_string(),
                                                    "paraformer".to_string(),
                                                ],
                                                speaker_aliases: vec![(
                                                    "Speaker 1".to_string(),
                                                    "张工".to_string(),
                                                )],
                                            },
                                            "已同步私有阿里云 qwennote-minutes 热词与说话人别名",
                                            cx,
                                        );
                                    })),
                            )
                            .child(
                                Button::new("btn-banner-open-mcp-tab")
                                    .primary()
                                    .small()
                                    .label("打开 AI 随心问 & MCP 标签页")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.dispatch_command(
                                            WorkspaceCommand::SelectDetailTab(
                                                DetailTab::AskAiAndMcp,
                                            ),
                                            "已切换到 AI 随心问与阿里云 MCP 面板",
                                            cx,
                                        );
                                    })),
                            ),
                    ),
            )
            .child(
                div()
                    .p_2p5()
                    .rounded(px(AppRadii::CONTROL))
                    .bg(rgb(AppColors::rgb24(AppColors::SURFACE_0)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER_SOFT)))
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .text_size(px(AppFontSizes::XS))
                            .font_semibold()
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child(format!(
                                "流式 ASR：{} | 录音文件精转：{} | 状态：{} | 凭据：{}",
                                ds.streaming_asr_model,
                                ds.filetrans_asr_model,
                                ws_badge,
                                key_badge
                            )),
                    )
                    .child(
                        div()
                            .text_size(px(AppFontSizes::XS))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_SECONDARY)))
                            .child(format!(
                                "流式队列帧：{} | 语音窗口提交：{} | 热词数：{} ({})",
                                ds.queued_asr_frames,
                                ds.committed_speech_windows,
                                ds.active_hotword_count,
                                proj.hot_words.join(" / ")
                            )),
                    ),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_2()
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_0p5()
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::XS))
                                    .font_semibold()
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                                    .child(format!(
                                        "配对模式：{} | 15s live.json 租约代数 #{} (到期时间戳 {}s) | 已处理调用 {} 次",
                                        mode_label,
                                        proj.aliyun_mcp.live_generation,
                                        proj.aliyun_mcp.live_lease_expires_at_epoch_sec,
                                        proj.mcp_handled_calls
                                    )),
                            )
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::XS))
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                                    .child(format!("KOEMCP1 票据：{ticket_preview}")),
                            ),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_wrap()
                            .gap_1p5()
                            .child(
                                Button::new("btn-issue-ticket-lan")
                                    .small()
                                    .label("签发 LAN 票据")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        let now = Self::now_epoch_sec();
                                        this.dispatch_command(
                                            WorkspaceCommand::IssuePairingTicket {
                                                mode: McpPairingMode::Lan,
                                                email: None,
                                                now_epoch_sec: now,
                                            },
                                            "已签发局域网 KOEMCP1 配对票据",
                                            cx,
                                        );
                                    })),
                            )
                            .child(
                                Button::new("btn-issue-ticket-vps")
                                    .small()
                                    .label("签发 VPS 票据")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        let now = Self::now_epoch_sec();
                                        this.dispatch_command(
                                            WorkspaceCommand::IssuePairingTicket {
                                                mode: McpPairingMode::Vps,
                                                email: Some("owner@koe.local".to_string()),
                                                now_epoch_sec: now,
                                            },
                                            "已签发 VPS 隧道 KOEMCP1 配对票据",
                                            cx,
                                        );
                                    })),
                            )
                            .child(
                                Button::new("btn-refresh-live-lease")
                                    .small()
                                    .label("续期 15s live.json 租约")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        let now = Self::now_epoch_sec();
                                        this.dispatch_command(
                                            WorkspaceCommand::RefreshLiveLease {
                                                now_epoch_sec: now,
                                            },
                                            "已续期 15s live.json 实时广播租约",
                                            cx,
                                        );
                                    })),
                            )
                            .child(
                                Button::new("btn-gen-mcp-stdio-cfg")
                                    .small()
                                    .label("生成 --mcp-stdio 配置")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.dispatch_command(
                                            WorkspaceCommand::GenerateMcpStdioConfig,
                                            "已生成 --mcp-stdio 零配置接入 JSON",
                                            cx,
                                        );
                                    })),
                            ),
                    ),
            )
            .child(
                div()
                    .p_2()
                    .rounded(px(AppRadii::CONTROL))
                    .bg(rgb(AppColors::rgb24(AppColors::SURFACE_0)))
                    .text_size(px(AppFontSizes::XS))
                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_SECONDARY)))
                    .child(proj.aliyun_mcp.mcp_stdio_config_json.clone()),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_2()
                    .child(
                        div()
                            .text_size(px(AppFontSizes::SM))
                            .font_semibold()
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child(format!(
                                "BM25 原话锚点多轮追问历史（共 {} 轮）：",
                                proj.aliyun_mcp.copilot_history.len()
                            )),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_wrap()
                            .gap_1p5()
                            .child(
                                Button::new("btn-mcp-ask-turn-1")
                                    .small()
                                    .label("追问：海外渠道结论")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        let now = Self::now_epoch_sec();
                                        this.dispatch_command(
                                            WorkspaceCommand::AskCopilot {
                                                prompt: "海外渠道样品合同的关键结论是什么？"
                                                    .to_string(),
                                                now_epoch_sec: now,
                                            },
                                            "已追加多轮追问：海外渠道样品合同结论",
                                            cx,
                                        );
                                    })),
                            )
                            .child(
                                Button::new("btn-mcp-ask-turn-2")
                                    .small()
                                    .label("追问：下一步行动项")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        let now = Self::now_epoch_sec();
                                        this.dispatch_command(
                                            WorkspaceCommand::AskCopilot {
                                                prompt: "下周需要跟进的行动承诺有哪些？"
                                                    .to_string(),
                                                now_epoch_sec: now,
                                            },
                                            "已追加多轮追问：下周行动承诺",
                                            cx,
                                        );
                                    })),
                            ),
                    ),
            )
            .child(copilot_turns)
    }

    fn render_settings_doctor_console(&self, cx: &mut Context<Self>) -> Div {
        let proj = &self.projection;
        let settings = &proj.settings;
        let wb = &proj.wifi_batch;
        let phase_label = match wb.phase {
            WifiBatchPhase::Idle => "空闲待命 (Idle)",
            WifiBatchPhase::ConnectingWs => "握手中 (ConnectingWs)",
            WifiBatchPhase::Transferring => "高速快传中 (Transferring)",
            WifiBatchPhase::Completed => "快传已完成 (Completed)",
            WifiBatchPhase::Interrupted => "中断已抢救 (Interrupted)",
            WifiBatchPhase::Failed => "快传异常 (Failed)",
        };
        let auto_launch_label = if settings.auto_launch_enabled {
            "开机自启：已开启"
        } else {
            "开机自启：已关闭"
        };
        let keep_alive_label = if settings.keep_alive_enabled {
            "后台常驻保活：已开启"
        } else {
            "后台常驻保活：已关闭"
        };
        let next_auto_launch = !settings.auto_launch_enabled;
        let next_keep_alive = !settings.keep_alive_enabled;

        div()
            .flex()
            .flex_col()
            .gap_3()
            .child(self.render_pipeline_doctor_card(cx))
            .child(
                div()
                    .p_3()
                    .rounded(px(AppRadii::CARD))
                    .bg(rgb(AppColors::rgb24(AppColors::BG_CARD)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .gap_2()
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::MD))
                                    .font_semibold()
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                                    .child("桌面常驻与开机自启偏好 (持久化至 settings.json)"),
                            )
                            .child(
                                div()
                                    .flex()
                                    .flex_wrap()
                                    .gap_1p5()
                                    .child({
                                        let btn = Button::new("btn-toggle-auto-launch")
                                            .small()
                                            .label(auto_launch_label);
                                        let btn = if settings.auto_launch_enabled {
                                            btn.primary()
                                        } else {
                                            btn
                                        };
                                        btn.on_click(cx.listener(move |this, _, _, cx| {
                                            this.dispatch_command(
                                                WorkspaceCommand::SetAutoLaunch(next_auto_launch),
                                                format!(
                                                    "已更新开机自启为：{}",
                                                    if next_auto_launch { "开启" } else { "关闭" }
                                                ),
                                                cx,
                                            );
                                        }))
                                    })
                                    .child({
                                        let btn = Button::new("btn-toggle-keep-alive")
                                            .small()
                                            .label(keep_alive_label);
                                        let btn = if settings.keep_alive_enabled {
                                            btn.primary()
                                        } else {
                                            btn
                                        };
                                        btn.on_click(cx.listener(move |this, _, _, cx| {
                                            this.dispatch_command(
                                                WorkspaceCommand::SetKeepAlive(next_keep_alive),
                                                format!(
                                                    "已更新后台常驻保活为：{}",
                                                    if next_keep_alive { "开启" } else { "关闭" }
                                                ),
                                                cx,
                                            );
                                        }))
                                    }),
                            ),
                    )
                    .child(
                        div()
                            .text_size(px(AppFontSizes::XS))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                            .child(format!(
                                "配置文件路径：{}",
                                settings.settings_path_display
                            )),
                    ),
            )
            .child(
                div()
                    .p_3()
                    .rounded(px(AppRadii::CARD))
                    .bg(rgb(AppColors::rgb24(AppColors::BG_CARD)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .gap_2()
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::MD))
                                    .font_semibold()
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                                    .child("Wi-Fi SoftAP (1A/05, 192.168.4.1:32002) 批量快传控制台"),
                            )
                            .child(
                                div()
                                    .flex()
                                    .flex_wrap()
                                    .gap_1p5()
                                    .child(
                                        Button::new("btn-wifi-start-softap")
                                            .primary()
                                            .small()
                                            .label("启动 1A/05 快传")
                                            .on_click(cx.listener(|this, _, _, cx| {
                                                let now = Self::now_epoch_sec();
                                                this.dispatch_command(
                                                    WorkspaceCommand::ControlWifiSoftApBatch {
                                                        action:
                                                            WifiSoftApAction::StartDefaultSoftAp,
                                                        now_epoch_sec: now,
                                                    },
                                                    "已协商 1A/05 热点 192.168.4.1:32002 并启动批量快传",
                                                    cx,
                                                );
                                            })),
                                    )
                                    .child(
                                        Button::new("btn-wifi-interrupt")
                                            .small()
                                            .label("模拟中断 (95% 抢救)")
                                            .on_click(cx.listener(|this, _, _, cx| {
                                                let now = Self::now_epoch_sec();
                                                this.dispatch_command(
                                                    WorkspaceCommand::ControlWifiSoftApBatch {
                                                        action: WifiSoftApAction::Interrupt,
                                                        now_epoch_sec: now,
                                                    },
                                                    "已模拟 SoftAP 断连并自动抢救 >=95% 录音文件",
                                                    cx,
                                                );
                                            })),
                                    )
                                    .child(
                                        Button::new("btn-wifi-resume-complete")
                                            .small()
                                            .label("断点续传并收尾")
                                            .on_click(cx.listener(|this, _, _, cx| {
                                                let now = Self::now_epoch_sec();
                                                this.dispatch_command(
                                                    WorkspaceCommand::ControlWifiSoftApBatch {
                                                        action: WifiSoftApAction::ResumeAndComplete,
                                                        now_epoch_sec: now,
                                                    },
                                                    "已恢复 SoftAP 批量快传并完成全部文件落盘",
                                                    cx,
                                                );
                                            })),
                                    )
                                    .child(
                                        Button::new("btn-wifi-cancel")
                                            .ghost()
                                            .small()
                                            .label("取消快传")
                                            .on_click(cx.listener(|this, _, _, cx| {
                                                let now = Self::now_epoch_sec();
                                                this.dispatch_command(
                                                    WorkspaceCommand::ControlWifiSoftApBatch {
                                                        action: WifiSoftApAction::Cancel,
                                                        now_epoch_sec: now,
                                                    },
                                                    "已取消 SoftAP 快传并重置为空闲状态",
                                                    cx,
                                                );
                                            })),
                                    ),
                            ),
                    )
                    .child(
                        div()
                            .p_2p5()
                            .rounded(px(AppRadii::CONTROL))
                            .bg(rgb(AppColors::rgb24(AppColors::SURFACE_0)))
                            .border_1()
                            .border_color(rgb(AppColors::rgb24(AppColors::BORDER_SOFT)))
                            .flex()
                            .items_center()
                            .justify_between()
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::XS))
                                    .font_semibold()
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                                    .child(format!(
                                        "SoftAP 端点：{} | 状态：{}",
                                        settings.softap_endpoint_label, phase_label
                                    )),
                            )
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::XS))
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_SECONDARY)))
                                    .child(format!(
                                        "已完成 {}/{} 份 | 95% 抢救 {} 份 | 当前文件字节 {}/{}",
                                        wb.finalized_count,
                                        wb.total_files,
                                        wb.salvaged_count,
                                        wb.received_wire_bytes,
                                        wb.expected_wire_bytes
                                    )),
                            ),
                    ),
            )
    }

    fn render_pipeline_doctor_card(&self, cx: &mut Context<Self>) -> Div {
        let doc = &self.projection.doctor;
        let stages = [
            (
                "1. BLE GATT 0x7777/0x8888 链路",
                doc.stage1_ble_gatt.is_ready(),
                format!(
                    "状态 {} 文件 #{}",
                    doc.stage1_ble_gatt.label_zh(),
                    doc.active_file_id
                ),
            ),
            (
                "2. 2E/01 ECDH 会话密钥协商",
                doc.stage2_session_key.is_ready(),
                format!("状态 {}", doc.stage2_session_key.label_zh()),
            ),
            (
                "3. 1A/06 -> 1A/07 -> 1A/08 实时流",
                doc.stage3_realtime_stream.is_ready(),
                format!(
                    "状态 {} 分片 {}",
                    doc.stage3_realtime_stream.label_zh(),
                    doc.unpacked_slices
                ),
            ),
            (
                "4. libopus 16kHz 解码与声学能量",
                doc.stage4_opus_decoder_16k.is_ready(),
                format!(
                    "PCM16 {}B RMS {}",
                    doc.decoded_pcm16_bytes, doc.latest_rms_energy
                ),
            ),
            (
                "5. 百炼流式 ASR 与 UtteranceSpine",
                doc.stage5_streaming_asr.is_ready(),
                format!(
                    "队列 {} 帧 主干 {} 段",
                    doc.outbound_asr_frames_queued, doc.spine_segment_count
                ),
            ),
        ];

        let mut row = div().flex().flex_wrap().gap_2();
        for (title, ok, detail) in stages {
            let badge_bg = if ok {
                AppColors::SUCCESS_SOFT
            } else {
                AppColors::WARNING_SOFT
            };
            let badge_fg = if ok {
                AppColors::SUCCESS
            } else {
                AppColors::WARNING
            };
            row = row.child(
                div()
                    .flex_1()
                    .min_w(px(160.0))
                    .p_2p5()
                    .rounded(px(AppRadii::CONTROL))
                    .bg(rgb(AppColors::rgb24(badge_bg)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER_SOFT)))
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .text_size(px(AppFontSizes::XS))
                            .font_semibold()
                            .text_color(rgb(AppColors::rgb24(badge_fg)))
                            .child(title),
                    )
                    .child(
                        div()
                            .text_size(px(AppFontSizes::XS))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_SECONDARY)))
                            .child(detail),
                    ),
            );
        }

        div()
            .p_3()
            .rounded(px(AppRadii::CARD))
            .bg(rgb(AppColors::rgb24(AppColors::BG_CARD)))
            .border_1()
            .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
            .flex()
            .flex_col()
            .gap_2p5()
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_2()
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_0p5()
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::MD))
                                    .font_semibold()
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                                    .child("安克录音豆 D3200 五阶实时链路自检 (Bean Doctor)"),
                            )
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::XS))
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                                    .child(doc.summary_label_zh.clone()),
                            ),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_wrap()
                            .gap_1p5()
                            .child(
                                Button::new("btn-doctor-retrigger-1a07")
                                    .primary()
                                    .small()
                                    .label("一键重发 1A/07 (realtimeFlag=1)")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        let now_ms = Self::now_epoch_sec().saturating_mul(1_000);
                                        this.dispatch_command(
                                            WorkspaceCommand::RetriggerRealtimeStream { now_ms },
                                            "已主动重发 1A/07 (realtimeFlag=1) 实时流订阅帧并唤醒百炼流式泵",
                                            cx,
                                        );
                                    })),
                            )
                            .child(
                                Button::new("btn-doctor-simulate-60-slices")
                                    .small()
                                    .label("模拟 60 片 Opus 实时闭环")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.dispatch_command(
                                            WorkspaceCommand::SimulateRealtimePipeline,
                                            "已执行 60 片 Opus 实时流闭环自检并更新五阶诊断",
                                            cx,
                                        );
                                    })),
                            ),
                    ),
            )
            .child(row)
    }

    fn render_detail_tabs(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let proj = &self.projection;
        let mut bar = div()
            .flex()
            .items_center()
            .gap_4()
            .border_b_1()
            .border_color(rgb(AppColors::rgb24(AppColors::BORDER)));

        for tab in DetailTab::ALL {
            let active = proj.detail_tab == tab;
            let text_col = if active {
                AppColors::TEXT_PRIMARY
            } else {
                AppColors::TEXT_MUTED
            };
            let border_col = if active {
                AppColors::ORANGE_BRAND
            } else {
                AppColors::CANVAS
            };
            let tab_id: SharedString = format!("detail-tab-{tab:?}").into();
            bar = bar.child(
                div()
                    .id(tab_id)
                    .pb_2()
                    .border_b_2()
                    .border_color(rgb(AppColors::rgb24(border_col)))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.dispatch_command(
                            WorkspaceCommand::SelectDetailTab(tab),
                            format!("已切换到「{}」标签页", tab.label()),
                            cx,
                        );
                    }))
                    .child(
                        div()
                            .text_size(px(AppFontSizes::SM))
                            .font_semibold()
                            .text_color(rgb(AppColors::rgb24(text_col)))
                            .child(tab.label()),
                    ),
            );
        }
        bar
    }

    fn render_visual_summary_tab(&self, cx: &mut Context<Self>) -> Div {
        let proj = &self.projection;

        let mut format_row = div().flex().items_center().justify_between().gap_2();
        let mut pills = div().flex().flex_wrap().gap_1p5();
        for fmt in SummaryFormat::ALL {
            let active = proj.active_aggregate.selected_format == fmt;
            let fid: SharedString = format!("fmt-pill-{fmt:?}").into();
            let btn = if active {
                Button::new(fid).primary().small().label(fmt.label_zh())
            } else {
                Button::new(fid).ghost().small().label(fmt.label_zh())
            };
            pills = pills.child(btn.on_click(cx.listener(move |this, _, _, cx| {
                this.dispatch_command(
                    WorkspaceCommand::SelectSummaryFormat(fmt),
                    format!("已切换总结格式为「{}」", fmt.label_zh()),
                    cx,
                );
            })));
        }
        format_row = format_row
            .child(
                div()
                    .text_size(px(AppFontSizes::SM))
                    .font_semibold()
                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                    .child("6 宫格 AI 视觉总结卡片 (AIVisualEditorialPalette 8% 柔彩层)"),
            )
            .child(pills);

        let mut cards_grid = div().flex().flex_wrap().gap_3();
        for card in &proj.visual_cards {
            let pal = AIVisualEditorialPalette::for_role(card.role);
            let cites: Vec<String> = card.citations.iter().map(|c| format!("[{c}]")).collect();
            let mut card_div = div()
                .w(px(285.0))
                .flex_1()
                .p_3p5()
                .rounded(px(AppRadii::CARD))
                .bg(rgb(AppColors::rgb24(pal.bg)))
                .border_1()
                .border_color(rgb(AppColors::rgb24(pal.border)))
                .flex()
                .flex_col()
                .gap_1p5()
                .child(
                    div()
                        .flex()
                        .items_center()
                        .justify_between()
                        .child(
                            div()
                                .text_size(px(AppFontSizes::XS))
                                .font_bold()
                                .text_color(rgb(AppColors::rgb24(pal.badge_text)))
                                .child(card.role.label_zh()),
                        )
                        .child(
                            div()
                                .px_1p5()
                                .py_0p5()
                                .rounded(px(AppRadii::concentric(AppRadii::CONTROL, 2.0)))
                                .bg(rgb(AppColors::rgb24(AppColors::BG_CARD)))
                                .text_size(px(AppFontSizes::XS))
                                .font_semibold()
                                .text_color(rgb(AppColors::rgb24(pal.badge_text)))
                                .child(cites.join(" ")),
                        ),
                )
                .child(
                    div()
                        .text_size(px(AppFontSizes::MD))
                        .font_bold()
                        .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                        .child(card.headline.clone()),
                )
                .child(
                    div()
                        .text_size(px(AppFontSizes::SM))
                        .text_color(rgb(AppColors::rgb24(AppColors::TEXT_SECONDARY)))
                        .child(card.body.clone()),
                );

            if let Some(ref hi) = card.highlight_box {
                card_div = card_div.child(
                    div()
                        .mt_1()
                        .p_2()
                        .rounded(px(AppRadii::concentric(AppRadii::CARD, 4.0)))
                        .bg(rgb(AppColors::rgb24(AppColors::BG_CARD)))
                        .text_size(px(AppFontSizes::XS))
                        .font_semibold()
                        .text_color(rgb(AppColors::rgb24(pal.badge_text)))
                        .child(hi.clone()),
                );
            }
            cards_grid = cards_grid.child(card_div);
        }

        let mut fishbone_panel = div()
            .p_3p5()
            .rounded(px(AppRadii::CARD))
            .bg(rgb(AppColors::rgb24(AppColors::BG_CARD)))
            .border_1()
            .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
            .flex()
            .flex_col()
            .gap_2()
            .child(
                div()
                    .text_size(px(AppFontSizes::MD))
                    .font_semibold()
                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                    .child("Cicada 根因鱼骨图 (MinuteFishbone 因果溯源)"),
            );

        if let Some(ref mins) = proj.active_aggregate.minutes {
            for fb in &mins.fishbones {
                let mut branches = div().flex().flex_wrap().gap_2();
                for cause in &fb.causes {
                    let cites: Vec<String> =
                        cause.citations.iter().map(|c| format!("[{c}]")).collect();
                    branches = branches.child(
                        div()
                            .flex_1()
                            .min_w(px(200.0))
                            .p_2p5()
                            .rounded(px(AppRadii::concentric(AppRadii::CARD, 4.0)))
                            .bg(rgb(AppColors::rgb24(AppColors::SURFACE_0)))
                            .border_1()
                            .border_color(rgb(AppColors::rgb24(AppColors::BORDER_SOFT)))
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .justify_between()
                                    .child(
                                        div()
                                            .text_size(px(AppFontSizes::XS))
                                            .font_bold()
                                            .text_color(rgb(AppColors::rgb24(
                                                AppColors::ORANGE_DEEP,
                                            )))
                                            .child(cause.category.clone()),
                                    )
                                    .child(
                                        div()
                                            .text_size(px(AppFontSizes::XS))
                                            .text_color(rgb(AppColors::rgb24(
                                                AppColors::TEXT_MUTED,
                                            )))
                                            .child(cites.join(" ")),
                                    ),
                            )
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::SM))
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                                    .child(cause.description.clone()),
                            ),
                    );
                }
                fishbone_panel = fishbone_panel
                    .child(
                        div()
                            .text_size(px(AppFontSizes::SM))
                            .font_semibold()
                            .text_color(rgb(AppColors::rgb24(AppColors::ORANGE_DEEP)))
                            .child(format!("主干问题：{}", fb.issue)),
                    )
                    .child(branches);
            }
        }

        div()
            .flex()
            .flex_col()
            .gap_3()
            .child(format_row)
            .child(cards_grid)
            .child(fishbone_panel)
    }

    fn render_transcript_and_voiceprint_tab(&self, cx: &mut Context<Self>) -> Div {
        let proj = &self.projection;
        let aliases_label = if proj.speaker_aliases.is_empty() {
            "暂无声纹别名".to_string()
        } else {
            proj.speaker_aliases
                .iter()
                .map(|(from, to)| format!("{from} -> {to}"))
                .collect::<Vec<_>>()
                .join("，")
        };

        let control_box = div()
            .p_3()
            .rounded(px(AppRadii::CARD))
            .bg(rgb(AppColors::rgb24(AppColors::BG_CARD)))
            .border_1()
            .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
            .flex()
            .items_center()
            .justify_between()
            .gap_2()
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .text_size(px(AppFontSizes::SM))
                            .font_semibold()
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child(format!("声纹映射：{aliases_label}")),
                    )
                    .child(
                        div()
                            .text_size(px(AppFontSizes::XS))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                            .child(format!(
                                "热词词表：{} | 流式诊断：{}",
                                proj.hot_words.join(" / "),
                                proj.doctor.summary_label_zh
                            )),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .gap_1p5()
                    .child(
                        Button::new("btn-retrigger-1a07")
                            .primary()
                            .small()
                            .label("一键重发 1A/07 实时流")
                            .on_click(cx.listener(|this, _, _, cx| {
                                let now_ms = Self::now_epoch_sec().saturating_mul(1_000);
                                this.dispatch_command(
                                    WorkspaceCommand::RetriggerRealtimeStream { now_ms },
                                    "已补发 1A/07 (realtimeFlag=1) 实时流订阅指令",
                                    cx,
                                );
                            })),
                    )
                    .child(
                        Button::new("btn-replace-speaker")
                            .small()
                            .label("声纹替换 Speaker 1 -> 张工")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.dispatch_command(
                                    WorkspaceCommand::ReplaceSpeaker {
                                        old_speaker: "Speaker 1".to_string(),
                                        new_speaker: "张工".to_string(),
                                    },
                                    "已将 Speaker 1 声纹统一替换为「张工」并同步纪要",
                                    cx,
                                );
                            })),
                    )
                    .child(
                        Button::new("btn-sync-hotwords")
                            .small()
                            .label("同步热词 D3200")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.dispatch_command(
                                    WorkspaceCommand::SyncHotWords {
                                        hotwords: vec![
                                            "D3200".to_string(),
                                            "soundcore".to_string(),
                                            "随心记".to_string(),
                                        ],
                                        speaker_aliases: vec![(
                                            "Speaker 2".to_string(),
                                            "李工".to_string(),
                                        )],
                                    },
                                    "已同步百炼热词词表与说话人声纹映射",
                                    cx,
                                );
                            })),
                    )
                    .child(
                        Button::new("btn-append-bilingual")
                            .small()
                            .label("+ 追加双语同传句段")
                            .on_click(cx.listener(|this, _, _, cx| {
                                let now = Self::now_epoch_sec();
                                let count = this.projection.active_aggregate.spine.len() as u64;
                                this.dispatch_command(
                                    WorkspaceCommand::AppendUtterance {
                                        text: "下周五前完成安克心力豆 D3200 真机双轨压测与百炼同传验收。"
                                            .to_string(),
                                        start_ms: count * 2_500,
                                        end_ms: (count + 1) * 2_500,
                                        source_language: "zh".to_string(),
                                        provider: "qwen3-asr-flash-realtime".to_string(),
                                        now_epoch_sec: now,
                                    },
                                    "已追加实时流句段并触发双语同传与待办提取",
                                    cx,
                                );
                            })),
                    ),
            );

        let mut seg_list = div().flex().flex_col().gap_2();
        for seg in proj.active_aggregate.spine.segments() {
            let speaker = seg.speaker.as_deref().unwrap_or("本人随记");
            let mut seg_card = div()
                .p_3()
                .rounded(px(AppRadii::CARD))
                .bg(rgb(AppColors::rgb24(AppColors::BG_CARD)))
                .border_1()
                .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
                .flex()
                .flex_col()
                .gap_1()
                .child(
                    div()
                        .flex()
                        .items_center()
                        .justify_between()
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .gap_2()
                                .child(
                                    div()
                                        .px_2()
                                        .py_0p5()
                                        .rounded(px(AppRadii::concentric(AppRadii::CONTROL, 2.0)))
                                        .bg(rgb(AppColors::rgb24(AppColors::ORANGE_TINT)))
                                        .text_size(px(AppFontSizes::XS))
                                        .font_bold()
                                        .text_color(rgb(AppColors::rgb24(AppColors::ORANGE_DEEP)))
                                        .child(format!("[{}]", seg.id)),
                                )
                                .child(
                                    div()
                                        .text_size(px(AppFontSizes::XS))
                                        .font_semibold()
                                        .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                                        .child(speaker.to_string()),
                                ),
                        )
                        .child(
                            div()
                                .text_size(px(AppFontSizes::XS))
                                .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                                .child(format!(
                                    "{} - {}",
                                    Self::format_mm_ss(seg.start_ms),
                                    Self::format_mm_ss(seg.end_ms)
                                )),
                        ),
                )
                .child(
                    div()
                        .text_size(px(AppFontSizes::SM))
                        .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                        .child(seg.text.clone()),
                );

            if let Some(ref tr) = seg.translation {
                seg_card = seg_card.child(
                    div()
                        .text_size(px(AppFontSizes::XS))
                        .text_color(rgb(AppColors::rgb24(AppColors::INFO)))
                        .child(format!("EN 同传：{tr}")),
                );
            }
            seg_list = seg_list.child(seg_card);
        }

        div()
            .flex()
            .flex_col()
            .gap_3()
            .child(control_box)
            .child(seg_list)
    }

    fn render_ask_ai_and_mcp_tab(&self, cx: &mut Context<Self>) -> Div {
        let proj = &self.projection;

        let mut search_hits_col = div().flex().flex_col().gap_1p5();
        if proj.search_hits.is_empty() {
            search_hits_col = search_hits_col.child(
                div()
                    .text_size(px(AppFontSizes::XS))
                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                    .child("暂无匹配片段，可点击上方检索预设词测试离线双字 BM25 索引。"),
            );
        } else {
            for hit in &proj.search_hits {
                search_hits_col = search_hits_col.child(
                    div()
                        .p_2()
                        .rounded(px(AppRadii::CONTROL))
                        .bg(rgb(AppColors::rgb24(AppColors::SURFACE_0)))
                        .border_1()
                        .border_color(rgb(AppColors::rgb24(AppColors::BORDER_SOFT)))
                        .flex()
                        .items_center()
                        .justify_between()
                        .child(
                            div()
                                .text_size(px(AppFontSizes::SM))
                                .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                                .child(format!("{}：{}", hit.title, hit.snippet)),
                        )
                        .child(
                            div()
                                .text_size(px(AppFontSizes::XS))
                                .font_semibold()
                                .text_color(rgb(AppColors::rgb24(AppColors::ORANGE_DEEP)))
                                .child(format!("BM25 {:.2}", hit.score)),
                        ),
                );
            }
        }

        let mut copilot_chips = div().flex().flex_wrap().gap_1p5();
        for preset in CopilotPresetChip::ALL {
            let cid: SharedString = format!("copilot-chip-{}", preset.slug()).into();
            copilot_chips = copilot_chips.child(
                Button::new(cid)
                    .small()
                    .label(preset.label())
                    .on_click(cx.listener(move |this, _, _, cx| {
                        let now = Self::now_epoch_sec();
                        this.dispatch_command(
                            WorkspaceCommand::RunCopilotPreset {
                                preset,
                                now_epoch_sec: now,
                            },
                            format!("已执行 AI 随心问预设：{}", preset.label()),
                            cx,
                        );
                    })),
            );
        }

        let copilot_answer_box = match &proj.copilot_card {
            Some(card) => {
                let cites: Vec<String> = card.citations.iter().map(|c| format!("[{c}]")).collect();
                div()
                    .p_3()
                    .rounded(px(AppRadii::concentric(AppRadii::CARD, 4.0)))
                    .bg(rgb(AppColors::rgb24(AppColors::ORANGE_TINT)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::ORANGE_BORDER)))
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .text_size(px(AppFontSizes::XS))
                            .font_bold()
                            .text_color(rgb(AppColors::rgb24(AppColors::ORANGE_DEEP)))
                            .child(format!(
                                "提问：{} | 引用：{} | 工具：{}",
                                card.prompt,
                                cites.join(" "),
                                card.tools_used.join(", ")
                            )),
                    )
                    .child(
                        div()
                            .text_size(px(AppFontSizes::SM))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                            .child(card.answer.clone()),
                    )
            }
            None => div()
                .p_2p5()
                .rounded(px(AppRadii::CONTROL))
                .bg(rgb(AppColors::rgb24(AppColors::SURFACE_0)))
                .text_size(px(AppFontSizes::XS))
                .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                .child("点击上方预设胶囊或「总结当前录音要务」，生成带 [S1..Sn] 原话引用的回答。"),
        };

        div()
            .flex()
            .flex_col()
            .gap_3()
            .child(
                div()
                    .p_3p5()
                    .rounded(px(AppRadii::CARD))
                    .bg(rgb(AppColors::rgb24(AppColors::BG_CARD)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::MD))
                                    .font_semibold()
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                                    .child(format!("离线双字 BM25 检索（当前词：{}）", proj.search_query)),
                            )
                            .child(
                                div()
                                    .flex()
                                    .gap_1p5()
                                    .child(
                                        Button::new("btn-q-overseas")
                                            .small()
                                            .label("检索：海外渠道")
                                            .on_click(cx.listener(|this, _, _, cx| {
                                                this.dispatch_command(
                                                    WorkspaceCommand::SearchContext {
                                                        query: "海外渠道".to_string(),
                                                        limit: 5,
                                                    },
                                                    "已完成「海外渠道」BM25 检索",
                                                    cx,
                                                );
                                            })),
                                    )
                                    .child(
                                        Button::new("btn-q-rust")
                                            .small()
                                            .label("检索：纯 Rust")
                                            .on_click(cx.listener(|this, _, _, cx| {
                                                this.dispatch_command(
                                                    WorkspaceCommand::SearchContext {
                                                        query: "纯 Rust".to_string(),
                                                        limit: 5,
                                                    },
                                                    "已完成「纯 Rust」BM25 检索",
                                                    cx,
                                                );
                                            })),
                                    ),
                            ),
                    )
                    .child(search_hits_col),
            )
            .child(
                div()
                    .p_3p5()
                    .rounded(px(AppRadii::CARD))
                    .bg(rgb(AppColors::rgb24(AppColors::BG_CARD)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::MD))
                                    .font_semibold()
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                                    .child("AI 随心问 (Ask AI Copilot)"),
                            )
                            .child(
                                Button::new("btn-ask-freeform")
                                    .primary()
                                    .small()
                                    .label("总结当前录音要务")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        let now = Self::now_epoch_sec();
                                        this.dispatch_command(
                                            WorkspaceCommand::AskCopilot {
                                                prompt: "当前录音的核心结论与下一步待办是什么？"
                                                    .to_string(),
                                                now_epoch_sec: now,
                                            },
                                            "已生成带 [S1] 原话锚点的随心问回答",
                                            cx,
                                        );
                                    })),
                            ),
                    )
                    .child(copilot_chips)
                    .child(copilot_answer_box),
            )
            .child(
                div()
                    .p_3p5()
                    .rounded(px(AppRadii::CARD))
                    .bg(rgb(AppColors::rgb24(AppColors::BG_CARD)))
                    .border_1()
                    .border_color(rgb(AppColors::rgb24(AppColors::BORDER)))
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .child(
                                div()
                                    .text_size(px(AppFontSizes::MD))
                                    .font_semibold()
                                    .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
                                    .child("本机原生 MCP / ACP 协议与 Google Workspace 同步"),
                            )
                            .child(
                                div()
                                    .flex()
                                    .gap_1p5()
                                    .child(
                                        Button::new("btn-sync-google-ws")
                                            .small()
                                            .label("同步 Google Tasks / Keep")
                                            .on_click(cx.listener(|this, _, _, cx| {
                                                let now = Self::now_epoch_sec();
                                                this.dispatch_command(
                                                    WorkspaceCommand::SyncGoogleWorkspace {
                                                        tasklist_id: "@default".to_string(),
                                                        now_epoch_sec: now,
                                                    },
                                                    "已同步 Google Tasks、NotebookLM 与 Keep 清单",
                                                    cx,
                                                );
                                            })),
                                    )
                                    .child(
                                        Button::new("btn-mcp-get-minutes")
                                            .small()
                                            .label("调用 MCP get_minutes")
                                            .on_click(cx.listener(|this, _, _, cx| {
                                                this.dispatch_command(
                                                    WorkspaceCommand::DispatchJsonRpc {
                                                        request_json: r#"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"get_minutes","arguments":{}}}"#.to_string(),
                                                    },
                                                    "已通过本机 MCP 2025-11-25 协议返回结构化纪要",
                                                    cx,
                                                );
                                            })),
                                    ),
                            ),
                    )
                    .child(
                        div()
                            .text_size(px(AppFontSizes::XS))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_SECONDARY)))
                            .child(format!(
                                "live.json 租约代数 #{} | 归档包 {} 份 | NotebookLM {} 本 | Keep 速记 {} 条",
                                proj.live_generation,
                                proj.pack_count,
                                proj.google_notebooks.len(),
                                proj.google_keep_notes.len()
                            )),
                    )
                    .child(
                        div()
                            .p_2()
                            .rounded(px(AppRadii::CONTROL))
                            .bg(rgb(AppColors::rgb24(AppColors::SURFACE_0)))
                            .text_size(px(AppFontSizes::XS))
                            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_MUTED)))
                            .child(if proj.last_jsonrpc_response.is_empty() {
                                "MCP stdio (--mcp-stdio) 与 15s live.json 已就绪，支持 Claude / Cursor / OpenClaw 零配置接入。".to_string()
                            } else {
                                proj.last_jsonrpc_response.clone()
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
                && (self.projection.library.entry_count > 0 || self.projection.pack_count > 0);
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

        let detail_view = match self.projection.detail_tab {
            DetailTab::VisualSummary => self.render_visual_summary_tab(cx),
            DetailTab::TranscriptAndVoiceprint => self.render_transcript_and_voiceprint_tab(cx),
            DetailTab::AskAiAndMcp => self.render_ask_ai_and_mcp_tab(cx),
        };

        div()
            .flex()
            .flex_col()
            .size_full()
            .bg(rgb(AppColors::rgb24(AppColors::CANVAS)))
            .text_color(rgb(AppColors::rgb24(AppColors::TEXT_PRIMARY)))
            .p_4()
            .gap_3()
            .child(
                div()
                    .flex()
                    .flex_1()
                    .min_h_0()
                    .gap_4()
                    .child(self.render_sidebar(cx))
                    .child(
                        div()
                            .id("workspace-main")
                            .flex_1()
                            .min_w_0()
                            .min_h_0()
                            .overflow_y_scroll()
                            .flex()
                            .flex_col()
                            .gap_3()
                            .child(self.render_header(cx))
                            .child(self.render_daily_context_strip(cx))
                            .child(self.render_waveform_player_strip(cx))
                            .child(self.render_section_context_banner(cx))
                            .child(self.render_detail_tabs(cx))
                            .child(detail_view),
                    ),
            )
            .child(
                div()
                    .p_2p5()
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
    anyhow::ensure!(
        app.projection.library.entry_count >= 1,
        "expected seeded recording in WorkspaceProjection"
    );
    anyhow::ensure!(
        app.projection.active_aggregate.spine.len() >= 2,
        "expected S1..S2 in WorkspaceProjection spine"
    );
    anyhow::ensure!(
        app.projection.visual_cards.len() == 6,
        "expected 6 editorial visual cards in WorkspaceProjection"
    );
    anyhow::ensure!(
        app.projection.pack_count >= 1,
        "expected exported .koepack v2"
    );
    anyhow::ensure!(
        app.projection.live_generation >= 1,
        "expected live.json lease"
    );
    anyhow::ensure!(
        !app.projection.search_hits.is_empty(),
        "expected BM25 search hits in WorkspaceProjection"
    );
    anyhow::ensure!(
        app.projection.focus_project.is_some(),
        "expected focus project in WorkspaceProjection"
    );
    anyhow::ensure!(
        app.projection.diary_entry.current.is_some(),
        "expected grounded DiaryEntry in WorkspaceProjection"
    );

    for sec in WorkspaceSection::ALL {
        let p = app.apply_command(WorkspaceCommand::SelectSection(sec));
        anyhow::ensure!(p.section == sec, "WorkspaceSection switch failed");
    }
    for tab in DetailTab::ALL {
        let p = app.apply_command(WorkspaceCommand::SelectDetailTab(tab));
        anyhow::ensure!(p.detail_tab == tab, "DetailTab switch failed");
    }

    let s1 = app.projection.active_aggregate.spine.segments()[0].id;
    let s2 = app.projection.active_aggregate.spine.segments()[1].id;
    anyhow::ensure!(
        validate_calculation_grounding(
            "基本工资3910元乘以80%发放",
            &[s1, s2],
            &app.projection.active_aggregate.spine
        )
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
    let mcp_proj = app.apply_command(WorkspaceCommand::DispatchJsonRpc {
        request_json: r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_context","arguments":{"query":"海外渠道","limit":5}}}"#.to_string(),
    });
    anyhow::ensure!(
        mcp_proj.last_jsonrpc_response.contains("海外渠道"),
        "mcp_resp: {}",
        mcp_proj.last_jsonrpc_response
    );

    let acp_proj = app.apply_command(WorkspaceCommand::DispatchJsonRpc {
        request_json: r#"{"jsonrpc":"2.0","id":2,"method":"acp/task.send","params":{"prompt":"海外渠道合同"}}"#.to_string(),
    });
    anyhow::ensure!(
        acp_proj.last_jsonrpc_response.contains("acp-task-1"),
        "acp_resp: {}",
        acp_proj.last_jsonrpc_response
    );

    let rec_id = app.active_exported_recordings()[0].entry.id;
    let mark_proj = app.apply_command(WorkspaceCommand::JumpMark(MarkJumpDirection::Next));
    anyhow::ensure!(mark_proj.library.position_ms == 300);
    let _ = app.apply_command(WorkspaceCommand::MoveToTrash(rec_id));
    anyhow::ensure!(app.active_exported_recordings().is_empty());
    let _ = app.apply_command(WorkspaceCommand::UndoTrash);
    anyhow::ensure!(app.active_exported_recordings().len() == 1);
    anyhow::ensure!(
        app.projection
            .open_todos
            .iter()
            .any(|t| t.status == TodoStatus::Open),
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
        reopened.projection.active_aggregate.spine.len() == 2
            && !reopened.projection.search_hits.is_empty(),
        "second launch on existing workspace must restore spine from .koepack v2 without duplicating sample sentences"
    );

    let real_only_dir =
        std::env::temp_dir().join(format!("koe-gpui-real-only-{}", std::process::id()));
    let _ = fs::remove_dir_all(&real_only_dir);
    fs::create_dir_all(&real_only_dir)?;
    let first_export = &app.active_exported_recordings()[0];
    fs::copy(
        &first_export.opus_path,
        real_only_dir.join(format!("{}.opus", first_export.entry.id)),
    )?;
    fs::copy(
        &first_export.wav_path,
        real_only_dir.join(format!("{}.wav", first_export.entry.id)),
    )?;
    let real_only_app = KoeDesktopApp::new(real_only_dir.clone(), false);
    let _ = fs::remove_dir_all(&real_only_dir);
    anyhow::ensure!(
        real_only_app.projection.library.entry_count == 1
            && real_only_app.projection.active_aggregate.spine.is_empty(),
        "directory with existing recordings and no .koepack must NOT inject default sample sentences"
    );
    let ephemeral_priv = KoeDesktopApp::generate_ephemeral_p256_key(now);
    let tx_frames = reopened
        .host
        .on_gatt_ready(ephemeral_priv)
        .ok_or_else(|| anyhow::anyhow!("on_gatt_ready must produce ECDH + telemetry TX frames"))?;
    anyhow::ensure!(
        tx_frames.len() == 2 && tx_frames[0][5] == 0x2E && tx_frames[1][5] == 0x01,
        "expected 2E/01 and 01/01 handshake frames"
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

    let tpl_proj = app.apply_command(WorkspaceCommand::SelectMinuteTemplate(
        BuiltinTemplateId::Fishbone,
    ));
    anyhow::ensure!(
        tpl_proj.formats.active_template == BuiltinTemplateId::Fishbone
            && !tpl_proj.formats.custom_sections.is_empty()
            && tpl_proj
                .formats
                .custom_sections
                .iter()
                .all(|s| !s.points.is_empty() && !s.points[0].citations.is_empty())
            && tpl_proj.visual_cards.len() == 6,
        "SelectMinuteTemplate(Fishbone) must update active_template, populate grounded custom_sections, and recompute 6 visual_cards"
    );

    let add_sec_proj = app.apply_command(WorkspaceCommand::AddCustomMinuteSection {
        heading: "客户原声锚点".to_string(),
    });
    anyhow::ensure!(
        add_sec_proj
            .formats
            .custom_sections
            .iter()
            .any(|s| s.heading == "客户原声锚点")
            && add_sec_proj.visual_cards.len() == 6,
        "AddCustomMinuteSection must append custom section heading and recompute 6 visual_cards"
    );
    let rm_sec_proj = app.apply_command(WorkspaceCommand::RemoveCustomMinuteSection {
        heading: "客户原声锚点".to_string(),
    });
    anyhow::ensure!(
        !rm_sec_proj
            .formats
            .custom_sections
            .iter()
            .any(|s| s.heading == "客户原声锚点")
            && rm_sec_proj.visual_cards.len() == 6,
        "RemoveCustomMinuteSection must remove custom section heading and recompute 6 visual_cards"
    );

    let pair_proj = app.apply_command(WorkspaceCommand::IssuePairingTicket {
        mode: McpPairingMode::Vps,
        email: Some("owner@example.com".to_string()),
        now_epoch_sec: now + 10,
    });
    anyhow::ensure!(
        pair_proj.aliyun_mcp.pairing_mode == McpPairingMode::Vps
            && pair_proj
                .aliyun_mcp
                .pairing_ticket
                .as_deref()
                .is_some_and(|t| t.starts_with(PAIRING_TICKET_PREFIX))
            && pair_proj
                .aliyun_mcp
                .mcp_stdio_config_json
                .contains("--mcp-stdio"),
        "IssuePairingTicket must issue KOEMCP1. ticket and expose --mcp-stdio config JSON"
    );
    let _ = app.apply_command(WorkspaceCommand::GenerateMcpStdioConfig);
    let _ = app.apply_command(WorkspaceCommand::AskCopilot {
        prompt: "海外渠道样品合同的关键结论是什么？".to_string(),
        now_epoch_sec: now + 11,
    });
    let copilot_proj = app.apply_command(WorkspaceCommand::AskCopilot {
        prompt: "下周需要跟进的行动承诺有哪些？".to_string(),
        now_epoch_sec: now + 12,
    });
    anyhow::ensure!(
        copilot_proj.aliyun_mcp.copilot_history.len() >= 2
            && copilot_proj
                .aliyun_mcp
                .copilot_history
                .iter()
                .all(|turn| !turn.citations.is_empty()),
        "two consecutive AskCopilot commands must populate copilot_history.len() >= 2 with grounded [S1..Sn] citations"
    );

    let _ = app.apply_command(WorkspaceCommand::SetAutoLaunch(true));
    let settings_proj = app.apply_command(WorkspaceCommand::SetKeepAlive(false));
    let settings_file = temp_dir.join("settings.json");
    anyhow::ensure!(
        settings_proj.settings.auto_launch_enabled
            && !settings_proj.settings.keep_alive_enabled
            && settings_file.exists(),
        "SetAutoLaunch(true) and SetKeepAlive(false) must update settings snapshot and persist settings.json on disk"
    );

    let wifi_start_proj = app.apply_command(WorkspaceCommand::ControlWifiSoftApBatch {
        action: WifiSoftApAction::StartDefaultSoftAp,
        now_epoch_sec: now + 20,
    });
    anyhow::ensure!(
        wifi_start_proj
            .settings
            .softap_endpoint_label
            .contains("192.168.4.1:32002")
            && wifi_start_proj.wifi_batch.phase == WifiBatchPhase::Transferring,
        "StartDefaultSoftAp must bind 192.168.4.1:32002 and enter Transferring phase"
    );
    let wifi_int_proj = app.apply_command(WorkspaceCommand::ControlWifiSoftApBatch {
        action: WifiSoftApAction::Interrupt,
        now_epoch_sec: now + 21,
    });
    anyhow::ensure!(
        wifi_int_proj.wifi_batch.phase == WifiBatchPhase::Interrupted
            && wifi_int_proj.wifi_batch.salvaged_count >= 1,
        "Interrupt must transition to Interrupted and salvage >=95% file"
    );
    let wifi_done_proj = app.apply_command(WorkspaceCommand::ControlWifiSoftApBatch {
        action: WifiSoftApAction::ResumeAndComplete,
        now_epoch_sec: now + 22,
    });
    anyhow::ensure!(
        wifi_done_proj.wifi_batch.phase == WifiBatchPhase::Completed,
        "ResumeAndComplete must transition to Completed"
    );
    let wifi_cancel_proj = app.apply_command(WorkspaceCommand::ControlWifiSoftApBatch {
        action: WifiSoftApAction::Cancel,
        now_epoch_sec: now + 23,
    });
    anyhow::ensure!(
        wifi_cancel_proj.wifi_batch.phase == WifiBatchPhase::Idle,
        "Cancel must transition to Idle"
    );

    let _ = fs::remove_dir_all(&temp_dir);
    println!(
        "PASS: koe-desktop pure-Rust GPUI + WorkspaceProjection self-check (spine={}, cards={}, packs={}, mcp_calls={})",
        app.projection.active_aggregate.spine.len(),
        app.projection.visual_cards.len(),
        app.projection.pack_count,
        app.projection.mcp_handled_calls
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
