use gpui_kit::base::Disableable;
use gpui_kit::component::{
    ActiveTheme,
    button::{Button, ButtonVariants},
};
use gpui_kit::*;
use koe_core::{
    Library, ReadingPack,
    mcp::McpPublisher,
    organize::format_minutes,
    recorder::{WavRecorder, next_recording_path},
};
use std::{
    fs::File,
    path::{Path, PathBuf},
    time::Duration,
};

struct Player {
    _stream: rodio::OutputStream,
    sink: rodio::Sink,
}

impl Player {
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

enum PackState {
    Empty,
    Loading,
    Loaded(ReadingPack),
    Error(String),
}

enum ActivePane {
    LibraryRecording(usize),
    Pack,
}

struct KoeApp {
    library: Library,
    active: ActivePane,
    pack_state: PackState,
    generation: u64,
    player: Option<Player>,
    playback_task: Option<Task<()>>,
    recorder: Option<WavRecorder>,
    mcp_publisher: McpPublisher,
    mcp_dir: PathBuf,
    mcp_lease_task: Option<Task<()>>,
    status: String,
    smoke: bool,
    smoke_scheduled: bool,
}

impl KoeApp {
    fn open_library_dir(&mut self, dir: PathBuf, cx: &mut Context<Self>) {
        self.player = None;
        match Library::open(&dir) {
            Ok(lib) => {
                let count = lib.recordings.len();
                self.mcp_dir = dir.join("mcp-live");
                self.library = lib;
                if count > 0 {
                    self.active = ActivePane::LibraryRecording(0);
                }
                self.status = format!("已载入资料目录（共 {count} 条录音）");
                if self.smoke {
                    self.pack_state = PackState::Empty;
                }
            }
            Err(error) => {
                self.status = format!("无法打开资料目录：{error:#}");
                if self.smoke {
                    self.pack_state = PackState::Error(error.to_string());
                }
            }
        }
        cx.notify();
    }

