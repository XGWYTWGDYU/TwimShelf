//! Response parsing.
//!
//! GraphQL responses are trees of modules and instructions whose shape changes regularly, so the
//! tweet is found by walking for an object with the requested `rest_id` instead of following a
//! fixed path. Everything else is read defensively and only the fields in `ProtectedPost` are
//! returned.

use serde_json::Value;
use tl_protected_api::{Account, MediaKind, ProtectedError, ProtectedMedia, ProtectedPost};

use crate::date::format_x_date;
use crate::http::{media_headers, Cookies};

const MEDIA_ARRAYS: &[&str] = &[
    "/legacy/extended_entities/media",
    "/legacy/entities/media",
    "/extended_entities/media",
    "/entities/media",
];

pub(crate) fn parse_tweet_response(
    root: &Value,
    expected_id: &str,
    cookies: &Cookies,
) -> Result<ProtectedPost, ProtectedError> {
    if let Some(tweet) = find_tweet(root, expected_id) {
        return parse_tweet(tweet, expected_id, cookies);
    }
    if has_unavailable_tweet(root) {
        return Err(ProtectedError::NotFound(
            "帖子不存在、已删除或当前账号无权查看".into(),
        ));
    }
    if root.get("data").is_none_or(Value::is_null) {
        return Err(ProtectedError::Other(
            "X 返回的数据为空（接口格式可能已变化）".into(),
        ));
    }
    Err(ProtectedError::NotFound(
        "帖子不存在、已删除或当前账号无权查看".into(),
    ))
}

fn parse_tweet(
    tweet: &Value,
    expected_id: &str,
    cookies: &Cookies,
) -> Result<ProtectedPost, ProtectedError> {
    let tweet = unwrap_visibility(tweet);
    let id = rest_id(tweet).unwrap_or_else(|| expected_id.to_string());
    let legacy = tweet.get("legacy").ok_or_else(|| {
        ProtectedError::Other("帖子数据缺少 legacy 字段（接口格式可能已变化）".into())
    })?;
    let author = tweet
        .pointer("/core/user_results/result")
        .or_else(|| tweet.pointer("/core/user_result/result"))
        .or_else(|| tweet.get("author"));
    let screen_name = author
        .and_then(|author| string_at(author, &["/core/screen_name", "/legacy/screen_name"]))
        .map(|name| name.trim().trim_start_matches('@').to_string())
        .filter(|name| !name.is_empty());
    let author_name = author.and_then(|author| string_at(author, &["/core/name", "/legacy/name"]));
    let protected = author.is_some_and(author_is_protected);

    let note_text = string_at(tweet, &["/note_tweet/note_tweet_results/result/text"]);
    let full_text = string_at(legacy, &["/full_text", "/text"])
        .or_else(|| string_at(tweet, &["/full_text", "/text"]));
    let raw_text = note_text.or(full_text).unwrap_or_default();

    let direct_entities = media_entities(tweet);
    let retweeted = tweet
        .pointer("/legacy/retweeted_status_result/result")
        .map(unwrap_visibility);
    let mut text_urls = media_urls(&direct_entities);
    if let Some(retweeted) = retweeted {
        text_urls.extend(media_urls(&media_entities(retweeted)));
    }
    let mut text = strip_media_links(&raw_text, &text_urls);
    text = decode_entities(&text);
    let text = text.trim_end().to_string();
    let text = if text.is_empty() { None } else { Some(text) };

    let created_at = string_at(legacy, &["/created_at"])
        .or_else(|| string_at(tweet, &["/created_at"]))
        .and_then(|date| format_x_date(&date));

    let mut media = build_media(&direct_entities, protected, cookies);
    if media.is_empty() {
        if let Some(retweeted) = retweeted {
            let retweeted_entities = media_entities(retweeted);
            let retweeted_protected =
                retweeted_author(retweeted).is_some_and(author_is_protected) || protected;
            media = build_media(&retweeted_entities, retweeted_protected, cookies);
        }
    }
    if media.is_empty() {
        return Err(ProtectedError::NoMedia);
    }

    let url = screen_name
        .as_ref()
        .map(|screen_name| format!("https://x.com/{screen_name}/status/{id}"));
    Ok(ProtectedPost {
        id,
        author_name,
        screen_name,
        text,
        created_at,
        url,
        media,
    })
}

fn find_tweet<'a>(root: &'a Value, expected_id: &str) -> Option<&'a Value> {
    let mut found = None;
    walk(root, &mut |value| {
        if found.is_none() && is_tweet_like(value) && rest_id(value).as_deref() == Some(expected_id)
        {
            found = Some(value);
        }
    });
    found
}

