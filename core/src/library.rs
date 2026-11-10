//! A library directory: SQLite metadata + content-addressed blobs.
use crate::legacy::{meta_from_folder_name, parse_sidecar};
use crate::model::{MediaKind, Origin, SearchScope};
use std::collections::HashMap;
use crate::store::Store;
use rand::seq::SliceRandom;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

/// Deletes incomplete temporary files on error, cancellation and task abort.
pub(crate) struct TempFile(pub PathBuf);
impl TempFile {
    pub fn into_path(mut self) -> PathBuf { std::mem::take(&mut self.0) }
}
impl Drop for TempFile { fn drop(&mut self) { let _ = fs::remove_file(&self.0); } }

pub struct Library {
    pub dir: PathBuf,
    store: Mutex<Store>,
    vec_cache: Mutex<Option<(String, std::sync::Arc<std::collections::HashMap<String, Vec<f32>>>)>>,
    /// Model folders live outside the library by default so tests and resets don't re-download them.
    models: Mutex<PathBuf>,
    /// Bumped by `wipe` while it holds the store: work started before (a download whose media
    /// are already fetched, a sync session) checks it with `db_at` and stops instead of writing
    /// the old content into the emptied library.
    epoch: std::sync::atomic::AtomicU64,
}


#[derive(Debug, Deserialize)]
pub struct FeedRequest {
    #[serde(default)] pub terms: Vec<String>,
    pub scope: SearchScope,
    /// Shuffle with this seed; None keeps a stable order (the apps order with the system RNG).
    #[serde(default)] pub seed: Option<u64>,
    /// By when it was added, newest first (instead of `seed`): a post's place is its newest media,
    /// its media stay in their order.
    #[serde(default)] pub newest_first: bool,
    /// Substring + semantic matching when true, exact label match when false.
    #[serde(default = "yes")] pub fuzzy: bool,
    /// Optional embedding per term (same order as `terms`), from `embed_model`.
    #[serde(default)] pub term_vectors: Vec<Option<Vec<f32>>>,
    #[serde(default)] pub embed_model: Option<String>,
    #[serde(default = "default_threshold")] pub threshold: f32,
    /// Where each term may match (any enabled field counts). Default: tags only.
    #[serde(default)] pub fields: SearchFields,
    #[serde(default)] pub filter: FeedFilter,
    /// Post cards: a post matches when any of its media does (a tag on one photo finds the post),
    /// and then comes with all its media — the ones the media filters (kind, folder, damaged,
    /// album, loose, recent) let through — so the card is the whole post, from its first media.
    /// Without it (the photo grid) only the matching media themselves.
    #[serde(default)] pub whole_posts: bool,
}

/// Extra feed filters (all must hold).
#[derive(Debug, Deserialize, Clone, Default)]
pub struct FeedFilter {
    /// Only this author's posts (@handle, or the display name when a post has no handle).
    #[serde(default)] pub author: Option<String>,
    /// Only media carrying every one of these exact tags (within the search scope).
    #[serde(default)] pub labels: Vec<String>,
    /// Reviewed = has a tag you added or endorsed; unreviewed = has none.
    #[serde(default)] pub review: crate::rules::Review,
    /// Only media whose file failed verification.
    #[serde(default)] pub bad_only: bool,
    /// Only media in this folder.
    #[serde(default)] pub folder: Option<String>,
    /// Only loose media (imported without a post).
    #[serde(default)] pub loose_only: bool,
    /// Only media brought in through a share extension (从相册导入).
    #[serde(default)] pub album_only: bool,
    /// Only "最近添加" posts.
    #[serde(default)] pub recent_only: bool,
    /// Only photos or only videos.
    #[serde(default)] pub kind: Option<MediaKind>,
    /// Search words written with a minus ("-猫"): media where any of them occurs in a searched
    /// field (a tag of an allowed origin, the post text, the author) are left out. Plain
    /// "contains" matching (`rules::search_matches`): an exclusion never reaches by meaning.
    #[serde(default)] pub exclude_terms: Vec<String>,
    /// Which tag origins a search counts, overriding the scope's (1 = only mine, 2 = only the
    /// AI's, 3 = both together; "-我的", "-AI", "-共同" take theirs away). Some(empty): no tag.
    #[serde(default)] pub origins: Option<Vec<u8>>,
    /// Media in none of these folders ("-文件夹 名称").
    #[serde(default)] pub exclude_folders: Vec<String>,
    /// No "最近添加" posts ("-最近").
    #[serde(default)] pub exclude_recent: bool,
    /// No loose media ("-外部导入").
    #[serde(default)] pub exclude_loose: bool,
}

impl FeedFilter {
    /// Whether anything here picks media by what they are about (rather than where they are).
    fn content(&self) -> bool {
        self.author.as_ref().is_some_and(|a| !a.trim().is_empty()) || !self.labels.is_empty() || self.review != crate::rules::Review::Any
            || self.exclude_terms.iter().any(|t| !t.trim().is_empty()) || self.origins.is_some()
    }
    /// Only the filters on the media themselves (type, place, state), not the search.
    fn media_filters(&self) -> FeedFilter {
        FeedFilter { author: None, labels: vec![], review: crate::rules::Review::Any, exclude_terms: vec![], origins: None, ..self.clone() }
    }
}

#[derive(Debug, Deserialize, Clone, Copy)]
pub struct SearchFields {
    #[serde(default = "yes")] pub tags: bool,
    #[serde(default)] pub text: bool,
    #[serde(default)] pub author: bool,
}
impl Default for SearchFields { fn default() -> Self { SearchFields { tags: true, text: false, author: false } } }
fn default_threshold() -> f32 { 0.55 }
fn yes() -> bool { true }

#[derive(Debug, Serialize, Clone)]
pub struct FeedItem {
    pub media_id: String,
    pub post_id: String,
    pub ordinal: i64,
    pub kind: MediaKind,
    pub path: String,
    pub text: Option<String>,
    pub author_name: Option<String>,
    pub screen_name: Option<String>,
    pub url: Option<String>,
    pub created_at: Option<String>,
    pub tags: Vec<TagView>,
    /// Why the file is damaged ('missing', 'hash', 'decode'), if it failed verification.
    pub bad: Option<String>,
    /// The post is "最近添加" (batch-downloaded from a bookmarks JSON in the last 5 days).
    #[serde(default)] pub recent: bool,
    /// Brought in through a share extension (从相册导入).
    #[serde(default)] pub album: bool,
    /// Width and height as displayed, once read from the file (`media_size`).
    #[serde(default)] pub size: Option<(u32, u32)>,
}

