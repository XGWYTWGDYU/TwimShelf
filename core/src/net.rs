//! Remote post resolution for public posts (FxTwitter). Protected posts come from the separate
//! module behind `crate::protected`.
use crate::model::{MediaKind, PostMeta};
use anyhow::{anyhow, bail, Context};
use serde_json::Value;
use std::sync::OnceLock;

#[derive(Debug, Clone)]
pub struct RemoteMedia { pub kind: MediaKind, pub url: String, pub headers: Vec<(String, String)> }

#[derive(Debug, Clone)]
pub struct RemotePost { pub meta: PostMeta, pub media: Vec<RemoteMedia> }

/// Parses `https://(x|twitter|fxtwitter…).com/<user>/status/<id>` into (user, id).
pub fn parse_status_url(url: &str) -> Option<(String, String)> {
    let api = crate::bookmarks::to_fx_api(url)?;
    let rest = api.strip_prefix("https://api.fxtwitter.com/")?;
    let (user, id) = rest.split_once("/status/")?;
    Some((user.to_string(), id.to_string()))
}

pub fn client() -> reqwest::Client {
    static C: OnceLock<reqwest::Client> = OnceLock::new();
    C.get_or_init(|| reqwest::Client::builder()
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15")
        .connect_timeout(std::time::Duration::from_secs(15))
        // a stalled server cannot hold a download forever (large videos still stream for as long as data flows)
        .read_timeout(std::time::Duration::from_secs(60))
        .https_only(true)
        .build().expect("http client")).clone()
}

/// Reads a response body up to `max` bytes (an answer larger than that is refused, not buffered).
pub async fn read_limited(resp: reqwest::Response, max: usize) -> anyhow::Result<Vec<u8>> {
    use futures_util::StreamExt;
    if resp.content_length().map_or(false, |n| n as usize > max) { bail!(tr!("net.tooLarge")); }
    let mut out = Vec::new();
    let mut s = resp.bytes_stream();
    while let Some(c) = s.next().await {
        let c = c?;
        if out.len() + c.len() > max { bail!(tr!("net.tooLarge")); }
        out.extend_from_slice(&c);
    }
    Ok(out)
}

fn best_mp4(variants: &[Value]) -> Option<String> {
    variants.iter()
        .filter(|v| v["content_type"].as_str().map_or(false, |c| c == "video/mp4") || v["url"].as_str().map_or(false, |u| u.contains(".mp4")))
        .max_by_key(|v| v["bitrate"].as_u64().unwrap_or(0))
        .and_then(|v| v["url"].as_str().map(str::to_string))
}

// ---------- FxTwitter ----------

pub fn parse_fx(v: &Value) -> anyhow::Result<RemotePost> {
    if v["code"].as_i64() != Some(200) { bail!("FxTwitter: {}", v["message"].as_str().unwrap_or("error")); }
    let t = &v["tweet"];
    let meta = PostMeta {
        id: t["id"].as_str().context("tweet.id")?.to_string(),
        author_name: t["author"]["name"].as_str().map(str::to_string),
        screen_name: t["author"]["screen_name"].as_str().map(str::to_string),
        text: t["text"].as_str().map(str::to_string).filter(|s| !s.is_empty()),
        created_at: t["created_at"].as_str().map(str::to_string),
        url: t["url"].as_str().map(str::to_string),
    };
    let mut media = vec![];
    for m in t["media"]["all"].as_array().into_iter().flatten() {
        match m["type"].as_str() {
            Some("photo") => if let Some(u) = m["url"].as_str() { media.push(RemoteMedia { kind: MediaKind::Photo, url: orig_photo(u), headers: vec![] }) },
            Some("video") | Some("gif") => {
                let u = m["variants"].as_array().and_then(|vs| best_mp4(vs))
                    .or_else(|| m["url"].as_str().filter(|u| u.contains(".mp4")).map(str::to_string));
                if let Some(u) = u { media.push(RemoteMedia { kind: MediaKind::Video, url: u, headers: vec![] }) }
            }
            _ => {}
        }
    }
    Ok(RemotePost { meta, media })
}

fn orig_photo(u: &str) -> String {
    if u.contains("name=") { u.to_string() } else if u.contains('?') { format!("{u}&name=orig") } else { format!("{u}?name=orig") }
}

pub async fn fetch_fx(url: &str) -> anyhow::Result<RemotePost> {
    let api = crate::bookmarks::to_fx_api(url).ok_or_else(|| anyhow!("not a status link: {url}"))?;
    let resp = client().get(&api).timeout(std::time::Duration::from_secs(30)).send().await?;
    let v: Value = serde_json::from_slice(&read_limited(resp, 8 << 20).await?)?;
    parse_fx(&v)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn fx_photo_and_video() {
        let v = json!({"code":200,"tweet":{"id":"1","url":"https://x.com/a/status/1","text":"hi","created_at":"x",
            "author":{"name":"A","screen_name":"a"},
            "media":{"all":[{"type":"photo","url":"https://pbs.twimg.com/media/X.jpg?name=orig"},
                {"type":"video","url":"https://video.twimg.com/v/low.mp4","variants":[
                    {"content_type":"application/x-mpegURL","url":"https://video.twimg.com/v/pl.m3u8"},
                    {"content_type":"video/mp4","bitrate":256000,"url":"https://video.twimg.com/v/low.mp4"},
                    {"content_type":"video/mp4","bitrate":2176000,"url":"https://video.twimg.com/v/high.mp4"}]}]}}});
        let p = parse_fx(&v).unwrap();
        assert_eq!(p.meta.screen_name.as_deref(), Some("a"));
        assert_eq!(p.media.len(), 2);
        assert_eq!(p.media[1].url, "https://video.twimg.com/v/high.mp4");
    }
}
