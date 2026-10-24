//! Offline tests. Every network call is replaced by `MockTransport`; fixtures are saved copies of
//! real response shapes. Network tests live behind `#[ignore]` in this module.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tl_protected_api::{Credentials, MediaKind, ProtectedError};

use crate::http::{Cookies, HttpError, HttpRequest, HttpResponse, Method, Transport};
use crate::ops::OpsTable;
use crate::{check_credentials_with, fetch_post_with};

const ID: &str = "1700000000000000001";
const LONG_ID: &str = "1700000000000000002";

fn credentials() -> Credentials {
    Credentials {
        auth_token: "auth-secret-value".to_string(),
        ct0: "csrf-secret-value".to_string(),
    }
}

fn cookies() -> Cookies {
    Cookies::new(&credentials()).expect("test credentials")
}

fn deadline() -> Instant {
    Instant::now() + Duration::from_secs(20)
}

struct MockResponse {
    status: u16,
    headers: Vec<(String, String)>,
    body: String,
}

fn reply(status: u16, body: impl Into<String>) -> MockResponse {
    MockResponse {
        status,
        headers: Vec::new(),
        body: body.into(),
    }
}

struct MockTransport {
    responses: Mutex<VecDeque<MockResponse>>,
    requests: Mutex<Vec<HttpRequest>>,
}

impl MockTransport {
    fn new(responses: Vec<MockResponse>) -> Self {
        Self {
            responses: Mutex::new(responses.into()),
            requests: Mutex::new(Vec::new()),
        }
    }

    fn with_body(status: u16, body: impl Into<String>) -> Self {
        Self::new(vec![reply(status, body)])
    }

    fn requests(&self) -> Vec<HttpRequest> {
        self.requests.lock().unwrap().clone()
    }
}

impl Transport for MockTransport {
    fn send(&self, request: &HttpRequest) -> Result<HttpResponse, HttpError> {
        self.requests.lock().unwrap().push(request.clone());
        let response = self
            .responses
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or_else(|| reply(500, "{}"));
        Ok(HttpResponse {
            status: response.status,
            headers: response.headers,
            body: response.body,
        })
    }
}

/// A transport that always returns one response; safe to share between threads.
struct FixedTransport {
    status: u16,
    body: String,
    calls: AtomicUsize,
}

impl FixedTransport {
    fn new(status: u16, body: impl Into<String>) -> Self {
        Self {
            status,
            body: body.into(),
            calls: AtomicUsize::new(0),
        }
    }
}

impl Transport for FixedTransport {
    fn send(&self, _request: &HttpRequest) -> Result<HttpResponse, HttpError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(HttpResponse {
            status: self.status,
            headers: Vec::new(),
            body: self.body.clone(),
        })
    }
}

fn fetch_with(
    id: &str,
    transport: &dyn Transport,
    table: &OpsTable,
) -> Result<tl_protected_api::ProtectedPost, ProtectedError> {
    fetch_post_with(id, &cookies(), transport, table, deadline())
}

#[test]
#[ignore = "requires private response fixtures; see BUILDING.md"]
fn parses_saved_photo_and_video_response() {
    let transport = MockTransport::with_body(
        200,
        std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/tweet_detail_photo_video.json")).expect("supply your own fixture"),
    );
    let post = fetch_with(ID, &transport, &OpsTable::builtin()).unwrap();

    assert_eq!(post.id, ID);
    assert_eq!(post.author_name.as_deref(), Some("Private Acct & Co"));
    assert_eq!(post.screen_name.as_deref(), Some("private_acct"));
    assert_eq!(post.text.as_deref(), Some("Sunset & sea"));
    assert_eq!(
        post.created_at.as_deref(),
        Some("2024-01-15 10:30:00 +0000")
    );
    assert_eq!(
        post.url.as_deref(),
        Some("https://x.com/private_acct/status/1700000000000000001")
    );
    assert_eq!(post.media.len(), 2);
    assert_eq!(post.media[0].kind, MediaKind::Photo);
    assert_eq!(
        post.media[0].url,
        "https://pbs.twimg.com/media/PHOTO1.jpg?name=orig"
    );
    assert_eq!(post.media[1].kind, MediaKind::Video);
    assert_eq!(post.media[1].url, "https://video.twimg.com/high.mp4");
    assert!(!post.media.iter().any(|media| media.url.contains("m3u8")));
    assert!(post.media.iter().all(|media| media.headers.len() == 1));
    assert!(post
        .media
        .iter()
        .all(|media| media.headers[0].0 == "Cookie"));

    let requests = transport.requests();
    assert_eq!(requests.len(), 1);
    assert!(requests[0]
        .url
        .starts_with("https://x.com/i/api/graphql/3BlMtudy4N-d78ch7zTLZQ/TweetDetail?"));
    assert!(requests[0].url.contains("variables="));
    assert!(requests[0].url.contains("features="));
    assert!(!requests[0].url.contains("auth-secret-value"));
    assert!(!requests[0].url.contains("csrf-secret-value"));
}

