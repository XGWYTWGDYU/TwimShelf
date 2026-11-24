//! Why tagging a picture did not work, as the apps show it, and how a job is called off.
use serde::Serialize;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

/// The kinds the apps know (their message keys follow from these names).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    BadUrl,
    Http,
    NoModel,
    Empty,
    InvalidResponse,
    Transport,
    Timeout,
    Cancelled,
    /// The picture could not be read.
    Unreadable,
    /// The model answered, but not with a list of tags (or with pieces of its syntax as tags).
    BadTags,
    /// The model's list holds no tags.
    NoTags,
    /// No GPU this device can run models on: on-device AI is off (never the processor).
    NoGpu,
    /// The on-device engine failed (a damaged model, out of memory, a GPU that gave up).
    Engine,
}

#[derive(Debug, Clone, Serialize)]
pub struct AiError {
    pub kind: Kind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<u16>,
    /// Sanitized text from the service or engine, never a request, header or credential.
    pub detail: String,
}

impl AiError {
    pub fn new(kind: Kind) -> Self { AiError { kind, status: None, detail: String::new() } }
    pub fn detail(kind: Kind, detail: impl Into<String>) -> Self { AiError { kind, status: None, detail: detail.into() } }
}

impl std::fmt::Display for AiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}", self.kind)?;
        if let Some(s) = self.status { write!(f, " {s}")?; }
        if !self.detail.is_empty() { write!(f, ": {}", self.detail)?; }
        Ok(())
    }
}

impl std::error::Error for AiError {}

impl From<crate::ai::reply::ReplyError> for AiError {
    fn from(e: crate::ai::reply::ReplyError) -> Self {
        AiError::new(match e { crate::ai::reply::ReplyError::Bad => Kind::BadTags, crate::ai::reply::ReplyError::None => Kind::NoTags })
    }
}

pub type AiResult<T> = Result<T, AiError>;

/// A job the app can call off by its name (`tl_ai_cancel`).
#[derive(Clone, Default)]
pub struct Cancel(Arc<(AtomicBool, tokio::sync::Notify)>);

impl Cancel {
    pub fn cancelled(&self) -> bool { self.0 .0.load(Ordering::SeqCst) }
    pub fn cancel(&self) { self.0 .0.store(true, Ordering::SeqCst); self.0 .1.notify_waiters(); }
    pub fn check(&self) -> AiResult<()> { if self.cancelled() { Err(AiError::new(Kind::Cancelled)) } else { Ok(()) } }
    /// Resolves once the job is called off.
    pub async fn wait(&self) {
        loop {
            let notified = self.0 .1.notified();
            if self.cancelled() { return; }
            notified.await;
        }
    }
}

fn jobs() -> &'static Mutex<HashMap<String, Cancel>> {
    static J: OnceLock<Mutex<HashMap<String, Cancel>>> = OnceLock::new();
    J.get_or_init(Default::default)
}

/// The job named `name` while it runs (an empty name: one nobody can call off).
pub struct Job { name: String, pub cancel: Cancel }

impl Job {
    pub fn start(name: &str) -> Job {
        let cancel = Cancel::default();
        if !name.is_empty() { jobs().lock().unwrap_or_else(|e| e.into_inner()).insert(name.to_string(), cancel.clone()); }
        Job { name: name.to_string(), cancel }
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        if !self.name.is_empty() { jobs().lock().unwrap_or_else(|e| e.into_inner()).remove(&self.name); }
    }
}

/// Calls off the job named `name`, if it runs.
pub fn cancel(name: &str) {
    if let Some(c) = jobs().lock().unwrap_or_else(|e| e.into_inner()).get(name) { c.cancel(); }
}
