//! GraphQL operation metadata.
//!
//! X rotates the `queryId` in the URL path. The built-in table is the value verified in
//! October 2026; when a call gets a bare 404 the module fetches the community-maintained table
//! (the same source the research backend used) and retries once. Nothing is cached on disk.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock, RwLock};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::http::{HttpRequest, Method, Transport};

pub(crate) const TWEET_DETAIL: &str = "TweetDetail";
pub(crate) const TWEET_BY_ID: &str = "TweetResultByRestId";
/// The web client's "who am I" query; used by the cookie check. The community table does not
/// carry it, so `refresh` leaves it alone.
pub(crate) const VIEWER: &str = "Viewer";

const COMMUNITY_URL: &str =
    "https://raw.githubusercontent.com/fa0311/twitter-openapi/refs/heads/main/src/config/placeholder.json";
const REFRESH_INTERVAL: Duration = Duration::from_secs(60);

#[derive(Clone)]
pub(crate) struct OpMeta {
    pub query_id: String,
    pub features: Value,
    pub field_toggles: Option<Value>,
}

pub(crate) struct OpsTable {
    ops: RwLock<HashMap<String, OpMeta>>,
    /// Avoid a stampede of 16 concurrent calls all fetching the community table after a 404.
    last_refresh: Mutex<Option<Instant>>,
}

impl OpsTable {
    pub(crate) fn builtin() -> Self {
        let mut ops = HashMap::new();
        ops.insert(
            TWEET_DETAIL.to_string(),
            OpMeta {
                query_id: "3BlMtudy4N-d78ch7zTLZQ".to_string(),
                features: default_features(),
                field_toggles: Some(detail_field_toggles()),
            },
        );
        ops.insert(
            TWEET_BY_ID.to_string(),
            OpMeta {
                query_id: "xZfFqfOmKQu_OXekGI59mg".to_string(),
                features: default_features(),
                field_toggles: Some(by_id_field_toggles()),
            },
        );
        ops.insert(
            VIEWER.to_string(),
            OpMeta {
                query_id: "TpQxQtWMTMnIAMPlMGMqNw".to_string(),
                features: viewer_features(),
                field_toggles: Some(json!({
                    "isDelegate": false,
                    "withAuxiliaryUserLabels": false
                })),
            },
        );
        Self {
            ops: RwLock::new(ops),
            last_refresh: Mutex::new(None),
        }
    }

    pub(crate) fn get(&self, operation: &str) -> Option<OpMeta> {
        self.ops
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(operation)
            .cloned()
    }

    /// Replaces the two operations from the community table. Returns whether anything changed.
    /// The request deliberately carries no cookies: it goes to GitHub, not X.
    pub(crate) fn refresh(&self, transport: &dyn Transport, timeout: Duration) -> bool {
        {
            let mut last = self
                .last_refresh
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if last.is_some_and(|at| at.elapsed() < REFRESH_INTERVAL) {
                return false;
            }
            *last = Some(Instant::now());
        }

        let request = HttpRequest {
            method: Method::Get,
            url: COMMUNITY_URL.to_string(),
            headers: vec![
                ("accept".into(), "application/json".into()),
                (
                    "user-agent".into(),
                    "TwitterLibrary/1.0 (+https://github.com/fa0311/twitter-openapi)".into(),
                ),
            ],
            body: None,
            timeout,
        };
        let Ok(response) = transport.send(&request) else {
            self.clear_refresh_stamp();
            return false;
        };
        if response.status != 200 {
            self.clear_refresh_stamp();
            return false;
        }
        let Ok(value) = serde_json::from_str::<Value>(&response.body) else {
            self.clear_refresh_stamp();
            return false;
        };

        let mut updated = false;
        let mut ops = self
            .ops
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        for operation in [TWEET_DETAIL, TWEET_BY_ID] {
            if let Some(meta) = parse_community_op(&value, operation) {
                if ops.get(operation).map(|old| old.query_id.as_str())
                    != Some(meta.query_id.as_str())
                    || ops
                        .get(operation)
                        .map(|old| old.features != meta.features)
                        .unwrap_or(true)
                {
                    updated = true;
                }
                ops.insert(operation.to_string(), meta);
            }
        }
        drop(ops);
        updated
    }

    fn clear_refresh_stamp(&self) {
        *self
            .last_refresh
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
    }
}

pub(crate) fn global() -> &'static OpsTable {
    static OPS: OnceLock<OpsTable> = OnceLock::new();
    OPS.get_or_init(OpsTable::builtin)
}