fn has_unavailable_tweet(root: &Value) -> bool {
    let mut found = false;
    walk(root, &mut |value| {
        let typename = value
            .get("__typename")
            .and_then(Value::as_str)
            .unwrap_or("");
        if matches!(typename, "TweetTombstone" | "TweetUnavailable") {
            found = true;
        }
    });
    found
}

fn walk<'a>(value: &'a Value, visit: &mut impl FnMut(&'a Value)) {
    match value {
        Value::Object(map) => {
            visit(value);
            for child in map.values() {
                walk(child, visit);
            }
        }
        Value::Array(items) => {
            for item in items {
                walk(item, visit);
            }
        }
        _ => {}
    }
}

fn is_tweet_like(value: &Value) -> bool {
    let typename = value.get("__typename").and_then(Value::as_str);
    if !matches!(
        typename,
        None | Some("Tweet") | Some("TweetWithVisibilityResults")
    ) {
        return false;
    }
    let has_text = value.pointer("/legacy/full_text").is_some()
        || value.pointer("/legacy/created_at").is_some()
        || value.pointer("/legacy/text").is_some();
    let has_author = value.pointer("/core/user_results").is_some()
        || value.pointer("/core/user_result").is_some();
    value.get("rest_id").is_some() && (has_text || has_author)
}

fn unwrap_visibility(value: &Value) -> &Value {
    if value.get("__typename").and_then(Value::as_str) == Some("TweetWithVisibilityResults") {
        value.get("tweet").unwrap_or(value)
    } else {
        value
    }
}

fn rest_id(value: &Value) -> Option<String> {
    value.get("rest_id").and_then(|id| {
        id.as_str()
            .map(str::to_string)
            .or_else(|| id.as_i64().map(|number| number.to_string()))
    })
}

fn author_is_protected(author: &Value) -> bool {
    author
        .pointer("/privacy/protected")
        .and_then(Value::as_bool)
        .or_else(|| author.pointer("/legacy/protected").and_then(Value::as_bool))
        .unwrap_or(false)
}

fn retweeted_author(tweet: &Value) -> Option<&Value> {
    tweet
        .pointer("/core/user_results/result")
        .or_else(|| tweet.pointer("/core/user_result/result"))
        .or_else(|| tweet.get("author"))
}

fn media_entities(tweet: &Value) -> Vec<&Value> {
    for path in MEDIA_ARRAYS {
        if let Some(items) = tweet.pointer(path).and_then(Value::as_array) {
            if !items.is_empty() {
                return items.iter().collect();
            }
        }
    }
    Vec::new()
}

fn media_urls<'a>(entities: &[&'a Value]) -> Vec<&'a str> {
    entities
        .iter()
        .filter_map(|entity| entity.get("url").and_then(Value::as_str))
        .filter(|url| !url.is_empty())
        .collect()
}

fn build_media(entities: &[&Value], protected: bool, cookies: &Cookies) -> Vec<ProtectedMedia> {
    entities
        .iter()
        .filter_map(|entity| {
            let kind = entity
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or("photo");
            let (kind, url) = match kind {
                "video" | "animated_gif" => (MediaKind::Video, best_mp4(entity)?),
                "photo" => (MediaKind::Photo, original_photo(entity)?),
                _ => {
                    if entity.get("video_info").is_some() {
                        (MediaKind::Video, best_mp4(entity)?)
                    } else {
                        (MediaKind::Photo, original_photo(entity)?)
                    }
                }
            };
            // Only send the session to X's own media CDN, and only when the author is
            // protected (public CDN files do not need it).
            let headers = if protected && is_x_media_url(&url) {
                media_headers(cookies)
            } else {
                Vec::new()
            };
            Some(ProtectedMedia { kind, url, headers })
        })
        .collect()
}

fn is_x_media_url(url: &str) -> bool {
    let Ok(parsed) = url::Url::parse(url) else {
        return false;
    };
    if parsed.scheme() != "https" {
        return false;
    }
    let host = parsed.host_str().unwrap_or("").to_ascii_lowercase();
    host == "twimg.com" || host.ends_with(".twimg.com")
}

fn original_photo(entity: &Value) -> Option<String> {
    let base = entity
        .get("media_url_https")
        .and_then(Value::as_str)
        .or_else(|| entity.get("media_url").and_then(Value::as_str))?
        .split('?')
        .next()?
        .trim();
    if !base.starts_with("https://") {
        return None;
    }
    Some(format!("{base}?name=orig"))
}

