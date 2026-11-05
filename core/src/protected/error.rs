//! Mapping X's HTTP responses and error envelopes onto `ProtectedError`.
//!
//! Messages are translated (`tr!`) because the core displays them in the app; server text is only
//! appended after the cookies (and control characters) have been scrubbed.

use serde_json::Value;
use super::ProtectedError;

use super::http::{now_secs, truncate, Cookies, HttpResponse};

pub(crate) struct XError {
    pub code: Option<i64>,
    pub code_text: Option<String>,
    pub message: String,
}

pub(crate) fn first_error(value: &Value) -> Option<XError> {
    let first = value.get("errors")?.as_array()?.first()?;
    let code = first.get("code").and_then(|code| {
        code.as_i64()
            .or_else(|| code.as_str().and_then(|text| text.parse().ok()))
    });
    let code_text = first
        .get("code")
        .and_then(|code| code.as_str())
        .map(str::to_string);
    let message = first
        .get("message")
        .and_then(|message| message.as_str())
        .map(str::to_string)
        .unwrap_or_else(|| tr!("protected.unknownError"));
    Some(XError {
        code,
        code_text,
        message,
    })
}

pub(crate) fn map_http_failure(response: &HttpResponse, cookies: &Cookies) -> ProtectedError {
    let value = serde_json::from_str::<Value>(&response.body).ok();
    let error = value.as_ref().and_then(first_error);
    match response.status {
        401 => unauthorized(error.as_ref(), cookies),
        403 => {
            if looks_like_not_visible(error.as_ref()) {
                not_found(error.as_ref(), cookies)
            } else {
                unauthorized(error.as_ref(), cookies)
            }
        }
        404 => not_found(error.as_ref(), cookies),
        408 => ProtectedError::Network(tr!("protected.timeout408")),
        422 => {
            let detail = error
                .as_ref()
                .map(|error| tr!("protected.detail", d = safe(&error.message, cookies)))
                .unwrap_or_default();
            ProtectedError::Other(tr!("protected.rejected422", detail = detail))
        }
        420 | 429 => rate_limited_opt(Some(response), value.as_ref()),
        500..=599 => ProtectedError::Network(tr!("protected.serverDown", status = response.status)),
        status => {
            let detail = error
                .as_ref()
                .map(|error| tr!("protected.detail", d = safe(&error.message, cookies)))
                .unwrap_or_default();
            ProtectedError::Other(tr!("protected.httpStatus", status = status, detail = detail))
        }
    }
}

/// A 404 that is really X saying "this post does not exist", not a rotated `queryId`.
pub(crate) fn definitive_not_found(response: &HttpResponse) -> bool {
    let Ok(value) = serde_json::from_str::<Value>(&response.body) else {
        return false;
    };
    let Some(error) = first_error(&value) else {
        return false;
    };
    matches!(error.code, Some(34 | 144 | 179 | 385)) || looks_like_not_visible(Some(&error))
}

pub(crate) fn map_envelope_error(
    error: &XError,
    response: Option<&HttpResponse>,
    cookies: &Cookies,
) -> ProtectedError {
    match error.code {
        Some(88) => rate_limited_opt(response, None),
        Some(32 | 89 | 326) => unauthorized(Some(error), cookies),
        Some(34 | 144 | 179 | 385) => not_found(Some(error), cookies),
        _ => {
            let lower = error.message.to_ascii_lowercase();
            if error.code_text.as_deref() == Some("GRAPHQL_VALIDATION_FAILED") {
                return ProtectedError::Other(tr!("protected.graphqlRejected"));
            }
            if contains_any(
                &lower,
                &[
                    "not authorized to see",
                    "you are not authorized",
                    "does not exist",
                    "not found",
                    "no status found",
                    "deleted",
                    "unavailable",
                ],
            ) {
                not_found(Some(error), cookies)
            } else if contains_any(
                &lower,
                &[
                    "could not authenticate",
                    "invalid or expired token",
                    "authentication",
                    "logged in",
                    "account is locked",
                ],
            ) {
                unauthorized(Some(error), cookies)
            } else if contains_any(
                &lower,
                &["rate limit", "over capacity", "too many requests"],
            ) {
                rate_limited_opt(response, None)
            } else {
                ProtectedError::Other(tr!("protected.xError", m = safe(&error.message, cookies)))
            }
        }
    }
}

