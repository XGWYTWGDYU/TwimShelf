//! A vision model as a service: any OpenAI-compatible endpoint (a cloud service, or Ollama, LM Studio
//! and the like on the LAN).
use super::error::{AiError, AiResult, Cancel, Kind};
use base64::Engine;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

/// A service as the app keeps it: its address, the model to ask (empty: the first it offers) and
/// its key (the app's secure storage holds it; it only passes through here).
#[derive(Debug, Clone, Deserialize)]
pub struct Service {
    /// The app's name for it (`ext:…`), which its prompt is kept under.
    #[serde(default)]
    pub id: String,
    pub url: String,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub key: Option<String>,
}

const MAX_REPLY: usize = 2 * 1024 * 1024;

fn client() -> &'static reqwest::Client {
    static C: OnceLock<reqwest::Client> = OnceLock::new();
    C.get_or_init(|| reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(120))
        .redirect(reqwest::redirect::Policy::none())
        .build().expect("http client"))
}

/// The address of `path` (`chat/completions`, `models`) of the service at `base`, however the user
/// wrote it (with or without the scheme, `/v1`, or the path itself).
pub fn endpoint(base: &str, path: &str) -> AiResult<reqwest::Url> {
    let mut v = base.trim().to_string();
    if !v.contains("://") { v = format!("http://{v}"); }
    while v.ends_with('/') { v.pop(); }
    for tail in ["/chat/completions", "/models"] {
        if let Some(s) = v.strip_suffix(tail) { v = s.to_string(); }
    }
    if !v.ends_with("/v1") { v += "/v1"; }
    let url = reqwest::Url::parse(&format!("{v}/{path}")).map_err(|_| AiError::new(Kind::BadUrl))?;
    let ok = matches!(url.scheme(), "http" | "https") && url.host_str().is_some_and(|h| !h.is_empty())
        && url.username().is_empty() && url.password().is_none() && url.query().is_none() && url.fragment().is_none();
    if !ok { return Err(AiError::new(Kind::BadUrl)); }
    Ok(url)
}

/// What turns a model's reasoning off, as this service spells it. Services that answer with the
/// result alone get nothing; the rest of the world (local servers) gets the usual words.
pub fn thinking_off(host: &str) -> Value {
    let h = host.to_lowercase();
    let at = |d: &str| h == d || h.ends_with(&format!(".{d}"));
    if at("openai.com") || at("openai.azure.com") || at("x.ai") || at("anthropic.com") { return json!({}); }
    if at("deepseek.com") || at("bigmodel.cn") || at("z.ai") { return json!({"thinking": {"type": "disabled"}}); }
    if at("aliyuncs.com") || at("siliconflow.cn") || at("siliconflow.com") { return json!({"enable_thinking": false}); }
    if at("openrouter.ai") { return json!({"reasoning": {"enabled": false}}); }
    if at("googleapis.com") { return json!({"reasoning_effort": "none"}); }
    json!({"think": false, "enable_thinking": false, "chat_template_kwargs": {"enable_thinking": false}})
}

/// Services that refused the switch above: asked plainly from then on.
fn refused_thinking_off() -> &'static Mutex<HashSet<String>> {
    static R: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    R.get_or_init(Default::default)
}

pub fn body(model: &str, system: &str, question: &str, jpeg: &[u8], extra: &Value) -> Value {
    let mut b = json!({
        "model": model,
        "max_tokens": 300,
        "temperature": 0.1,
        "stream": false,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": [
                {"type": "text", "text": question},
                {"type": "image_url", "image_url": {"url": format!("data:image/jpeg;base64,{}", base64::engine::general_purpose::STANDARD.encode(jpeg))}},
            ]},
        ],
    });
    if let (Some(o), Some(e)) = (b.as_object_mut(), extra.as_object()) {
        for (k, v) in e { o.insert(k.clone(), v.clone()); }
    }
    b
}

/// The text of a chat completion (never the parts that hold the model's reasoning).
pub fn answer(data: &[u8]) -> AiResult<String> {
    let v: Value = serde_json::from_slice(data).map_err(|_| AiError::new(Kind::InvalidResponse))?;
    let content = &v["choices"][0]["message"]["content"];
    if let Some(s) = content.as_str().filter(|s| !s.is_empty()) { return Ok(s.to_string()); }
    if let Some(parts) = content.as_array() {
        let text: String = parts.iter()
            .filter(|p| { let t = p["type"].as_str().unwrap_or("").to_lowercase(); !t.contains("think") && !t.contains("reason") })
            .filter_map(|p| p["text"].as_str()).collect();
        if !text.is_empty() { return Ok(text); }
    }
    Err(AiError::new(Kind::Empty))
}