    fn load_pack(&mut self, path: PathBuf, cx: &mut Context<Self>) {
        self.player = None;
        self.generation += 1;
        let generation = self.generation;
        self.active = ActivePane::Pack;
        self.pack_state = PackState::Loading;
        self.status = "正在读取资料包…".into();
        cx.notify();
        let task = cx.background_spawn(async move {
            File::open(path)
                .map_err(|error| error.to_string())
                .and_then(koe_core::read_pack)
        });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| {
                if view.generation == generation {
                    match result {
                        Ok(pack) => {
                            view.status = format!("已打开资料包：{}", pack.title);
                            view.pack_state = PackState::Loaded(pack);
                        }
                        Err(error) => {
                            view.status = format!("无法打开资料包：{error}");
                            view.pack_state = PackState::Error(error);
                        }
                    }
                    cx.notify();
                }
            });
        })
        .detach();
    }

    fn refresh_mcp_publication(&mut self, cx: &mut Context<Self>) {
        if self.mcp_publisher.granted_count() == 0 {
            let _ = self.mcp_publisher.clear_live(&self.mcp_dir);
            self.mcp_lease_task = None;
            return;
        }
        if let Err(error) = self
            .mcp_publisher
            .publish_live(&self.library, &self.mcp_dir, 15)
        {
            self.status = format!("MCP 共享刷新失败：{error:#}");
            return;
        }
        if self.mcp_lease_task.is_none() {
            self.mcp_lease_task = Some(cx.spawn(async |view, cx| {
                loop {
                    cx.background_executor().timer(Duration::from_secs(5)).await;
                    let keep_going = view.update(cx, |view, cx| {
                        if view.mcp_publisher.granted_count() == 0 {
                            view.mcp_lease_task = None;
                            return false;
                        }
                        let _ = view
                            .mcp_publisher
                            .publish_live(&view.library, &view.mcp_dir, 15);
                        cx.notify();
                        true
                    });
                    if !matches!(keep_going, Ok(true)) {
                        break;
                    }
                }
            }));
        }
    }

    fn render_pack_view(&self) -> Div {
        match &self.pack_state {
            PackState::Empty => div().child("选择左侧本机资料，或打开一个 .koepack 资料包。"),
            PackState::Loading => div().child("正在读取资料包…"),
            PackState::Error(error) => div().child(format!("无法打开资料包：{error}")),
            PackState::Loaded(pack) => {
                let segments = pack
                    .segments
                    .iter()
                    .map(|segment| {
                        let milliseconds = segment["startMs"].as_u64().unwrap_or(0);
                        let speaker = segment["speaker"].as_str().unwrap_or("未标注发言人");
                        let text = segment["text"].as_str().unwrap_or("");
                        format!(
                            "{:02}:{:02}  {}  {}",
                            milliseconds / 60000,
                            milliseconds / 1000 % 60,
                            speaker,
                            text
                        )
                    })
                    .collect::<Vec<_>>();
                let minutes = pack
                    .minutes
                    .as_ref()
                    .and_then(|m| m["current"]["text"].as_str())
                    .unwrap_or("暂无纪要");
                div()
                    .flex()
                    .flex_col()
                    .gap_4()
                    .child(div().text_xl().child(pack.title.clone()))
                    .child(div().text_lg().child("校订正文"))
                    .child(pack.text.clone().unwrap_or_else(|| "暂无正文".into()))
                    .child(div().text_lg().child("时码与发言人"))
                    .children(segments.into_iter().map(|line| div().child(line)))
                    .child(div().text_lg().child("纪要"))
                    .child(format_minutes(minutes))
            }
        }
    }

    fn render_recording_view(&self, index: usize, cx: &mut Context<Self>) -> Div {
        let Some(recording) = self.library.recordings.get(index) else {
            return self.render_pack_view();
        };
        let title = recording.display_name.clone();
        let can_play = recording.playable();
        let audio_notice = if !recording.path.is_file() {
            "原音频不在此路径，仍可阅读文字"
        } else if !recording.playable() {
            "此原音频格式尚未接入解码，暂不能播放"
        } else {
            "本机原声"
        };
        let rec_id = recording.recording_id().unwrap_or_default();
        let mcp_granted = !rec_id.is_empty() && self.mcp_publisher.is_granted(&rec_id);
        let mcp_label = if mcp_granted {
            "撤销 MCP 共享"
        } else {
            "授权 MCP 共享"
        };
        let mcp_status = if mcp_granted {
            format!("MCP：本会话已授权共享（{}）", self.mcp_dir.display())
        } else {
            "MCP：未共享（仅在当前会话显式授权后暴露）".to_owned()
        };
        let transcript = if recording.transcript.trim().is_empty() {
            "暂无已保存的转写".to_owned()
        } else {
            recording.transcript.clone()
        };
        let minutes_text = recording
            .formatted_minutes()
            .unwrap_or_else(|| "暂无结构化纪要，点击「生成结构化纪要」即可生成。".into());

        div()
            .flex()
            .flex_col()
            .gap_3()
            .child(div().text_xl().child(title))
            .child(
                div()
                    .text_sm()
                    .child(format!("{audio_notice} · {mcp_status}")),
            )
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .child(
                        Button::new("play")
                            .primary()
                            .label("播放原声")
                            .disabled(!can_play)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if let Some(rec) = this.library.recordings.get(index) {
                                    this.player = None;
                                    match Player::play(&rec.path) {
                                        Ok(player) => {
                                            this.player = Some(player);
                                            this.status = "正在播放".into();
                                            this.playback_task =
                                                Some(cx.spawn(async |view, cx| {
                                                    loop {
                                                        cx.background_executor()
                                                            .timer(Duration::from_millis(200))
                                                            .await;
                                                        let running =
                                                            view.update(cx, |view, cx| {
                                                                if view
                                                                    .player
                                                                    .as_ref()
                                                                    .is_some_and(|p| p.sink.empty())
                                                                {
                                                                    view.player = None;
                                                                    view.status = "播放结束".into();
                                                                    cx.notify();
                                                                }
                                                                view.player.is_some()
                                                            });
                                                        if !matches!(running, Ok(true)) {
                                                            break;
                                                        }
                                                    }
                                                }));
                                        }
                                        Err(error) => {
                                            this.status = format!("无法播放：{error}");
                                        }
                                    }
                                }
                                cx.notify();
                            })),
                    )
                    .child(Button::new("stop").label("停止播放").on_click(cx.listener(
                        |this, _, _, cx| {
                            this.player = None;
                            this.status = "已停止播放".into();
                            cx.notify();
                        },
                    )))
                    .child(
                        Button::new("save-transcript")
                            .label("保存校订标记")
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if let Some(rec) = this.library.recordings.get(index) {
                                    let updated = if rec.transcript.trim().is_empty() {
                                        "说话人 1：桌面端校订记录。".to_owned()
                                    } else {
                                        rec.transcript.clone()
                                    };
                                    match this.library.save_manual_transcript(index, &updated) {
                                        Ok(()) => {
                                            this.status = "已保存转写校订".into();
                                            this.refresh_mcp_publication(cx);
                                        }
                                        Err(error) => {
                                            this.status = format!("保存校订失败：{error:#}");
                                        }
                                    }
                                    cx.notify();
                                }
                            })),
                    )
                    .child(
                        Button::new("generate-minutes")
                            .label("生成结构化纪要")
                            .on_click(cx.listener(move |this, _, _, cx| {
                                match this.library.generate_minutes(index, "提炼会议纪要与行动项")
                                {
                                    Ok(_) => {
                                        this.status = "已生成并保存结构化纪要".into();
                                        this.refresh_mcp_publication(cx);
                                    }
                                    Err(error) => {
                                        this.status = format!("生成纪要失败：{error:#}");
                                    }
                                }
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("toggle-mcp")
                            .label(mcp_label)
                            .disabled(rec_id.is_empty())
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if let Some(rec) = this.library.recordings.get(index)
                                    && let Ok(id) = rec.recording_id()
                                {
                                    if this.mcp_publisher.is_granted(&id) {
                                        this.mcp_publisher.revoke(&id);
                                        this.status = "已撤销该录音的 MCP 会话共享".into();
                                    } else {
                                        this.mcp_publisher.grant(&id);
                                        this.status = "已授权该录音通过 MCP 会话共享".into();
                                    }
                                    this.refresh_mcp_publication(cx);
                                    cx.notify();
                                }
                            })),
                    ),
            )
            .child(div().text_lg().child("校订与转写正文"))
            .child(div().id("transcript").child(transcript))
            .child(div().text_lg().child("结构化纪要"))
            .child(div().id("minutes").child(minutes_text))
    }
}