/// For a 200 response that is not JSON. A login/consent page means the session was rejected;
/// anything else is probably a changed endpoint or a proxy.
pub(crate) fn non_json_response(body: &str, cookies: &Cookies) -> ProtectedError {
    let head = body.trim_start();
    let lower = head.to_ascii_lowercase();
    if (head.starts_with('<') || lower.starts_with("<!doctype"))
        && (lower.contains("login")
            || lower.contains("log in")
            || lower.contains("sign in")
            || lower.contains("consent")
            || lower.contains("challenge")
            || lower.contains("authenticate"))
    {
        ProtectedError::Unauthorized(tr!("protected.loginPage"))
    } else if head.starts_with('<') || lower.starts_with("<!doctype") {
        ProtectedError::Other(tr!("protected.webPage"))
    } else {
        let detail = truncate(&cookies.scrub(head), 120);
        ProtectedError::Other(tr!("protected.unparsable", detail = detail))
    }
}

/// The "检查 Cookie" endpoint always describes a rejected session as `Unauthorized`, even when X
/// uses a 403 and a post-specific message.
pub(crate) fn unauthorized_for_credentials(
    response: &HttpResponse,
    cookies: &Cookies,
) -> ProtectedError {
    let value = serde_json::from_str::<Value>(&response.body).ok();
    match value.as_ref().and_then(first_error) {
        Some(error) => ProtectedError::Unauthorized(tr!("protected.cookieRejectedHint", m = safe(&error.message, cookies))),
        None => ProtectedError::Unauthorized(tr!("protected.cookieRejected")),
    }
}

pub(crate) fn rate_limited_opt(
    response: Option<&HttpResponse>,
    body: Option<&Value>,
) -> ProtectedError {
    let mut retry_after = response.and_then(|response| {
        response
            .header("retry-after")
            .and_then(|value| value.trim().parse::<u64>().ok())
    });
    if retry_after.is_none() {
        retry_after = response.and_then(|response| {
            response
                .header("x-rate-limit-reset")
                .and_then(|value| value.trim().parse::<i64>().ok())
                .map(|reset| reset.saturating_sub(now_secs()).max(0) as u64)
        });
    }
    if retry_after.is_none() {
        retry_after = body
            .and_then(|body| body.pointer("/errors/0/extensions/reset"))
            .and_then(|reset| {
                reset
                    .as_i64()
                    .or_else(|| reset.as_str().and_then(|text| text.parse().ok()))
            })
            .map(|reset| reset.saturating_sub(now_secs()).max(0) as u64);
    }
    ProtectedError::RateLimited {
        retry_after_secs: retry_after,
    }
}

fn unauthorized(error: Option<&XError>, cookies: &Cookies) -> ProtectedError {
    match error {
        Some(error) => ProtectedError::Unauthorized(tr!("protected.cookieExpiredHint", m = safe(&error.message, cookies))),
        None => ProtectedError::Unauthorized(tr!("protected.cookieExpired")),
    }
}

fn not_found(error: Option<&XError>, cookies: &Cookies) -> ProtectedError {
    match error {
        Some(error) => ProtectedError::NotFound(tr!("protected.postGoneHint", m = safe(&error.message, cookies))),
        None => ProtectedError::NotFound(tr!("protected.postGone")),
    }
}

fn looks_like_not_visible(error: Option<&XError>) -> bool {
    let Some(error) = error else { return false };
    if error.code == Some(179) {
        return true;
    }
    let lower = error.message.to_ascii_lowercase();
    contains_any(
        &lower,
        &[
            "not authorized to see",
            "you are not authorized",
            "protected",
            "not a follower",
            "blocked",
        ],
    )
}

fn contains_any(text: &str, needles: &[&str]) -> bool {
    needles.iter().any(|needle| text.contains(needle))
}

fn safe(text: &str, cookies: &Cookies) -> String {
    let text = cookies.scrub(text);
    let one_line: String = text
        .chars()
        .map(|ch| if ch.is_control() { ' ' } else { ch })
        .collect();
    truncate(one_line.trim(), 180)
}
