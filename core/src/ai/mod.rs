//! Tagging a picture with a vision model, the same in every app: the app hands over the picture and
//! what is known about it, the core prepares the picture, asks the model (on this device's GPU, or a
//! service) and reads the tags out of its reply. What the app keeps: when to tag what, and taking a
//! frame from a video (its own player does that).
pub mod devices;
pub mod engine;
pub mod error;
pub mod external;
pub mod picture;
pub mod prompt;
pub mod reply;

use error::{AiError, AiResult, Cancel, Kind};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::Instant;

pub use prompt::Prompt;

/// The model to ask.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ModelRef {
    /// An installed model (`tl_models_installed`), on this device.
    Local { id: String },
    /// A service.
    External(external::Service),
}

/// One picture to tag.
#[derive(Debug, Clone, Deserialize)]
pub struct TagRequest {
    /// A name to call it off by (`tl_ai_cancel`); may be empty.
    #[serde(default)]
    pub job: String,
    pub model: ModelRef,
    /// The picture: a photo, or a frame the app took from a video. Empty: a plain grey picture (to
    /// try a model).
    #[serde(default)]
    pub image: String,
    /// The picture's tags now.
    #[serde(default)]
    pub existing: Vec<String>,
    /// The library's tags, most used first.
    #[serde(default)]
    pub vocabulary: Vec<String>,
    /// The post's text.
    #[serde(default)]
    pub post_text: Option<String>,
    /// A prompt to use instead of the model's (as the user edits it, before saving); none: the
    /// model's own, from the shared settings.
    #[serde(default)]
    pub prompt: Option<Prompt>,
}

/// What the tags of a picture came from: the GPU it ran on, how long it took.
#[derive(Debug, Clone, Serialize)]
pub struct Tagged {
    pub tags: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device: Option<String>,
    pub ms: u64,
}

const LOCAL_MAX_TOKENS: i32 = 160;

impl ModelRef {
    /// The name the model's prompt is kept under.
    pub fn id(&self) -> &str { match self { ModelRef::Local { id } => id, ModelRef::External(s) => &s.id } }
}

/// The tags for one picture. `setting`: the shared settings (the model's prompt is there).
pub fn tag(models_dir: &Path, setting: impl Fn(&str) -> Option<String>, req: &TagRequest) -> AiResult<Tagged> {
    let job = error::Job::start(&req.job);
    let start = Instant::now();
    let jpeg = if req.image.is_empty() { picture::grey() } else {
        picture::tagging_jpeg(Path::new(&req.image)).map_err(|e| AiError::detail(Kind::Unreadable, format!("{e:#}")))?
    };
    let prompt = req.prompt.clone().unwrap_or_else(|| Prompt::for_model(setting, req.model.id()));
    let question = prompt.question(&req.existing, &req.vocabulary, req.post_text.as_deref());
    match &req.model {
        ModelRef::External(service) => {
            let text = crate::download::runtime().block_on(external::describe(service, &prompt.system, &question, &jpeg, &job.cancel))?;
            Ok(Tagged { tags: reply::parse_tags(&text)?, device: None, ms: start.elapsed().as_millis() as u64 })
        }
        ModelRef::Local { id } => {
            let info = crate::models::installed(models_dir).into_iter().find(|m| &m.id == id && m.vision)
                .ok_or_else(|| AiError::new(Kind::NoModel))?;
            let picture = Picture::write(&jpeg)?;
            let dir = PathBuf::from(&info.path);
            let (tags, device) = if info.format == "gguf" {
                let gguf = engine::Gguf {
                    weights: dir.join(info.weights.as_deref().ok_or_else(|| AiError::new(Kind::NoModel))?),
                    projector: info.projector.as_deref().map(|p| dir.join(p)),
                };
                local_gguf(models_dir, &gguf, info.bytes, &picture.0, &prompt.system, &question, &job.cancel)?
            } else {
                let text = engine::describe_mlx(&dir, &picture.0, &prompt.system, &question, LOCAL_MAX_TOKENS)?;
                (reply::parse_tags(&text)?, None)
            };
            Ok(Tagged { tags, device, ms: start.elapsed().as_millis() as u64 })
        }
    }
}

/// The prepared picture as a file for the engine, removed afterwards.
struct Picture(PathBuf);