fn best_mp4(entity: &Value) -> Option<String> {
    let variants = entity
        .pointer("/video_info/variants")
        .and_then(Value::as_array)?;
    variants
        .iter()
        .filter(|variant| {
            let content_type = variant
                .get("content_type")
                .and_then(Value::as_str)
                .unwrap_or("");
            let url = variant.get("url").and_then(Value::as_str).unwrap_or("");
            !url.contains(".m3u8")
                && (content_type.eq_ignore_ascii_case("video/mp4")
                    || (content_type.is_empty() && url.contains(".mp4")))
        })
        .max_by_key(|variant| {
            variant
                .get("bitrate")
                .and_then(|bitrate| {
                    bitrate
                        .as_u64()
                        .or_else(|| bitrate.as_i64().map(|number| number.max(0) as u64))
                })
                .unwrap_or(0)
        })
        .and_then(|variant| variant.get("url").and_then(Value::as_str))
        .map(str::trim)
        .filter(|url| url.starts_with("https://"))
        .map(str::to_string)
}

fn strip_media_links(text: &str, media_urls: &[&str]) -> String {
    let mut out = text.trim_end().to_string();
    loop {
        let trimmed = out.trim_end();
        if trimmed.len() != out.len() {
            out.truncate(trimmed.len());
        }
        let mut removed = false;
        for url in media_urls {
            if url.is_empty() {
                continue;
            }
            if let Some(prefix) = out.strip_suffix(url) {
                out = prefix.trim_end().to_string();
                removed = true;
                break;
            }
        }
        if !removed {
            return out;
        }
    }
}

fn decode_entities(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut index = 0;
    while index < text.len() {
        if text.as_bytes()[index] == b'&' {
            if let Some(end) = text[index + 1..].find(';') {
                let entity = &text[index + 1..index + 1 + end];
                if let Some(decoded) = decode_entity(entity) {
                    out.push_str(&decoded);
                    index += 1 + end + 1;
                    continue;
                }
            }
        }
        let ch = text[index..].chars().next().expect("char boundary");
        out.push(ch);
        index += ch.len_utf8();
    }
    out
}

fn decode_entity(entity: &str) -> Option<String> {
    let named = match entity {
        "amp" => Some('&'),
        "lt" => Some('<'),
        "gt" => Some('>'),
        "quot" => Some('"'),
        "apos" => Some('\''),
        "nbsp" => Some(' '),
        _ => None,
    };
    if let Some(ch) = named {
        return Some(ch.to_string());
    }
    let number = if let Some(hex) = entity
        .strip_prefix("#x")
        .or_else(|| entity.strip_prefix("#X"))
    {
        u32::from_str_radix(hex, 16).ok()?
    } else {
        let decimal = entity.strip_prefix('#')?;
        decimal.parse::<u32>().ok()?
    };
    char::from_u32(number).map(|ch| ch.to_string())
}

pub(crate) fn parse_account(root: &Value) -> Option<Account> {
    let screen_name = string_at(
        root,
        &[
            "/screen_name",
            "/user/screen_name",
            "/data/user/result/core/screen_name",
            "/data/user/result/legacy/screen_name",
            "/data/user_result/result/core/screen_name",
            "/data/user_results/result/core/screen_name",
            "/data/viewer/user_results/result/core/screen_name",
            "/data/viewer/user_results/result/legacy/screen_name",
            "/users/0/screen_name",
            "/0/user/screen_name",
        ],
    )?;
    let screen_name = screen_name.trim().trim_start_matches('@').to_string();
    if screen_name.is_empty() {
        return None;
    }
    let name = string_at(
        root,
        &[
            "/name",
            "/user/name",
            "/data/user/result/core/name",
            "/data/user/result/legacy/name",
            "/data/user_result/result/core/name",
            "/data/user_results/result/core/name",
            "/data/viewer/user_results/result/core/name",
            "/data/viewer/user_results/result/legacy/name",
            "/users/0/name",
            "/0/user/name",
        ],
    )
    .filter(|name| !name.trim().is_empty());
    Some(Account { screen_name, name })
}