fn parse_community_op(root: &Value, operation: &str) -> Option<OpMeta> {
    let object = root.get(operation)?;
    let query_id = object.get("queryId")?.as_str()?.trim();
    if !valid_query_id(query_id) {
        return None;
    }
    let features = object
        .get("features")
        .filter(|features| features.as_object().is_some_and(|map| !map.is_empty()))
        .cloned()
        .unwrap_or_else(default_features);
    let field_toggles = object
        .get("fieldToggles")
        .filter(|toggles| toggles.as_object().is_some_and(|map| !map.is_empty()))
        .cloned()
        .or_else(|| {
            Some(match operation {
                TWEET_DETAIL => detail_field_toggles(),
                _ => by_id_field_toggles(),
            })
        });
    Some(OpMeta {
        query_id: query_id.to_string(),
        features,
        field_toggles,
    })
}

fn valid_query_id(query_id: &str) -> bool {
    (5..=120).contains(&query_id.len())
        && query_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

pub(crate) fn detail_variables(id: &str) -> Value {
    json!({
        "focalTweetId": id,
        "referrer": "home",
        "with_rux_injections": false,
        "rankingMode": "Relevance",
        "includePromotedContent": false,
        "withCommunity": true,
        "withQuickPromoteEligibilityTweetFields": true,
        "withBirdwatchNotes": true,
        "withVoice": true
    })
}

pub(crate) fn by_id_variables(id: &str) -> Value {
    json!({
        "tweetId": id,
        "withCommunity": false,
        "includePromotedContent": false,
        "withVoice": false,
        "withBirdwatchNotes": true
    })
}

pub(crate) fn viewer_variables() -> Value {
    json!({ "withCommunitiesMemberships": true })
}

fn viewer_features() -> Value {
    json!({
        "creator_subscriptions_tweet_preview_api_enabled": true,
        "profile_label_improvements_pcf_label_in_post_enabled": true,
        "responsive_web_graphql_timeline_navigation_enabled": true,
        "responsive_web_profile_redirect_enabled": true,
        "rweb_tipjar_consumption_enabled": false,
        "subscriptions_upsells_api_enabled": false,
        "verified_phone_label_enabled": false
    })
}

fn default_features() -> Value {
    json!({
        "articles_preview_enabled": true,
        "c9s_tweet_anatomy_moderator_badge_enabled": true,
        "communities_web_enable_tweet_community_results_fetch": true,
        "content_disclosure_ai_generated_indicator_enabled": true,
        "content_disclosure_indicator_enabled": true,
        "creator_subscriptions_tweet_preview_api_enabled": true,
        "freedom_of_speech_not_reach_fetch_enabled": true,
        "graphql_is_translatable_rweb_tweet_is_translatable_enabled": true,
        "longform_notetweets_consumption_enabled": true,
        "longform_notetweets_inline_media_enabled": true,
        "longform_notetweets_rich_text_read_enabled": true,
        "profile_label_improvements_pcf_label_in_post_enabled": true,
        "responsive_web_edit_tweet_api_enabled": true,
        "responsive_web_graphql_exclude_directive_enabled": true,
        "responsive_web_graphql_timeline_navigation_enabled": true,
        "responsive_web_grok_analysis_button_from_backend": true,
        "responsive_web_grok_analyze_post_followups_enabled": true,
        "responsive_web_grok_annotations_enabled": true,
        "responsive_web_grok_community_note_auto_translation_is_enabled": true,
        "responsive_web_grok_image_annotation_enabled": true,
        "responsive_web_grok_imagine_annotation_enabled": true,
        "responsive_web_grok_share_attachment_enabled": true,
        "responsive_web_grok_show_grok_translated_post": true,
        "responsive_web_jetfuel_frame": true,
        "responsive_web_nested_quote_preview_enabled": true,
        "responsive_web_profile_redirect_enabled": true,
        "responsive_web_twitter_article_tweet_consumption_enabled": true,
        "rweb_cashtags_composer_attachment_enabled": true,
        "rweb_cashtags_enabled": true,
        "rweb_sports_post_context_enabled": true,
        "rweb_tipjar_consumption_enabled": true,
        "rweb_video_screen_enabled": true,
        "rweb_video_timestamps_enabled": true,
        "standardized_nudges_misinfo": true,
        "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled": true,
        "tweetypie_unmention_optimization_enabled": true,
        "view_counts_everywhere_api_enabled": true
    })
}

fn detail_field_toggles() -> Value {
    json!({
        "withPayments": false,
        "withDmBlocks": false,
        "withArticleRichContentState": true,
        "withArticlePlainText": false,
        "withArticleSummaryText": true,
        "withArticleVoiceOver": true,
        "withGrokAnalyze": false,
        "withDisallowedReplyControls": false
    })
}

fn by_id_field_toggles() -> Value {
    json!({
        "withArticleRichContentState": true,
        "withArticlePlainText": false,
        "withArticleSummaryText": true,
        "withArticleVoiceOver": true,
        "withPayments": false
    })
}