impl Picture {
    fn write(jpeg: &[u8]) -> AiResult<Picture> {
        let p = std::env::temp_dir().join(format!("tl-ai-{:016x}.jpg", rand::random::<u64>()));
        std::fs::write(&p, jpeg).map_err(|e| AiError::detail(Kind::Unreadable, e.to_string()))?;
        Ok(Picture(p))
    }
}

impl Drop for Picture {
    fn drop(&mut self) { let _ = std::fs::remove_file(&self.0); }
}

/// A GGUF model's tags, on the GPU chosen for it (see [`devices`]).
fn local_gguf(models_dir: &Path, model: &engine::Gguf, bytes: u64, image: &Path, system: &str, question: &str, cancel: &Cancel) -> AiResult<(Vec<String>, Option<String>)> {
    let run = |device: &str| -> AiResult<Vec<String>> {
        cancel.check()?;
        let text = engine::describe_gguf(model, device, image, system, question, LOCAL_MAX_TOKENS)?;
        Ok(reply::parse_tags(&text)?)
    };
    let gpus = devices::gpus();
    if gpus.is_empty() { return Err(AiError::new(Kind::NoGpu)); }
    if !devices::chooses() {
        let d = devices::mobile_gpu(&gpus).map(|d| d.name.clone()).ok_or_else(|| AiError::new(Kind::NoGpu))?;
        return run(&d).map(|t| (t, Some(d)));
    }
    if gpus.len() == 1 { return run(&gpus[0].name).map(|t| (t, Some(gpus[0].name.clone()))); }
    if let Some(d) = devices::remembered(models_dir, &gpus) {
        return match run(&d) {
            Err(e) if e.kind == Kind::Engine => { devices::forget(models_dir); Err(e) }
            r => r.map(|t| (t, Some(d))),
        };
    }
    // more than one GPU and no choice among them yet: this job, on each
    let need = devices::need(bytes);
    let mut trials = Vec::new();
    let mut best: Option<(u64, String, Vec<String>)> = None;
    let mut first_error = None;
    for d in &gpus {
        if d.total > 0 && d.total < need { trials.push((d.name.clone(), None)); continue; }
        let t = Instant::now();
        match run(&d.name) {
            Ok(tags) => {
                let ms = t.elapsed().as_millis() as u64;
                eprintln!("local ai: {} ({}) {ms} ms", d.name, d.description);
                trials.push((d.name.clone(), Some(ms)));
                if best.as_ref().is_none_or(|(b, _, _)| ms < *b) { best = Some((ms, d.name.clone(), tags)); }
            }
            Err(e) if e.kind == Kind::Cancelled => return Err(e),
            Err(e) => {
                eprintln!("local ai: {} ({}) failed: {e}", d.name, d.description);
                trials.push((d.name.clone(), None));
                first_error.get_or_insert(e);
            }
        }
    }
    let Some((_, device, tags)) = best else { return Err(first_error.unwrap_or_else(|| AiError::new(Kind::NoGpu))) };
    devices::remember(models_dir, &devices::Choice { among: devices::fingerprint(&gpus), device: device.clone(), trials });
    Ok((tags, Some(device)))
}

/// What this device has for on-device AI, for the app's settings and the model store.
#[derive(Debug, Clone, Serialize)]
pub struct Hardware {
    /// The engine is there (llama.cpp, or MLX on the Apple devices).
    pub engine: bool,
    /// The GPUs it can run models on (none: on-device AI is off).
    pub gpus: Vec<engine::Device>,
    /// The memory of the largest of them.
    pub memory: Option<u64>,
    /// The GPU chosen among several, when there is a choice.
    pub chosen: Option<String>,
}

pub fn hardware(models_dir: &Path) -> Hardware {
    if engine::has_mlx() {
        return Hardware { engine: true, gpus: Vec::new(), memory: devices::memory(), chosen: None };
    }
    let gpus = devices::gpus();
    let chosen = if devices::chooses() && gpus.len() > 1 { devices::remembered(models_dir, &gpus) }
        else if devices::chooses() { gpus.first().map(|d| d.name.clone()) }
        else { devices::mobile_gpu(&gpus).map(|d| d.name.clone()) };
    let memory = devices::memory();
    Hardware { engine: engine::available(), gpus, memory, chosen }
}