fn string_at(value: &Value, paths: &[&str]) -> Option<String> {
    paths.iter().find_map(|path| {
        value
            .pointer(path)
            .and_then(Value::as_str)
            .filter(|text| !text.is_empty())
            .map(str::to_string)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cookies() -> Cookies {
        Cookies::new(&tl_protected_api::Credentials {
            auth_token: "auth-secret-value".into(),
            ct0: "csrf-secret-value".into(),
        })
        .unwrap()
    }

    #[test]
    fn strips_only_media_links_at_the_end() {
        let text = "hello https://t.co/card and https://t.co/media";
        assert_eq!(
            strip_media_links(text, &["https://t.co/media"]),
            "hello https://t.co/card and"
        );
        assert_eq!(
            strip_media_links("only https://t.co/a", &["https://t.co/a"]),
            "only"
        );
        assert_eq!(
            strip_media_links("https://t.co/a https://t.co/a", &["https://t.co/a"]),
            ""
        );
    }

    #[test]
    fn decodes_html_entities_once() {
        assert_eq!(
            decode_entities("AT&amp;T &lt;3 &#39;quoted&#39;"),
            "AT&T <3 'quoted'"
        );
        assert_eq!(decode_entities("&amp;lt;"), "&lt;");
        assert_eq!(decode_entities("&unknown;"), "&unknown;");
        assert_eq!(decode_entities("rock & roll"), "rock & roll");
    }

    #[test]
    fn photo_uses_original_size() {
        let entity: Value = serde_json::json!({
            "type": "photo",
            "media_url_https": "https://pbs.twimg.com/media/ABC.jpg?format=jpg&name=small"
        });
        assert_eq!(
            original_photo(&entity).as_deref(),
            Some("https://pbs.twimg.com/media/ABC.jpg?name=orig")
        );
    }

    #[test]
    fn picks_highest_bitrate_mp4_and_never_hls() {
        let entity: Value = serde_json::json!({
            "type": "video",
            "video_info": {"variants": [
                {"content_type": "application/x-mpegURL", "url": "https://video.twimg.com/pl.m3u8"},
                {"content_type": "video/mp4", "bitrate": 256000, "url": "https://video.twimg.com/low.mp4"},
                {"content_type": "video/mp4", "bitrate": 2176000, "url": "https://video.twimg.com/high.mp4"},
                {"content_type": "video/mp4", "bitrate": 99999999, "url": "https://video.twimg.com/playlist.m3u8"}
            ]}
        });
        assert_eq!(
            best_mp4(&entity).as_deref(),
            Some("https://video.twimg.com/high.mp4")
        );
    }

    #[test]
    fn protected_media_carries_the_cookie() {
        let entity: Value = serde_json::json!({
            "type": "photo",
            "media_url_https": "https://pbs.twimg.com/media/ABC.jpg"
        });
        let media = build_media(&[&entity], true, &cookies());
        assert_eq!(media.len(), 1);
        assert_eq!(media[0].headers.len(), 1);
        assert_eq!(media[0].headers[0].0, "Cookie");
        assert!(media[0].headers[0].1.contains("auth_token="));
        let media = build_media(&[&entity], false, &cookies());
        assert!(media[0].headers.is_empty());
    }

    #[test]
    fn protected_media_cookie_is_only_sent_to_the_x_cdn() {
        let entity: Value = serde_json::json!({
            "type": "photo",
            "media_url_https": "https://example.com/media/ABC.jpg"
        });
        let media = build_media(&[&entity], true, &cookies());
        assert_eq!(media.len(), 1);
        assert!(media[0].headers.is_empty());
    }

    #[test]
    fn parses_account_from_verify_credentials() {
        let value: Value = serde_json::json!({
            "id_str": "1", "screen_name": "someone", "name": "Some One"
        });
        let account = parse_account(&value).unwrap();
        assert_eq!(account.screen_name, "someone");
        assert_eq!(account.name.as_deref(), Some("Some One"));
    }

    #[test]
    fn parses_account_from_settings() {
        let value: Value = serde_json::json!({"screen_name": "@someone"});
        let account = parse_account(&value).unwrap();
        assert_eq!(account.screen_name, "someone");
        assert_eq!(account.name, None);
    }

    #[test]
    fn parses_account_from_viewer_and_multi_list() {
        let viewer: Value = serde_json::json!({"data": {"viewer": {"user_results": {"result": {
            "core": {"screen_name": "someone", "name": "Some One"}
        }}}}});
        let legacy: Value = serde_json::json!({"data": {"viewer": {"user_results": {"result": {
            "legacy": {"screen_name": "someone", "name": "Some One"}
        }}}}});
        let multi: Value = serde_json::json!({"users": [
            {"user_id": "1", "screen_name": "someone", "name": "Some One"}
        ]});
        let old_multi: Value = serde_json::json!([
            {"user": {"id_str": "1", "screen_name": "someone", "name": "Some One"}}
        ]);
        for value in [viewer, legacy, multi, old_multi] {
            let account = parse_account(&value).unwrap();
            assert_eq!(account.screen_name, "someone");
            assert_eq!(account.name.as_deref(), Some("Some One"));
        }
        assert!(parse_account(&serde_json::json!({"users": []})).is_none());
    }
}