#[test]
#[ignore = "requires private response fixtures; see BUILDING.md"]
fn parses_long_text_and_public_media_has_no_cookie_header() {
    let transport = MockTransport::with_body(
        200,
        std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/tweet_result_long_text.json")).expect("supply your own fixture"),
    );
    let post = fetch_with(LONG_ID, &transport, &OpsTable::builtin()).unwrap();

    assert_eq!(post.text.as_deref(), Some("Long & complete"));
    assert_eq!(
        post.created_at.as_deref(),
        Some("2024-01-14 08:00:00 +0000")
    );
    assert_eq!(post.author_name.as_deref(), Some("Long Form"));
    assert_eq!(post.screen_name.as_deref(), Some("longform"));
    assert_eq!(post.media.len(), 1);
    assert_eq!(
        post.media[0].url,
        "https://pbs.twimg.com/media/LONG.jpg?name=orig"
    );
    assert!(post.media[0].headers.is_empty());
}

#[test]
#[ignore = "requires private response fixtures; see BUILDING.md"]
fn tombstone_is_not_found() {
    let transport = MockTransport::with_body(
        200,
        std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/tweet_detail_tombstone.json")).expect("supply your own fixture"),
    );
    let error = fetch_with(ID, &transport, &OpsTable::builtin()).unwrap_err();
    assert!(matches!(error, ProtectedError::NotFound(_)), "{error:?}");
}

#[test]
fn sends_false_variables_instead_of_dropping_them() {
    // X answers HTTP 422 "must be defined" when a `false` variable is left out.
    let transport = MockTransport::with_body(
        401,
        r#"{"errors":[{"code":32,"message":"Could not authenticate you."}]}"#,
    );
    let _ = fetch_with(ID, &transport, &OpsTable::builtin());
    let requests = transport.requests();
    let query: std::collections::HashMap<String, String> = url::Url::parse(&requests[0].url)
        .unwrap()
        .query_pairs()
        .into_owned()
        .collect();
    let variables: serde_json::Value = serde_json::from_str(&query["variables"]).unwrap();
    assert_eq!(variables["focalTweetId"], serde_json::json!(ID));
    assert_eq!(variables["includePromotedContent"], serde_json::json!(false));
    assert_eq!(variables["with_rux_injections"], serde_json::json!(false));
    // The same goes for feature flags: every builtin flag, `false` ones included, is sent.
    let features: serde_json::Value = serde_json::from_str(&query["features"]).unwrap();
    let builtin = OpsTable::builtin();
    let meta = builtin.get(crate::ops::TWEET_DETAIL).unwrap();
    assert_eq!(features, meta.features);
    // Field toggles keep their `false` entries too, exactly like the web client sends them.
    let toggles: serde_json::Value = serde_json::from_str(&query["fieldToggles"]).unwrap();
    assert_eq!(Some(&toggles), meta.field_toggles.as_ref());
    assert_eq!(toggles["withPayments"], serde_json::json!(false));
}

