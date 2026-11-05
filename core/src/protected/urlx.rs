//! Status-link recognition.
//!
//! We only extract the numeric id from the link; the request always goes to `https://x.com`.
//! Accepted shapes include `x.com` / `twitter.com` (and their `www`/`mobile` subdomains),
//! `/status/` and legacy `/statuses/`, `/i/web/status/`, query strings, fragments, `/photo/1`
//! suffixes and an optional scheme. A bare numeric id is accepted too.

use url::Url;

const MIRRORS: &[&str] = &["fxtwitter.com", "vxtwitter.com", "fixupx.com", "fixvx.com", "nitter.net"];

pub(crate) fn parse_status_id(input: &str) -> Option<String> {
    let raw = input.trim();
    if raw.is_empty() {
        return None;
    }
    if is_status_id(raw) {
        return Some(raw.to_string());
    }

    let has_scheme = raw
        .get(..8)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("https://"))
        || raw
            .get(..7)
            .is_some_and(|prefix| prefix.eq_ignore_ascii_case("http://"));
    let absolute = if has_scheme {
        raw.to_string()
    } else {
        format!("https://{raw}")
    };
    let url = Url::parse(&absolute).ok()?;
    if !matches!(url.scheme(), "http" | "https") {
        return None;
    }
    let host = url.host_str()?.to_ascii_lowercase();
    let host_without_www = host.strip_prefix("www.").unwrap_or(&host);
    let known_host = host_without_www == "x.com"
        || host_without_www == "twitter.com"
        || host_without_www.ends_with(".x.com")
        || host_without_www.ends_with(".twitter.com")
        || MIRRORS.contains(&host_without_www);
    if !known_host {
        return None;
    }

    let segments: Vec<&str> = url.path_segments()?.filter(|s| !s.is_empty()).collect();
    for (index, segment) in segments.iter().enumerate() {
        if (*segment == "status" || *segment == "statuses")
            && segments.get(index + 1).is_some_and(|id| is_status_id(id))
        {
            return Some(segments[index + 1].to_string());
        }
    }
    None
}

fn is_status_id(text: &str) -> bool {
    !text.is_empty() && text.len() <= 25 && text.bytes().all(|b| b.is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_common_status_links() {
        let expected = "1900000000000000001";
        let links = [
            "https://x.com/someone/status/1900000000000000001",
            "https://twitter.com/someone/status/1900000000000000001",
            "https://www.x.com/someone/status/1900000000000000001",
            "https://mobile.twitter.com/someone/status/1900000000000000001",
            "https://m.twitter.com/someone/status/1900000000000000001",
            "https://x.com/someone/status/1900000000000000001?s=20&t=abc",
            "https://x.com/someone/status/1900000000000000001/photo/1",
            "https://x.com/someone/status/1900000000000000001/video/1",
            "https://x.com/someone/status/1900000000000000001/",
            "https://x.com/i/web/status/1900000000000000001",
            "https://x.com/i/status/1900000000000000001",
            "https://x.com/status/1900000000000000001",
            "https://x.com/someone/statuses/1900000000000000001",
            "https://x.com/someone/status/1900000000000000001#fragment",
            "HTTPS://X.COM/someone/status/1900000000000000001",
            "http://x.com/someone/status/1900000000000000001",
            "x.com/someone/status/1900000000000000001",
            "twitter.com/someone/status/1900000000000000001",
            "  https://x.com/someone/status/1900000000000000001  ",
            "https://fxtwitter.com/someone/status/1900000000000000001",
            "https://nitter.net/someone/status/1900000000000000001",
            "https://fixvx.com/someone/status/1900000000000000001",
            "1900000000000000001",
        ];
        for link in links {
            assert_eq!(parse_status_id(link).as_deref(), Some(expected), "{link}");
        }
    }

    #[test]
    fn rejects_other_hosts_and_garbage() {
        for link in [
            "",
            "not a link",
            "https://example.com/someone/status/1900000000000000001",
            "https://x.com.evil.example/someone/status/1900000000000000001",
            "https://evilx.com/someone/status/1900000000000000001",
            "https://x.com/someone/status/not-a-number",
            "https://x.com/someone/status/",
            "https://x.com/someone/",
            "https://x.com/someone/status/12345678901234567890123456",
            "ftp://x.com/someone/status/1900000000000000001",
        ] {
            assert_eq!(parse_status_id(link), None, "{link}");
        }
    }
}
