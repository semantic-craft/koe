use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex, MutexGuard, PoisonError};
use std::thread;

use tokio::sync::watch;
use transcribe_cpp::{Backend, CancelToken, Model, ModelOptions, RunOptions, Session};

use super::artifacts::{artifact_for, ensure_artifact};
use super::{OfflineSpeechEvent, OfflineSpeechSegment};

const MAX_OUTSTANDING: usize = 4;

fn lock_unpoisoned<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

pub(super) struct Control {
    epoch: watch::Sender<u64>,
    stopped: AtomicBool,
    inference: Mutex<Option<CancelToken>>,
}

impl Control {
    pub(super) fn new() -> Self {
        Self {
            epoch: watch::channel(0).0,
            stopped: AtomicBool::new(false),
            inference: Mutex::new(None),
        }
    }

    pub(super) fn cancel(&self) {
        self.epoch
            .send_modify(|epoch| *epoch = epoch.wrapping_add(1));
        if let Some(token) = lock_unpoisoned(&self.inference).as_ref() {
            token.cancel();
        }
    }

    pub(super) fn check(&self, epoch: u64) -> Result<(), String> {
        if self.stopped.load(Ordering::Acquire) || *self.epoch.borrow() != epoch {
            Err("offline speech operation cancelled".into())
        } else {
            Ok(())
        }
    }

    pub(super) async fn cancelled(&self, epoch: u64) {
        let mut receiver = self.epoch.subscribe();
        loop {
            if self.check(epoch).is_err() {
                return;
            }
            if receiver.changed().await.is_err() {
                return;
            }
        }
    }
}

#[derive(Default)]
struct Events {
    queue: VecDeque<OfflineSpeechEvent>,
    outstanding: usize,
}

impl Events {
    fn push(&mut self, event: OfflineSpeechEvent) {
        if matches!(event, OfflineSpeechEvent::Preparing { .. })
            && matches!(
                self.queue.back(),
                Some(OfflineSpeechEvent::Preparing { .. })
            )
        {
            self.queue.pop_back();
        }
        self.queue.push_back(event);
    }
}

enum Task {
    Prepare(String),
    Transcribe(u64, Vec<i16>),
}

struct Command {
    epoch: u64,
    task: Task,
}

/// Owns one background inference thread and at most four outstanding operations.
///
/// The thread owns the model and session. Dropping the worker requests cancellation
/// and detaches the thread, so native model loading never blocks the caller's drop.
pub struct OfflineSpeechWorker {
    commands: mpsc::SyncSender<Command>,
    control: Arc<Control>,
    events: Arc<Mutex<Events>>,
}

impl OfflineSpeechWorker {
    /// Creates a worker storing only model artifacts beneath `root`.
    pub fn new(root: PathBuf) -> Result<Self, String> {
        std::fs::create_dir_all(&root)
            .map_err(|error| format!("create model directory: {error}"))?;
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|error| format!("create model download runtime: {error}"))?;
        let client = crate::http_client::validated_download_client(
            std::time::Duration::from_secs(30),
            std::time::Duration::from_secs(30),
            false,
        )
        .map_err(|error| format!("create model download client: {error}"))?;
        let (commands, receiver) = mpsc::sync_channel::<Command>(MAX_OUTSTANDING);
        let control = Arc::new(Control::new());
        let events = Arc::new(Mutex::new(Events::default()));
        let worker_control = Arc::clone(&control);
        let worker_events = Arc::clone(&events);
        thread::Builder::new()
            .name("koe-offline-speech".into())
            .spawn(move || {
                let mut loaded: Option<Session> = None;
                while let Ok(command) = receiver.recv() {
                    if worker_control.stopped.load(Ordering::Acquire) {
                        break;
                    }
                    let event = match command.task {
                        Task::Prepare(model_id) => handle_prepare(
                            &mut loaded,
                            &worker_control,
                            command.epoch,
                            model_id,
                            |id| {
                                fetch_artifact(
                                    &root,
                                    id,
                                    &runtime,
                                    &client,
                                    &worker_control,
                                    command.epoch,
                                    &worker_events,
                                )
                            },
                            load_session,
                        ),
                        Task::Transcribe(operation_id, pcm16) => {
                            match transcribe(
                                loaded.as_mut(),
                                &pcm16,
                                &worker_control,
                                command.epoch,
                            ) {
                                Ok((text, segments)) => OfflineSpeechEvent::Transcribed {
                                    operation_id,
                                    text,
                                    segments,
                                },
                                Err(error) => OfflineSpeechEvent::TranscriptionFailed {
                                    operation_id,
                                    error,
                                },
                            }
                        }
                    };
                    lock_unpoisoned(&worker_events).push(event);
                }
            })
            .map_err(|error| format!("start offline speech worker: {error}"))?;
        Ok(Self {
            commands,
            control,
            events,
        })
    }

    /// Queues verified download and loading of a catalog model.
    pub fn prepare(&self, model_id: &str) -> Result<(), String> {
        artifact_for(model_id)?;
        self.submit(Task::Prepare(model_id.into()))
    }

    /// Queues nonempty 16 kHz mono PCM16 audio for the prepared model.
    pub fn transcribe(&self, operation_id: u64, pcm16: Vec<i16>) -> Result<(), String> {
        if pcm16.is_empty() {
            return Err("offline transcription requires nonempty 16 kHz mono PCM16 audio".into());
        }
        self.submit(Task::Transcribe(operation_id, pcm16))
    }

    fn submit(&self, task: Task) -> Result<(), String> {
        let mut events = lock_unpoisoned(&self.events);
        if events.outstanding >= MAX_OUTSTANDING {
            return Err(
                "offline speech queue is full; poll completed operations before retrying".into(),
            );
        }
        let command = Command {
            epoch: *self.control.epoch.borrow(),
            task,
        };
        self.commands
            .try_send(command)
            .map_err(|error| match error {
                mpsc::TrySendError::Full(_) => "offline speech queue is full".to_owned(),
                mpsc::TrySendError::Disconnected(_) => "offline speech worker stopped".to_owned(),
            })?;
        events.outstanding += 1;
        Ok(())
    }

    /// Cancels current and queued operations without waiting for native code.
    /// The loaded model remains available for subsequently submitted audio.
    pub fn cancel(&self) {
        self.control.cancel();
    }

    /// Takes current progress and terminal events and releases their queue slots.
    #[must_use]
    pub fn poll(&self) -> Vec<OfflineSpeechEvent> {
        let mut events = lock_unpoisoned(&self.events);
        let result: Vec<_> = events.queue.drain(..).collect();
        let completed = result
            .iter()
            .filter(|event| !matches!(event, OfflineSpeechEvent::Preparing { .. }))
            .count();
        events.outstanding -= completed;
        result
    }
}