#[test]
fn retries_a_422_as_post_with_the_full_body() {
    let transport = MockTransport::with_body(422, r#"{"errors":[{"message":"must be defined"}]}"#);
    let _ = fetch_with(ID, &transport, &OpsTable::builtin());
    let requests = transport.requests();
    assert!(requests.len() >= 2, "{requests:?}");
    assert!(matches!(requests[1].method, Method::Post));
    let body: serde_json::Value =
        serde_json::from_str(requests[1].body.as_deref().unwrap()).unwrap();
    assert_eq!(body["variables"]["includePromotedContent"], serde_json::json!(false));
}

#[test]
fn maps_http_failures_to_the_right_error() {
    let unauthorized = fetch_with(
        ID,
        &MockTransport::with_body(
            401,
            r#"{"errors":[{"code":32,"message":"Could not authenticate you."}]}"#,
        ),
        &OpsTable::builtin(),
    )
    .unwrap_err();
    assert!(
        matches!(unauthorized, ProtectedError::Unauthorized(_)),
        "{unauthorized:?}"
    );

    let forbidden = fetch_with(
        ID,
        &MockTransport::with_body(
            403,
            r#"{"errors":[{"code":179,"message":"Sorry, you are not authorized to see this status."}]}"#,
        ),
        &OpsTable::builtin(),
    )
    .unwrap_err();
    assert!(
        matches!(forbidden, ProtectedError::NotFound(_)),
        "{forbidden:?}"
    );

    let generic_forbidden = fetch_with(
        ID,
        &MockTransport::with_body(403, r#"{"error":"Forbidden"}"#),
        &OpsTable::builtin(),
    )
    .unwrap_err();
    assert!(
        matches!(generic_forbidden, ProtectedError::Unauthorized(_)),
        "{generic_forbidden:?}"
    );

    let deleted = fetch_with(
        ID,
        &MockTransport::with_body(
            404,
            r#"{"errors":[{"code":144,"message":"No status found with that ID."}]}"#,
        ),
        &OpsTable::builtin(),
    )
    .unwrap_err();
    assert!(
        matches!(deleted, ProtectedError::NotFound(_)),
        "{deleted:?}"
    );

    let limited = fetch_with(
        ID,
        &MockTransport::new(vec![MockResponse {
            status: 429,
            headers: vec![("retry-after".into(), "42".into())],
            body: "{}".into(),
        }]),
        &OpsTable::builtin(),
    )
    .unwrap_err();
    assert_eq!(
        limited,
        ProtectedError::RateLimited {
            retry_after_secs: Some(42)
        }
    );

    let server =
        fetch_with(ID, &MockTransport::with_body(503, ""), &OpsTable::builtin()).unwrap_err();
    assert!(matches!(server, ProtectedError::Network(_)), "{server:?}");

    let malformed = fetch_with(
        ID,
        &MockTransport::with_body(200, "not json"),
        &OpsTable::builtin(),
    )
    .unwrap_err();
    assert!(
        matches!(malformed, ProtectedError::Other(_)),
        "{malformed:?}"
    );
}

#[test]
fn rate_limit_reset_header_is_used_when_retry_after_is_absent() {
    let reset = crate::http::now_secs() + 120;
    let transport = MockTransport::new(vec![MockResponse {
        status: 429,
        headers: vec![("x-rate-limit-reset".into(), reset.to_string())],
        body: "{}".into(),
    }]);
    let error = fetch_with(ID, &transport, &OpsTable::builtin()).unwrap_err();
    match error {
        ProtectedError::RateLimited {
            retry_after_secs: Some(seconds),
        } => {
            assert!((100..=120).contains(&seconds), "{seconds}");
        }
        other => panic!("expected rate limited, got {other:?}"),
    }
}

#[test]
fn no_media_is_its_own_error() {
    let body = r#"{
        "data": {"threaded_conversation_with_injections_v2": {"instructions": [{
            "type": "TimelineAddEntries",
            "entries": [{
                "entryId": "tweet-42",
                "content": {"entryType": "TimelineTimelineItem", "itemContent": {
                    "itemType": "TimelineTweet",
                    "tweet_results": {"result": {
                        "__typename": "Tweet",
                        "rest_id": "42",
                        "core": {"user_results": {"result": {
                            "rest_id": "7",
                            "legacy": {"screen_name": "someone", "name": "Someone"}
                        }}},
                        "legacy": {
                            "full_text": "just text",
                            "created_at": "Mon Jan 15 10:30:00 +0000 2024"
                        }
                    }}
                }}
            }]
        }]}}
    }"#
    .to_string();
    let error = fetch_with(
        "42",
        &MockTransport::with_body(200, body),
        &OpsTable::builtin(),
    )
    .unwrap_err();
    assert_eq!(error, ProtectedError::NoMedia);
}

#[test]
#[ignore = "requires private response fixtures; see BUILDING.md"]
fn rotates_a_stale_query_id_and_retries_once() {
    let transport = MockTransport::new(vec![
        reply(404, ""),
        reply(200, std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/community_table.json")).expect("supply your own fixture")),
        reply(
            200,
            std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/tweet_detail_photo_video.json")).expect("supply your own fixture"),
        ),
    ]);
    let post = fetch_with(ID, &transport, &OpsTable::builtin()).unwrap();
    assert_eq!(post.media.len(), 2);

    let requests = transport.requests();
    assert_eq!(requests.len(), 3);
    assert!(requests[0].url.contains("3BlMtudy4N-d78ch7zTLZQ"));
    assert!(requests[1]
        .url
        .starts_with("https://raw.githubusercontent.com/"));
    assert!(
        requests[1]
            .headers
            .iter()
            .all(|(name, _)| !name.eq_ignore_ascii_case("cookie")),
        "the community lookup must not send cookies"
    );
    assert!(requests[2].url.contains("ROTATEDdetail12345"));
}

#[test]
#[ignore = "requires private response fixtures; see BUILDING.md"]
fn retries_a_rejected_long_get_as_post() {
    let transport = MockTransport::new(vec![
        reply(414, ""),
        reply(
            200,
            std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/tweet_detail_photo_video.json")).expect("supply your own fixture"),
        ),
    ]);
    let post = fetch_with(ID, &transport, &OpsTable::builtin()).unwrap();
    assert_eq!(post.media.len(), 2);

    let requests = transport.requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].method, Method::Get);
    assert_eq!(requests[1].method, Method::Post);
    let body = requests[1].body.as_deref().expect("POST body");
    assert!(body.contains("\"queryId\""));
    assert!(body.contains("\"focalTweetId\""));
    assert!(requests[1]
        .headers
        .iter()
        .any(|(name, _)| name.eq_ignore_ascii_case("content-type")));
}

