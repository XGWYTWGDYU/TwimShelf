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

/// Twelve tags of six characters in a code fence take about 130 of Gemma 4's tokens (measured:
/// 107 for ten); an answer that runs out of budget is a failure now, so leave room.
const LOCAL_MAX_TOKENS: i32 = 256;

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
                // MLX does not say why it stopped: the list itself must be whole and not loop
                (reply::local_tags(&text, reply::Finish::Ended)?, None)
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
        let (text, finish) = engine::describe_gguf(model, device, image, system, question, LOCAL_MAX_TOKENS)?;
        Ok(reply::local_tags(&text, finish)?)
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
    let need = crate::hub::need(bytes);
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
    /// Android: who made the chip and which it is (`ro.soc.manufacturer`, `ro.soc.model`, e.g.
    /// "QTI", "SM8975"), for what the app says about on-device AI there.
    pub soc: Option<Soc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Soc {
    pub manufacturer: String,
    pub model: String,
}

#[cfg(target_os = "android")]
fn soc() -> Option<Soc> {
    use std::ffi::{c_char, c_int, CStr, CString};
    extern "C" { fn __system_property_get(name: *const c_char, value: *mut c_char) -> c_int; }
    let get = |key: &str| {
        let k = CString::new(key).ok()?;
        let mut v = [0 as c_char; 92]; // PROP_VALUE_MAX
        unsafe { __system_property_get(k.as_ptr(), v.as_mut_ptr()) };
        let s = unsafe { CStr::from_ptr(v.as_ptr()) }.to_string_lossy().trim().to_string();
        (!s.is_empty()).then_some(s)
    };
    let manufacturer = get("ro.soc.manufacturer")?;
    Some(Soc { manufacturer, model: get("ro.soc.model").unwrap_or_default() })
}

#[cfg(not(target_os = "android"))]
fn soc() -> Option<Soc> { None }

pub fn hardware(models_dir: &Path) -> Hardware {
    if engine::has_mlx() {
        return Hardware { engine: true, gpus: Vec::new(), memory: devices::memory(), chosen: None, soc: None };
    }
    let gpus = devices::gpus();
    let chosen = if devices::chooses() && gpus.len() > 1 { devices::remembered(models_dir, &gpus) }
        else if devices::chooses() { gpus.first().map(|d| d.name.clone()) }
        else { devices::mobile_gpu(&gpus).map(|d| d.name.clone()) };
    let memory = devices::memory();
    Hardware { engine: engine::available(), gpus, memory, chosen, soc: soc() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Read, Write};

    /// A service on this machine that answers like an OpenAI-compatible one, and keeps what it was
    /// sent: the model asked, the key, whether the picture was a JPEG.
    fn service(reply: &'static str) -> (String, std::sync::mpsc::Receiver<serde_json::Value>) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for stream in listener.incoming().take(4) {
                let mut s = stream.unwrap();
                let mut r = BufReader::new(s.try_clone().unwrap());
                let (mut line, mut len, mut auth) = (String::new(), 0usize, String::new());
                r.read_line(&mut line).unwrap();
                let path = line.split_whitespace().nth(1).unwrap_or("").to_string();
                loop {
                    let mut h = String::new();
                    r.read_line(&mut h).unwrap();
                    if h == "\r\n" || h.is_empty() { break; }
                    let l = h.to_ascii_lowercase();
                    if let Some(v) = l.strip_prefix("content-length:") { len = v.trim().parse().unwrap(); }
                    if l.starts_with("authorization:") { auth = h["authorization:".len()..].trim().to_string(); }
                }
                let mut body = vec![0; len];
                r.read_exact(&mut body).unwrap();
                let answer = if path.ends_with("/models") {
                    r#"{"data":[{"id":"first-model"}]}"#.to_string()
                } else {
                    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
                    let url = v["messages"][1]["content"][1]["image_url"]["url"].as_str().unwrap_or("");
                    let jpeg = base64::engine::general_purpose::STANDARD.decode(url.split(',').nth(1).unwrap_or("")).unwrap_or_default();
                    use base64::Engine;
                    tx.send(serde_json::json!({ "model": v["model"], "auth": auth, "jpeg": jpeg.starts_with(&[0xff, 0xd8]), "question": v["messages"][1]["content"][0]["text"] })).unwrap();
                    serde_json::json!({ "choices": [{ "message": { "content": reply } }] }).to_string()
                };
                write!(s, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", answer.len(), answer).unwrap();
            }
        });
        (url, rx)
    }

    #[test]
    fn a_service_tags_a_picture() {
        let (url, sent) = service("思考中</think>[\"猫\",\"沙发\"]");
        let req: TagRequest = serde_json::from_value(serde_json::json!({
            "model": { "kind": "external", "id": "ext:test", "url": url, "model": "", "key": "TEST-KEY" },
            "existing": ["旧标签"],
        })).unwrap();
        let none = |_: &str| None;
        let got = tag(Path::new("/nonexistent"), none, &req).unwrap();
        assert_eq!(got.tags, ["猫", "沙发"]);
        let s = sent.recv().unwrap();
        // no model named: the service's first; the key as a bearer token; a JPEG; what is known
        assert_eq!((s["model"].as_str(), s["auth"].as_str(), s["jpeg"].as_bool()), (Some("first-model"), Some("Bearer TEST-KEY"), Some(true)));
        assert!(s["question"].as_str().unwrap().contains("旧标签"));
    }

    #[test]
    fn a_reply_without_tags_is_a_failed_analysis() {
        let (url, _sent) = service("I cannot help with that.");
        let req: TagRequest = serde_json::from_value(serde_json::json!({ "model": { "kind": "external", "url": url, "model": "m" } })).unwrap();
        let none = |_: &str| None;
        let e = tag(Path::new("/nonexistent"), none, &req).unwrap_err();
        assert!(matches!(e.kind, Kind::BadTags | Kind::NoTags), "{e}");
    }

    #[test]
    fn a_local_model_needs_a_gpu_never_the_processor() {
        // no llama.cpp here (a plain cargo test): no GPU, so no running the model at all
        let dir = std::env::temp_dir().join(format!("tl-nogpu-{}", rand::random::<u64>()));
        let m = dir.join("tiny");
        std::fs::create_dir_all(&m).unwrap();
        let file = |n: &str| { let mut v = b"GGUF".to_vec(); v.extend([3, 0, 0, 0, 0, 0, 0, 0]); std::fs::write(m.join(n), v).unwrap(); };
        file("w.gguf");
        file("p.gguf");
        std::fs::write(m.join("tl-model.json"), r#"{"format":"gguf","weights":"w.gguf","projector":"p.gguf"}"#).unwrap();
        let req: TagRequest = serde_json::from_value(serde_json::json!({ "model": { "kind": "local", "id": "tiny" } })).unwrap();
        let none = |_: &str| None;
        let e = tag(&dir, none, &req).unwrap_err();
        assert_eq!(e.kind, Kind::NoGpu);
        let _ = std::fs::remove_dir_all(dir);
    }
}
