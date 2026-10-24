//! Protected-post module for TwimShelf.
//!
//! Fetches a post with the user's X session (`auth_token` + `ct0`) through the same GraphQL
//! `TweetDetail` operation the web client uses, and checks the session with the GraphQL `Viewer`
//! operation, falling back to the v1.1 account endpoints. The core calls these functions directly on blocking
//! worker threads; there is no subprocess, no Tokio runtime on the calling thread, and no file
//! access.
//!
//! See `docs/protected-module-interface.md` for the contract.

#![forbid(unsafe_code)]

use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tl_protected_api::{Account, Credentials, ProtectedError, ProtectedPost};
use url::Url;

mod date;
mod error;
mod http;
mod ops;
mod parse;
mod urlx;

use http::{Cookies, HttpError, HttpRequest, HttpResponse, Method, ReqwestTransport, Transport};
use ops::OpsTable;

/// Leave a little room under the core's 30-second call limit.
const TOTAL_BUDGET: Duration = Duration::from_secs(28);
const API_TIMEOUT: Duration = Duration::from_secs(12);
const COMMUNITY_TIMEOUT: Duration = Duration::from_secs(8);
const MIN_REQUEST_TIME: Duration = Duration::from_millis(500);

const VERIFY_URL: &str =
    "https://api.x.com/1.1/account/verify_credentials.json?skip_status=true&include_entities=false";
const SETTINGS_URL: &str = "https://x.com/i/api/1.1/account/settings.json";
/// Still answers web sessions that send no `x-client-transaction-id`, unlike the two above.
const MULTI_LIST_URL: &str = "https://x.com/i/api/1.1/account/multi/list.json";

/// Fetches one post (a status link, e.g. `https://x.com/someone/status/1700000000000000001`).
///
/// Blocking. Safe to call from up to sixteen threads at the same time; every call has its own
/// deadline and shares only an immutable HTTP client plus a thread-safe query-id cache.
pub fn fetch_post(
    status_url: &str,
    credentials: &Credentials,
) -> Result<ProtectedPost, ProtectedError> {
    let id = urlx::parse_status_id(status_url).ok_or_else(|| {
        ProtectedError::Other(
            "无法识别帖子链接，请使用 https://x.com/<用户名>/status/<帖子编号> 格式".into(),
        )
    })?;
    let cookies = Cookies::new(credentials)?;
    let client = http::client()?;
    let transport = ReqwestTransport::new(client);
    let deadline = Instant::now() + TOTAL_BUDGET;
    fetch_post_with(&id, &cookies, &transport, ops::global(), deadline)
}

/// Checks the cookies (Settings → 检查 Cookie) and returns the signed-in account.
///
/// Blocking. Uses the web client's GraphQL `Viewer` query, then `account/multi/list`,
/// `account/verify_credentials` and `account/settings`; a 404 from one falls through to the next.
pub fn check_credentials(credentials: &Credentials) -> Result<Account, ProtectedError> {
    let cookies = Cookies::new(credentials)?;
    let client = http::client()?;
    let transport = ReqwestTransport::new(client);
    let deadline = Instant::now() + TOTAL_BUDGET;
    check_credentials_with(&cookies, &transport, ops::global(), deadline)
}

pub(crate) fn fetch_post_with(
    id: &str,
    cookies: &Cookies,
    transport: &dyn Transport,
    table: &OpsTable,
    deadline: Instant,
) -> Result<ProtectedPost, ProtectedError> {
    let first = fetch_via_op(
        ops::TWEET_DETAIL,
        ops::detail_variables(id),
        id,
        cookies,
        transport,
        table,
        deadline,
    );
    match first {
        Ok(post) => Ok(post),
        // A stale queryId, an unexpected schema or a deleted post can all look like this.
        // `TweetResultByRestId` is a cheaper second opinion; only try it if there is time.
        Err(error @ (ProtectedError::NotFound(_) | ProtectedError::Other(_))) => {
            if remaining(deadline) > Duration::from_secs(5) {
                if let Ok(post) = fetch_via_op(
                    ops::TWEET_BY_ID,
                    ops::by_id_variables(id),
                    id,
                    cookies,
                    transport,
                    table,
                    deadline,
                ) {
                    return Ok(post);
                }
            }
            Err(error)
        }
        Err(error) => Err(error),
    }
}

fn fetch_via_op(
    operation: &str,
    variables: Value,
    id: &str,
    cookies: &Cookies,
    transport: &dyn Transport,
    table: &OpsTable,
    deadline: Instant,
) -> Result<ProtectedPost, ProtectedError> {
    let response = graphql(table, transport, operation, variables, cookies, deadline)?;
    match parse::parse_tweet_response(&response.value, id, cookies) {
        Ok(post) => Ok(post),
        Err(error @ (ProtectedError::NotFound(_) | ProtectedError::Other(_))) => {
            if let Some(x_error) = error::first_error(&response.value) {
                Err(error::map_envelope_error(
                    &x_error,
                    Some(&response.http),
                    cookies,
                ))
            } else {
                Err(error)
            }
        }
        Err(error) => Err(error),
    }
}

