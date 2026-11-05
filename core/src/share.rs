//! A link shared to the app: the post is downloaded into a library of its own (a staging folder),
//! never the real one, so the share page can show it and ask where it goes. Nothing reaches the
//! real library until the person says so: `pack` makes a `.tlpack` of it for `archive::import_pack_into`.
//! Closing the page is deleting the folder. It works without the app's library being open (a share
//! extension has none) and beside a running one (the Flutter apps show this page themselves).
use crate::archive::{self, ExportOptions};
use crate::download::{self, Route};
use crate::library::{FeedItem, FeedRequest, Library};
use serde::Serialize;
use std::path::Path;

#[derive(Debug, Serialize)]
pub struct Staged {
    /// Everything that came down, each post's media in order.
    pub items: Vec<FeedItem>,
    /// Links that did not, with why: (link, reason).
    pub failed: Vec<(String, String)>,
}

fn items(lib: &Library) -> anyhow::Result<Vec<FeedItem>> {
    let all: FeedRequest = serde_json::from_value(serde_json::json!({ "scope": "both" }))?;
    lib.feed(&all)
}

/// Downloads `urls` into the staging folder `dir`. Blocks until they are done: call it off the main
/// thread.
pub fn stage(dir: &Path, urls: &[String], route: Route) -> anyhow::Result<Staged> {
    let lib = Library::open(dir)?;
    let failed = urls.iter().filter_map(|u| download::stage_link(&lib, u, route).err().map(|e| (u.clone(), format!("{e:#}")))).collect();
    Ok(Staged { items: items(&lib)?, failed })
}

/// What `dir` holds, as a `.tlpack` at `out`.
pub fn pack(dir: &Path, out: &Path) -> anyhow::Result<()> {
    let lib = Library::open(dir)?;
    let ids: Vec<String> = items(&lib)?.into_iter().map(|i| i.media_id).collect();
    archive::export_media(&lib, &ids, ExportOptions::default(), out)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("tl-share-{name}-{}", rand::random::<u64>()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn a_bad_link_is_reported_and_nothing_is_staged() {
        let dir = temp("bad");
        let s = stage(&dir, &["not a link".to_string()], Route::Fx).unwrap();
        assert!(s.items.is_empty());
        assert_eq!(s.failed.len(), 1);
        assert_eq!(s.failed[0].0, "not a link");
        assert!(pack(&dir, &dir.join("x.tlpack")).is_err(), "an empty stage makes no pack");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// The real network: `cargo test --lib share -- --ignored`
    #[test]
    #[ignore]
    fn staged_post_reaches_the_library_only_through_its_pack() {
        let (stage_dir, lib_dir) = (temp("stage"), temp("lib"));
        // any public post with a photo or a video
        let url = std::env::var("TL_TEST_PUBLIC_POST_URL").expect("TL_TEST_PUBLIC_POST_URL");
        let s = stage(&stage_dir, &[url], Route::Fx).unwrap();
        assert!(s.failed.is_empty(), "{:?}", s.failed);
        assert!(!s.items.is_empty());
        assert!(std::path::Path::new(&s.items[0].path).exists());

        let real = Library::open(&lib_dir).unwrap();
        assert!(items(&real).unwrap().is_empty(), "staging leaves the real library alone");
        let pack_file = stage_dir.join("post.tlpack");
        pack(&stage_dir, &pack_file).unwrap();
        archive::import_pack_into(&real, &pack_file, Some("分享测试")).unwrap();
        assert_eq!(items(&real).unwrap().len(), s.items.len());
        assert_eq!(real.db().folders().unwrap().iter().find(|f| f.0 == "分享测试").map(|f| f.1), Some(s.items.len() as _));
        std::fs::remove_dir_all(&stage_dir).unwrap();
        std::fs::remove_dir_all(&lib_dir).unwrap();
    }
}