impl Drop for OfflineSpeechWorker {
    fn drop(&mut self) {
        self.control.stopped.store(true, Ordering::Release);
        self.cancel();
    }
}

fn handle_prepare<P, S>(
    loaded: &mut Option<S>,
    control: &Control,
    epoch: u64,
    model_id: String,
    fetch: impl FnOnce(&str) -> Result<P, String>,
    load: impl FnOnce(&str, P) -> Result<S, String>,
) -> OfflineSpeechEvent {
    let artifact = match control.check(epoch).and_then(|()| fetch(&model_id)) {
        Ok(artifact) => artifact,
        Err(error) => return OfflineSpeechEvent::PreparationFailed { model_id, error },
    };
    if let Err(error) = control.check(epoch) {
        return OfflineSpeechEvent::PreparationFailed { model_id, error };
    }
    *loaded = None;
    match load(&model_id, artifact).and_then(|session| {
        control.check(epoch)?;
        Ok(session)
    }) {
        Ok(session) => {
            *loaded = Some(session);
            OfflineSpeechEvent::Ready { model_id }
        }
        Err(error) => OfflineSpeechEvent::PreparationFailed { model_id, error },
    }
}

fn fetch_artifact(
    root: &std::path::Path,
    model_id: &str,
    runtime: &tokio::runtime::Runtime,
    client: &reqwest::Client,
    control: &Control,
    epoch: u64,
    events: &Mutex<Events>,
) -> Result<PathBuf, String> {
    control.check(epoch)?;
    let artifact = artifact_for(model_id)?;
    runtime.block_on(ensure_artifact(
        root,
        &artifact,
        client,
        control,
        epoch,
        |downloaded_bytes| {
            lock_unpoisoned(events).push(OfflineSpeechEvent::Preparing {
                model_id: model_id.into(),
                downloaded_bytes,
                total_bytes: artifact.bytes,
            });
        },
    ))
}

fn load_session(model_id: &str, path: PathBuf) -> Result<Session, String> {
    transcribe_cpp::init_backends_with(
        None::<&std::path::Path>,
        transcribe_cpp::BackendMask::for_backend(Backend::Cpu),
    )
    .map_err(|error| format!("initialize CPU speech backend: {error}"))?;
    let model = Model::load_with(
        path,
        &ModelOptions {
            backend: Backend::Cpu,
            ..Default::default()
        },
    )
    .map_err(|error| format!("load {model_id}: {error}"))?;
    model
        .session()
        .map_err(|error| format!("create {model_id} session: {error}"))
}

fn transcribe(
    session: Option<&mut Session>,
    pcm16: &[i16],
    control: &Control,
    epoch: u64,
) -> Result<(String, Vec<OfflineSpeechSegment>), String> {
    control.check(epoch)?;
    let session = session.ok_or("offline speech model is not ready; prepare a model first")?;
    let token = CancelToken::new();
    session.set_cancel_token(&token);
    *lock_unpoisoned(&control.inference) = Some(token);
    let result = recognize(session, pcm16, control, epoch);
    *lock_unpoisoned(&control.inference) = None;
    session.clear_cancel_token();
    result
}

fn recognize(
    session: &mut Session,
    pcm16: &[i16],
    control: &Control,
    epoch: u64,
) -> Result<(String, Vec<OfflineSpeechSegment>), String> {
    let limits = session
        .limits()
        .map_err(|error| format!("read model audio limits: {error}"))?;
    let mut chunk_samples = 30 * 16_000;
    if limits.effective_max_audio_ms > 0 {
        chunk_samples =
            chunk_samples.min((limits.effective_max_audio_ms as usize).saturating_mul(16));
    }
    let mut texts = Vec::new();
    let mut segments = Vec::new();
    for (index, chunk) in pcm16.chunks(chunk_samples).enumerate() {
        control.check(epoch)?;
        let samples: Vec<_> = chunk
            .iter()
            .map(|sample| f32::from(*sample) / 32768.0)
            .collect();
        let transcript = session
            .run(&samples, &RunOptions::default())
            .map_err(|error| format!("offline transcription failed: {error}"))?;
        control.check(epoch)?;
        let text = transcript.text.trim();
        if !text.is_empty() {
            texts.push(text.to_owned());
        }
        let offset = (index * chunk_samples) as u64 / 16;
        segments.extend(transcript.segments.into_iter().filter_map(|segment| {
            let text = segment.text.trim().to_owned();
            (!text.is_empty()).then(|| OfflineSpeechSegment {
                start_ms: offset + segment.t0_ms.max(0) as u64,
                end_ms: offset + segment.t1_ms.max(segment.t0_ms).max(0) as u64,
                text,
            })
        }));
    }
    Ok((texts.join(" "), segments))
}

#[cfg(test)]
mod tests;