struct GraphqlResponse {
    value: Value,
    http: HttpResponse,
}

fn graphql(
    table: &OpsTable,
    transport: &dyn Transport,
    operation: &str,
    variables: Value,
    cookies: &Cookies,
    deadline: Instant,
) -> Result<GraphqlResponse, ProtectedError> {
    let mut use_post = false;
    let mut refreshed = false;
    loop {
        let meta = table.get(operation).ok_or_else(|| {
            ProtectedError::Other(format!("内部错误：找不到 GraphQL 操作 {operation}"))
        })?;
        let attempted_query_id = meta.query_id.clone();
        let request =
            build_graphql_request(&meta, operation, &variables, use_post, cookies, deadline)?;
        let response = transport
            .send(&request)
            .map_err(HttpError::into_protected)?;

        match response.status {
            200 => {
                let value = serde_json::from_str::<Value>(&response.body)
                    .map_err(|_| error::non_json_response(&response.body, cookies))?;
                if value.get("data").is_some_and(|data| !data.is_null()) {
                    return Ok(GraphqlResponse {
                        value,
                        http: response,
                    });
                }
                if let Some(x_error) = error::first_error(&value) {
                    return Err(error::map_envelope_error(
                        &x_error,
                        Some(&response),
                        cookies,
                    ));
                }
                return Err(ProtectedError::Other(
                    "X 返回的数据为空（接口格式可能已变化）".into(),
                ));
            }
            414 | 400 | 422 if !use_post => {
                // Long GET URLs and some parameter changes are accepted only as POST; a 422
                // "must be defined" also gets one POST retry with the full JSON body.
                use_post = true;
            }
            404 => {
                if error::definitive_not_found(&response) {
                    return Err(error::map_http_failure(&response, cookies));
                }
                if !refreshed {
                    refreshed = true;
                    let remaining = remaining(deadline);
                    if remaining > Duration::from_secs(5) {
                        let timeout = remaining.min(COMMUNITY_TIMEOUT);
                        // OpsTable::refresh checks the community table; it never sees cookies.
                        if table.refresh(transport, timeout) {
                            continue;
                        }
                        // Another call may have refreshed the table while we waited on the
                        // shared budget; retry if its queryId is newer than ours.
                        if table
                            .get(operation)
                            .is_some_and(|current| current.query_id != attempted_query_id)
                        {
                            continue;
                        }
                    }
                }
                return Err(ProtectedError::NotFound(
                    "帖子不存在、已删除或当前账号无权查看".into(),
                ));
            }
            _ => return Err(error::map_http_failure(&response, cookies)),
        }
    }
}

fn build_graphql_request(
    meta: &ops::OpMeta,
    operation: &str,
    variables: &Value,
    use_post: bool,
    cookies: &Cookies,
    deadline: Instant,
) -> Result<HttpRequest, ProtectedError> {
    let timeout = request_timeout(deadline, API_TIMEOUT)?;
    let path = format!("/i/api/graphql/{}/{}", meta.query_id, operation);
    let mut headers = http::api_headers(cookies);

    if use_post {
        headers.push(("content-type".into(), "application/json".into()));
        let body = json!({
            "variables": variables,
            "features": meta.features,
            "queryId": meta.query_id,
            "fieldToggles": meta.field_toggles.clone().unwrap_or_else(|| json!({})),
        });
        Ok(HttpRequest {
            method: Method::Post,
            url: format!("https://x.com{path}"),
            headers,
            body: Some(body.to_string()),
            timeout,
        })
    } else {
        let mut url = Url::parse(&format!("https://x.com{path}"))
            .map_err(|_| ProtectedError::Other("无法构造 X 请求地址".into()))?;
        {
            let mut query = url.query_pairs_mut();
            // Everything goes out verbatim, `false` entries included: since October 2026 X
            // rejects a request whose `false` variables (e.g. `includePromotedContent`) are
            // missing with HTTP 422 "must be defined", and the web client sends all flags.
            query.append_pair("variables", &verbatim(variables));
            query.append_pair("features", &verbatim(&meta.features));
            if let Some(toggles) = &meta.field_toggles {
                if toggles.as_object().is_some_and(|map| !map.is_empty()) {
                    query.append_pair("fieldToggles", &verbatim(toggles));
                }
            }
        }
        Ok(HttpRequest {
            method: Method::Get,
            url: url.to_string(),
            headers,
            body: None,
            timeout,
        })
    }
}