impl Render for KoeApp {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let smoke_ready = match self.active {
            ActivePane::Pack => {
                matches!(self.pack_state, PackState::Loaded(_) | PackState::Error(_))
            }
            ActivePane::LibraryRecording(_) => {
                !self.library.directory.as_os_str().is_empty()
                    || matches!(self.pack_state, PackState::Error(_))
            }
        };
        if self.smoke && !self.smoke_scheduled && smoke_ready {
            self.smoke_scheduled = true;
            let success = !matches!(self.pack_state, PackState::Error(_));
            window.on_next_frame(move |_, cx| {
                cx.spawn(async move |cx| {
                    cx.background_executor()
                        .timer(Duration::from_millis(800))
                        .await;
                    std::process::exit(if success { 0 } else { 1 });
                })
                .detach();
            });
        }

        let is_recording = self.recorder.is_some();
        let record_label = if is_recording {
            "停止并保存录音"
        } else {
            "开始麦克风录音"
        };
        let can_record = !self.library.directory.as_os_str().is_empty() || is_recording;

        let detail = match self.active {
            ActivePane::LibraryRecording(idx) => self.render_recording_view(idx, cx),
            ActivePane::Pack => self.render_pack_view(),
        };

        div()
            .flex()
            .flex_col()
            .size_full()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .p_6()
            .gap_4()
            .child(
                div()
                    .flex()
                    .justify_between()
                    .items_center()
                    .child(div().text_2xl().child("Koe · 本机资料与纪要工作台"))
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(
                                Button::new("open-library")
                                    .label("打开资料目录")
                                    .on_click(cx.listener(|_, _, _, cx| {
                                        let picker = cx.prompt_for_paths(PathPromptOptions {
                                            files: false,
                                            directories: true,
                                            multiple: false,
                                            prompt: Some("打开 Koe 资料目录".into()),
                                        });
                                        cx.spawn(async move |view, cx| {
                                            if let Ok(Ok(Some(paths))) = picker.await
                                                && let Some(dir) = paths.into_iter().next()
                                            {
                                                let _ = view.update(cx, |view, cx| {
                                                    view.open_library_dir(dir, cx);
                                                });
                                            }
                                        })
                                        .detach();
                                    })),
                            )
                            .child(
                                Button::new("open-pack")
                                    .label("打开资料包")
                                    .on_click(cx.listener(|_, _, _, cx| {
                                        let picker = cx.prompt_for_paths(PathPromptOptions {
                                            files: true,
                                            directories: false,
                                            multiple: false,
                                            prompt: Some("打开 Koe 资料包".into()),
                                        });
                                        cx.spawn(async move |view, cx| {
                                            if let Ok(Ok(Some(paths))) = picker.await
                                                && let Some(path) = paths.into_iter().next()
                                            {
                                                let _ = view.update(cx, |view, cx| {
                                                    view.load_pack(path, cx);
                                                });
                                            }
                                        })
                                        .detach();
                                    })),
                            )
                            .child(
                                Button::new("record-toggle")
                                    .primary()
                                    .label(record_label)
                                    .disabled(!can_record)
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        if let Some(recorder) = this.recorder.take() {
                                            match recorder.stop() {
                                                Ok(receipt) => {
                                                    match this.library.register_recording(
                                                        &receipt.path,
                                                        "桌面麦克风录音",
                                                        "localImport",
                                                    ) {
                                                        Ok(idx) => {
                                                            let _ = this
                                                                .library
                                                                .save_manual_transcript(
                                                                    idx,
                                                                    "说话人 1：桌面端新录制语音待转写与校订。",
                                                                );
                                                            this.active =
                                                                ActivePane::LibraryRecording(idx);
                                                            this.status =
                                                                "录音已保存并加入资料库".into();
                                                        }
                                                        Err(err) => {
                                                            this.status =
                                                                format!("注册录音失败：{err:#}");
                                                        }
                                                    }
                                                }
                                                Err(err) => {
                                                    this.status = format!("停止录音失败：{err:#}");
                                                }
                                            }
                                        } else {
                                            let path = next_recording_path(&this.library.directory);
                                            match WavRecorder::start_default_input(path) {
                                                Ok(rec) => {
                                                    this.recorder = Some(rec);
                                                    this.status = "正在录制麦克风音频…".into();
                                                }
                                                Err(err) => {
                                                    this.status = format!("无法开始录音：{err:#}");
                                                }
                                            }
                                        }
                                        cx.notify();
                                    })),
                            ),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_1()
                    .min_h_0()
                    .gap_6()
                    .child(
                        div()
                            .id("library")
                            .w(px(280.))
                            .overflow_y_scroll()
                            .flex()
                            .flex_col()
                            .gap_2()
                            .children(self.library.recordings.iter().enumerate().map(
                                |(index, recording)| {
                                    let shared = recording
                                        .recording_id()
                                        .ok()
                                        .is_some_and(|id| self.mcp_publisher.is_granted(&id));
                                    let has_minutes = recording.minutes.is_some();
                                    let mut badge = String::new();
                                    if has_minutes {
                                        badge.push_str(" [纪要]");
                                    }
                                    if shared {
                                        badge.push_str(" [MCP]");
                                    }
                                    Button::new(("recording", index))
                                        .label(format!("{}{badge}", recording.display_name))
                                        .on_click(cx.listener(move |this, _, _, cx| {
                                            this.player = None;
                                            this.active = ActivePane::LibraryRecording(index);
                                            this.status = "已选择资料".into();
                                            cx.notify();
                                        }))
                                },
                            )),
                    )
                    .child(
                        div()
                            .id("reader")
                            .flex_1()
                            .min_w_0()
                            .min_h_0()
                            .overflow_y_scroll()
                            .child(detail),
                    ),
            )
            .child(div().text_sm().child(self.status.clone()))
    }
}

