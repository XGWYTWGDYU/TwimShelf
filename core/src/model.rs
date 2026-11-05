use serde::{Deserialize, Serialize};

/// Who added a tag. Endorsing an AI tag yields USER|AI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Origin(pub u8);

impl Origin {
    pub const USER: Origin = Origin(1);
    pub const AI: Origin = Origin(2);
    pub fn endorse(self) -> Origin { Origin(self.0 | Self::USER.0) }
    pub fn matches(self, filter: SearchScope) -> bool {
        match filter {
            SearchScope::Mine => self.0 & Self::USER.0 != 0,
            SearchScope::Ai => self.0 & Self::AI.0 != 0,
            SearchScope::Both => self.0 != 0,
            SearchScope::Common => self.0 & 3 == 3,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
/// Which tags a search looks at: mine, the AI's, either ("both"), or only the tags both carry
/// ("common": mine and the AI's at once, e.g. an AI tag I endorsed).
pub enum SearchScope { Mine, Ai, Both, Common }

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MediaKind { Photo, Video }

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PostMeta {
    pub id: String,
    pub author_name: Option<String>,
    pub screen_name: Option<String>,
    pub text: Option<String>,
    pub created_at: Option<String>,
    pub url: Option<String>,
}

impl PostMeta {
    /// Longest post text kept (bytes): far above any real post, and small enough that one sync
    /// record (a post is one record, which cannot be split) always fits in a sync frame.
    pub const MAX_TEXT_BYTES: usize = 512 << 10;
    /// Longest author name, @handle, date or link kept (bytes).
    pub const MAX_FIELD_BYTES: usize = 4 << 10;

    /// This post with every field cut (at a character boundary) to its limit, and the names of
    /// the fields that were cut. Everything that stores a post goes through this, so that an
    /// imported file cannot make a sync record too large to ever be sent.
    pub fn clamped(&self) -> (PostMeta, Vec<&'static str>) {
        fn cut(v: &Option<String>, max: usize, name: &'static str, cutlist: &mut Vec<&'static str>) -> Option<String> {
            let s = v.as_ref()?;
            if s.len() <= max { return Some(s.clone()); }
            let mut end = max;
            while !s.is_char_boundary(end) { end -= 1; }
            cutlist.push(name);
            Some(s[..end].to_string())
        }
        let mut cutlist = vec![];
        let p = PostMeta {
            id: self.id.clone(),
            author_name: cut(&self.author_name, Self::MAX_FIELD_BYTES, "field.author", &mut cutlist),
            screen_name: cut(&self.screen_name, Self::MAX_FIELD_BYTES, "field.screenName", &mut cutlist),
            text: cut(&self.text, Self::MAX_TEXT_BYTES, "field.text", &mut cutlist),
            created_at: cut(&self.created_at, Self::MAX_FIELD_BYTES, "field.date", &mut cutlist),
            url: cut(&self.url, Self::MAX_FIELD_BYTES, "field.url", &mut cutlist),
        };
        (p, cutlist)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn endorsed_tag_matches_every_scope() {
        let o = Origin::AI.endorse();
        for s in [SearchScope::Mine, SearchScope::Ai, SearchScope::Both] { assert!(o.matches(s)); }
        assert!(!Origin::AI.matches(SearchScope::Mine));
        assert!(!Origin::USER.matches(SearchScope::Ai));
        assert!(o.matches(SearchScope::Common), "an endorsed tag is common");
        assert!(!Origin::AI.matches(SearchScope::Common) && !Origin::USER.matches(SearchScope::Common));
    }
}