/// A feed in a compact form for the apps: a library of a hundred thousand media listed item by
/// item repeats each post's text, author and link for every one of its media, each tag list, and
/// the library folder in every path (47 MB of JSON). Here each post and each distinct tag list
/// comes once and media refer to them by position; paths are relative to `root`. `unpack` (and
/// the apps' decoders) rebuild the same items.
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct PackedFeed {
    /// Prefix of every media path (the library folder, with its trailing separator).
    pub root: String,
    pub posts: Vec<PackedPost>,
    /// Distinct tag lists: [label, origin, models] per tag.
    pub tag_lists: Vec<Vec<(String, u8, Vec<String>)>>,
    /// One per media: [media id, post (index), ordinal, kind ("p"/"v"), path below root,
    /// tag list (index), damage or "", width and height (0 when not known) ].
    pub media: Vec<(String, u32, i64, String, String, u32, String, u32, u32)>,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct PackedPost {
    pub id: String,
    pub text: Option<String>,
    pub author_name: Option<String>,
    pub screen_name: Option<String>,
    pub url: Option<String>,
    pub created_at: Option<String>,
    pub recent: bool,
    #[serde(default)] pub album: bool,
}

impl PackedFeed {
    pub fn pack(items: &[FeedItem], root: &str) -> PackedFeed {
        let mut posts: Vec<PackedPost> = Vec::new();
        let mut post_index: HashMap<&str, u32> = HashMap::new();
        let mut tag_lists: Vec<Vec<(String, u8, Vec<String>)>> = Vec::new();
        let mut tag_index: HashMap<Vec<(String, u8, Vec<String>)>, u32> = HashMap::new();
        let mut media = Vec::with_capacity(items.len());
        for it in items {
            let p = *post_index.entry(it.post_id.as_str()).or_insert_with(|| {
                posts.push(PackedPost { id: it.post_id.clone(), text: it.text.clone(), author_name: it.author_name.clone(), screen_name: it.screen_name.clone(), url: it.url.clone(), created_at: it.created_at.clone(), recent: it.recent, album: it.album });
                posts.len() as u32 - 1
            });
            let tags: Vec<(String, u8, Vec<String>)> = it.tags.iter().map(|t| (t.label.clone(), t.origin, t.models.clone())).collect();
            let t = match tag_index.get(&tags) { Some(&i) => i, None => { tag_lists.push(tags.clone()); let i = tag_lists.len() as u32 - 1; tag_index.insert(tags, i); i } };
            let path = it.path.strip_prefix(root).unwrap_or(&it.path).to_string();
            let kind = if matches!(it.kind, MediaKind::Video) { "v" } else { "p" };
            media.push((it.media_id.clone(), p, it.ordinal, kind.to_string(), path, t, it.bad.clone().unwrap_or_default(), it.size.map_or(0, |s| s.0), it.size.map_or(0, |s| s.1)));
        }
        PackedFeed { root: root.to_string(), posts, tag_lists, media }
    }

    pub fn unpack(&self) -> Vec<FeedItem> {
        self.media.iter().map(|(id, p, ordinal, kind, path, t, bad, w, h)| {
            let post = &self.posts[*p as usize];
            FeedItem {
                media_id: id.clone(), post_id: post.id.clone(), ordinal: *ordinal,
                kind: if kind == "v" { MediaKind::Video } else { MediaKind::Photo },
                path: if path.starts_with('/') || path.contains(':') { path.clone() } else { format!("{}{path}", self.root) },
                text: post.text.clone(), author_name: post.author_name.clone(), screen_name: post.screen_name.clone(),
                url: post.url.clone(), created_at: post.created_at.clone(),
                tags: self.tag_lists[*t as usize].iter().map(|(label, origin, models)| TagView { label: label.clone(), origin: *origin, models: models.clone() }).collect(),
                bad: (!bad.is_empty()).then(|| bad.clone()), recent: post.recent, album: post.album,
                size: (*w > 0 && *h > 0).then_some((*w, *h)),
            }
        }).collect()
    }
}

#[derive(Debug, Serialize, Clone)]
pub struct TagView { pub label: String, pub origin: u8, /// AI models that proposed this tag.
    pub models: Vec<String> }

pub use crate::import::ImportReport;

/// A file refused because its content is not the media it claims to be (an HTML error page saved
/// as .jpg…): the import's "not_media" category, told apart by this type rather than by words.
#[derive(Debug)]
pub struct NotMedia(pub String);
impl std::fmt::Display for NotMedia { fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { f.write_str(&self.0) } }
impl std::error::Error for NotMedia {}

/// Whether an error is (or wraps) a `NotMedia`.
pub fn is_not_media(e: &anyhow::Error) -> bool { e.chain().any(|c| c.is::<NotMedia>()) }

/// Post metadata of a legacy folder: the sidecar when present, else the folder name is the text.
pub fn legacy_post_meta(folder_name: &str, sidecar: Option<String>) -> crate::model::PostMeta {
    let mut meta = match sidecar { Some(t) => parse_sidecar(&t), None => meta_from_folder_name(folder_name) };
    if meta.id.is_empty() { meta.id = format!("legacy:{folder_name}"); }
    if meta.text.is_none() { meta.text = Some(folder_name.to_string()); }
    meta
}

/// Text of a sidecar file: UTF-8 when valid, otherwise GBK (files written on Chinese Windows).
pub fn decode_text(b: &[u8]) -> String {
    match std::str::from_utf8(b) { Ok(s) => s.to_string(), Err(_) => encoding_rs::GBK.decode(b).0.into_owned() }
}

pub fn kind_for(path: &Path) -> Option<(MediaKind, &'static str)> {
    let ext = path.extension()?.to_str()?.to_ascii_lowercase();
    match ext.as_str() {
        "jpg" | "jpeg" => Some((MediaKind::Photo, "jpg")),
        "png" => Some((MediaKind::Photo, "png")),
        "webp" => Some((MediaKind::Photo, "webp")),
        "gif" => Some((MediaKind::Photo, "gif")),
        "heic" | "heif" | "hif" => Some((MediaKind::Photo, "heic")),
        "avif" => Some((MediaKind::Photo, "avif")),
        "mp4" | "m4v" => Some((MediaKind::Video, "mp4")),
        "mov" | "qt" => Some((MediaKind::Video, "mov")),
        _ => None,
    }
}

impl Library {
    pub fn open(dir: impl Into<PathBuf>) -> anyhow::Result<Library> {
        let dir = dir.into();
        fs::create_dir_all(dir.join("blobs"))?;
        let db = dir.join("library.sqlite");
        let had_media = fs::read_dir(dir.join("blobs")).map_or(false, |mut r| r.next().is_some());
        let (store, _) = Store::open_reporting(db.to_str().unwrap())?;
        // media files on disk but no media in the database (the database was deleted): the files
        // stay — they are not orphans. Sync brings the library's records back from the account's
        // other devices and finds the files already here.
        let lost = had_media && store.conn().query_row("SELECT count(*) FROM media", [], |r| r.get::<_, i64>(0)).unwrap_or(0) == 0;
        // Leftovers from interrupted downloads/syncs/imports: nothing is mid-write at startup.
        let _ = fs::remove_dir_all(dir.join("tmp"));
        let models = dir.join("models");
        let lib = Library { dir, store: Mutex::new(store), vec_cache: Mutex::new(None), models: Mutex::new(models), epoch: Default::default() };
        // Housekeeping below writes to the database; on a full disk it fails, and the library must
        // still open (so media can be deleted to make room). Each step is retried at the next start.
        if let Err(e) = lib.settle() { lib.diag("maintenance_skipped", serde_json::json!({ "step": "settle", "error": crate::diagnostics::scrub(&format!("{e:#}")) })); } // finish file removals interrupted by a quit
        if !lost {
            if let Ok(n) = lib.sweep_orphan_blobs() { if n > 0 { lib.diag("orphan_files_removed", serde_json::json!({ "files": n })); } }
        }
        lib.keep_reserve();
        let _ = lib.db().prune_recent(crate::store::now_ms());
        let _ = lib.db().gc_dead_tags();
        // records a newer app version sent before this device was updated
        let dir2 = lib.dir.clone();
        if let Ok(n) = lib.db().retry_pending_ops(|id, ext| dir2.join(crate::oplog::blob_rel(id, ext)).exists()) {
            if n > 0 { lib.diag("pending_ops_applied", serde_json::json!({ "applied": n })); }
        }
        Ok(lib)
    }

    // ---------- diagnostics (counts only) ----------

    /// Appends one line to `logs/diagnostics.log`: a timestamp, an event name and numbers. Never
    /// contains post text, authors, tags, file names or media — only counts — so it can be read to
    /// diagnose totals without looking at the library's content. Rotates at 2 MB.
    pub fn diag(&self, event: &str, data: serde_json::Value) {
        let ts = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
        let line = serde_json::json!({ "t": ts, "event": event, "data": data }).to_string();
        crate::diagnostics::append_capped(&self.dir.join("logs").join("diagnostics.log"), &line);
    }

    /// Library totals for the diagnostics log (numbers only).
    pub fn counts(&self) -> serde_json::Value {
        let db = self.db();
        let q = |sql: &str| db.conn().query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap_or(-1);
        let st = db.stats().ok();
        serde_json::json!({
            "posts_with_live_media": st.as_ref().map(|s| s.posts), "photos": st.as_ref().map(|s| s.photos), "videos": st.as_ref().map(|s| s.videos),
            "post_rows": q("SELECT count(*) FROM post"),
            "post_rows_without_media": q("SELECT count(*) FROM post p WHERE NOT EXISTS(SELECT 1 FROM media m WHERE m.post_id=p.id)"),
            "media_rows": q("SELECT count(*) FROM media"),
            "media_trashed": q("SELECT count(*) FROM trash WHERE state=1"), "media_purged": q("SELECT count(*) FROM trash WHERE state=2"),
            "waiting_for_file": q("SELECT count(*) FROM want_blob"), "pending_file_removal": q("SELECT count(*) FROM gc"),
            "damaged": q("SELECT count(*) FROM bad_media"),
            "ops_local": q("SELECT count(*) FROM op WHERE device=(SELECT v FROM meta WHERE k='device')"),
            "ops_remote": q("SELECT count(*) FROM op WHERE device!=(SELECT v FROM meta WHERE k='device')"),
        })
    }

    /// Logs the start of an import with the totals before it.
    pub fn diag_import_start(&self, kind: &str) { self.diag("import_start", serde_json::json!({ "kind": kind, "before": self.counts() })); }

    // ---------- recycle bin ----------

    /// Removes the files of permanently deleted media (local and synced deletions). The state
    /// check and the removal happen under the store lock, so a concurrent restore from a peer can
    /// never leave a live media without its file. Returns how many files were removed.
    pub fn settle(&self) -> anyhow::Result<usize> {
        let db = self.db();
        let pending = db.gc_pending()?;
        if pending.is_empty() { return Ok(0); }
        let tx = db.conn().unchecked_transaction()?;
        let mut removed = 0;
        for (id, path) in pending {
            if db.trash_reg(&id)?.state == crate::rules::PURGED {
                // only files inside blobs/ are ever deleted, whatever a row says
                if let Some(p) = path.filter(|p| crate::rules::is_blob_path(p.as_bytes())) {
                    match fs::remove_file(self.dir.join(p)) {
                        Ok(()) => removed += 1,
                        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {},
                        Err(_) => continue, // retain the GC row and retry; never forget a failed deletion
                    }
                }
            }
            db.gc_done(&id)?;
        }
        let _ = db.gc_dead_tags();
        tx.commit()?;
        drop(db);
        self.diag("files_removed_after_deletion", serde_json::json!({ "files": removed }));
        Ok(removed)
    }

    // ---------- full disk ----------

    /// A small placeholder file: on a full disk even deleting needs a little room (SQLite writes
    /// its log first), so deleting media to make room releases it and tries again.
    pub(crate) fn reserve_path(&self) -> PathBuf { self.dir.join(".space-reserve") }
    const RESERVE_BYTES: usize = 4 << 20;

    /// Creates the placeholder if it is missing and there is room (best effort).
    fn keep_reserve(&self) {
        let p = self.reserve_path();
        if fs::metadata(&p).map_or(false, |m| m.len() as usize == Self::RESERVE_BYTES) { return; }
        if fs::write(&p, vec![0u8; Self::RESERVE_BYTES]).is_err() { let _ = fs::remove_file(&p); }
    }

    /// Whether an error means the disk (or the database) is full.
    pub fn is_disk_full(e: &anyhow::Error) -> bool {
        let t = format!("{e:#}");
        t.contains("disk is full") || t.contains("No space left") || t.contains("os error 28")
    }

    /// Applies one recycle-bin action to each media; returns how many changed. On a full disk the
    /// space reserve is released and the action tried once more, so room can always be made.
    pub fn trash_apply(&self, ids: &[String], a: crate::rules::TrashAction) -> anyhow::Result<usize> {
        match self.trash_apply_once(ids, a) {
            Err(e) if Self::is_disk_full(&e) && self.reserve_path().exists() => {
                let _ = fs::remove_file(self.reserve_path());
                self.diag("space_reserve_released", serde_json::json!({ "action": format!("{a:?}") }));
                self.trash_apply_once(ids, a)
            }
            r => r,
        }
    }

    fn trash_apply_once(&self, ids: &[String], a: crate::rules::TrashAction) -> anyhow::Result<usize> {
        let n = {
            let db = self.db();
            let tx = db.conn().unchecked_transaction()?;
            let mut n = 0;
            for id in ids { if db.trash_action(id, a)? { n += 1; } }
            tx.commit()?;
            n
        };
        self.diag("bin", serde_json::json!({ "action": format!("{a:?}"), "requested": ids.len(), "changed": n }));
        if a == crate::rules::TrashAction::Purge { self.settle()?; }
        Ok(n)
    }

    /// Moves every live media of a post to the bin.
    pub fn trash_post(&self, post_id: &str) -> anyhow::Result<usize> {
        let ids = self.db().action_ids(&[], &[post_id.into()])?;
        self.trash_apply(&ids, crate::rules::TrashAction::Trash)
    }

    /// Empties the bin (every media in it is deleted permanently, on all devices).
    pub fn empty_trash(&self) -> anyhow::Result<usize> {
        let ids: Vec<String> = self.db().trashed_ids()?.into_iter().map(|(id, _)| id).collect();
        self.trash_apply(&ids, crate::rules::TrashAction::Purge)
    }

    /// Days a media stays in the bin before it is deleted automatically (0 = never). Default 30.
    pub fn trash_keep_days(&self) -> u32 {
        self.db().meta_get("trash_keep_days").ok().flatten().and_then(|v| v.parse().ok()).unwrap_or(30)
    }
    pub fn set_trash_keep_days(&self, days: u32) -> anyhow::Result<()> { Ok(self.db().meta_set("trash_keep_days", &days.to_string())?) }

    /// Deletes media that stayed in the bin longer than the retention period.
    pub fn expire_trash(&self, now_ms: u64) -> anyhow::Result<usize> {
        let keep = self.trash_keep_days() as u64 * 86_400_000;
        let ids: Vec<String> = self.db().trashed_ids()?.into_iter()
            .filter(|(_, r)| crate::rules::trash_expired(*r, now_ms, keep)).map(|(id, _)| id).collect();
        self.trash_apply(&ids, crate::rules::TrashAction::Purge)
    }

    pub fn trash_list(&self) -> anyhow::Result<Vec<crate::store::TrashItem>> {
        let mut v = self.db().trash_items()?;
        for t in &mut v { t.item.path = self.dir.join(&t.item.path).to_string_lossy().into_owned(); }
        Ok(v)
    }

    // ---------- verification ----------

    /// Hashes a stored file and compares it with its id: None = intact, else the reason.
    pub fn check_file(&self, id: &str, rel: &str) -> Option<&'static str> {
        use std::io::Read;
        if !crate::rules::is_blob_path(rel.as_bytes()) { return Some("missing"); }   // never read outside blobs/
        let Ok(mut f) = fs::File::open(self.dir.join(rel)) else { return Some("missing") };
        let mut h = Sha256::new();
        let mut buf = vec![0u8; 1 << 20];
        let mut head: Vec<u8> = vec![];
        loop {
            match f.read(&mut buf) { Ok(0) => break, Ok(n) => { if head.len() < 16 { head.extend_from_slice(&buf[..n.min(16 - head.len())]); } h.update(&buf[..n]) } Err(_) => return Some("missing") }
        }
        if hex::encode(h.finalize()) != id { return Some("hash"); }
        // intact, but is it really media? (files imported before content checks existed)
        let photo = !crate::rules::is_video_path(rel);
        if !crate::rules::sniff_ok(crate::rules::sniff(&head), photo) { return Some("not_media"); }
        None
    }

    /// The app could not decode a media: verify its file and record why it is damaged.
    /// An intact file that does not decode was broken at the source ('decode').
    pub fn report_bad(&self, media_id: &str) -> anyhow::Result<Option<String>> {
        let Some((_, _, _, rel)) = self.db().media_row(media_id)? else { return Ok(None) };
        let reason = self.check_file(media_id, &rel).unwrap_or("decode");
        self.db().set_bad(media_id, Some(reason))?;
        Ok(Some(reason.to_string()))
    }

    /// A grid could not make a thumbnail, with this core's decoders. A format it does not decode
    /// (HEIC, AVIF…) is no sign of damage: only the file itself is checked then.
    pub fn report_thumbnail_failed(&self, media_id: &str) -> anyhow::Result<Option<String>> {
        let Some((_, _, _, rel)) = self.db().media_row(media_id)? else { return Ok(None) };
        let ext = Path::new(&rel).extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
        if ["jpg", "jpeg", "png", "gif", "webp"].contains(&ext.as_str()) { return self.report_bad(media_id); }
        let Some(reason) = self.check_file(media_id, &rel) else { return Ok(None) };
        self.db().set_bad(media_id, Some(reason))?;
        Ok(Some(reason.to_string()))
    }

    /// Exclusive access to the metadata store.
    pub fn db(&self) -> MutexGuard<'_, Store> { self.store.lock().unwrap_or_else(|e| e.into_inner()) }

    /// The current library generation (see `epoch`).
    pub fn epoch(&self) -> u64 { self.epoch.load(std::sync::atomic::Ordering::SeqCst) }

    /// The store, if the library has not been wiped since `epoch` was read.
    pub fn db_at(&self, epoch: u64) -> anyhow::Result<MutexGuard<'_, Store>> {
        let db = self.db();
        if self.epoch() != epoch { anyhow::bail!(tr!("library.wiped")); }
        Ok(db)
    }

    /// Removes the copy of a file that an import or a backup restore stored for a media that is
    /// permanently deleted here (nothing refers to it any more). Called with the store locked
    /// (`db`), like `settle`: the check and the removal cannot interleave with a revival, or a
    /// restore from another device, which would otherwise leave a live media without its file.
    /// Returns whether the file was removed.
    pub fn drop_purged_copy(&self, db: &Store, sha: &str, rel: &str) -> bool {
        let purged = db.trash_reg(sha).map_or(false, |r| r.state == crate::rules::PURGED);
        let unused = db.media_row(sha).map_or(false, |m| m.is_none());
        purged && unused && crate::rules::is_blob_path(rel.as_bytes()) && fs::remove_file(self.dir.join(rel)).is_ok()
    }

    /// Files in blobs/ that no media (live, in the bin, or still awaited from a peer) refers to:
    /// left by a download, import or sync that stopped between storing the file and recording it.
    /// Runs at startup, when nothing is writing. Returns how many were removed.
    fn sweep_orphan_blobs(&self) -> anyhow::Result<usize> {
        let known: std::collections::HashSet<String> = {
            let db = self.db();
            let mut st = db.conn().prepare("SELECT id FROM media UNION SELECT media_id FROM want_blob")?;
            let v = st.query_map([], |r| r.get::<_, String>(0))?.collect::<Result<_, _>>()?;
            v
        };
        let mut removed = 0;
        let Ok(dirs) = fs::read_dir(self.dir.join("blobs")) else { return Ok(0) };
        for d in dirs.flatten() {
            let Ok(files) = fs::read_dir(d.path()) else { continue };
            for f in files.flatten() {
                let name = f.file_name().to_string_lossy().into_owned();
                let rel = format!("blobs/{}/{}", d.file_name().to_string_lossy(), name);
                // only well-formed library files are ever considered, and only unreferenced ones go
                if !crate::rules::is_blob_path(rel.as_bytes()) { continue; }
                let id = name.split('.').next().unwrap_or_default();
                if !known.contains(id) && fs::remove_file(f.path()).is_ok() { removed += 1; }
            }
        }
        Ok(removed)
    }

    /// Copies bytes into blobs/ab/<sha>.<ext> atomically; returns (sha, relative path). How tests
    /// put a file in place: the app stores through a temporary file and the media checks instead.
    pub fn put_blob(&self, bytes: &[u8], ext: &str) -> anyhow::Result<(String, String)> {
        let sha = hex::encode(Sha256::digest(bytes));
        let rel = format!("blobs/{}/{}.{}", &sha[..2], sha, ext);
        let dst = self.dir.join(&rel);
        if !dst.exists() {
            fs::create_dir_all(dst.parent().unwrap())?;
            let tmp = dst.with_extension("partial");
            let mut f = fs::File::create(&tmp)?;
            f.write_all(bytes)?;
            f.sync_all()?;
            fs::rename(&tmp, &dst)?;
        }
        Ok((sha, rel))
    }

    /// A fresh temp path inside the library (same volume as blobs, so the final rename is atomic).
    pub fn tmp_path(&self) -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static N: AtomicU64 = AtomicU64::new(0);
        let d = self.dir.join("tmp");
        let _ = fs::create_dir_all(&d);
        d.join(format!("{}-{}.partial", std::process::id(), N.fetch_add(1, Ordering::Relaxed)))
    }

    /// Moves a fully written, fsynced temp file into the blob store under its hash. An existing
    /// file is kept, unless it failed verification: then the verified copy atomically replaces it.
    pub fn commit_tmp(&self, tmp: &Path, sha: &str, ext: &str) -> anyhow::Result<String> {
        let db = self.db();
        self.commit_tmp_locked(&db, tmp, sha, ext)
    }

    pub(crate) fn commit_tmp_locked(&self, db: &Store, tmp: &Path, sha: &str, ext: &str) -> anyhow::Result<String> {
        if !crate::rules::valid_blob_id(sha.as_bytes()) || !crate::rules::valid_ext(ext.as_bytes()) { anyhow::bail!("invalid file name"); }
        let rel = format!("blobs/{}/{}.{}", &sha[..2], sha, ext);
        let dst = self.dir.join(&rel);
        let damaged = || db.bad_reason(sha).ok().flatten().map_or(false, |r| r == "missing" || r == "hash");
        // A copy we know is right takes the place of a file that is not, marked as such or not. The
        // length is cheap; the content is read only when no check has vouched for the file (the
        // exception is a file that went bad after a check: `verify` finds that one).
        let intact = || -> bool {
            let same_len = fs::metadata(&dst).ok().map(|m| m.len()) == fs::metadata(tmp).ok().map(|m| m.len());
            if !same_len { return false; }
            let checked = db.conn().prepare_cached("SELECT 1 FROM verified_media WHERE media_id=?1").and_then(|mut s| s.exists([sha])).unwrap_or(false);
            checked || self.check_file(sha, &rel).is_none()
        };
        if dst.exists() && !damaged() && intact() { fs::remove_file(tmp)?; } else {
            fs::create_dir_all(dst.parent().unwrap())?;
            db.conn().execute("DELETE FROM verified_media WHERE media_id=?1", [sha])?;
            fs::rename(tmp, &dst)?;
            // the rename itself is durable only once its folder is synced
            if let Ok(d) = fs::File::open(dst.parent().unwrap()) { let _ = d.sync_all(); }
        }
        Ok(rel)
    }

    /// Imports an unzipped legacy tree: root/<post folder>/{media…, 推文内容.txt?} (see `import`).
    pub fn import_legacy_dir(&self, root: &Path) -> anyhow::Result<ImportReport> { crate::import::import_dir(self, root, None) }

    /// Media matching every term (substring on tag labels within scope), shuffled by seed.
    pub fn feed(&self, req: &FeedRequest) -> anyhow::Result<Vec<FeedItem>> {
        let terms: Vec<String> = req.terms.iter().map(|t| t.trim().to_lowercase()).filter(|t| !t.is_empty()).collect();
        let sets: Vec<Vec<String>> = if terms.is_empty() || (!req.fields.tags && !req.fields.text && req.fields.author) {
            vec![]
        } else if !req.fuzzy {
            // without the semantic part a term still matches every tag that contains it
            // (棒球 → 棒球服): "contains" is the baseline, meaning-based matches come on top
            let labels = self.db().all_labels()?;
            terms.iter().map(|t| labels.iter().filter(|l| l.contains(t.as_str())).cloned().collect()).collect()
        } else {
            let labels = self.db().all_labels()?;
            let vectors = match &req.embed_model { Some(m) => self.vectors(m)?, None => Default::default() };
            terms.iter().enumerate().map(|(i, t)| {
                let qv = req.term_vectors.get(i).and_then(|v| v.as_deref());
                crate::semantic::expand(t, &labels, qv, &vectors, req.threshold)
            }).collect()
        };
        let mut items = self.db().feed_filtered(&sets, &terms, req.scope, req.fields, &req.filter)?;
        if req.whole_posts && (!terms.is_empty() || req.filter.content()) {
            let matched: std::collections::HashSet<String> = items.iter().map(|i| i.post_id.clone()).collect();
            let media_only = req.filter.media_filters();
            items = self.db().feed_filtered(&[], &[], req.scope, req.fields, &media_only)?;
            items.retain(|i| matched.contains(&i.post_id));
        }
        if req.newest_first {
            let added = self.db().posts_added()?;
            let at = |post: &str| added.get(post).copied().unwrap_or(0);
            items.sort_by(|a, b| at(&b.post_id).cmp(&at(&a.post_id)).then_with(|| a.post_id.cmp(&b.post_id)).then(a.ordinal.cmp(&b.ordinal)));
        } else if let Some(seed) = req.seed {
            let mut rng: rand::rngs::StdRng = rand::SeedableRng::seed_from_u64(seed);
            items.shuffle(&mut rng);
        }
        crate::media_size::read_few(self)?;
        let sizes = self.db().media_sizes()?;
        for it in &mut items {
            it.path = self.dir.join(&it.path).to_string_lossy().into_owned();
            it.size = sizes.get(&it.media_id).copied();
        }
        Ok(items)
    }

    /// The feed in the compact form the apps read (`PackedFeed`).
    pub fn feed_packed(&self, req: &FeedRequest) -> anyhow::Result<PackedFeed> {
        let items = self.feed(req)?;
        Ok(PackedFeed::pack(&items, &self.dir.join("").to_string_lossy()))
    }

    /// The folders page: folders with counts and covers (paths resolved), plus photo and video totals.
    pub fn folder_overview(&self) -> anyhow::Result<serde_json::Value> {
        let db = self.db();
        let mut folders = db.folder_overview()?;
        for f in &mut folders {
            // a cover path that is not a library file is dropped, never resolved
            f.cover_path = f.cover_path.take().filter(|p| crate::rules::is_blob_path(p.as_bytes())).map(|p| self.dir.join(p).to_string_lossy().into_owned());
        }
        let (photos, videos) = db.kind_counts()?;
        Ok(serde_json::json!({ "folders": folders, "photos": photos, "videos": videos }))
    }

    pub fn models_dir(&self) -> PathBuf { self.models.lock().unwrap().clone() }
    pub fn set_models_dir(&self, p: PathBuf) -> anyhow::Result<()> {
        fs::create_dir_all(&p)?;
        // Remove staging folders of interrupted model imports/pulls and stray partial files
        // (only while no model operation is running: those folders are then in use).
        let busy = crate::models::status().map_or(false, |s| s.running);
        if let Ok(rd) = fs::read_dir(&p).map_err(|_| ()).and_then(|r| if busy { Err(()) } else { Ok(r) }) {
            for e in rd.filter_map(|e| e.ok()) {
                let n = e.file_name().to_string_lossy().into_owned();
                if n.starts_with(".import-") || n.starts_with(".pull-") { let _ = fs::remove_dir_all(e.path()); }
            }
        }
        *self.models.lock().unwrap() = p;
        Ok(())
    }

    /// Streams a file into the blob store (constant memory, any size), hashing while copying.
    /// Videos must really be MP4 (`ftyp` box). Runs without holding the database lock.
    pub fn put_file(&self, src: &Path, kind: &MediaKind, ext: &str) -> anyhow::Result<(String, String)> {
        self.put_reader(&mut fs::File::open(src)?, kind, ext)
    }

    /// Why a file was refused as media (shown in import reports; returned as a `NotMedia`
    /// error, which the import tells apart by type).
    /// names the actual content.
    pub fn not_media_reason(sn: crate::rules::Sniff, photo: bool) -> String {
        use crate::rules::Sniff::*;
        let want = if photo { tr!("media.want.photo") } else { tr!("media.want.video") };
        let actual = match sn { Html => tr!("media.actual.html"), Text => tr!("media.actual.text"), Empty => tr!("media.actual.empty"),
            Jpeg | Png | Gif | Webp | Heif => tr!("media.actual.photoAsVideo"), Mp4 | Mov => tr!("media.actual.videoAsPhoto"), Unknown => tr!("media.actual.unknown") };
        tr!("media.notMedia", want = want, actual = actual)
    }

    /// Streams any reader (a file, a zip entry) into the blob store with constant memory.
    pub fn put_reader(&self, input: &mut dyn std::io::Read, kind: &MediaKind, ext: &str) -> anyhow::Result<(String, String)> {
        self.put_reader_limited(input, kind, ext, u64::MAX, &|| false)
    }

    /// `put_reader` for a source that can inflate on the way (a zip entry): at most `max_bytes`
    /// are written, a stop request (`cancelled`) is honoured after every chunk, and content that
    /// is not the media it claims to be is refused from its first bytes on, before the rest of it
    /// is written. The partial file is always removed again.
    pub fn put_reader_limited(&self, input: &mut dyn std::io::Read, kind: &MediaKind, ext: &str, max_bytes: u64, cancelled: &dyn Fn() -> bool) -> anyhow::Result<(String, String)> {
        let tmp = self.tmp_path();
        let r = (|| -> anyhow::Result<String> {
            let mut out = std::io::BufWriter::with_capacity(1 << 20, fs::File::create(&tmp)?);
            let mut h = Sha256::new();
            let mut buf = vec![0u8; 1 << 20];
            let mut head: Vec<u8> = Vec::new();
            let mut total = 0u64;
            let mut checked = false;
            // Check the content, not the extension (e.g. an HTML error page saved as .jpg).
            let photo = *kind == MediaKind::Photo;
            let check = |head: &[u8]| -> anyhow::Result<()> {
                let sn = crate::rules::sniff(head);
                if !crate::rules::sniff_ok(sn, photo) { anyhow::bail!(NotMedia(Self::not_media_reason(sn, photo))); }
                Ok(())
            };
            loop {
                if cancelled() { anyhow::bail!(tr!("common.cancelled")); }
                let n = input.read(&mut buf)?;
                if n == 0 { break; }
                total += n as u64;
                if total > max_bytes { anyhow::bail!(tr!("library.tooLarge", gb = max_bytes >> 30)); }
                if head.len() < 16 { head.extend_from_slice(&buf[..n.min(16 - head.len())]); }
                if !checked && head.len() >= 16 { check(&head)?; checked = true; }
                h.update(&buf[..n]);
                out.write_all(&buf[..n])?;
            }
            out.into_inner()?.sync_all()?;
            if !checked { check(&head)?; }
            Ok(hex::encode(h.finalize()))
        })();
        match r {
            Ok(sha) => Ok((sha.clone(), self.commit_tmp(&tmp, &sha, ext)?)),
            Err(e) => { let _ = fs::remove_file(&tmp); Err(e) }
        }
    }

    /// Applies one model's labels to a media (see `rules::retag_plan`) and marks it analysed,
    /// atomically. `replace_old` drops unendorsed AI tags the model did not propose again.
    pub fn apply_ai_tags(&self, media_id: &str, model: &str, labels: &[String], replace_old: bool) -> anyhow::Result<()> {
        self.apply_ai_tags_at(self.epoch(), media_id, model, labels, replace_old)
    }

    pub fn apply_ai_tags_at(&self, epoch: u64, media_id: &str, model: &str, labels: &[String], replace_old: bool) -> anyhow::Result<()> {
        let db = self.db_at(epoch)?;
        if db.media_row(media_id)?.is_none() || db.trash_reg(media_id)?.state != crate::rules::LIVE {
            anyhow::bail!(tr!("library.mediaGone"));
        }
        let tx = db.conn().unchecked_transaction()?;
        db.retag(media_id, model, labels, replace_old)?;
        tx.commit()?;
        Ok(())
    }

    /// Tag vectors for a model, cached in memory until they change.
    /// Never holds the cache lock while waiting for the store (wipe takes the store, then the
    /// cache: holding them in the other order here could deadlock with it).
    fn vectors(&self, model: &str) -> anyhow::Result<std::sync::Arc<std::collections::HashMap<String, Vec<f32>>>> {
        if let Some((m, v)) = self.vec_cache.lock().unwrap().as_ref() { if m == model { return Ok(v.clone()); } }
        let (v, epoch) = { let db = self.db(); (std::sync::Arc::new(db.vectors(model)?), self.epoch()) };
        // store it only if no wipe happened meanwhile
        let mut cache = self.vec_cache.lock().unwrap();
        if self.epoch() == epoch { *cache = Some((model.to_string(), v.clone())); }
        Ok(v)
    }

    /// For the lock-order test: whether someone holds the vector cache right now.
    #[doc(hidden)]
    pub fn vector_cache_busy(&self) -> bool { self.vec_cache.try_lock().is_err() }
    #[doc(hidden)]
    pub fn load_vectors_for_test(&self, model: &str) -> usize { self.vectors(model).map_or(0, |v| v.len()) }

    pub fn set_vectors(&self, model: &str, items: &[(String, Vec<f32>)]) -> anyhow::Result<()> {
        self.set_vectors_at(self.epoch(), model, items)
    }

    pub fn set_vectors_at(&self, epoch: u64, model: &str, items: &[(String, Vec<f32>)]) -> anyhow::Result<()> {
        {
            let db = self.db_at(epoch)?;
            let tx = db.conn().unchecked_transaction()?;
            for (l, v) in items { db.set_vector(model, l, v)?; }
            tx.commit()?;
        }
        *self.vec_cache.lock().unwrap() = None;
        Ok(())
    }

    pub fn tag(&self, media_id: &str, label: &str, origin: Origin) -> anyhow::Result<()> {
        Ok(self.db().tag_media(media_id, label, origin)?)
    }

    /// Deletes all local data (metadata, blobs, temp files). Never recorded or synced.
    /// Deletes posts, media, tags and sync state. AI model folders are kept unless
    /// `include_models` (they are large to download again, and hold no library data).
    pub fn wipe(&self, include_models: bool) -> anyhow::Result<()> {
        let db = self.db();
        // from here on, work started before the wipe can no longer write (see `db_at`)
        self.epoch.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        // the models stay: so do their prompts and the external models' settings, freshly recorded
        let kept = if include_models { vec![] } else { db.settings_with_prefix("ai.")? };
        db.wipe()?;
        for (key, value) in kept { db.set_setting(&key, Some(&value))?; }
        // Logical deletion is committed even if optional compaction cannot allocate space.
        let _ = db.conn().execute_batch("VACUUM");
        // after the store: the same order as everywhere else (store, then cache)
        *self.vec_cache.lock().unwrap() = None;
        // import records list source paths and problem files: they are library content too
        let mut dirs = vec![self.dir.join("blobs"), self.dir.join("tmp"), self.dir.join("logs").join("import-reports")];
        if include_models { dirs.push(self.models_dir()); }
        for p in dirs {
            if p.exists() { fs::remove_dir_all(&p)?; }
        }
        fs::create_dir_all(self.dir.join("blobs"))?;
        drop(db);
        Ok(())
    }

    /// Renames (or merges) a tag everywhere, atomically; see `Store::rename_tag`.
    pub fn rename_tag(&self, from: &str, to: &str) -> anyhow::Result<String> {
        let db = self.db();
        let tx = db.conn().unchecked_transaction()?;
        let n = db.rename_tag(from, to)?;
        tx.commit()?;
        drop(db);
        *self.vec_cache.lock().unwrap() = None;
        self.diag("rename_tag", serde_json::json!({ "renames_active": self.db().renames()?.len() }));
        Ok(n)
    }

    pub fn untag(&self, media_id: &str, label: &str) -> anyhow::Result<()> {
        Ok(self.db().untag_media(media_id, label)?)
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_right_copy_heals_a_file_that_went_bad_unnoticed() {
        let d = std::env::temp_dir().join(format!("tl-heal-{}", rand::random::<u64>()));
        let lib = Library::open(&d).unwrap();
        let src = d.join("src.png");
        std::fs::write(&src, b"\x89PNG\r\n\x1a\nsynthetic").unwrap();
        let (sha, rel) = lib.put_file(&src, &MediaKind::Photo, "png").unwrap();
        std::fs::write(d.join(&rel), b"\x89PNG\r\n\x1a\nsynthetiX").unwrap();   // same length
        lib.put_file(&src, &MediaKind::Photo, "png").unwrap();
        assert!(lib.check_file(&sha, &rel).is_none());
        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn a_library_of_an_ancient_format_is_refused_not_rebuilt() {
        let d = std::env::temp_dir().join(format!("tl-old-{}", rand::random::<u64>()));
        std::fs::create_dir_all(d.join("blobs/ab")).unwrap();
        std::fs::write(d.join("blobs/ab/keep"), b"x").unwrap();
        {
            let c = rusqlite::Connection::open(d.join("library.sqlite")).unwrap();
            c.execute_batch("CREATE TABLE post(id TEXT); INSERT INTO post VALUES('mine'); PRAGMA user_version=2;").unwrap();
        }
        assert!(Library::open(&d).is_err());
        assert!(d.join("blobs/ab/keep").exists());
        let c = rusqlite::Connection::open(d.join("library.sqlite")).unwrap();
        assert_eq!(c.query_row("SELECT count(*) FROM post", [], |r| r.get::<_, i64>(0)).unwrap(), 1);
        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn search_ignores_case_in_every_script() {
        let d = std::env::temp_dir().join(format!("tl-case-{}", rand::random::<u64>()));
        let lib = Library::open(&d).unwrap();
        let s: String = lib.db().conn().query_row("SELECT ulower('ÄÉΣA')", [], |r| r.get(0)).unwrap();
        assert_eq!(s, "ÄÉΣA".to_lowercase());
        assert_eq!(s, "äéσa");
        std::fs::remove_dir_all(&d).unwrap();
    }

    use super::*;
    use crate::legacy::SIDECAR_NAME;

    /// A post with four photos, only the second tagged 猫: a search for 猫 shows the whole post
    /// (from its first photo) on a card, but only the tagged photo in the grid.
    #[test]
    fn a_match_on_one_media_finds_the_whole_post() {
        let tmp = std::env::temp_dir().join(format!("tl-whole-{}", rand::random::<u64>()));
        for i in 1..=4 {
            fs::create_dir_all(tmp.join("src/帖子")).unwrap();
            fs::write(tmp.join(format!("src/帖子/{i}.jpg")), crate::testutil::jpg(format!("a{i}").as_bytes())).unwrap();
        }
        fs::create_dir_all(tmp.join("src/别的")).unwrap();
        fs::write(tmp.join("src/别的/1.jpg"), crate::testutil::jpg(b"other")).unwrap();
        let lib = Library::open(tmp.join("lib")).unwrap();
        lib.import_legacy_dir(&tmp.join("src")).unwrap();
        let a2 = hex::encode(Sha256::digest(crate::testutil::jpg(b"a2")));
        lib.db().tag_media(&a2, "猫", crate::model::Origin::USER).unwrap();
        let req = |whole: bool, kind: Option<MediaKind>| FeedRequest { terms: vec!["猫".into()], scope: SearchScope::Both, seed: None, newest_first: false, fuzzy: false,
            term_vectors: vec![], embed_model: None, threshold: 0.5, fields: SearchFields::default(),
            filter: FeedFilter { kind, ..Default::default() }, whole_posts: whole };
        let grid = lib.feed(&req(false, None)).unwrap();
        assert_eq!(grid.iter().map(|i| i.media_id.clone()).collect::<Vec<_>>(), vec![a2.clone()]);
        let mut cards = lib.feed(&req(true, None)).unwrap();
        cards.sort_by_key(|i| i.ordinal);
        assert_eq!(cards.len(), 4, "the whole post, not the other one");
        assert!(cards.iter().all(|i| i.post_id == grid[0].post_id));
        assert_eq!(cards[0].ordinal, grid[0].ordinal - 1, "starts at the post's first photo");
        assert!(lib.feed(&req(true, Some(MediaKind::Video))).unwrap().is_empty(), "media filters still apply");
        // no search: the plain feed, unchanged
        let mut all = req(true, None); all.terms.clear();
        assert_eq!(lib.feed(&all).unwrap().len(), 5);
        let _ = fs::remove_dir_all(&tmp);
    }
    /// A permanent deletion and a restore arriving in the same sync batch: the file of the
    /// (restored) live media must survive the clean-up of the deletion.
    #[test]
    fn deletion_then_restore_in_one_batch_keeps_the_file() {
        use crate::oplog::{LoggedOp, Op};
        let tmp = std::env::temp_dir().join(format!("tl-gc-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(tmp.join("src/帖子")).unwrap();
        fs::write(tmp.join("src/帖子/1.jpg"), crate::testutil::jpg(b"x")).unwrap();
        let lib = Library::open(tmp.join("lib")).unwrap();
        lib.import_legacy_dir(&tmp.join("src")).unwrap();
        let id = hex::encode(Sha256::digest(crate::testutil::jpg(b"x")));
        let op = |dev: &str, inc, state, hlc| LoggedOp { device: dev.into(), seq: 1, op: Op::Trash { media_id: id.clone(), inc, state, hlc } };
        // device d1 deleted it (incarnation 0), device d2 restored it (incarnation 1)
        lib.db().apply_remote(&[op("d1", 0, crate::rules::PURGED, 10 << 16), op("d2", 1, crate::rules::LIVE, 11 << 16)], |_, _| true).unwrap();
        lib.settle().unwrap();
        assert!(lib.dir.join(crate::oplog::blob_rel(&id, "jpg")).exists(), "live media keeps its file");
        assert_eq!(lib.db().stats().unwrap().photos, 1);
        // the other order of arrival ends the same way
        lib.db().apply_remote(&[op("d3", 0, crate::rules::PURGED, 12 << 16)], |_, _| true).unwrap();
        lib.settle().unwrap();
        assert!(lib.dir.join(crate::oplog::blob_rel(&id, "jpg")).exists());
        fs::remove_dir_all(&tmp).unwrap();
    }

    /// The import report explains why library totals can be lower than what was imported:
    /// identical files are stored once and folders of the same post ID merge.
    #[test]
    fn import_report_explains_duplicates() {
        let tmp = std::env::temp_dir().join(format!("tl-dup-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        let src = tmp.join("src");
        for (d, files) in [("A", vec![("1.jpg", "same"), ("2.jpg", "a2")]), ("B", vec![("1.jpg", "same")]), ("C", vec![("1.jpg", "c1"), ("2.jpg", "c1")])] {
            fs::create_dir_all(src.join(d)).unwrap();
            for (n, b) in files { fs::write(src.join(d).join(n), crate::testutil::jpg(b.as_bytes())).unwrap(); }
        }
        // D and E are two folders of the same post (same ID in their sidecars)
        for d in ["D", "E"] {
            fs::create_dir_all(src.join(d)).unwrap();
            fs::write(src.join(d).join("1.jpg"), crate::testutil::jpg(format!("{d}-img").as_bytes())).unwrap();
            fs::write(src.join(d).join(SIDECAR_NAME), "推文 ID: 99\n【推文完整正文】\nx").unwrap();
        }
        let lib = Library::open(tmp.join("lib")).unwrap();
        let r = lib.import_legacy_dir(&src).unwrap();
        assert_eq!((r.posts, r.media), (5, 7), "every folder and file is reported");
        assert_eq!(r.duplicate_media, 2, "B's file equals A's; C has the same file twice");
        assert_eq!(r.merged_posts, 1, "E merged into D's post");
        assert_eq!(r.posts_without_media, 1, "B owns no media of its own");
        let st = lib.db().stats().unwrap();
        assert_eq!(st.photos as usize, r.media - r.duplicate_media);
        assert_eq!(st.posts as usize, r.posts - r.merged_posts - r.posts_without_media);
        fs::remove_dir_all(&tmp).unwrap();
    }

    /// Clearing all data keeps installed AI models unless they are explicitly included.
    #[test]
    fn wipe_keeps_models_unless_asked() {
        let tmp = std::env::temp_dir().join(format!("tl-wipe-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(tmp.join("src/帖子")).unwrap();
        fs::write(tmp.join("src/帖子/1.jpg"), crate::testutil::jpg(b"w")).unwrap();
        let lib = Library::open(tmp.join("lib")).unwrap();
        lib.set_models_dir(tmp.join("models")).unwrap();
        fs::create_dir_all(tmp.join("models/some-model")).unwrap();
        fs::write(tmp.join("models/some-model/config.json"), b"{}").unwrap();
        lib.import_legacy_dir(&tmp.join("src")).unwrap();
        lib.wipe(false).unwrap();
        assert_eq!(lib.db().stats().unwrap().photos, 0, "library data is gone");
        assert!(tmp.join("models/some-model/config.json").exists(), "models are kept by default");
        lib.wipe(true).unwrap();
        assert!(!tmp.join("models").exists(), "and removed when asked");
        fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn import_and_search() {
        let tmp = std::env::temp_dir().join(format!("tl-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        let src = tmp.join("src");
        fs::create_dir_all(src.join("帖子A")).unwrap();
        fs::create_dir_all(src.join("帖子B")).unwrap();
        fs::write(src.join("帖子A/1.jpg"), crate::testutil::jpg(b"a")).unwrap();
        fs::write(src.join("帖子A/2.mp4"), b"\0\0\0\x18ftypisomB").unwrap();
        fs::write(src.join("帖子A/3.mov"), b"c").unwrap();
        fs::write(src.join("帖子B/1.png"), crate::testutil::jpg(b"d")).unwrap();
        fs::write(src.join("帖子B").join(SIDECAR_NAME), "作者: X (@x)\n推文 ID: 42\n【推文完整正文】\nhi").unwrap();
        let lib = Library::open(tmp.join("lib")).unwrap();
        let rep = lib.import_legacy_dir(&src).unwrap();
        assert_eq!((rep.posts, rep.media, rep.skipped.len()), (2, 3, 1));
        // a ".mp4" that is not MP4 is skipped, not imported
        fs::create_dir_all(src.join("帖子C")).unwrap();
        fs::write(src.join("帖子C/fake.mp4"), b"not a video").unwrap();
        let rep2 = lib.import_legacy_dir(&src).unwrap();
        assert!(rep2.skipped.iter().any(|s| s.contains("fake.mp4")));
        let all = lib.feed(&FeedRequest { whole_posts: false, newest_first: false, terms: vec![], scope: SearchScope::Both, seed: Some(1), fuzzy: true, term_vectors: vec![], embed_model: None, threshold: 0.7, fields: Default::default(), filter: Default::default() }).unwrap();
        assert_eq!(all.len(), 3);
        let b = all.iter().find(|i| i.post_id == "42").unwrap();
        assert_eq!(b.text.as_deref(), Some("hi"));
        lib.tag(&b.media_id, "白墙", Origin::AI).unwrap();
        let q = |t: &str, s| lib.feed(&FeedRequest { whole_posts: false, newest_first: false, terms: vec![t.into()], scope: s, seed: Some(0), fuzzy: true, term_vectors: vec![], embed_model: None, threshold: 0.7, fields: Default::default(), filter: Default::default() }).unwrap().len();
        assert_eq!(q("墙", SearchScope::Both), 1);
        assert_eq!(q("墙", SearchScope::Mine), 0);
        assert_eq!(q("墙", SearchScope::Common), 0, "an AI-only tag is not common");
        lib.tag(&b.media_id, "白墙", Origin::USER).unwrap();
        assert_eq!(q("墙", SearchScope::Mine), 1);
        // text / author search
        let f = |t: &str, fields: SearchFields| lib.feed(&FeedRequest { whole_posts: false, newest_first: false, terms: vec![t.into()], scope: SearchScope::Both, seed: Some(0), fuzzy: true, term_vectors: vec![], embed_model: None, threshold: 0.7, fields, filter: Default::default() }).unwrap().len();
        let text = SearchFields { tags: false, text: true, author: false };
        let author = SearchFields { tags: false, text: false, author: true };
        assert_eq!(f("hi", text), 1, "post text");
        assert_eq!(f("帖子a", text), 2, "legacy folder name is the text");
        assert_eq!(f("x", author), 1, "@handle");
        assert_eq!(f("hi", author), 0);
        assert_eq!(f("墙", SearchFields { tags: true, text: true, author: false }), 1, "tag OR text");
        assert_eq!(f("hi", SearchFields::default()), 0, "default is tags only");
        assert_eq!(q("墙", SearchScope::Ai), 1);
        // "common": only where the tag is both mine and the AI's
        assert_eq!(q("墙", SearchScope::Common), 1, "the AI tag I also added is common");
        let exact = lib.feed(&FeedRequest { whole_posts: false, newest_first: false, terms: vec!["墙".into()], scope: SearchScope::Both, seed: Some(0), fuzzy: false, term_vectors: vec![], embed_model: None, threshold: 0.7, fields: Default::default(), filter: Default::default() }).unwrap();
        assert!(!exact.is_empty(), "without fuzzy a term still matches the tags that contain it");
        let none = lib.feed(&FeedRequest { whole_posts: false, newest_first: false, terms: vec!["不存在的词".into()], scope: SearchScope::Both, seed: Some(0), fuzzy: false, term_vectors: vec![], embed_model: None, threshold: 0.7, fields: Default::default(), filter: Default::default() }).unwrap();
        assert!(none.is_empty());
        fs::remove_dir_all(&tmp).unwrap();
    }

    /// Fuzzy search works on tags and post text — for every such condition present, alone or
    /// together — and never on authors; terms combine with AND.
    #[test]
    fn fuzzy_reaches_tags_and_text_but_not_authors() {
        let tmp = std::env::temp_dir().join(format!("tl-fuzzy-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        let src = tmp.join("src");
        for (dir, id, author, text, byte) in [("p1", "1", "小猫咪粉丝 (@fan)", "一只小猫咪在睡觉", b"1"), ("p2", "2", "路人 (@walker)", "今天天气好", b"2"), ("p3", "3", "小猫咪 (@neko)", "睡觉中", b"3")] {
            fs::create_dir_all(src.join(dir)).unwrap();
            fs::write(src.join(dir).join("1.jpg"), crate::testutil::jpg(byte)).unwrap();
            fs::write(src.join(dir).join(SIDECAR_NAME), format!("作者: {author}\n推文 ID: {id}\n【推文完整正文】\n{text}")).unwrap();
        }
        let lib = Library::open(tmp.join("lib")).unwrap();
        lib.import_legacy_dir(&src).unwrap();
        let all = lib.feed(&FeedRequest { whole_posts: false, newest_first: false, terms: vec![], scope: SearchScope::Both, seed: None, fuzzy: true, term_vectors: vec![], embed_model: None, threshold: 0.7, fields: Default::default(), filter: Default::default() }).unwrap();
        let media = |post: &str| all.iter().find(|i| i.post_id == post).unwrap().media_id.clone();
        lib.tag(&media("2"), "小猫咪", Origin::AI).unwrap();
        lib.tag(&media("3"), "风景", Origin::USER).unwrap();
        lib.db().set_vector("m", "小猫咪", &[0.95, 0.1]).unwrap();
        lib.db().set_vector("m", "风景", &[0.0, 1.0]).unwrap();
        // "喵" means 小猫咪 (by vectors), and is written nowhere
        let run = |terms: &[&str], vecs: Vec<Option<Vec<f32>>>, fuzzy: bool, tags: bool, text: bool, author: bool| -> Vec<String> {
            let mut v: Vec<String> = lib.feed(&FeedRequest { whole_posts: false, newest_first: false, terms: terms.iter().map(|t| t.to_string()).collect(), scope: SearchScope::Both, seed: None, fuzzy,
                term_vectors: vecs, embed_model: Some("m".into()), threshold: 0.7, fields: SearchFields { tags, text, author }, filter: Default::default() }).unwrap()
                .into_iter().map(|i| i.post_id).collect();
            v.sort(); v
        };
        let miao = || vec![Some(vec![1.0, 0.0])];
        assert_eq!(run(&["喵"], miao(), true, true, false, false), vec!["2"], "tags alone");
        assert_eq!(run(&["喵"], miao(), true, false, true, false), vec!["1"], "text alone");
        assert_eq!(run(&["喵"], miao(), true, false, false, true), Vec::<String>::new(), "never authors (p1 and p3 have 小猫咪 in the author)");
        assert_eq!(run(&["喵"], miao(), true, true, true, false), vec!["1", "2"], "tags and text together");
        assert_eq!(run(&["喵"], miao(), true, true, false, true), vec!["2"], "with author: only the tag part is fuzzy");
        assert_eq!(run(&["喵"], miao(), true, false, true, true), vec!["1"], "with author: only the text part is fuzzy");
        assert_eq!(run(&["喵"], miao(), false, true, true, true), Vec::<String>::new(), "fuzzy off: literal only");
        assert_eq!(run(&["猫咪"], vec![None], false, false, false, true), vec!["1", "3"], "authors match literally");
        // several terms: each must hold, each fuzzy where it may be
        assert_eq!(run(&["喵", "睡觉"], vec![Some(vec![1.0, 0.0]), None], true, false, true, false), vec!["1"]);
        assert_eq!(run(&["喵", "睡觉"], vec![Some(vec![1.0, 0.0]), None], true, true, true, false), vec!["1"], "p2 has the tag but no 睡觉");
        fs::remove_dir_all(&tmp).unwrap();
    }
}