pub(crate) fn check_credentials_with(
    cookies: &Cookies,
    transport: &dyn Transport,
    table: &OpsTable,
    deadline: Instant,
) -> Result<Account, ProtectedError> {
    let mut last_error: Option<ProtectedError> = None;
    // Index 0 is the GraphQL `Viewer` query; the rest are plain v1.1 GETs.
    for (index, url) in ["", MULTI_LIST_URL, VERIFY_URL, SETTINGS_URL]
        .iter()
        .enumerate()
    {
        let cap = if index == 0 {
            API_TIMEOUT
        } else {
            COMMUNITY_TIMEOUT
        };
        let timeout = match request_timeout(deadline, cap) {
            Ok(timeout) => timeout,
            Err(error) => return Err(last_error.unwrap_or(error)),
        };
        let request = if index == 0 {
            let Some(meta) = table.get(ops::VIEWER) else {
                continue;
            };
            let variables = ops::viewer_variables();
            match build_graphql_request(&meta, ops::VIEWER, &variables, false, cookies, deadline) {
                Ok(request) => HttpRequest { timeout, ..request },
                Err(error) => {
                    remember_error(&mut last_error, error);
                    continue;
                }
            }
        } else {
            HttpRequest {
                method: Method::Get,
                url: (*url).to_string(),
                headers: http::api_headers(cookies),
                body: None,
                timeout,
            }
        };
        let response = match transport.send(&request) {
            Ok(response) => response,
            Err(error) => {
                return Err(last_error.unwrap_or_else(|| error.into_protected()));
            }
        };

        match response.status {
            200 => {
                let value = match serde_json::from_str::<Value>(&response.body) {
                    Ok(value) => value,
                    Err(_) => {
                        // Could be a login/consent page; try the other endpoint.
                        remember_error(
                            &mut last_error,
                            error::non_json_response(&response.body, cookies),
                        );
                        continue;
                    }
                };
                if let Some(account) = parse::parse_account(&value) {
                    return Ok(account);
                }
                if let Some(x_error) = error::first_error(&value) {
                    let mapped = error::map_envelope_error(&x_error, Some(&response), cookies);
                    if matches!(
                        &mapped,
                        ProtectedError::Unauthorized(_) | ProtectedError::RateLimited { .. }
                    ) {
                        return Err(mapped);
                    }
                    remember_error(&mut last_error, mapped);
                } else {
                    remember_error(
                        &mut last_error,
                        ProtectedError::Other(
                            "X 返回的账号信息不完整（接口格式可能已变化）".into(),
                        ),
                    );
                }
            }
            401 => return Err(error::map_http_failure(&response, cookies)),
            403 => {
                remember_error(
                    &mut last_error,
                    error::unauthorized_for_credentials(&response, cookies),
                );
            }
            404 => {
                remember_error(
                    &mut last_error,
                    ProtectedError::Other(
                        "X 的账号检查接口不可用（HTTP 404），接口可能已变更".into(),
                    ),
                );
            }
            420 | 429 => return Err(error::map_http_failure(&response, cookies)),
            _ => {
                remember_error(&mut last_error, error::map_http_failure(&response, cookies));
            }
        }
    }
    Err(last_error
        .unwrap_or_else(|| ProtectedError::Other("无法检查 Cookie，X 接口可能已变化".into())))
}

/// Keeps the most informative error while trying the account endpoints. A fallback endpoint
/// failing with 404/500 must not hide the first endpoint's "Cookie rejected".
fn remember_error(slot: &mut Option<ProtectedError>, candidate: ProtectedError) {
    fn rank(error: &ProtectedError) -> u8 {
        match error {
            ProtectedError::Unauthorized(_) => 5,
            ProtectedError::RateLimited { .. } => 4,
            ProtectedError::NotFound(_) => 3,
            ProtectedError::Network(_) => 2,
            ProtectedError::NoMedia => 1,
            ProtectedError::Other(_) | ProtectedError::NotAvailable => 0,
        }
    }
    if slot
        .as_ref()
        .is_none_or(|current| rank(&candidate) >= rank(current))
    {
        *slot = Some(candidate);
    }
}

fn remaining(deadline: Instant) -> Duration {
    deadline.saturating_duration_since(Instant::now())
}

fn request_timeout(deadline: Instant, cap: Duration) -> Result<Duration, ProtectedError> {
    let remaining = remaining(deadline);
    if remaining <= MIN_REQUEST_TIME {
        return Err(ProtectedError::Network(
            "请求超时（30 秒内未能完成），请检查网络后重试".into(),
        ));
    }
    Ok(remaining.min(cap).max(MIN_REQUEST_TIME))
}

/// Serialises a value as-is, keeping `false` entries (X now requires them to be present).
fn verbatim(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "{}".into())
}

#[cfg(test)]
mod tests;