#[test]
#[ignore = "requires private response fixtures; see BUILDING.md"]
fn falls_back_to_tweet_result_by_rest_id() {
    let transport = MockTransport::new(vec![
        reply(200, r#"{"data":{}}"#),
        reply(
            200,
            std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/tweet_result_long_text.json")).expect("supply your own fixture"),
        ),
    ]);
    let post = fetch_with(LONG_ID, &transport, &OpsTable::builtin()).unwrap();
    assert_eq!(post.id, LONG_ID);
    let requests = transport.requests();
    assert_eq!(requests.len(), 2);
    assert!(requests[1].url.contains("TweetResultByRestId"));
}

#[test]
#[ignore = "requires private response fixtures; see BUILDING.md"]
fn check_credentials_returns_the_account() {
    let transport = MockTransport::new(vec![
        reply(404, ""),
        reply(404, ""),
        reply(200, std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/verify_credentials.json")).expect("supply your own fixture")),
    ]);
    let account = check_credentials_with(&cookies(), &transport, &OpsTable::builtin(), deadline()).unwrap();
    assert_eq!(account.screen_name, "test_user");
    assert_eq!(account.name.as_deref(), Some("Test User"));
    let requests = transport.requests();
    assert_eq!(requests.len(), 3);
    assert!(requests[2]
        .url
        .starts_with("https://api.x.com/1.1/account/verify_credentials.json"));
}

#[test]
fn check_credentials_maps_a_bad_session() {
    let transport = MockTransport::with_body(
        401,
        r#"{"errors":[{"code":32,"message":"Could not authenticate you."}]}"#,
    );
    let error = check_credentials_with(&cookies(), &transport, &OpsTable::builtin(), deadline()).unwrap_err();
    assert!(
        matches!(error, ProtectedError::Unauthorized(_)),
        "{error:?}"
    );
    assert_eq!(transport.requests().len(), 1);
}

#[test]
#[ignore = "requires private response fixtures; see BUILDING.md"]
fn check_credentials_falls_back_to_settings() {
    let transport = MockTransport::new(vec![
        reply(404, ""),
        reply(404, ""),
        reply(
            403,
            r#"{"errors":[{"code":32,"message":"Could not authenticate you."}]}"#,
        ),
        reply(200, std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/settings.json")).expect("supply your own fixture")),
    ]);
    let account = check_credentials_with(&cookies(), &transport, &OpsTable::builtin(), deadline()).unwrap();
    assert_eq!(account.screen_name, "test_user");
    assert_eq!(account.name, None);
    let requests = transport.requests();
    assert_eq!(requests.len(), 4);
    assert!(requests[3].url.contains("account/settings.json"));
}

#[test]
fn check_credentials_treats_a_login_page_as_unauthorized() {
    let transport = MockTransport::new(vec![
        reply(200, "<html>login</html>"),
        reply(200, "<html>login</html>"),
        reply(200, "<html>login</html>"),
        reply(200, "<html>login</html>"),
    ]);
    let error = check_credentials_with(&cookies(), &transport, &OpsTable::builtin(), deadline()).unwrap_err();
    assert!(
        matches!(error, ProtectedError::Unauthorized(_)),
        "{error:?}"
    );
    assert!(error.to_string().contains("Cookie"));
}

#[test]
fn check_credentials_uses_the_viewer_query() {
    let transport = MockTransport::with_body(
        200,
        r#"{"data":{"viewer":{"user_results":{"result":{"core":{"screen_name":"someone","name":"Some One"}}}}}}"#,
    );
    let account =
        check_credentials_with(&cookies(), &transport, &OpsTable::builtin(), deadline()).unwrap();
    assert_eq!(account.screen_name, "someone");
    assert_eq!(account.name.as_deref(), Some("Some One"));
    let requests = transport.requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, Method::Get);
    assert!(requests[0].url.starts_with("https://x.com/i/api/graphql/"));
    assert!(requests[0].url.contains("/Viewer?"));
}

#[test]
fn check_credentials_maps_a_viewer_auth_error() {
    let transport = MockTransport::with_body(
        200,
        r#"{"errors":[{"code":32,"message":"Could not authenticate you."}]}"#,
    );
    let error = check_credentials_with(&cookies(), &transport, &OpsTable::builtin(), deadline())
        .unwrap_err();
    assert!(
        matches!(error, ProtectedError::Unauthorized(_)),
        "{error:?}"
    );
    assert_eq!(transport.requests().len(), 1);
}

#[test]
fn check_credentials_falls_through_a_404_to_multi_list() {
    let transport = MockTransport::new(vec![
        reply(404, ""),
        reply(
            200,
            r#"{"users":[{"user_id":"1","name":"Some One","screen_name":"someone"}]}"#,
        ),
    ]);
    let account =
        check_credentials_with(&cookies(), &transport, &OpsTable::builtin(), deadline()).unwrap();
    assert_eq!(account.screen_name, "someone");
    assert_eq!(account.name.as_deref(), Some("Some One"));
    let requests = transport.requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(
        requests[1].url,
        "https://x.com/i/api/1.1/account/multi/list.json"
    );
}

#[test]
fn check_credentials_reports_404_only_when_every_endpoint_fails() {
    let transport = MockTransport::new(vec![
        reply(404, ""),
        reply(404, ""),
        reply(404, ""),
        reply(404, ""),
    ]);
    let error = check_credentials_with(&cookies(), &transport, &OpsTable::builtin(), deadline())
        .unwrap_err();
    assert!(error.to_string().contains("HTTP 404"), "{error:?}");
    let urls: Vec<String> = transport.requests().into_iter().map(|r| r.url).collect();
    assert_eq!(urls.len(), 4);
    assert!(urls[0].contains("/Viewer?"));
    assert!(urls[1].contains("account/multi/list.json"));
    assert!(urls[2].contains("account/verify_credentials.json"));
    assert!(urls[3].contains("account/settings.json"));
}

#[test]
fn secrets_never_appear_in_errors() {
    let body =
        r#"{"errors":[{"code":32,"message":"bad auth-secret-value and csrf-secret-value"}]}"#;
    let error = fetch_with(
        ID,
        &MockTransport::with_body(401, body),
        &OpsTable::builtin(),
    )
    .unwrap_err();
    let message = error.to_string();
    assert!(!message.contains("auth-secret-value"), "{message}");
    assert!(!message.contains("csrf-secret-value"), "{message}");

    let error = fetch_with(
        ID,
        &MockTransport::with_body(200, "junk auth-secret-value csrf-secret-value"),
        &OpsTable::builtin(),
    )
    .unwrap_err();
    let message = error.to_string();
    assert!(!message.contains("auth-secret-value"), "{message}");
    assert!(!message.contains("csrf-secret-value"), "{message}");
}

#[test]
fn public_api_rejects_bad_input_without_network() {
    let error = crate::fetch_post("not a status link", &credentials()).unwrap_err();
    assert!(matches!(error, ProtectedError::Other(_)), "{error:?}");

    let empty = Credentials {
        auth_token: String::new(),
        ct0: String::new(),
    };
    for url in ["https://x.com/someone/status/1", "1700000000000000001"] {
        let error = crate::fetch_post(url, &empty).unwrap_err();
        assert!(
            matches!(error, ProtectedError::Unauthorized(_)),
            "{error:?}"
        );
    }
    let error = crate::check_credentials(&empty).unwrap_err();
    assert!(
        matches!(error, ProtectedError::Unauthorized(_)),
        "{error:?}"
    );

    let bad = Credentials {
        auth_token: "a\nb".into(),
        ct0: "c".into(),
    };
    let error = crate::check_credentials(&bad).unwrap_err();
    assert!(
        matches!(error, ProtectedError::Unauthorized(_)),
        "{error:?}"
    );
}

#[test]
#[ignore = "requires private response fixtures; see BUILDING.md"]
fn sixteen_threads_fetch_at_once() {
    let transport = Arc::new(FixedTransport::new(
        200,
        std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/tweet_detail_photo_video.json")).expect("supply your own fixture"),
    ));
    let table = Arc::new(OpsTable::builtin());

    let results = std::thread::scope(|scope| {
        let mut handles = Vec::new();
        for _ in 0..16 {
            let transport = Arc::clone(&transport);
            let table = Arc::clone(&table);
            handles.push(scope.spawn(move || {
                let cookies = cookies();
                fetch_post_with(ID, &cookies, &*transport, &table, deadline())
            }));
        }
        handles
            .into_iter()
            .map(|handle| handle.join().expect("thread panicked"))
            .collect::<Vec<_>>()
    });

    assert_eq!(transport.calls.load(Ordering::SeqCst), 16);
    assert_eq!(results.len(), 16);
    for result in results {
        let post = result.expect("concurrent fetch");
        assert_eq!(post.id, ID);
        assert_eq!(post.media.len(), 2);
    }
}

#[test]
#[ignore = "network: checks the real endpoint with a deliberately fake session"]
fn live_rejects_fake_credentials() {
    let error = crate::check_credentials(&Credentials {
        auth_token: "not-a-real-auth-token".into(),
        ct0: "not-a-real-csrf-token".into(),
    })
    .unwrap_err();
    assert!(
        matches!(error, ProtectedError::Unauthorized(_)),
        "{error:?}"
    );
}

#[test]
#[ignore = "network probe: check the GraphQL request shape with a fake session"]
fn live_probe_graphql_request_shape() {
    let result = crate::fetch_post(
        &std::env::var("TL_TEST_STATUS_URL").expect("TL_TEST_STATUS_URL"),
        &Credentials {
            auth_token: "not-a-real-auth-token".into(),
            ct0: "not-a-real-csrf-token".into(),
        },
    );
    match &result {
        // A fake session is normally rejected; if X ignores it and serves the public post,
        // that still proves the request shape is valid.
        Ok(post) => assert!(!post.id.is_empty()),
        Err(ProtectedError::Unauthorized(_))
        | Err(ProtectedError::NotFound(_))
        | Err(ProtectedError::RateLimited { .. })
        | Err(ProtectedError::NoMedia) => {}
        Err(error) => panic!("unexpected GraphQL response: {error:?}"),
    }
}

#[test]
#[ignore = "requires a real X session cookie in TL_TEST_AUTH_TOKEN / TL_TEST_CT0"]
fn live_check_credentials() {
    let auth_token = std::env::var("TL_TEST_AUTH_TOKEN").expect("TL_TEST_AUTH_TOKEN");
    let ct0 = std::env::var("TL_TEST_CT0").expect("TL_TEST_CT0");
    let account = crate::check_credentials(&Credentials { auth_token, ct0 }).unwrap();
    assert!(!account.screen_name.is_empty());
}

#[test]
#[ignore = "requires a real X session cookie in TL_TEST_AUTH_TOKEN / TL_TEST_CT0"]
fn live_fetch_known_post() {
    let auth_token = std::env::var("TL_TEST_AUTH_TOKEN").expect("TL_TEST_AUTH_TOKEN");
    let ct0 = std::env::var("TL_TEST_CT0").expect("TL_TEST_CT0");
    let url = std::env::var("TL_TEST_STATUS_URL")
        .expect("TL_TEST_STATUS_URL");
    let post = crate::fetch_post(&url, &Credentials { auth_token, ct0 }).unwrap();
    assert!(!post.id.is_empty());
    assert!(!post.media.is_empty());
}