async fn send(service: &Service, path: &str, body: Option<&Value>, cancel: &Cancel) -> AiResult<Vec<u8>> {
    cancel.check()?;
    let url = endpoint(&service.url, path)?;
    let mut req = match body { Some(b) => client().post(url).json(b), None => client().get(url) };
    let key = service.key.as_deref().filter(|k| !k.is_empty());
    if let Some(k) = key { req = req.bearer_auth(k); }
    let work = async {
        let resp = req.send().await.map_err(|e| AiError::new(if e.is_timeout() { Kind::Timeout } else { Kind::Transport }))?;
        let status = resp.status();
        let mut data = Vec::new();
        let mut stream = resp.bytes_stream();
        use futures_util::StreamExt;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| AiError::new(if e.is_timeout() { Kind::Timeout } else { Kind::Transport }))?;
            if data.len() + chunk.len() > MAX_REPLY { return Err(AiError::new(Kind::InvalidResponse)); }
            data.extend_from_slice(&chunk);
        }
        if !status.is_success() {
            let parsed: Option<Value> = serde_json::from_slice(&data).ok();
            let mut message = parsed.as_ref().and_then(|v| v["error"]["message"].as_str().or(v["error"].as_str()).map(str::to_string))
                .unwrap_or_else(|| String::from_utf8_lossy(&data[..data.len().min(200)]).into_owned());
            if let Some(k) = key { message = message.replace(k, ""); }
            return Err(AiError { kind: Kind::Http, status: Some(status.as_u16()), detail: message });
        }
        Ok(data)
    };
    tokio::select! {
        r = work => { cancel.check()?; r }
        _ = cancel.wait() => Err(AiError::new(Kind::Cancelled)),
    }
}

/// The models the service offers.
pub async fn models(service: &Service, cancel: &Cancel) -> AiResult<Vec<String>> {
    let v: Value = serde_json::from_slice(&send(service, "models", None, cancel).await?).map_err(|_| AiError::new(Kind::InvalidResponse))?;
    Ok(v["data"].as_array().map(|d| d.iter().filter_map(|r| r["id"].as_str().map(str::to_string)).collect()).unwrap_or_default())
}

/// The service's answer about the picture.
pub async fn describe(service: &Service, system: &str, question: &str, jpeg: &[u8], cancel: &Cancel) -> AiResult<String> {
    let mut name = service.model.trim_matches(|c: char| c.is_whitespace() && c != '\n' && c != '\r').to_string();
    if name.is_empty() {
        name = models(service, cancel).await?.into_iter().next().ok_or_else(|| AiError::new(Kind::NoModel))?;
    }
    let refused = refused_thinking_off().lock().unwrap_or_else(|e| e.into_inner()).contains(&service.url);
    let off = if refused { json!({}) } else { thinking_off(endpoint(&service.url, "chat/completions")?.host_str().unwrap_or("")) };
    let data = match send(service, "chat/completions", Some(&body(&name, system, question, jpeg, &off)), cancel).await {
        Err(e) if off.as_object().is_some_and(|o| !o.is_empty()) && e.kind == Kind::Http && matches!(e.status, Some(400 | 422)) => {
            refused_thinking_off().lock().unwrap_or_else(|e| e.into_inner()).insert(service.url.clone());
            send(service, "chat/completions", Some(&body(&name, system, question, jpeg, &json!({}))), cancel).await?
        }
        r => r?,
    };
    answer(&data)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoints() {
        assert_eq!(endpoint("localhost:11434", "models").unwrap().as_str(), "http://localhost:11434/v1/models");
        assert_eq!(endpoint("https://api.x.ai/v1/chat/completions/", "models").unwrap().as_str(), "https://api.x.ai/v1/models");
        assert!(endpoint("https://u:p@host", "models").is_err());
        assert!(endpoint("ftp://host", "models").is_err());
    }

    #[test]
    fn answers() {
        assert_eq!(answer(br#"{"choices":[{"message":{"content":"[\"a\"]"}}]}"#).unwrap(), "[\"a\"]");
        assert_eq!(answer(br#"{"choices":[{"message":{"content":[{"type":"thinking","text":"x"},{"type":"text","text":"y"}]}}]}"#).unwrap(), "y");
        assert_eq!(answer(b"{}").unwrap_err().kind, Kind::Empty);
        assert_eq!(answer(b"nope").unwrap_err().kind, Kind::InvalidResponse);
    }
}