enum LaunchTarget {
    None,
    Library(PathBuf),
    Pack(PathBuf),
    Smoke(PathBuf),
}

fn parse_args() -> LaunchTarget {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    match args.as_slice() {
        [] => LaunchTarget::None,
        [flag] if flag == "--help" => {
            println!(
                "Koe 桌面端\n用法：koe-desktop [--library DIR | --pack PATH | --smoke-test PATH]"
            );
            std::process::exit(0);
        }
        [flag, path] if flag == "--library" => LaunchTarget::Library(PathBuf::from(path)),
        [flag, path] if flag == "--pack" => LaunchTarget::Pack(PathBuf::from(path)),
        [flag, path] if flag == "--smoke-test" => LaunchTarget::Smoke(PathBuf::from(path)),
        _ => {
            eprintln!("用法：koe-desktop [--library DIR | --pack PATH | --smoke-test PATH]");
            std::process::exit(2);
        }
    }
}

fn main() {
    let target = parse_args();
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
                    size(px(1080.), px(740.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                cx.new(|cx| {
                    let mut app = KoeApp {
                        library: Library::default(),
                        active: ActivePane::Pack,
                        pack_state: PackState::Empty,
                        generation: 0,
                        player: None,
                        playback_task: None,
                        recorder: None,
                        mcp_publisher: McpPublisher::new(),
                        mcp_dir: std::env::temp_dir().join("koe-desktop-mcp"),
                        mcp_lease_task: None,
                        status: "打开资料目录或 .koepack 资料包；未访问默认资料与凭据".into(),
                        smoke,
                        smoke_scheduled: false,
                    };
                    match target {
                        LaunchTarget::None => {}
                        LaunchTarget::Library(dir) => app.open_library_dir(dir, cx),
                        LaunchTarget::Pack(path) => app.load_pack(path, cx),
                        LaunchTarget::Smoke(path) => {
                            if path.is_dir() {
                                app.open_library_dir(path, cx);
                            } else {
                                app.load_pack(path, cx);
                            }
                        }
                    }
                    app
                })
            },
        )
        .expect("无法打开 Koe 窗口");
        cx.activate(true);
    });
}

#[cfg(test)]
mod tests {
    use koe_core::organize::format_minutes;

    #[test]
    fn renders_legacy_review_items() {
        let result = format_minutes(
            r#"{"title":"会议","overview":"摘要","topics":[],"decisions":[],"actions":[],"questions":[],"review_items":["核对日期"]}"#,
        );
        assert!(result.contains("核对日期"));
    }
}
