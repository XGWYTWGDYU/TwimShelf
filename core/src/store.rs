//! SQLite-backed metadata store.
use crate::library::{FeedItem, TagView};
use crate::model::{MediaKind, Origin, PostMeta, SearchScope};
use rusqlite::{params, Connection};

pub struct Store { conn: Connection }

#[derive(Debug, serde::Serialize)]
pub struct TagCount { pub label: String, pub count: i64, pub user: i64, pub ai: i64 }

#[derive(Debug, serde::Serialize)]
pub struct Stats { pub posts: i64, pub photos: i64, pub videos: i64, pub tags: i64, pub pending_jobs: i64, pub failed_jobs: i64,
    /// Media in the recycle bin, and media whose file failed verification.
    pub trashed: i64, pub bad: i64,
    /// Sync records from a newer app version, kept until this device is updated.
    pub newer_ops: i64 }

/// SQL condition: media `m` is live (not in the recycle bin, not deleted).
pub const LIVE_SQL: &str = "NOT EXISTS(SELECT 1 FROM trash x WHERE x.media_id=m.id AND x.state!=0)";

/// One folder on the folders page (`cover_path` is relative to the library until the library
/// resolves it).
#[derive(Debug, serde::Serialize, Clone)]
pub struct FolderOverview { pub name: String, pub count: i64, pub videos: i64, pub cover_id: Option<String>, pub cover_path: Option<String>, pub cover_video: bool }

/// A media in the recycle bin.
#[derive(Debug, serde::Serialize)]
pub struct TrashItem { #[serde(flatten)] pub item: FeedItem, /// When it was moved to the bin (ms since 1970).
    pub trashed_at_ms: u64 }

/// Schema version. Versions from 3 on are migrated in place; anything older, or a newer one
/// (written by a newer app), is refused: a library is never rebuilt from nothing or downgraded.
const VERSION: i64 = 18;

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS post(id TEXT PRIMARY KEY, author_name TEXT, screen_name TEXT, text TEXT, created_at TEXT, url TEXT,
  h_author INTEGER NOT NULL DEFAULT 0, h_screen INTEGER NOT NULL DEFAULT 0, h_text INTEGER NOT NULL DEFAULT 0, h_created INTEGER NOT NULL DEFAULT 0, h_url INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS media(id TEXT PRIMARY KEY, post_id TEXT NOT NULL REFERENCES post(id) ON DELETE CASCADE, ordinal INTEGER, kind TEXT, path TEXT);
CREATE INDEX IF NOT EXISTS media_post ON media(post_id);
-- canon: the tag this label is shown as after rename rules (NULL = itself). Derived locally.
CREATE TABLE IF NOT EXISTS tag(id INTEGER PRIMARY KEY, label TEXT UNIQUE NOT NULL, canon INTEGER);
-- Per (media, tag): origin bits (0 = removed), each bit its own LWW register (h_user, h_ai;
-- crdt::merge_bits); hlc = the later of the two. No FK to media so tags that sync ahead of
-- their media blob are kept.
CREATE TABLE IF NOT EXISTS tag_media(media_id TEXT NOT NULL, tag_id INTEGER NOT NULL REFERENCES tag(id), origin INTEGER NOT NULL, hlc INTEGER NOT NULL DEFAULT 0,
  h_user INTEGER NOT NULL DEFAULT 0, h_ai INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(media_id, tag_id));
CREATE INDEX IF NOT EXISTS tag_media_tag ON tag_media(tag_id);
-- Which AI model proposed a tag: LWW register per (media, tag, model), present 0/1.
CREATE TABLE IF NOT EXISTS tag_src(media_id TEXT NOT NULL, tag_id INTEGER NOT NULL REFERENCES tag(id), model TEXT NOT NULL, present INTEGER NOT NULL, hlc INTEGER NOT NULL, PRIMARY KEY(media_id, tag_id, model));
-- Grow-only set: media analysed by a model (synced, so other devices don't redo the work).
CREATE TABLE IF NOT EXISTS ai_done(media_id TEXT NOT NULL, model TEXT NOT NULL, PRIMARY KEY(media_id, model));
CREATE TABLE IF NOT EXISTS tag_vec(label TEXT NOT NULL, model TEXT NOT NULL, vec BLOB NOT NULL, PRIMARY KEY(label, model));
CREATE TABLE IF NOT EXISTS job(url TEXT PRIMARY KEY, status TEXT NOT NULL, error TEXT, updated INTEGER);
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS op(device TEXT NOT NULL, seq INTEGER NOT NULL, body TEXT NOT NULL, PRIMARY KEY(device, seq));
-- Every (post, ordinal) a media has been claimed by, from any device (grow-only, derived from
-- the Media records). The owner shown is the smallest claim whose post is known here.
CREATE TABLE IF NOT EXISTS media_claim(media_id TEXT NOT NULL, post_id TEXT NOT NULL, ordinal INTEGER NOT NULL, PRIMARY KEY(media_id, post_id, ordinal));
CREATE TABLE IF NOT EXISTS want_blob(media_id TEXT PRIMARY KEY, post_id TEXT NOT NULL, ordinal INTEGER NOT NULL, kind TEXT NOT NULL, ext TEXT NOT NULL);
-- Recycle bin: one register per media (rules::merge_trash). Absent = live, incarnation 0. Synced.
CREATE TABLE IF NOT EXISTS trash(media_id TEXT PRIMARY KEY, inc INTEGER NOT NULL, state INTEGER NOT NULL, hlc INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS trash_state ON trash(state);
-- Local only: permanently deleted media whose file still has to be removed from disk.
CREATE TABLE IF NOT EXISTS gc(media_id TEXT PRIMARY KEY);
-- Local only: media whose file failed verification ('missing', 'hash', 'decode').
-- Width and height of a media as displayed, from its file (0×0: the file says nothing). Local.
CREATE TABLE IF NOT EXISTS media_size(media_id TEXT PRIMARY KEY, w INTEGER NOT NULL, h INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS verified_media(media_id TEXT PRIMARY KEY, path TEXT NOT NULL, checked_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS bad_media(media_id TEXT PRIMARY KEY, reason TEXT NOT NULL, at INTEGER NOT NULL);
-- Rename rules: 「label src is now called dst」 (dst NULL = rule removed). LWW register, synced.
-- Tag registers keep their original labels; every read goes through the rules (view tag_c).
CREATE TABLE IF NOT EXISTS tag_alias(src TEXT PRIMARY KEY, dst TEXT, hlc INTEGER NOT NULL);
-- Folders, identified by name: an LWW register (deleted 0/1) and one LWW membership register
-- per (folder, media). Synced.
CREATE TABLE IF NOT EXISTS folder(name TEXT PRIMARY KEY, deleted INTEGER NOT NULL, hlc INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS folder_media(folder TEXT NOT NULL, media_id TEXT NOT NULL, present INTEGER NOT NULL, hlc INTEGER NOT NULL, PRIMARY KEY(folder, media_id));
CREATE INDEX IF NOT EXISTS folder_media_media ON folder_media(media_id);
-- Recently added (最近添加): when a post was batch-downloaded (ms). Grow-only register; expiry is computed.
CREATE TABLE IF NOT EXISTS recent(post_id TEXT PRIMARY KEY, at INTEGER NOT NULL);
-- Media brought in through a share extension as media (从相册导入). Grow-only, synced.
CREATE TABLE IF NOT EXISTS album(media_id TEXT PRIMARY KEY);
-- Settings shared by every device (the AI prompt…): LWW register (hlc, value), NULL = default. Synced.
CREATE TABLE IF NOT EXISTS setting(key TEXT PRIMARY KEY, value TEXT, hlc INTEGER NOT NULL);
-- AI analysis attempts that failed ON THIS DEVICE, per (media, model). LOCAL ONLY: never in the
-- op log, never synced, so another device can still analyse the media (and its result syncs
-- back as ai_done). An attempt is counted before the model runs, so an app crash during the
-- analysis counts too; after MAX_AI_ATTEMPTS this device skips the media (listed in settings).
CREATE TABLE IF NOT EXISTS ai_fail(media_id TEXT NOT NULL, model TEXT NOT NULL, attempts INTEGER NOT NULL, reason TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY(media_id, model));
-- Records from a newer app version: stored in op (passed on to peers), applied after an update.
CREATE TABLE IF NOT EXISTS op_pending(device TEXT NOT NULL, seq INTEGER NOT NULL, PRIMARY KEY(device, seq));
";

/// SQL condition: media `m` is in folder ?N (live membership in a live folder).
fn in_folder_sql(k: usize) -> String {
    format!("EXISTS(SELECT 1 FROM folder_media fm JOIN folder f ON f.name=fm.folder WHERE fm.media_id=m.id AND fm.present=1 AND f.deleted=0 AND fm.folder=?{k})")
}

/// raw tag id → canonical (id, label) after rename rules.
const TAG_VIEW: &str = "CREATE VIEW IF NOT EXISTS tag_c AS SELECT r.id AS raw_id, c.id AS id, c.label AS label FROM tag r JOIN tag c ON c.id = coalesce(r.canon, r.id);";


/// A media row needing AI work.
#[derive(Debug, serde::Serialize)]
pub struct MediaRef {
    pub media_id: String,
    pub path: String,
    pub kind: String,
    /// The post's text (context for AI tagging; author fields are deliberately not included).
    pub text: Option<String>,
}

/// A media this device could not analyse (`Store::ai_failures`).
#[derive(Debug, serde::Serialize)]
pub struct AiFailure { pub media_id: String, pub model: String, pub attempts: i64, pub reason: String, pub at: i64 }

impl Store {
    pub fn open(path: &str) -> rusqlite::Result<Store> {
        Ok(Self::open_reporting(path)?.0)
    }

    /// Opens the store; the flag is true when an older schema was discarded.
    ///
    /// The whole migration is one transaction, `user_version` included: interrupted at any
    /// point it leaves the old version, and every step checks the schema before changing it,
    /// so running it again is always safe.
    pub fn open_reporting(path: &str) -> rusqlite::Result<(Store, bool)> {
        let conn = Connection::open(path)?;
        // FULL: a committed transaction survives a power loss (not only an app crash)
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")?;
        // lower() of SQLite knows ASCII only; terms are lowercased by Rust, for every script
        conn.create_scalar_function("ulower", 1, rusqlite::functions::FunctionFlags::SQLITE_UTF8 | rusqlite::functions::FunctionFlags::SQLITE_DETERMINISTIC, |c| {
            Ok(c.get_raw(0).as_str().map(|t| t.to_lowercase()).unwrap_or_default())
        })?;
        let version: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        let existed = conn.query_row("SELECT count(*) FROM sqlite_master WHERE type='table'", [], |r| r.get::<_, i64>(0))? > 0;
        if existed && version > VERSION {
            return Err(rusqlite::Error::SqliteFailure(rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CANTOPEN),
                Some(tr!("store.newer", version = version, VERSION = VERSION))));
        }
        // A format from before any release, or a damaged version number: never rebuilt from nothing,
        // which would delete the library. It stays as it is, and the person is told.
        if existed && version < 3 {
            return Err(rusqlite::Error::SqliteFailure(rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CANTOPEN),
                Some(tr!("store.tooOld", version = version))));
        }
        // up to date: opening writes nothing (a full disk must not keep the library from opening)
        if existed && version == VERSION { return Ok((Store { conn }, false)); }
        let has = |table: &str, col: &str| -> rusqlite::Result<bool> {
            conn.prepare(&format!("SELECT 1 FROM pragma_table_info('{table}') WHERE name=?1"))?.exists([col])
        };
        conn.execute_batch("BEGIN IMMEDIATE;")?;
        let r: rusqlite::Result<()> = (|| {
            // v3 → v4: per-field clocks on posts
            let post_exists: bool = conn.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='post'")?.exists([])?;
            if post_exists {
                for c in ["h_author", "h_screen", "h_text", "h_created", "h_url"] {
                    if !has("post", c)? { conn.execute_batch(&format!("ALTER TABLE post ADD COLUMN {c} INTEGER NOT NULL DEFAULT 0;"))?; }
                }
            }
            // v4 → v5 and later new tables
            conn.execute_batch(SCHEMA)?;
            // v5 → v6: rename rules and the derived canonical column
            if !has("tag", "canon")? { conn.execute_batch("ALTER TABLE tag ADD COLUMN canon INTEGER;")?; }
            // v8 → v9: per-link download options and a request counter
            if !has("job", "opts")? { conn.execute_batch("ALTER TABLE job ADD COLUMN opts TEXT;")?; }
            if !has("job", "epoch")? { conn.execute_batch("ALTER TABLE job ADD COLUMN epoch INTEGER NOT NULL DEFAULT 0;")?; }
            // v9 → v10: one clock per tag origin bit (both start at the register's clock)
            if !has("tag_media", "h_user")? {
                conn.execute_batch("ALTER TABLE tag_media ADD COLUMN h_user INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE tag_media ADD COLUMN h_ai INTEGER NOT NULL DEFAULT 0;
                    UPDATE tag_media SET h_user=hlc, h_ai=hlc;")?;
            }
            // v10 → v11: every claim of a media, rebuilt from the full history of Media records
            // (before, only the smallest pending claim was kept, and a claim whose post had not
            // arrived yet could be lost: devices then disagreed on the owner)
            if existed && version < 11 {
                conn.execute_batch("INSERT OR IGNORE INTO media_claim SELECT json_extract(body,'$.id'), json_extract(body,'$.post_id'), json_extract(body,'$.ordinal')
                        FROM op WHERE json_extract(body,'$.t')='media' AND json_extract(body,'$.id') IS NOT NULL AND json_extract(body,'$.post_id') IS NOT NULL;
                    INSERT OR IGNORE INTO media_claim SELECT id, post_id, ordinal FROM media;
                    INSERT OR IGNORE INTO media_claim SELECT media_id, post_id, ordinal FROM want_blob;
                    UPDATE media SET (post_id, ordinal) = (SELECT c.post_id, c.ordinal FROM media_claim c JOIN post p ON p.id=c.post_id
                        WHERE c.media_id=media.id ORDER BY c.post_id, c.ordinal LIMIT 1)
                      WHERE EXISTS(SELECT 1 FROM media_claim c JOIN post p ON p.id=c.post_id WHERE c.media_id=media.id);")?;
            }
            // v14 → v15: triage mode is gone; its decisions were local to this device (never in
            // the op log), so the table simply goes. A step of the ladder like the others: a
            // library from any older version passes it once, however many versions it skips.
            conn.execute_batch("DROP TABLE IF EXISTS triage;")?;
            // v15 → v16: every post that arrives looks up its claims by post
            conn.execute_batch("CREATE INDEX IF NOT EXISTS media_claim_post ON media_claim(post_id, media_id);")?;
            conn.execute_batch(TAG_VIEW)?;
            conn.execute_batch(&format!("PRAGMA user_version={VERSION};"))?;
            Ok(())
        })();
        match r {
            Ok(()) => conn.execute_batch("COMMIT;")?,
            Err(e) => { let _ = conn.execute_batch("ROLLBACK;"); return Err(e); }
        }
        Ok((Store { conn }, false))
    }

    /// Local import/download of a post: present fields are written with a fresh clock, so the
    /// latest import wins on every device; absent fields never erase anything.
    pub fn upsert_post(&self, p: &PostMeta) -> rusqlite::Result<()> { self.upsert_post_checked(p, |_, _| false) }

    /// `upsert_post`, and the media that name this post as a claimed owner follow it at once (see
    /// `post_arrived`); `blob_exists` tells whether an awaited file is already on disk.
    pub fn upsert_post_checked(&self, p: &PostMeta, blob_exists: impl Fn(&str, &str) -> bool) -> rusqlite::Result<()> { self.atomic(|| {
        // a record that cannot be sent in one sync frame would block every later one: limits
        // are applied here whatever the source (importers report what they cut)
        let (p, _) = p.clamped();
        let hlc = self.next_hlc()?;
        self.apply_post(&p, hlc)?;
        self.record(&crate::oplog::Op::Post { meta: p.clone(), hlc })?;
        self.post_arrived(&p.id, &blob_exists)
    }) }

    /// Applies post metadata with the per-field LWW rule (`rules::merge_field`).
    pub(crate) fn apply_post(&self, p: &PostMeta, hlc: u64) -> rusqlite::Result<()> {
        use rusqlite::OptionalExtension;
        type F = Option<(u64, String)>;
        let cur: Option<[F; 5]> = self.conn.query_row(
            "SELECT author_name, h_author, screen_name, h_screen, text, h_text, created_at, h_created, url, h_url FROM post WHERE id=?1", [&p.id],
            |r| {
                let f = |v: usize, h: usize| -> rusqlite::Result<F> { Ok(r.get::<_, Option<String>>(v)?.map(|s| (r.get::<_, i64>(h).unwrap_or(0) as u64, s))) };
                Ok([f(0, 1)?, f(2, 3)?, f(4, 5)?, f(6, 7)?, f(8, 9)?])
            }).optional()?;
        // an empty value is no value: a newer "" (an empty 作者: line, an empty field in a package)
        // must not replace a real one. Normalized the same way on every device, so merges still agree.
        let incoming: [F; 5] = [&p.author_name, &p.screen_name, &p.text, &p.created_at, &p.url]
            .map(|v| v.clone().filter(|s| !s.trim().is_empty()).map(|s| (hlc, s)));
        let base: [F; 5] = cur.unwrap_or_default();
        let m: Vec<F> = base.into_iter().zip(incoming).map(|(a, b)| crate::rules::merge_field(a, b)).collect();
        let v = |i: usize| m[i].as_ref().map(|x| x.1.clone());
        let h = |i: usize| m[i].as_ref().map_or(0, |x| x.0 as i64);
        self.conn.execute("INSERT INTO post(id, author_name, h_author, screen_name, h_screen, text, h_text, created_at, h_created, url, h_url)
            VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11) ON CONFLICT(id) DO UPDATE SET
            author_name=excluded.author_name, h_author=excluded.h_author, screen_name=excluded.screen_name, h_screen=excluded.h_screen,
            text=excluded.text, h_text=excluded.h_text, created_at=excluded.created_at, h_created=excluded.h_created, url=excluded.url, h_url=excluded.h_url",
            params![p.id, v(0), h(0), v(1), h(1), v(2), h(2), v(3), h(3), v(4), h(4)])?;
        Ok(())
    }

    fn tag_reg(&self, media_id: &str, label: &str) -> rusqlite::Result<Option<crate::crdt::TagBits>> {
        use rusqlite::OptionalExtension;
        self.conn.query_row("SELECT tm.origin, tm.h_user, tm.h_ai FROM tag_media tm JOIN tag t ON t.id=tm.tag_id WHERE tm.media_id=?1 AND t.label=?2",
            params![media_id, label], |r| Ok(crate::crdt::TagBits { origin: r.get(0)?, h_user: r.get::<_, i64>(1)? as u64, h_ai: r.get::<_, i64>(2)? as u64 })).optional()
    }

    /// Writes a register value unconditionally (callers have already merged).
    fn put_tag_reg(&self, media_id: &str, label: &str, reg: crate::crdt::TagBits) -> rusqlite::Result<()> {
        self.ensure_tag(label)?;
        self.conn.execute("INSERT INTO tag_media(media_id, tag_id, origin, hlc, h_user, h_ai) SELECT ?1, id, ?3, ?4, ?5, ?6 FROM tag WHERE label=?2
            ON CONFLICT DO UPDATE SET origin=excluded.origin, hlc=excluded.hlc, h_user=excluded.h_user, h_ai=excluded.h_ai",
            params![media_id, label, reg.origin, reg.hlc() as i64, reg.h_user as i64, reg.h_ai as i64])?;
        Ok(())
    }

    /// The name a label is shown as after rename rules (the label itself when not renamed).
    pub fn canonical(&self, label: &str) -> rusqlite::Result<String> {
        use rusqlite::OptionalExtension;
        let l = label.trim().to_lowercase();
        Ok(self.conn.query_row("SELECT c.label FROM tag_c c JOIN tag r ON r.id=c.raw_id WHERE r.label=?1", [&l], |r| r.get(0)).optional()?
            .or(self.conn.query_row("SELECT dst FROM tag_alias WHERE src=?1 AND dst IS NOT NULL", [&l], |r| r.get(0)).optional()?)
            .unwrap_or(l))
    }

    /// Raw labels on a media that are shown as `canon`, with their registers.
    fn raws_of(&self, media_id: &str, canon: &str) -> rusqlite::Result<Vec<(String, u8)>> {
        let mut st = self.conn.prepare_cached("SELECT r.label, tm.origin FROM tag_media tm JOIN tag_c c ON c.raw_id=tm.tag_id JOIN tag r ON r.id=tm.tag_id WHERE tm.media_id=?1 AND c.label=?2")?;
        let v = st.query_map(params![media_id, canon], |r| Ok((r.get(0)?, r.get(1)?)))?.collect();
        v
    }

    /// Effective origin of a (renamed) tag on a media: the OR of every raw label shown as it.
    fn eff_origin(&self, media_id: &str, canon: &str) -> rusqlite::Result<u8> {
        Ok(self.raws_of(media_id, canon)?.iter().fold(0, |a, (_, o)| a | o) & 3)
    }

    /// Sets the origin bits of one raw label. Only the bits that change are written (so a
    /// concurrent change of the other bit on another device is kept); a removal writes both.
    fn write_raw(&self, media_id: &str, label: &str, origin: u8) -> rusqlite::Result<()> {
        let existing = self.tag_reg(media_id, label)?;
        let cur = existing.map_or(0, |r| r.origin);
        if cur == origin && (origin != 0 || existing.is_some()) { return Ok(()); }
        let mask = if origin == 0 || cur ^ origin == 0 { 3 } else { cur ^ origin };
        let hlc = self.next_hlc()?;
        let reg = crate::crdt::merge_bits(existing.unwrap_or_default(), crate::crdt::TagBits::write(origin, mask, hlc));
        self.put_tag_reg(media_id, label, reg)?;
        self.record(&crate::oplog::Op::Tag { media_id: media_id.into(), label: label.into(), origin, mask, hlc })
    }

    /// Sets the effective origin of a tag on a media exactly: written under the current name,
    /// and the old (renamed) labels of the same tag on this media are cleared.
    fn set_effective(&self, media_id: &str, canon: &str, origin: u8) -> rusqlite::Result<()> {
        for (raw, o) in self.raws_of(media_id, canon)? { if raw != canon && o != 0 { self.write_raw(media_id, &raw, 0)?; } }
        let cur = self.tag_reg(media_id, canon)?.map_or(0, |r| r.origin);
        if cur != origin { self.write_raw(media_id, canon, origin)?; }
        Ok(())
    }

    /// Adds a tag locally (under its current name); existing origins are OR-ed, so a USER add on
    /// an AI tag endorses it.
    pub fn tag_media(&self, media_id: &str, label: &str, origin: Origin) -> rusqlite::Result<()> { self.atomic(|| {
        let label = self.canonical(label)?;
        if label.is_empty() { return Ok(()); }
        let cur = self.eff_origin(media_id, &label)?;
        let new = crate::crdt::add_origin(cur, origin.0);
        if new == cur { return Ok(()); }
        self.set_effective(media_id, &label, new)
    }) }

    /// Removes a tag locally by writing tombstones (origin 0), for its current and old names.
    pub fn untag_media(&self, media_id: &str, label: &str) -> rusqlite::Result<()> { self.atomic(|| {
        let label = self.canonical(label)?;
        if self.eff_origin(media_id, &label)? == 0 { return Ok(()); }
        for (raw, o) in self.raws_of(media_id, &label)? { if o != 0 { self.write_raw(media_id, &raw, 0)?; } }
        Ok(())
    }) }

    /// Removes a tag (under every name it had) from every media carrying it, as one change.
    /// Each removal is an ordinary untag, so it syncs. Returns how many media lost the tag.
    pub fn delete_label(&self, label: &str) -> rusqlite::Result<usize> { self.atomic(|| {
        let canon = self.canonical(label)?;
        if canon.is_empty() { return Ok(0); }
        let ids: Vec<String> = {
            let mut st = self.conn.prepare("SELECT DISTINCT tm.media_id FROM tag_media tm JOIN tag_c t ON t.raw_id=tm.tag_id WHERE t.label=?1 AND tm.origin!=0")?;
            let v = st.query_map([&canon], |r| r.get(0))?.collect::<Result<_, _>>()?;
            v
        };
        for id in &ids { self.untag_media(id, &canon)?; }
        Ok(ids.len())
    }) }

    /// Removes what the AI added, everywhere: the AI bit of every tag (an AI-only tag goes, one
    /// I endorsed stays as mine) and every record of which model proposed it. All are ordinary
    /// writes, so they sync. What the AI has analysed stays recorded, so it does not tag the same
    /// media again by itself. Returns how many tags lost their AI part.
    pub fn remove_ai_tags(&self) -> rusqlite::Result<usize> { self.atomic(|| {
        let rows: Vec<(String, String, u8)> = {
            let mut st = self.conn.prepare("SELECT tm.media_id, r.label, tm.origin FROM tag_media tm JOIN tag r ON r.id=tm.tag_id WHERE (tm.origin & 2)!=0")?;
            let v = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect::<Result<_, _>>()?;
            v
        };
        for (m, raw, o) in &rows { self.write_raw(m, raw, o & 1)?; }
        let sources: Vec<(String, String, String)> = {
            let mut st = self.conn.prepare("SELECT s.media_id, r.label, s.model FROM tag_src s JOIN tag r ON r.id=s.tag_id WHERE s.present=1")?;
            let v = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect::<Result<_, _>>()?;
            v
        };
        for (m, raw, model) in &sources { self.set_raw_source(m, raw, model, false)?; }
        Ok(rows.len())
    }) }

    /// Applies a remote tag write with the LWW merge rule.
    pub(crate) fn apply_tag(&self, media_id: &str, label: &str, incoming: crate::crdt::TagBits) -> rusqlite::Result<()> {
        let cur = self.tag_reg(media_id, label)?;
        let merged = crate::crdt::merge_bits(cur.unwrap_or_default(), incoming);
        if Some(merged) != cur { self.put_tag_reg(media_id, label, merged)?; }
        Ok(())
    }

    // ---------- tag provenance (which model proposed a tag) ----------

    fn tag_id(&self, label: &str) -> rusqlite::Result<i64> {
        self.ensure_tag(label)?;
        self.conn.query_row("SELECT id FROM tag WHERE label=?1", [label], |r| r.get(0))
    }

    /// Inserts a label if new; a new label that a rename rule mentions gets its canonical name.
    pub(crate) fn ensure_tag(&self, label: &str) -> rusqlite::Result<()> {
        if self.conn.execute("INSERT OR IGNORE INTO tag(label) VALUES(?1)", [label])? > 0 {
            let ruled: bool = self.conn.prepare_cached("SELECT 1 FROM tag_alias WHERE (src=?1 OR dst=?1) AND dst IS NOT NULL")?.exists([label])?;
            if ruled { self.recompute_canon()?; }
        }
        Ok(())
    }

    // ---------- tag renaming ----------

    /// Recomputes every label's canonical tag from the rename rules (`rules::resolve_alias`).
    /// A pure function of the rules, so every device derives the same names.
    fn recompute_canon(&self) -> rusqlite::Result<()> {
        let rules: Vec<(String, String)> = {
            let mut st = self.conn.prepare("SELECT src, dst FROM tag_alias WHERE dst IS NOT NULL")?;
            let v = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_, _>>()?;
            v
        };
        for (a, b) in &rules { for l in [a, b] { self.conn.execute("INSERT OR IGNORE INTO tag(label) VALUES(?1)", [l])?; } }
        let tags: Vec<(i64, String, Option<i64>)> = {
            let mut st = self.conn.prepare("SELECT id, label, canon FROM tag ORDER BY label")?;
            let v = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect::<Result<_, _>>()?;
            v
        };
        // indices in label order, so "smallest member of a cycle" means the same label everywhere
        let idx: std::collections::HashMap<&str, usize> = tags.iter().enumerate().map(|(i, t)| (t.1.as_str(), i)).collect();
        let mut next: Vec<Option<usize>> = vec![None; tags.len()];
        for (a, b) in &rules { if let (Some(&i), Some(&j)) = (idx.get(a.as_str()), idx.get(b.as_str())) { next[i] = Some(j); } }
        for (i, (id, _, canon)) in tags.iter().enumerate() {
            let c = tags[crate::rules::resolve_alias(i, &next)].0;
            let want = (c != *id).then_some(c);
            if want != *canon { self.conn.execute("UPDATE tag SET canon=?2 WHERE id=?1", params![id, want])?; }
        }
        Ok(())
    }

    /// A rename rule from a backup ("`old` is shown as `shown`"), applied only where this library
    /// has no say of its own about `old`: no rule for it, and no rule the user removed. It points
    /// `old` at whatever `shown` is shown as now and never changes any other rule (a plain
    /// rename would clear a later rule of `shown`, e.g. the user's newer `shown → c`).
    pub fn restore_rename(&self, old: &str, shown: &str) -> rusqlite::Result<bool> { self.atomic(|| {
        let old = old.trim().to_lowercase();
        let shown = shown.trim().to_lowercase();
        if old.is_empty() || shown.is_empty() || self.alias_reg(&old)?.is_some() || self.canonical(&old)? != old { return Ok(false); }
        let target = self.canonical(&shown)?;
        if target == old { return Ok(false); }
        self.ensure_tag(&old)?;
        self.ensure_tag(&target)?;
        self.set_alias(&old, Some(&target))?;
        self.recompute_canon()?;
        Ok(true)
    }) }

    fn alias_reg(&self, src: &str) -> rusqlite::Result<Option<(u64, Option<String>)>> {
        use rusqlite::OptionalExtension;
        self.conn.query_row("SELECT hlc, dst FROM tag_alias WHERE src=?1", [src], |r| Ok((r.get::<_, i64>(0)? as u64, r.get(1)?))).optional()
    }

    fn put_alias(&self, src: &str, reg: (u64, Option<String>)) -> rusqlite::Result<()> {
        self.conn.execute("INSERT INTO tag_alias VALUES(?1,?2,?3) ON CONFLICT(src) DO UPDATE SET dst=excluded.dst, hlc=excluded.hlc",
            params![src, reg.1, reg.0 as i64])?;
        Ok(())
    }

    fn set_alias(&self, src: &str, dst: Option<&str>) -> rusqlite::Result<()> {
        let reg = (self.next_hlc()?, dst.map(|d| d.to_string()));
        self.put_alias(src, reg.clone())?;
        self.record(&crate::oplog::Op::Alias { src: src.into(), dst: reg.1, hlc: reg.0 })
    }

    pub(crate) fn apply_alias(&self, src: &str, incoming: (u64, Option<String>)) -> rusqlite::Result<()> {
        let cur = self.alias_reg(src)?;
        let merged = match cur.clone() { Some(c) => crate::rules::merge_alias(c, incoming), None => incoming };
        if Some(&merged) != cur.as_ref() { self.put_alias(src, merged)?; self.recompute_canon()?; }
        Ok(())
    }

    /// Renames a tag everywhere (also merges it into an existing tag of that name). Implemented as
    /// synced rename rules: tags written later under the old name — by an AI tagging run on this
    /// or another device, or arriving from a peer — are shown under the new name too, and the
    /// rename can be undone because no tag record is rewritten. Returns the new name.
    pub fn rename_tag(&self, from: &str, to: &str) -> rusqlite::Result<String> { self.atomic(|| {
        let from = self.canonical(from)?;
        let to = to.trim().to_lowercase();
        if to.is_empty() || to == from { return Ok(from); }
        self.ensure_tag(&to)?;
        // every label currently shown as `from` now points at `to`
        let raws: Vec<String> = {
            let mut st = self.conn.prepare("SELECT r.label FROM tag r JOIN tag_c c ON c.raw_id=r.id WHERE c.label=?1")?;
            let v = st.query_map([&from], |r| r.get(0))?.collect::<Result<_, _>>()?;
            v
        };
        for r in raws.iter().filter(|r| **r != to) { self.set_alias(r, Some(&to))?; }
        // and `to` itself is a name of its own (renaming back simply reverses the earlier rule)
        if self.alias_reg(&to)?.map_or(false, |r| r.1.is_some()) { self.set_alias(&to, None)?; }
        self.recompute_canon()?;
        Ok(to)
    }) }

    /// Active rename rules (old name, current name), for listing and undo.
    pub fn renames(&self) -> rusqlite::Result<Vec<(String, String)>> {
        let mut st = self.conn.prepare("SELECT a.src, c.label FROM tag_alias a JOIN tag r ON r.label=a.src JOIN tag_c c ON c.raw_id=r.id WHERE a.dst IS NOT NULL AND c.label != a.src ORDER BY c.label, a.src")?;
        let v = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?.collect();
        v
    }

    /// Undoes a rename: the old name is shown on its own again.
    pub fn undo_rename(&self, old: &str) -> rusqlite::Result<()> { self.atomic(|| {
        let old = old.trim().to_lowercase();
        if self.alias_reg(&old)?.map_or(false, |r| r.1.is_some()) { self.set_alias(&old, None)?; self.recompute_canon()?; }
        Ok(())
    }) }

    fn src_reg(&self, media_id: &str, tag_id: i64, model: &str) -> rusqlite::Result<Option<crate::crdt::TagReg>> {
        use rusqlite::OptionalExtension;
        self.conn.query_row("SELECT present, hlc FROM tag_src WHERE media_id=?1 AND tag_id=?2 AND model=?3", params![media_id, tag_id, model],
            |r| Ok(crate::crdt::TagReg { origin: r.get(0)?, hlc: r.get::<_, i64>(1)? as u64 })).optional()
    }

    fn put_src_reg(&self, media_id: &str, tag_id: i64, model: &str, reg: crate::crdt::TagReg) -> rusqlite::Result<()> {
        self.conn.execute("INSERT INTO tag_src VALUES(?1,?2,?3,?4,?5) ON CONFLICT DO UPDATE SET present=excluded.present, hlc=excluded.hlc",
            params![media_id, tag_id, model, reg.origin, reg.hlc as i64])?;
        Ok(())
    }

    /// Records locally that `model` does (or no longer does) propose `label` for a media.
    /// Clearing also clears the old (renamed) names of the same tag.
    pub fn set_tag_source(&self, media_id: &str, label: &str, model: &str, present: bool) -> rusqlite::Result<()> { self.atomic(|| {
        let label = self.canonical(label)?;
        if !present {
            let olds: Vec<String> = {
                let mut st = self.conn.prepare_cached("SELECT r.label FROM tag_src s JOIN tag_c c ON c.raw_id=s.tag_id JOIN tag r ON r.id=s.tag_id WHERE s.media_id=?1 AND c.label=?2 AND s.model=?3 AND s.present=1 AND r.label!=?2")?;
                let v = st.query_map(params![media_id, &label, model], |r| r.get(0))?.collect::<Result<_, _>>()?;
                v
            };
            for o in olds { self.set_raw_source(media_id, &o, model, false)?; }
        }
        self.set_raw_source(media_id, &label, model, present)
    }) }

    fn set_raw_source(&self, media_id: &str, label: &str, model: &str, present: bool) -> rusqlite::Result<()> {
        let label = label.to_string();
        let tid = self.tag_id(&label)?;
        let cur = self.src_reg(media_id, tid, model)?.map_or(0, |r| r.origin);
        if cur == present as u8 { return Ok(()); }
        let reg = crate::crdt::TagReg { origin: present as u8, hlc: self.next_hlc()? };
        self.put_src_reg(media_id, tid, model, reg)?;
        self.record(&crate::oplog::Op::TagSrc { media_id: media_id.into(), label, model: model.into(), present, hlc: reg.hlc })
    }

    pub(crate) fn apply_tag_source(&self, media_id: &str, label: &str, model: &str, incoming: crate::crdt::TagReg) -> rusqlite::Result<()> {
        let tid = self.tag_id(label)?;
        let cur = self.src_reg(media_id, tid, model)?;
        let merged = cur.map_or(incoming, |c| crate::crdt::merge_tag(c, incoming));
        if Some(merged) != cur { self.put_src_reg(media_id, tid, model, merged)?; }
        Ok(())
    }

    /// Models currently recorded as sources of a media's label.
    pub fn tag_sources(&self, media_id: &str, label: &str) -> rusqlite::Result<Vec<String>> {
        let label = self.canonical(label)?;
        let mut st = self.conn.prepare_cached("SELECT DISTINCT s.model FROM tag_src s JOIN tag_c t ON t.raw_id=s.tag_id WHERE s.media_id=?1 AND t.label=?2 AND s.present=1 ORDER BY s.model")?;
        let v = st.query_map(params![media_id, label], |r| r.get(0))?.collect();
        v
    }

    /// Marks a media as analysed by a model (grow-only, synced).
    pub fn mark_ai_done(&self, media_id: &str, model: &str) -> rusqlite::Result<()> { self.atomic(|| {
        if self.conn.execute("INSERT OR IGNORE INTO ai_done VALUES(?1,?2)", params![media_id, model])? > 0 {
            self.record(&crate::oplog::Op::AiDone { media_id: media_id.into(), model: model.into() })?;
        }
        // analysed: earlier failed attempts on this device no longer matter
        self.conn.execute("DELETE FROM ai_fail WHERE media_id=?1", [media_id])?;
        Ok(())
    }) }

    pub(crate) fn apply_ai_done(&self, media_id: &str, model: &str) -> rusqlite::Result<()> {
        self.conn.execute("INSERT OR IGNORE INTO ai_done VALUES(?1,?2)", params![media_id, model]).map(|_| ())
    }

    /// Tags of one media as (current name, effective origin) for rule evaluation (0 = removed).
    pub fn media_tags(&self, media_id: &str) -> rusqlite::Result<Vec<(String, u8)>> {
        let mut st = self.conn.prepare_cached("SELECT t.label, max(tm.origin & 1) | max(tm.origin & 2) FROM tag_media tm JOIN tag_c t ON t.raw_id=tm.tag_id WHERE tm.media_id=?1 GROUP BY t.id ORDER BY t.label")?;
        let v = st.query_map([media_id], |r| Ok((r.get(0)?, r.get(1)?)))?.collect();
        v
    }

    /// Writes an origin chosen by a rule (not OR-merged), under the tag's current name.
    fn set_origin(&self, media_id: &str, label: &str, origin: u8) -> rusqlite::Result<()> {
        if self.eff_origin(media_id, label)? == origin { return Ok(()); }
        self.set_effective(media_id, label, origin)
    }

    /// Re-tags one media with `model`'s labels following `rules::retag_plan`, atomically
    /// (callers hold the store lock; wrap in a transaction).
    pub fn retag(&self, media_id: &str, model: &str, labels: &[String], replace_old: bool) -> rusqlite::Result<()> { self.atomic(|| {
        let mut names: Vec<String> = vec![];
        for l in labels.iter().map(|l| l.trim().to_lowercase()).filter(|l| !l.is_empty() && l.chars().count() <= 24) {
            let c = self.canonical(&l)?;   // a model answering with an old name gets the new one
            if !names.contains(&c) { names.push(c); }
        }
        let labels = names;
        let existing = self.media_tags(media_id)?;
        for c in crate::rules::retag_plan(&existing, &labels, replace_old) {
            if let Some(o) = c.origin { self.set_origin(media_id, &c.label, o)?; }
            if c.model_source == Some(true) { self.set_tag_source(media_id, &c.label, model, true)?; }
            if c.clear_sources {
                for m in self.tag_sources(media_id, &c.label)? { self.set_tag_source(media_id, &c.label, &m, false)?; }
            }
        }
        self.mark_ai_done(media_id, model)
    }) }

    /// Records a locally imported/downloaded file as media of a post. A media that is in the
    /// recycle bin or was deleted is left alone (Ok(false)) unless `revive` (the user explicitly
    /// asked for this post again), which restores it — even after a permanent deletion.
    pub fn add_media(&self, id: &str, post_id: &str, ordinal: i64, kind: &MediaKind, path: &str, revive: bool) -> rusqlite::Result<bool> { self.atomic(|| {
        if self.trash_reg(id)?.state != crate::rules::LIVE {
            if !revive { return Ok(false); }
            self.trash_action(id, crate::rules::TrashAction::Reimport)?;
        }
        // Log every new claim (a file seen in another post too), not only new files, so all
        // devices see the same set of claims and pick the same owner.
        let new_claim = !self.conn.prepare_cached("SELECT 1 FROM media_claim WHERE media_id=?1 AND post_id=?2 AND ordinal=?3")?.exists(params![id, post_id, ordinal])?;
        self.apply_media(id, post_id, ordinal, kind, path)?;
        if new_claim {
            let ext = path.rsplit('.').next().unwrap_or("bin").to_string();
            self.record(&crate::oplog::Op::Media { id: id.into(), post_id: post_id.into(), ordinal, kind: kind.clone(), ext })?;
        }
        Ok(true)
    }) }

    // ---------- recycle bin ----------

    pub fn trash_reg(&self, media_id: &str) -> rusqlite::Result<crate::rules::TrashReg> {
        use rusqlite::OptionalExtension;
        Ok(self.conn.query_row("SELECT inc, state, hlc FROM trash WHERE media_id=?1", [media_id],
            |r| Ok(crate::rules::TrashReg { inc: r.get::<_, i64>(0)? as u32, state: r.get(1)?, hlc: r.get::<_, i64>(2)? as u64 })).optional()?.unwrap_or_default())
    }

    fn put_trash(&self, media_id: &str, r: crate::rules::TrashReg, prev: crate::rules::TrashReg) -> rusqlite::Result<()> {
        self.conn.execute("INSERT INTO trash VALUES(?1,?2,?3,?4) ON CONFLICT(media_id) DO UPDATE SET inc=excluded.inc, state=excluded.state, hlc=excluded.hlc",
            params![media_id, r.inc as i64, r.state, r.hlc as i64])?;
        // Entering the deleted state schedules the file for removal on this device.
        if r.state == crate::rules::PURGED && prev.state != crate::rules::PURGED {
            self.conn.execute("INSERT OR IGNORE INTO gc VALUES(?1)", [media_id])?;
        }
        Ok(())
    }

    /// Applies a local recycle-bin action (see `rules::trash_step`); false when it does not apply.
    pub fn trash_action(&self, media_id: &str, a: crate::rules::TrashAction) -> rusqlite::Result<bool> { self.atomic(|| {
        let cur = self.trash_reg(media_id)?;
        let Some(next) = crate::rules::trash_step(cur, a, self.next_hlc()?) else { return Ok(false) };
        self.put_trash(media_id, next, cur)?;
        self.record(&crate::oplog::Op::Trash { media_id: media_id.into(), inc: next.inc, state: next.state, hlc: next.hlc })?;
        Ok(true)
    }) }

    pub(crate) fn apply_trash(&self, media_id: &str, incoming: crate::rules::TrashReg) -> rusqlite::Result<()> {
        let cur = self.trash_reg(media_id)?;
        let m = crate::rules::merge_trash(cur, incoming);
        if m != cur { self.put_trash(media_id, m, cur)?; }
        Ok(())
    }

    /// Live media of a post (what "delete post" moves to the bin).
    pub fn live_media_of_post(&self, post_id: &str) -> rusqlite::Result<Vec<String>> {
        let mut st = self.conn.prepare(&format!("SELECT m.id FROM media m WHERE m.post_id=?1 AND {LIVE_SQL} ORDER BY m.ordinal"))?;
        let v = st.query_map([post_id], |r| r.get(0))?.collect();
        v
    }

    /// Media of a post still awaited from another device (not in the bin): deleting the post
    /// deletes them too, so they do not appear later as a "revived" post.
    pub fn pending_media_of_post(&self, post_id: &str) -> rusqlite::Result<Vec<String>> {
        let mut st = self.conn.prepare("SELECT w.media_id FROM want_blob w WHERE EXISTS(SELECT 1 FROM media_claim c WHERE c.media_id=w.media_id AND c.post_id=?1) AND NOT EXISTS(SELECT 1 FROM trash x WHERE x.media_id=w.media_id AND x.state>0) ORDER BY w.ordinal")?;
        let v = st.query_map([post_id], |r| r.get(0))?.collect();
        v
    }

    /// Media in the bin (state Trashed), newest first. Only media whose file is on this device.
    pub fn trash_items(&self) -> rusqlite::Result<Vec<TrashItem>> {
        let sql = "SELECT m.id, m.post_id, m.ordinal, m.kind, m.path, p.text, p.author_name, p.screen_name, p.url, p.created_at FROM media m JOIN post p ON p.id=m.post_id JOIN trash x ON x.media_id=m.id WHERE x.state=1 ORDER BY x.hlc DESC";
        let items = self.query_items(sql, &[])?;
        let mut out = Vec::with_capacity(items.len());
        for it in items {
            let r = self.trash_reg(&it.media_id)?;
            out.push(TrashItem { item: it, trashed_at_ms: r.hlc >> 16 });
        }
        Ok(out)
    }

    /// Every media currently in the bin (including ones whose file has not arrived here yet).
    pub fn trashed_ids(&self) -> rusqlite::Result<Vec<(String, crate::rules::TrashReg)>> {
        let mut st = self.conn.prepare("SELECT media_id, inc, state, hlc FROM trash WHERE state=1")?;
        let v = st.query_map([], |r| Ok((r.get(0)?, crate::rules::TrashReg { inc: r.get::<_, i64>(1)? as u32, state: r.get(2)?, hlc: r.get::<_, i64>(3)? as u64 })))?.collect();
        v
    }

    /// Deleted media whose file removal is pending, with the blob path (from the media row, or
    /// from the awaited-file record when the media was never shown here).
    pub fn gc_pending(&self) -> rusqlite::Result<Vec<(String, Option<String>)>> {
        let mut st = self.conn.prepare("SELECT g.media_id, m.path, w.ext FROM gc g LEFT JOIN media m ON m.id=g.media_id LEFT JOIN want_blob w ON w.media_id=g.media_id")?;
        let rows: Vec<(String, Option<String>, Option<String>)> = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect::<Result<_, _>>()?;
        // a media that was never shown here (its post had not arrived) has no row, but its file may
        // be on disk under the name it would have: that is the file to remove
        Ok(rows.into_iter().map(|(id, path, ext)| { let p = path.or_else(|| ext.map(|e| crate::oplog::blob_rel(&id, &e))); (id, p) }).collect())
    }

    /// After the file of a deleted media was removed: its claim moves back to `want_blob` (so a
    /// later restore on another device can fetch it again; the purge filter keeps it unrequested).
    pub fn gc_done(&self, media_id: &str) -> rusqlite::Result<()> {
        if self.trash_reg(media_id)?.state == crate::rules::PURGED {
            self.conn.execute("INSERT OR REPLACE INTO want_blob SELECT id, post_id, ordinal, kind, substr(path, length(rtrim(path, replace(path, '.', ''))) + 1) FROM media WHERE id=?1", [media_id])?;
            self.conn.execute("DELETE FROM media WHERE id=?1", [media_id])?;
            self.conn.execute("DELETE FROM bad_media WHERE media_id=?1", [media_id])?;
        }
        self.conn.execute("DELETE FROM gc WHERE media_id=?1", [media_id])?;
        Ok(())
    }

    // ---------- folders ----------

    pub(crate) fn folder_reg(&self, name: &str) -> rusqlite::Result<Option<crate::crdt::TagReg>> {
        use rusqlite::OptionalExtension;
        self.conn.query_row("SELECT deleted, hlc FROM folder WHERE name=?1", [name], |r| Ok(crate::crdt::TagReg { origin: r.get(0)?, hlc: r.get::<_, i64>(1)? as u64 })).optional()
    }
    fn put_folder(&self, name: &str, r: crate::crdt::TagReg) -> rusqlite::Result<()> {
        self.conn.execute("INSERT INTO folder VALUES(?1,?2,?3) ON CONFLICT(name) DO UPDATE SET deleted=excluded.deleted, hlc=excluded.hlc", params![name, r.origin, r.hlc as i64])?;
        Ok(())
    }
    pub(crate) fn member_reg(&self, folder: &str, media_id: &str) -> rusqlite::Result<Option<crate::crdt::TagReg>> {
        use rusqlite::OptionalExtension;
        self.conn.query_row("SELECT present, hlc FROM folder_media WHERE folder=?1 AND media_id=?2", [folder, media_id],
            |r| Ok(crate::crdt::TagReg { origin: r.get(0)?, hlc: r.get::<_, i64>(1)? as u64 })).optional()
    }
    fn put_member(&self, folder: &str, media_id: &str, r: crate::crdt::TagReg) -> rusqlite::Result<()> {
        self.conn.execute("INSERT INTO folder_media VALUES(?1,?2,?3,?4) ON CONFLICT(folder, media_id) DO UPDATE SET present=excluded.present, hlc=excluded.hlc",
            params![folder, media_id, r.origin, r.hlc as i64])?;
        Ok(())
    }

    fn norm_folder(name: &str) -> String { name.trim().to_string() }

    /// Creates a folder (or brings back a deleted one, empty).
    pub fn create_folder(&self, name: &str) -> rusqlite::Result<String> { self.atomic(|| {
        let name = Self::norm_folder(name);
        if name.is_empty() { return Ok(name); }
        if self.folder_reg(&name)?.map_or(true, |r| r.origin != 0) {
            let r = crate::crdt::TagReg { origin: 0, hlc: self.next_hlc()? };
            self.put_folder(&name, r)?;
            self.record(&crate::oplog::Op::Folder { name: name.clone(), deleted: false, hlc: r.hlc })?;
        }
        Ok(name)
    }) }

    /// Deletes a folder (its media stay in the library). Its memberships are cleared, so a
    /// folder of the same name created later starts empty.
    pub fn delete_folder(&self, name: &str) -> rusqlite::Result<()> { self.atomic(|| {
        let name = Self::norm_folder(name);
        let members: Vec<String> = {
            let mut st = self.conn.prepare("SELECT media_id FROM folder_media WHERE folder=?1 AND present=1")?;
            let v = st.query_map([&name], |r| r.get(0))?.collect::<Result<_, _>>()?;
            v
        };
        for m in members { self.set_member(&name, &m, false)?; }
        let r = crate::crdt::TagReg { origin: 1, hlc: self.next_hlc()? };
        self.put_folder(&name, r)?;
        self.record(&crate::oplog::Op::Folder { name, deleted: true, hlc: r.hlc })
    }) }

    /// Renames a folder: its media go into `new` (created if needed, merged if it exists) and
    /// `old` is deleted, in one transaction. A folder is identified by its name in sync, so on
    /// other devices this arrives as those same ordinary folder records. Returns the media moved.
    pub fn rename_folder(&self, old: &str, new: &str) -> rusqlite::Result<usize> { self.atomic(|| {
        let (old, new) = (Self::norm_folder(old), Self::norm_folder(new));
        if old.is_empty() || new.is_empty() || old == new { return Ok(0); }
        let members: Vec<String> = {
            let mut st = self.conn.prepare("SELECT media_id FROM folder_media WHERE folder=?1 AND present=1")?;
            let v = st.query_map([&old], |r| r.get(0))?.collect::<Result<_, _>>()?;
            v
        };
        let new = self.create_folder(&new)?;
        let mut n = 0;
        for m in &members { if self.set_member(&new, m, true)? { n += 1; } }
        self.delete_folder(&old)?;
        Ok(n)
    }) }

    fn set_member(&self, folder: &str, media_id: &str, present: bool) -> rusqlite::Result<bool> {
        if self.member_reg(folder, media_id)?.map_or(0, |r| r.origin) == present as u8 { return Ok(false); }
        let r = crate::crdt::TagReg { origin: present as u8, hlc: self.next_hlc()? };
        self.put_member(folder, media_id, r)?;
        self.record(&crate::oplog::Op::FolderMedia { folder: folder.into(), media_id: media_id.into(), present, hlc: r.hlc })?;
        Ok(true)
    }

    /// Adds media to a folder (created if needed); returns how many were newly added.
    pub fn add_to_folder(&self, name: &str, media: &[String]) -> rusqlite::Result<usize> { self.atomic(|| {
        let name = self.create_folder(name)?;
        if name.is_empty() { return Ok(0); }
        let mut n = 0;
        for m in media { if self.set_member(&name, m, true)? { n += 1; } }
        Ok(n)
    }) }

    pub fn remove_from_folder(&self, name: &str, media: &[String]) -> rusqlite::Result<usize> { self.atomic(|| {
        let name = Self::norm_folder(name);
        let mut n = 0;
        for m in media { if self.set_member(&name, m, false)? { n += 1; } }
        Ok(n)
    }) }

    /// Puts every live media of these posts into a folder (imports and downloads into a folder:
    /// also media of those posts that were already in the library; `rules::import_folder_member`).
    /// Media of a post that another device recorded and whose file has not arrived yet go in too:
    /// it is the whole post that is meant, and they belong to the folder when they appear.
    pub fn add_posts_to_folder(&self, name: &str, posts: &[String]) -> rusqlite::Result<usize> { self.atomic(|| {
        self.add_to_folder(name, &self.action_ids(&[], posts)?)
    }) }

    pub(crate) fn apply_folder(&self, name: &str, incoming: crate::crdt::TagReg) -> rusqlite::Result<()> {
        let cur = self.folder_reg(name)?;
        let m = cur.map_or(incoming, |c| crate::crdt::merge_tag(c, incoming));
        if Some(m) != cur { self.put_folder(name, m)?; }
        Ok(())
    }
    pub(crate) fn apply_member(&self, folder: &str, media_id: &str, incoming: crate::crdt::TagReg) -> rusqlite::Result<()> {
        let cur = self.member_reg(folder, media_id)?;
        let m = cur.map_or(incoming, |c| crate::crdt::merge_tag(c, incoming));
        if Some(m) != cur { self.put_member(folder, media_id, m)?; }
        Ok(())
    }

    /// Live folders with how many live media each holds.
    pub fn folders(&self) -> rusqlite::Result<Vec<(String, i64)>> {
        let mut st = self.conn.prepare(&format!("SELECT f.name, (SELECT count(*) FROM folder_media fm JOIN media m ON m.id=fm.media_id WHERE fm.folder=f.name AND fm.present=1 AND {LIVE_SQL}) FROM folder f WHERE f.deleted=0 ORDER BY f.name"))?;
        let v = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?.collect();
        v
    }

    /// The folders page: every live folder with its live media count, how many are videos, and
    /// a cover (the media put in most recently whose file is here: id, path, kind).
    pub fn folder_overview(&self) -> rusqlite::Result<Vec<FolderOverview>> {
        let mut st = self.conn.prepare(&format!("SELECT f.name,
            (SELECT count(*) FROM folder_media fm JOIN media m ON m.id=fm.media_id WHERE fm.folder=f.name AND fm.present=1 AND {LIVE_SQL}),
            (SELECT count(*) FROM folder_media fm JOIN media m ON m.id=fm.media_id WHERE fm.folder=f.name AND fm.present=1 AND m.kind='video' AND {LIVE_SQL}),
            (SELECT m.id || char(9) || m.kind || char(9) || m.path FROM folder_media fm JOIN media m ON m.id=fm.media_id
               WHERE fm.folder=f.name AND fm.present=1 AND {LIVE_SQL} AND NOT EXISTS(SELECT 1 FROM want_blob w WHERE w.media_id=m.id)
               ORDER BY fm.hlc DESC LIMIT 1)
            FROM folder f WHERE f.deleted=0 ORDER BY f.name"))?;
        let v = st.query_map([], |r| {
            let cover: Option<String> = r.get(3)?;
            let cover = cover.and_then(|c| { let mut p = c.splitn(3, '\t'); Some((p.next()?.to_string(), p.next()?.to_string(), p.next()?.to_string())) });
            Ok(FolderOverview { name: r.get(0)?, count: r.get(1)?, videos: r.get(2)?,
                cover_id: cover.as_ref().map(|c| c.0.clone()), cover_video: cover.as_ref().map_or(false, |c| c.1 == "video"), cover_path: cover.map(|c| c.2) })
        })?.collect();
        v
    }

    /// Live media counts by kind (the folders page's media types).
    pub fn kind_counts(&self) -> rusqlite::Result<(i64, i64)> {
        self.conn.query_row(&format!("SELECT coalesce(sum(m.kind!='video'),0), coalesce(sum(m.kind='video'),0) FROM media m WHERE {LIVE_SQL}"), [], |r| Ok((r.get(0)?, r.get(1)?)))
    }

    /// Live folders a media is in.
    pub fn folders_of(&self, media_id: &str) -> rusqlite::Result<Vec<String>> {
        let mut st = self.conn.prepare_cached("SELECT fm.folder FROM folder_media fm JOIN folder f ON f.name=fm.folder WHERE fm.media_id=?1 AND fm.present=1 AND f.deleted=0 ORDER BY fm.folder")?;
        let v = st.query_map([media_id], |r| r.get(0))?.collect();
        v
    }

    // ---------- verification ----------

    /// Media whose size has not been read yet: (id, path, kind).
    pub fn media_without_size(&self, limit: usize) -> rusqlite::Result<Vec<(String, String, String)>> {
        let mut st = self.conn.prepare_cached("SELECT m.id, m.path, m.kind FROM media m WHERE NOT EXISTS(SELECT 1 FROM media_size s WHERE s.media_id=m.id) LIMIT ?1")?;
        let rows = st.query_map([limit as i64], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        rows.collect()
    }

    pub fn set_media_sizes(&self, sizes: &[(&str, u32, u32)]) -> rusqlite::Result<()> {
        self.atomic(|| {
            let mut st = self.conn.prepare_cached("INSERT OR REPLACE INTO media_size(media_id, w, h) VALUES(?1, ?2, ?3)")?;
            for (id, w, h) in sizes { st.execute(rusqlite::params![id, w, h])?; }
            Ok(())
        })
    }

    /// The sizes that are known (never 0×0).
    pub fn media_sizes(&self) -> rusqlite::Result<std::collections::HashMap<String, (u32, u32)>> {
        let mut st = self.conn.prepare_cached("SELECT media_id, w, h FROM media_size WHERE w>0 AND h>0")?;
        let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, (r.get(1)?, r.get(2)?))))?;
        rows.collect()
    }

    pub fn set_bad(&self, media_id: &str, reason: Option<&str>) -> rusqlite::Result<()> {
        match reason {
            Some(r) => self.conn.execute("INSERT OR REPLACE INTO bad_media VALUES(?1,?2,unixepoch())", params![media_id, r])?,
            None => self.conn.execute("DELETE FROM bad_media WHERE media_id=?1", [media_id])?,
        };
        Ok(())
    }

    /// What this device lacks, as part of working out what to ask peers for: a media whose file
    /// is gone (deleted by hand, a cleaning tool) is marked `missing`, which `wanted_blobs` asks
    /// peers for; one whose file came back is unmarked. Nothing is sent to peers: a missing file
    /// is not a deletion, so the others never lose theirs. Returns how many were newly missing.
    pub fn note_missing_files(&self, exists: impl Fn(&str) -> bool) -> rusqlite::Result<usize> {
        let rows: Vec<(String, String, Option<String>)> = {
            let mut st = self.conn.prepare("SELECT m.id, m.path, b.reason FROM media m LEFT JOIN bad_media b ON b.media_id=m.id WHERE m.path IS NOT NULL AND NOT EXISTS(SELECT 1 FROM trash x WHERE x.media_id=m.id AND x.state=2)")?;
            let v = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect::<Result<_, _>>()?;
            v
        };
        let mut newly = 0;
        self.atomic(|| {
            for (id, path, reason) in &rows {
                let there = exists(path);
                match (there, reason.as_deref()) {
                    (false, Some("missing")) | (true, None) => {}
                    (false, _) => { self.set_bad(id, Some("missing"))?; newly += 1; }
                    (true, Some("missing")) => self.set_bad(id, None)?,
                    (true, Some(_)) => {}
                }
            }
            Ok(())
        })?;
        Ok(newly)
    }

    pub fn bad_reason(&self, media_id: &str) -> rusqlite::Result<Option<String>> {
        use rusqlite::OptionalExtension;
        self.conn.query_row("SELECT reason FROM bad_media WHERE media_id=?1", [media_id], |r| r.get(0)).optional()
    }

    /// Live media rows (id, relative path), for verification.
    pub fn live_media_paths(&self) -> rusqlite::Result<Vec<(String, String)>> {
        let mut st = self.conn.prepare(&format!("SELECT m.id, m.path FROM media m WHERE {LIVE_SQL} ORDER BY m.rowid"))?;
        let v = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?.collect();
        v
    }

    /// One media row: (post id, ordinal, kind, relative path).
    pub fn media_row(&self, media_id: &str) -> rusqlite::Result<Option<(String, i64, String, String)>> {
        use rusqlite::OptionalExtension;
        self.conn.query_row("SELECT post_id, ordinal, kind, path FROM media WHERE id=?1", [media_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))).optional()
    }

    pub fn post_meta(&self, post_id: &str) -> rusqlite::Result<Option<PostMeta>> {
        use rusqlite::OptionalExtension;
        self.conn.query_row("SELECT id, author_name, screen_name, text, created_at, url FROM post WHERE id=?1", [post_id],
            |r| Ok(PostMeta { id: r.get(0)?, author_name: r.get(1)?, screen_name: r.get(2)?, text: r.get(3)?, created_at: r.get(4)?, url: r.get(5)? })).optional()
    }

    /// Inserts a media row; returns whether it was new.
    /// Records a claim (`post_id`, `ordinal`) of a stored file and makes the media row show the
    /// owner: the smallest claim whose post is known (`rules::merge_owner` over every claim).
    /// Returns whether the media row is new.
    pub(crate) fn apply_media(&self, id: &str, post_id: &str, ordinal: i64, kind: &MediaKind, path: &str) -> rusqlite::Result<bool> {
        let k = match kind { MediaKind::Photo => "photo", MediaKind::Video => "video" };
        use rusqlite::OptionalExtension;
        self.add_claim(id, post_id, ordinal)?;
        let owner = self.known_owner(id)?.unwrap_or((post_id.to_string(), ordinal));
        let cur: Option<(String, i64)> = self.conn.query_row("SELECT post_id, ordinal FROM media WHERE id=?1", [id], |r| Ok((r.get(0)?, r.get(1)?))).optional()?;
        match cur {
            None => {
                self.conn.execute("DELETE FROM verified_media WHERE media_id=?1", [id])?;
                self.conn.execute("INSERT INTO media VALUES(?1,?2,?3,?4,?5)", params![id, owner.0, owner.1, k, path])?;
                self.conn.execute("DELETE FROM want_blob WHERE media_id=?1", [id])?;
                Ok(true)
            }
            Some(c) => {
                if owner != c { self.conn.execute("UPDATE media SET post_id=?2, ordinal=?3 WHERE id=?1", params![id, owner.0, owner.1])?; }
                Ok(false)
            }
        }
    }

    pub(crate) fn add_claim(&self, id: &str, post_id: &str, ordinal: i64) -> rusqlite::Result<()> {
        self.conn.prepare_cached("INSERT OR IGNORE INTO media_claim VALUES(?1,?2,?3)")?.execute(params![id, post_id, ordinal]).map(|_| ())
    }

    /// The owner of a media: the smallest of its claims whose post is known here.
    pub(crate) fn known_owner(&self, id: &str) -> rusqlite::Result<Option<(String, i64)>> {
        let mut st = self.conn.prepare_cached("SELECT c.post_id, c.ordinal FROM media_claim c JOIN post p ON p.id=c.post_id WHERE c.media_id=?1")?;
        let claims: Vec<(String, i64)> = st.query_map([id], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_, _>>()?;
        Ok(claims.into_iter().reduce(crate::rules::merge_owner))
    }

    /// Re-derives the owner shown for a stored media (after a claim's post arrived).
    pub(crate) fn refresh_owner(&self, id: &str) -> rusqlite::Result<()> {
        if let Some(o) = self.known_owner(id)? {
            self.conn.execute("UPDATE media SET post_id=?2, ordinal=?3 WHERE id=?1 AND (post_id, ordinal) IS NOT (?2, ?3)", params![id, o.0, o.1])?;
        }
        Ok(())
    }

    /// Media where every term matches in at least one enabled field: a tag from its label set
    /// (within `scope`), the post text, or the author's name / @handle (substring).
    pub fn feed_items_with(&self, label_sets: &[Vec<String>], terms: &[String], scope: SearchScope, fields: crate::library::SearchFields) -> rusqlite::Result<Vec<FeedItem>> {
        self.feed_filtered(label_sets, terms, scope, fields, &crate::library::FeedFilter::default())
    }

    /// The feed query: search terms plus the extra filters (author, exact tags, review state,
    /// damaged files). Only live media (never the recycle bin).
    pub fn feed_filtered(&self, label_sets: &[Vec<String>], terms: &[String], scope: SearchScope, fields: crate::library::SearchFields, f: &crate::library::FeedFilter) -> rusqlite::Result<Vec<FeedItem>> {
        // which tag origins count (1 = mine, 2 = AI; "common" needs both bits), or exactly the
        // origins the search allows (`rules::origins_for`)
        let origin_ok = match &f.origins {
            Some(set) => {
                let v: Vec<String> = set.iter().filter(|o| (1..=3).contains(*o)).map(|o| o.to_string()).collect();
                if v.is_empty() { "0".to_string() } else { format!("(tm.origin & 3) IN ({})", v.join(",")) }
            }
            None => match scope { SearchScope::Mine => "(tm.origin & 1)!=0", SearchScope::Ai => "(tm.origin & 2)!=0", SearchScope::Both => "(tm.origin & 3)!=0", SearchScope::Common => "(tm.origin & 3)=3" }.to_string(),
        };
        let mut sql = format!("SELECT m.id, m.post_id, m.ordinal, m.kind, m.path, p.text, p.author_name, p.screen_name, p.url, p.created_at FROM media m JOIN post p ON p.id=m.post_id WHERE {LIVE_SQL}");
        let mut args: Vec<String> = vec![];
        if let Some(a) = f.author.as_ref().map(|a| a.trim().trim_start_matches('@').to_lowercase()).filter(|a| !a.is_empty()) {
            args.push(a);
            let k = args.len();
            sql += &format!(" AND (ulower(coalesce(p.screen_name,''))=?{k} OR (p.screen_name IS NULL AND ulower(coalesce(p.author_name,''))=?{k}))");
        }
        for l in &f.labels {
            args.push(l.trim().to_lowercase());
            sql += &format!(" AND EXISTS(SELECT 1 FROM (SELECT raw.media_id, c.label, max(raw.origin & 1) | max(raw.origin & 2) AS origin FROM tag_media raw JOIN tag_c c ON c.raw_id=raw.tag_id GROUP BY raw.media_id, c.id) tm JOIN tag t ON t.label=tm.label WHERE tm.media_id=m.id AND {origin_ok} AND t.label=?{})", args.len());
        }
        match f.review {
            crate::rules::Review::Any => {}
            crate::rules::Review::Unreviewed => sql += " AND NOT EXISTS(SELECT 1 FROM tag_media tm WHERE tm.media_id=m.id AND (tm.origin & 1)!=0)",
            crate::rules::Review::Reviewed => sql += " AND EXISTS(SELECT 1 FROM tag_media tm WHERE tm.media_id=m.id AND (tm.origin & 1)!=0)",
        }
        if f.bad_only { sql += " AND EXISTS(SELECT 1 FROM bad_media b WHERE b.media_id=m.id)"; }
        if f.loose_only { sql += " AND m.post_id LIKE 'loose:%'"; }
        if f.exclude_loose { sql += " AND m.post_id NOT LIKE 'loose:%'"; }
        if f.album_only { sql += " AND m.id IN (SELECT media_id FROM album)"; }
        if f.recent_only { sql += " AND m.post_id IN (SELECT post_id FROM recent)"; }
        match f.kind { Some(MediaKind::Video) => sql += " AND m.kind='video'", Some(MediaKind::Photo) => sql += " AND m.kind!='video'", None => {} }
        if let Some(name) = f.folder.as_ref().filter(|n| !n.is_empty()) {
            args.push(name.clone());
            sql += &format!(" AND {}", in_folder_sql(args.len()));
        }
        for name in f.exclude_folders.iter().filter(|n| !n.is_empty()) {
            args.push(name.clone());
            sql += &format!(" AND NOT {}", in_folder_sql(args.len()));
        }
        let fields = if !fields.text && !fields.author { crate::library::SearchFields { tags: true, text: false, author: false } } else { fields };
        // words with a minus: the media must not contain any of them in a searched field
        // ("contains" only: tags that contain the word, the text, the author)
        let excluded: Vec<String> = f.exclude_terms.iter().map(|t| t.trim().to_lowercase()).filter(|t| !t.is_empty()).collect();
        let labels = if excluded.is_empty() || !fields.tags { vec![] } else { self.all_labels()? };
        for term in &excluded {
            let mut parts: Vec<String> = vec![];
            if fields.tags {
                let set: Vec<&String> = labels.iter().filter(|l| l.contains(term.as_str())).collect();
                if !set.is_empty() {
                    let ph: Vec<String> = set.iter().map(|l| { args.push((*l).clone()); format!("?{}", args.len()) }).collect();
                    parts.push(format!("EXISTS(SELECT 1 FROM (SELECT raw.media_id, c.label, max(raw.origin & 1) | max(raw.origin & 2) AS origin FROM tag_media raw JOIN tag_c c ON c.raw_id=raw.tag_id GROUP BY raw.media_id, c.id) tm JOIN tag t ON t.label=tm.label WHERE tm.media_id=m.id AND {origin_ok} AND t.label IN ({}))", ph.join(",")));
                }
            }
            if fields.text || fields.author {
                args.push(term.clone());
                let k = args.len();
                if fields.text { parts.push(format!("instr(ulower(coalesce(p.text,'')), ?{k})>0")); }
                if fields.author { parts.push(format!("(instr(ulower(coalesce(p.author_name,'')), ?{k})>0 OR instr(ulower(coalesce(p.screen_name,'')), ?{k})>0)")); }
            }
            if !parts.is_empty() { sql += &format!(" AND NOT ({})", parts.join(" OR ")); }
        }
        for (i, term) in terms.iter().enumerate() {
            let mut parts: Vec<String> = vec![];
            if fields.tags {
                if let Some(set) = label_sets.get(i).filter(|s| !s.is_empty()) {
                    let ph: Vec<String> = set.iter().map(|l| { args.push(l.clone()); format!("?{}", args.len()) }).collect();
                    parts.push(format!("EXISTS(SELECT 1 FROM (SELECT raw.media_id, c.label, max(raw.origin & 1) | max(raw.origin & 2) AS origin FROM tag_media raw JOIN tag_c c ON c.raw_id=raw.tag_id GROUP BY raw.media_id, c.id) tm JOIN tag t ON t.label=tm.label WHERE tm.media_id=m.id AND {origin_ok} AND t.label IN ({}))", ph.join(",")));
                }
            }
            if !fields.text && !fields.author {
                // tags only: a term without matching labels matches nothing
                if parts.is_empty() { return Ok(vec![]); }
                sql += &format!(" AND ({})", parts.join(" OR "));
                continue;
            }
            args.push(term.clone());
            let k = args.len();
            if fields.text {
                parts.push(format!("instr(ulower(coalesce(p.text,'')), ?{k})>0"));
                // fuzzy search reaches the post text too: words close in meaning to the term (the
                // labels it expanded to) count as well. Never for authors or folders. (Labels that
                // contain the term add nothing: the term itself already matches there.)
                for l in label_sets.get(i).into_iter().flatten().filter(|l| !l.contains(term.as_str())).take(32) {
                    args.push(l.clone());
                    parts.push(format!("instr(ulower(coalesce(p.text,'')), ?{})>0", args.len()));
                }
            }
            if fields.author { parts.push(format!("(instr(ulower(coalesce(p.author_name,'')), ?{k})>0 OR instr(ulower(coalesce(p.screen_name,'')), ?{k})>0)")); }
            sql += &format!(" AND ({})", parts.join(" OR "));
        }
        let mut items = self.query_items(&sql, &args)?;
        // the window is decided by the verified rule, not by SQL arithmetic
        if f.recent_only { items.retain(|i| i.recent); }
        if f.exclude_recent { items.retain(|i| !i.recent); }
        Ok(items)
    }

    /// Each post's place in the order things were added to this library: its newest media's row.
    pub fn posts_added(&self) -> rusqlite::Result<std::collections::HashMap<String, i64>> {
        let mut st = self.conn.prepare_cached("SELECT post_id, max(rowid) FROM media GROUP BY post_id")?;
        let v = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?.collect();
        v
    }

    /// Labels a search term can match: only tags that are on at least one media in the library
    /// (a tag whose media are all gone no longer exists for the user).
    pub fn all_labels(&self) -> rusqlite::Result<Vec<String>> {
        let mut st = self.conn.prepare_cached(&format!("SELECT DISTINCT t.label FROM tag_c t JOIN tag_media tm ON tm.tag_id=t.raw_id JOIN media m ON m.id=tm.media_id WHERE tm.origin != 0 AND {LIVE_SQL}"))?;
        let v = st.query_map([], |r| r.get(0))?.collect();
        v
    }

    pub fn labels_missing_vectors(&self, model: &str) -> rusqlite::Result<Vec<String>> {
        let mut st = self.conn.prepare(&format!("SELECT DISTINCT t.label FROM tag_c t JOIN tag_media tm ON tm.tag_id=t.raw_id JOIN media m ON m.id=tm.media_id WHERE tm.origin != 0 AND {LIVE_SQL} AND t.label NOT IN (SELECT label FROM tag_vec WHERE model=?1)"))?;
        let v = st.query_map([model], |r| r.get(0))?.collect();
        v
    }

    pub fn set_vector(&self, model: &str, label: &str, v: &[f32]) -> rusqlite::Result<()> {
        self.conn.execute("INSERT OR REPLACE INTO tag_vec(label, model, vec) VALUES(?1,?2,?3)", params![label.trim().to_lowercase(), model, crate::semantic::to_blob(v)])?;
        Ok(())
    }

    pub fn vectors(&self, model: &str) -> rusqlite::Result<std::collections::HashMap<String, Vec<f32>>> {
        let mut st = self.conn.prepare("SELECT label, vec FROM tag_vec WHERE model=?1")?;
        let v = st.query_map([model], |r| Ok((r.get::<_, String>(0)?, crate::semantic::from_blob(&r.get::<_, Vec<u8>>(1)?))))?.collect();
        v
    }

    /// Media no model has analysed yet (switching the default model does not re-trigger work).
    pub fn media_needing_ai(&self, limit: i64) -> rusqlite::Result<Vec<MediaRef>> {
        self.media_needing_ai_for("", 0, limit)
    }

    /// The same for `model` on this device: media whose analysis failed here `MAX_AI_ATTEMPTS`
    /// times, or once since `since` (the current run), are left out, so one image that cannot
    /// be analysed never blocks the rest of the queue (`rules::ai_skip`).
    pub fn media_needing_ai_for(&self, model: &str, since: i64, limit: i64) -> rusqlite::Result<Vec<MediaRef>> {
        let mut st = self.conn.prepare(&format!("SELECT m.id, m.path, m.kind, p.text FROM media m JOIN post p ON p.id=m.post_id WHERE m.id NOT IN (SELECT media_id FROM ai_done) AND NOT EXISTS(SELECT 1 FROM trash x WHERE x.media_id=m.id AND x.state!=0)
            AND NOT EXISTS(SELECT 1 FROM ai_fail f WHERE f.media_id=m.id AND f.model=?2 AND (f.attempts>={} OR (?3>0 AND f.at>=?3))) ORDER BY m.rowid LIMIT ?1", crate::rules::MAX_AI_ATTEMPTS))?;
        let v = st.query_map(params![limit, model, since], |r| Ok(MediaRef { media_id: r.get(0)?, path: r.get(1)?, kind: r.get(2)?, text: r.get(3)? }))?.collect();
        v
    }

    /// Counts an attempt before the model runs (so a crash during it counts too); `reason` is
    /// what is shown if nothing else is recorded. Local only.
    pub fn ai_attempt_begin(&self, media_id: &str, model: &str, now: i64) -> rusqlite::Result<()> {
        self.conn.execute("INSERT INTO ai_fail VALUES(?1,?2,1,'@ai.crashed',?3) ON CONFLICT(media_id, model) DO UPDATE SET attempts=attempts+1, reason='@ai.crashed', at=?3",
            params![media_id, model, now]).map(|_| ())
    }

    /// The attempt failed with an error (already counted by `ai_attempt_begin`).
    pub fn ai_attempt_failed(&self, media_id: &str, model: &str, reason: &str) -> rusqlite::Result<()> {
        self.conn.execute("UPDATE ai_fail SET reason=?3 WHERE media_id=?1 AND model=?2", params![media_id, model, reason]).map(|_| ())
    }

    /// The attempt did not count against the media (the run stopped for a reason of its own:
    /// cancelled, the model could not load): back to how it was before `ai_attempt_begin`.
    pub fn ai_attempt_undo(&self, media_id: &str, model: &str) -> rusqlite::Result<()> {
        self.conn.execute("UPDATE ai_fail SET attempts=attempts-1 WHERE media_id=?1 AND model=?2", params![media_id, model])?;
        self.conn.execute("DELETE FROM ai_fail WHERE media_id=?1 AND model=?2 AND attempts<=0", params![media_id, model]).map(|_| ())
    }

    /// Media this device gave up on (live, not analysed by any device yet), with the reason.
    pub fn ai_failures(&self) -> rusqlite::Result<Vec<AiFailure>> {
        let mut st = self.conn.prepare(&format!("SELECT f.media_id, f.model, f.attempts, f.reason, f.at FROM ai_fail f JOIN media m ON m.id=f.media_id
            WHERE f.attempts>={} AND f.media_id NOT IN (SELECT media_id FROM ai_done) AND NOT EXISTS(SELECT 1 FROM trash x WHERE x.media_id=m.id AND x.state!=0) ORDER BY f.at DESC", crate::rules::MAX_AI_ATTEMPTS))?;
        let v = st.query_map([], |r| Ok(AiFailure { media_id: r.get(0)?, model: r.get(1)?, attempts: r.get(2)?, reason: Self::shown_reason(r.get(3)?), at: r.get(4)? }))?.collect();
        v
    }

    /// A stored reason that is a message key ("@ai.crashed") in the current language.
    fn shown_reason(r: String) -> String { match r.strip_prefix('@') { Some(k) => crate::i18n::text(k), None => r } }

    /// Lets this device try those media again.
    pub fn ai_failures_clear(&self) -> rusqlite::Result<usize> { self.conn.execute("DELETE FROM ai_fail", []) }

    /// Every media, in a stable order, for "re-tag all".
    /// Live media after `after` in id order (keyset paging: media added or deleted during a long
    /// run never make it skip or repeat any, as an OFFSET over a changing table would).
    pub fn media_page(&self, after: &str, limit: i64) -> rusqlite::Result<Vec<MediaRef>> {
        let mut st = self.conn.prepare("SELECT m.id, m.path, m.kind, p.text FROM media m JOIN post p ON p.id=m.post_id WHERE m.id > ?1 AND NOT EXISTS(SELECT 1 FROM trash x WHERE x.media_id=m.id AND x.state!=0) ORDER BY m.id LIMIT ?2")?;
        let v = st.query_map(params![after, limit], |r| Ok(MediaRef { media_id: r.get(0)?, path: r.get(1)?, kind: r.get(2)?, text: r.get(3)? }))?.collect();
        v
    }

    /// (media analysed by any model, total media).
    pub fn ai_counts(&self) -> rusqlite::Result<(i64, i64)> {
        let total = self.conn.query_row(&format!("SELECT count(*) FROM media m WHERE {LIVE_SQL}"), [], |r| r.get(0))?;
        let done = self.conn.query_row(&format!("SELECT count(DISTINCT a.media_id) FROM ai_done a JOIN media m ON m.id=a.media_id WHERE {LIVE_SQL}"), [], |r| r.get(0))?;
        Ok((done, total))
    }

    /// Live media carrying any of `include` (all when empty) and none of `exclude`
    /// (`rules::export_selected`), in post order. Paths stay relative.
    fn live_items_sql(narrower: &str) -> String {
        format!("SELECT m.id, m.post_id, m.ordinal, m.kind, m.path, p.text, p.author_name, p.screen_name, p.url, p.created_at FROM media m JOIN post p ON p.id=m.post_id WHERE {LIVE_SQL}{narrower} ORDER BY m.post_id, m.ordinal")
    }

    pub fn export_items(&self, include: &[String], exclude: &[String]) -> rusqlite::Result<Vec<FeedItem>> {
        let norm = |v: &[String]| -> Vec<String> { v.iter().map(|t| t.trim().to_lowercase()).filter(|t| !t.is_empty()).collect() };
        let (inc, exc) = (norm(include), norm(exclude));
        let items = self.query_items(&Self::live_items_sql(""), &[])?;
        Ok(items.into_iter().filter(|it| {
            let tags: Vec<(String, u8)> = it.tags.iter().map(|t| (t.label.clone(), t.origin)).collect();
            crate::rules::export_selected(&tags, &inc, &exc)
        }).collect())
    }

    /// The live media with these ids (what a search showed), in post order. Ids that are gone,
    /// in the recycle bin or unknown are left out.
    pub fn items_of(&self, ids: &[String]) -> rusqlite::Result<Vec<FeedItem>> {
        // through a temporary list of ids: a small export reads only what it takes
        self.conn.execute_batch("CREATE TEMP TABLE IF NOT EXISTS wanted_media(id TEXT PRIMARY KEY); DELETE FROM wanted_media;")?;
        {
            let mut st = self.conn.prepare_cached("INSERT OR IGNORE INTO wanted_media VALUES(?1)")?;
            for id in ids { st.execute([id])?; }
        }
        let items = self.query_items(&Self::live_items_sql(" AND m.id IN (SELECT id FROM wanted_media)"), &[]);
        self.conn.execute_batch("DELETE FROM wanted_media;")?;
        items
    }

    /// The claims of media by posts other than the one shown as their owner, with those posts: what
    /// a feed does not list, and a backup must keep. (media, ordinal, post)
    pub fn secondary_claims(&self) -> rusqlite::Result<Vec<(String, i64, PostMeta)>> {
        let mut st = self.conn.prepare("SELECT c.media_id, c.ordinal, c.post_id FROM media_claim c JOIN media m ON m.id=c.media_id JOIN post p ON p.id=c.post_id WHERE NOT (c.post_id=m.post_id AND c.ordinal=m.ordinal) ORDER BY c.post_id, c.ordinal")?;
        let rows: Vec<(String, i64, String)> = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect::<Result<_, _>>()?;
        let mut out = Vec::with_capacity(rows.len());
        for (media, ordinal, post) in rows {
            if let Some(meta) = self.post_meta(&post)? { out.push((media, ordinal, meta)); }
        }
        Ok(out)
    }

    /// Every (media, model) analysed, by media and model.
    pub(crate) fn all_ai_done(&self) -> rusqlite::Result<Vec<(String, String)>> {
        let mut st = self.conn.prepare("SELECT media_id, model FROM ai_done ORDER BY media_id, model")?;
        let v = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?.collect();
        v
    }

    /// Every (media, folder), as `folders_of` lists them.
    pub(crate) fn all_folder_media(&self) -> rusqlite::Result<Vec<(String, String)>> {
        let mut st = self.conn.prepare("SELECT fm.media_id, fm.folder FROM folder_media fm JOIN folder f ON f.name=fm.folder WHERE fm.present=1 AND f.deleted=0 ORDER BY fm.media_id, fm.folder")?;
        let v = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?.collect();
        v
    }

    /// Every (post, mark time) of 最近添加.
    pub(crate) fn all_recent(&self) -> rusqlite::Result<Vec<(String, u64)>> {
        let mut st = self.conn.prepare("SELECT post_id, at FROM recent")?;
        let v = st.query_map([], |r| Ok((r.get(0)?, r.get::<_, i64>(1)? as u64)))?.collect();
        v
    }

    /// Models that analysed a media.
    pub fn ai_models_for(&self, media_id: &str) -> rusqlite::Result<Vec<String>> {
        let mut st = self.conn.prepare_cached("SELECT model FROM ai_done WHERE media_id=?1 ORDER BY model")?;
        let v = st.query_map([media_id], |r| r.get(0))?.collect();
        v
    }

    pub(crate) fn query_items(&self, sql: &str, args: &[String]) -> rusqlite::Result<Vec<FeedItem>> {
        let mut st = self.conn.prepare(sql)?;
        let mut items: Vec<FeedItem> = st.query_map(rusqlite::params_from_iter(args.iter()), |r| Ok(FeedItem {
            media_id: r.get(0)?, post_id: r.get(1)?, ordinal: r.get(2)?,
            kind: if r.get::<_, String>(3)? == "video" { MediaKind::Video } else { MediaKind::Photo },
            path: r.get(4)?, text: r.get(5)?, author_name: r.get(6)?, screen_name: r.get(7)?, url: r.get(8)?, created_at: r.get(9)?, tags: vec![], bad: None, recent: false, album: false, size: None,
        }))?.collect::<Result<_, _>>()?;
        {
            let recent = self.recent_posts(now_ms())?;
            if !recent.is_empty() { for it in &mut items { it.recent = recent.contains(&it.post_id); } }
            let album = self.album_media()?;
            if !album.is_empty() { for it in &mut items { it.album = album.contains(&it.media_id); } }
        }
        // Limit detail queries to this result set, including narrow searches and exports.
        // Chunking stays below SQLite's parameter limit and avoids one query per media.
        for chunk in items.chunks_mut(400) {
            let ids: Vec<String> = chunk.iter().map(|i| i.media_id.clone()).collect();
            let ph = vec!["?"; ids.len()].join(",");
            let mut tags: std::collections::HashMap<String, Vec<TagView>> = Default::default();
            let mut tq = self.conn.prepare(&format!("SELECT tm.media_id, t.label, max(tm.origin & 1) | max(tm.origin & 2) FROM tag_media tm JOIN tag_c t ON t.raw_id=tm.tag_id WHERE tm.media_id IN ({ph}) AND tm.origin != 0 GROUP BY tm.media_id, t.id ORDER BY t.label"))?;
            let mut rows = tq.query(rusqlite::params_from_iter(ids.iter()))?;
            while let Some(r) = rows.next()? {
                tags.entry(r.get(0)?).or_default().push(TagView { label: r.get(1)?, origin: r.get(2)?, models: vec![] });
            }
            let mut src: std::collections::HashMap<(String, String), Vec<String>> = Default::default();
            let mut sq = self.conn.prepare(&format!("SELECT DISTINCT s.media_id, t.label, s.model FROM tag_src s JOIN tag_c t ON t.raw_id=s.tag_id WHERE s.media_id IN ({ph}) AND s.present=1 ORDER BY s.model"))?;
            let mut rows = sq.query(rusqlite::params_from_iter(ids.iter()))?;
            while let Some(r) = rows.next()? { src.entry((r.get(0)?, r.get(1)?)).or_default().push(r.get(2)?); }
            let mut bq = self.conn.prepare(&format!("SELECT media_id, reason FROM bad_media WHERE media_id IN ({ph})"))?;
            let bad: std::collections::HashMap<String, String> = bq.query_map(rusqlite::params_from_iter(ids.iter()), |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_, _>>()?;
            for it in chunk {
                it.bad = bad.get(&it.media_id).cloned();
                it.tags = tags.remove(&it.media_id).unwrap_or_default();
                for tag in &mut it.tags {
                    tag.models = src.remove(&(it.media_id.clone(), tag.label.clone())).unwrap_or_default();
                }
            }
        }
        Ok(items)
    }

    /// Queues a URL, with no options (see `enqueue_job_with`).
    pub fn enqueue_job(&self, url: &str) -> rusqlite::Result<()> { self.enqueue_job_with(url, None) }

    /// Queues a link with its options (JSON). Every new request queues it again, also when an
    /// earlier request finished it: the request may differ (revive, folder, mark), and a link
    /// already in the library is settled without any network access. The epoch tells a worker
    /// that a link it already handled was asked for again.
    pub fn enqueue_job_with(&self, url: &str, opts: Option<&str>) -> rusqlite::Result<()> {
        if url.is_empty() { return Ok(()); }
        self.conn.execute("INSERT INTO job(url,status,updated,opts,epoch) VALUES(?1,'pending',unixepoch(),?2,1) ON CONFLICT(url) DO UPDATE SET status='pending', error=NULL, opts=excluded.opts, epoch=job.epoch+1, updated=unixepoch()", params![url, opts])?;
        Ok(())
    }

    /// Explicit pause/cancel survives process exit; increment epochs so in-flight workers
    /// cannot mark stopped jobs completed or failed afterwards.
    pub fn stop_jobs(&self, pause: bool) -> rusqlite::Result<usize> {
        self.conn.execute(if pause {
            "UPDATE job SET status='paused', epoch=epoch+1, error=NULL, updated=unixepoch() WHERE status='pending'"
        } else {
            "UPDATE job SET status='cancelled', epoch=epoch+1, error=NULL, updated=unixepoch() WHERE status IN ('pending','paused')"
        }, [])
    }
    pub fn resume_jobs(&self) -> rusqlite::Result<usize> {
        self.conn.execute("UPDATE job SET status='pending', epoch=epoch+1, updated=unixepoch() WHERE status='paused'", [])
    }
    pub fn paused_jobs(&self) -> rusqlite::Result<usize> {
        self.conn.query_row("SELECT count(*) FROM job WHERE status='paused'", [], |r| r.get(0))
    }

    pub fn pending_jobs(&self) -> rusqlite::Result<Vec<String>> {
        Ok(self.pending_jobs_epoch()?.into_iter().map(|(u, _, _)| u).collect())
    }

    /// Pending links with their request epoch and options.
    pub fn pending_jobs_epoch(&self) -> rusqlite::Result<Vec<(String, i64, Option<String>)>> {
        let mut st = self.conn.prepare("SELECT url, epoch, opts FROM job WHERE status='pending' ORDER BY rowid")?;
        let v = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect();
        v
    }

    /// Finishes a link only if it was not asked for again meanwhile (then it stays pending).
    /// Returns false when the link was requested again meanwhile (a newer epoch): this run's
    /// result is then not counted, the newer request is.
    pub fn finish_job_epoch(&self, url: &str, epoch: i64, error: Option<String>) -> rusqlite::Result<bool> {
        use rusqlite::OptionalExtension;
        let now: Option<i64> = self.conn.query_row("SELECT epoch FROM job WHERE url=?1", [url], |r| r.get(0)).optional()?;
        if !now.map_or(false, |n| crate::rules::job_finishes(n, epoch)) { return Ok(false); }
        Ok(self.conn.execute("UPDATE job SET status=?2, error=?3, updated=unixepoch() WHERE url=?1 AND epoch=?4",
            params![url, if error.is_some() { "failed" } else { "done" }, error, epoch])? > 0)
    }

    pub fn finish_job(&self, url: &str, error: Option<String>) -> rusqlite::Result<()> {
        self.conn.execute("UPDATE job SET status=?2, error=?3, updated=unixepoch() WHERE url=?1",
            params![url, if error.is_some() { "failed" } else { "done" }, error])?;
        Ok(())
    }

    /// Media this device knows for a post: every claim (live, binned, deleted, or still arriving).
    pub fn post_media_count(&self, post_id: &str) -> rusqlite::Result<i64> {
        self.conn.query_row("SELECT (SELECT count(*) FROM media WHERE post_id=?1) + (SELECT count(*) FROM want_blob WHERE post_id=?1)", [post_id], |r| r.get(0))
    }

    /// Live media of a post.
    pub fn post_live_count(&self, post_id: &str) -> rusqlite::Result<i64> {
        self.conn.query_row(&format!("SELECT count(*) FROM media m WHERE m.post_id=?1 AND {LIVE_SQL}"), [post_id], |r| r.get(0))
    }

    /// Every tag with how many media carry it, by origin bit.
    pub fn all_tags(&self) -> rusqlite::Result<Vec<TagCount>> {
        let mut st = self.conn.prepare("SELECT t.label, count(DISTINCT tm.media_id), count(DISTINCT CASE WHEN tm.origin & 1 != 0 THEN tm.media_id END), count(DISTINCT CASE WHEN tm.origin & 2 != 0 THEN tm.media_id END) FROM tag_c t JOIN tag_media tm ON tm.tag_id=t.raw_id JOIN media m ON m.id=tm.media_id WHERE tm.origin != 0 AND NOT EXISTS(SELECT 1 FROM trash x WHERE x.media_id=m.id AND x.state!=0) GROUP BY t.id ORDER BY count(DISTINCT tm.media_id) DESC, t.label")?;
        let v = st.query_map([], |r| Ok(TagCount { label: r.get(0)?, count: r.get(1)?, user: r.get(2)?, ai: r.get(3)? }))?.collect();
        v
    }

    pub fn stats(&self) -> rusqlite::Result<Stats> {
        let q = |sql: &str| self.conn.query_row(sql, [], |r| r.get::<_, i64>(0));
        Ok(Stats { posts: q(&format!("SELECT count(DISTINCT m.post_id) FROM media m WHERE {LIVE_SQL}"))?,
            photos: q(&format!("SELECT count(*) FROM media m WHERE m.kind='photo' AND {LIVE_SQL}"))?,
            videos: q(&format!("SELECT count(*) FROM media m WHERE m.kind='video' AND {LIVE_SQL}"))?,
            tags: q(&format!("SELECT count(DISTINCT t.id) FROM tag_media tm JOIN tag_c t ON t.raw_id=tm.tag_id JOIN media m ON m.id=tm.media_id WHERE tm.origin != 0 AND {LIVE_SQL}"))?,
            pending_jobs: q("SELECT count(*) FROM job WHERE status='pending'")?, failed_jobs: q("SELECT count(*) FROM job WHERE status='failed'")?,
            trashed: q("SELECT count(*) FROM trash x JOIN media m ON m.id=x.media_id WHERE x.state=1")?,   // as listed (awaited files are not shown)
            bad: q(&format!("SELECT count(*) FROM bad_media b JOIN media m ON m.id=b.media_id WHERE {LIVE_SQL}"))?,
            newer_ops: q("SELECT count(*) FROM op_pending")? })
    }

    // ---------- meta, clock and op log ----------

    pub fn meta_get(&self, k: &str) -> rusqlite::Result<Option<String>> {
        use rusqlite::OptionalExtension;
        self.conn.query_row("SELECT v FROM meta WHERE k=?1", [k], |r| r.get(0)).optional()
    }
    pub fn meta_set(&self, k: &str, v: &str) -> rusqlite::Result<()> {
        self.conn.execute("INSERT OR REPLACE INTO meta VALUES(?1,?2)", [k, v]).map(|_| ())
    }

    /// This install's identity; regenerated after a wipe.
    pub fn device_id(&self) -> rusqlite::Result<String> {
        if let Some(d) = self.meta_get("device")? { return Ok(d); }
        let d = hex::encode(rand::random::<[u8; 8]>());
        self.meta_set("device", &d)?;
        Ok(d)
    }

    pub fn next_hlc(&self) -> rusqlite::Result<u64> {
        let last: u64 = self.meta_get("hlc")?.and_then(|v| v.parse().ok()).unwrap_or(0);
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64);
        let n = crate::crdt::next_hlc(last, now);
        self.meta_set("hlc", &n.to_string())?;
        Ok(n)
    }

    /// Observes a remote clock so later local writes order after it.
    /// A clock far in the future (a wrong date, a forged op) is not adopted: see `rules::observe_clock`.
    pub fn observe_hlc(&self, remote: u64) -> rusqlite::Result<()> {
        let last: u64 = self.meta_get("hlc")?.and_then(|v| v.parse().ok()).unwrap_or(0);
        let next = crate::rules::observe_clock(last, remote, now_ms());
        if next != last { self.meta_set("hlc", &next.to_string())?; }
        Ok(())
    }

    pub(crate) fn record(&self, op: &crate::oplog::Op) -> rusqlite::Result<()> {
        let dev = self.device_id()?;
        let last: i64 = self.conn.query_row("SELECT coalesce(max(seq),0) FROM op WHERE device=?1", [&dev], |r| r.get(0))?;
        let seq = last.checked_add(1).ok_or_else(|| rusqlite::Error::ToSqlConversionFailure(tr!("store.seqExhausted").into()))?;
        let body = serde_json::to_string(op).unwrap();
        // the sync frame holds one op at most and sequence numbers have no gaps: a larger one could
        // never be sent, and everything after it would stay on this device
        if body.len() > crate::sync::MAX_OP_BYTES {
            return Err(rusqlite::Error::ToSqlConversionFailure(tr!("store.opTooLarge", bytes = body.len()).into()));
        }
        self.conn.execute("INSERT INTO op VALUES(?1,?2,?3)", params![dev, seq, body])?;
        Ok(())
    }

    /// Deletes tag names nothing refers to any more (no media record, no AI source, no rename
    /// rule, no other name shown as it) and search vectors of names no live media carries.
    /// Records of permanently deleted media are kept on purpose: they are sync state (a media
    /// imported again later must look the same on every device). Tags without live media are
    /// never shown anywhere — see `all_tags` / `all_labels`.
    pub fn gc_dead_tags(&self) -> rusqlite::Result<usize> {
        let n = self.conn.execute("DELETE FROM tag WHERE NOT EXISTS(SELECT 1 FROM tag_media tm WHERE tm.tag_id=tag.id)
            AND NOT EXISTS(SELECT 1 FROM tag_src s WHERE s.tag_id=tag.id)
            AND NOT EXISTS(SELECT 1 FROM tag_alias a WHERE a.src=tag.label OR a.dst=tag.label)
            AND NOT EXISTS(SELECT 1 FROM tag o WHERE o.canon=tag.id)", [])?;
        self.conn.execute(&format!("DELETE FROM tag_vec WHERE label NOT IN (SELECT DISTINCT t.label FROM tag_c t JOIN tag_media tm ON tm.tag_id=t.raw_id JOIN media m ON m.id=tm.media_id WHERE tm.origin != 0 AND {LIVE_SQL})"), [])?;
        Ok(n)
    }

    /// Marks a post "最近添加" at `at` (ms) and records it for sync.
    pub fn mark_recent(&self, post_id: &str, at: u64) -> rusqlite::Result<()> { self.atomic(|| {
        self.apply_recent(post_id, at)?;
        self.record(&crate::oplog::Op::Recent { post_id: post_id.into(), at })
    }) }

    /// Marks a media as brought in through a share extension (从相册导入); synced.
    pub fn mark_album(&self, media_id: &str) -> rusqlite::Result<()> { self.atomic(|| {
        if self.conn.execute("INSERT OR IGNORE INTO album VALUES(?1)", [media_id])? > 0 {
            self.record(&crate::oplog::Op::Album { media_id: media_id.into() })?;
        }
        Ok(())
    }) }

    pub(crate) fn apply_album(&self, media_id: &str) -> rusqlite::Result<()> {
        self.conn.execute("INSERT OR IGNORE INTO album VALUES(?1)", [media_id])?;
        Ok(())
    }

    pub fn album_media(&self) -> rusqlite::Result<std::collections::HashSet<String>> {
        let mut st = self.conn.prepare_cached("SELECT media_id FROM album")?;
        let v = st.query_map([], |r| r.get(0))?.collect();
        v
    }

    /// Merges a mark (max of the two times, `rules::merge_recent`).
    pub(crate) fn apply_recent(&self, post_id: &str, at: u64) -> rusqlite::Result<()> {
        let cur = self.recent_at(post_id)?;
        let at = crate::rules::merge_recent(cur, at).min(i64::MAX as u64) as i64;
        self.conn.execute("INSERT INTO recent VALUES(?1,?2) ON CONFLICT(post_id) DO UPDATE SET at=excluded.at", params![post_id, at])?;
        Ok(())
    }

    // ---------- shared settings ----------

    pub(crate) fn settings_with_prefix(&self, prefix: &str) -> rusqlite::Result<Vec<(String, String)>> {
        let mut st = self.conn.prepare("SELECT key, value FROM setting WHERE value IS NOT NULL AND substr(key, 1, length(?1))=?1")?;
        let v = st.query_map([prefix], |r| Ok((r.get(0)?, r.get(1)?)))?.collect();
        v
    }

    /// A setting shared by every device (None = the default).
    pub fn setting(&self, key: &str) -> rusqlite::Result<Option<String>> {
        use rusqlite::OptionalExtension;
        Ok(self.conn.query_row("SELECT value FROM setting WHERE key=?1", [key], |r| r.get::<_, Option<String>>(0)).optional()?.flatten())
    }

    /// Changes a shared setting here and on every device (None = back to the default).
    pub fn set_setting(&self, key: &str, value: Option<&str>) -> rusqlite::Result<()> { self.atomic(|| {
        if self.setting(key)?.as_deref() == value { return Ok(()); }
        let reg = (self.next_hlc()?, value.map(str::to_string));
        self.apply_setting(key, reg.clone())?;
        self.record(&crate::oplog::Op::Setting { key: key.into(), value: reg.1, hlc: reg.0 })
    }) }

    pub(crate) fn apply_setting(&self, key: &str, incoming: (u64, Option<String>)) -> rusqlite::Result<()> {
        use rusqlite::OptionalExtension;
        let cur: Option<(u64, Option<String>)> = self.conn.query_row("SELECT hlc, value FROM setting WHERE key=?1", [key], |r| Ok((r.get::<_, i64>(0)? as u64, r.get(1)?))).optional()?;
        let m = cur.clone().map_or(incoming.clone(), |c| crate::rules::merge_alias(c, incoming));
        if Some(&m) != cur.as_ref() {
            self.conn.execute("INSERT INTO setting VALUES(?1,?2,?3) ON CONFLICT(key) DO UPDATE SET value=excluded.value, hlc=excluded.hlc", params![key, m.1, m.0 as i64])?;
        }
        Ok(())
    }

    /// Mark time of a post (0 = none).
    pub fn recent_at(&self, post_id: &str) -> rusqlite::Result<u64> {
        use rusqlite::OptionalExtension;
        Ok(self.conn.query_row("SELECT at FROM recent WHERE post_id=?1", [post_id], |r| r.get::<_, i64>(0)).optional()?.unwrap_or(0).max(0) as u64)
    }

    /// Posts whose mark is active at `now` (`rules::recent_active`).
    pub fn recent_posts(&self, now: u64) -> rusqlite::Result<std::collections::HashSet<String>> {
        let mut st = self.conn.prepare_cached("SELECT post_id, at FROM recent")?;
        let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?.max(0) as u64)))?;
        let mut out = std::collections::HashSet::new();
        for r in rows { let (p, at) = r?; if crate::rules::recent_active(at, now) { out.insert(p); } }
        Ok(out)
    }

    /// Drops local rows of marks expired for over a day. Not an op: the register only grows, so
    /// a re-delivered old mark is merely expired again.
    pub fn prune_recent(&self, now: u64) -> rusqlite::Result<usize> {
        let cutoff = now.saturating_sub(crate::rules::RECENT_MS + 86_400_000).min(i64::MAX as u64) as i64;
        self.conn.execute("DELETE FROM recent WHERE at < ?1", [cutoff])
    }

    /// Wipes every row. Never recorded in the sync log.
    pub fn wipe(&self) -> rusqlite::Result<()> {
        self.atomic(|| self.conn.execute_batch("DELETE FROM album; DELETE FROM tag_src; DELETE FROM tag_media; DELETE FROM tag_vec; DELETE FROM ai_done; DELETE FROM tag; DELETE FROM media; DELETE FROM post; DELETE FROM job; DELETE FROM op; DELETE FROM want_blob; DELETE FROM media_claim; DELETE FROM setting; DELETE FROM meta; DELETE FROM trash; DELETE FROM gc; DELETE FROM verified_media; DELETE FROM media_size; DELETE FROM bad_media; DELETE FROM tag_alias; DELETE FROM folder; DELETE FROM folder_media; DELETE FROM recent; DELETE FROM op_pending; DELETE FROM ai_fail;"))
    }

    pub fn conn(&self) -> &Connection { &self.conn }

    /// Runs a local change and the records that sync it as one unit (a savepoint, so it nests
    /// inside callers' transactions): killed at any moment, either both are on disk or neither.
    /// Without it a change could survive a crash without its record and never reach other devices.
    pub(crate) fn atomic<T>(&self, f: impl FnOnce() -> rusqlite::Result<T>) -> rusqlite::Result<T> {
        self.conn.execute_batch("SAVEPOINT local_change")?;
        struct Rollback<'a>(&'a Connection, bool);
        impl Drop for Rollback<'_> {
            fn drop(&mut self) { if self.1 { let _ = self.0.execute_batch("ROLLBACK TO local_change; RELEASE local_change"); } }
        }
        let mut rollback = Rollback(&self.conn, true);
        let v = f()?;
        self.conn.execute_batch("RELEASE local_change")?;
        rollback.1 = false;
        Ok(v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn endorse_via_user_add() {
        let s = Store::open(":memory:").unwrap();
        s.upsert_post(&PostMeta { id: "1".into(), ..Default::default() }).unwrap();
        s.conn().execute("INSERT INTO media VALUES('m','1',0,'photo','p')", []).unwrap();
        s.tag_media("m", "白墙", Origin::AI).unwrap();
        s.tag_media("m", "白墙", Origin::USER).unwrap();
        let o: u8 = s.conn().query_row("SELECT origin FROM tag_media", [], |r| r.get(0)).unwrap();
        assert_eq!(o, 3);
    }
}

/// Wall-clock milliseconds since the Unix epoch.
pub fn now_ms() -> u64 { std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64) }

#[cfg(test)]
mod chatgpt_atomic_tests {
    use super::*;
    #[test]
    fn panic_in_nested_savepoint_rolls_back_and_releases_connection() {
        let db = Store::open(":memory:").unwrap();
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _: rusqlite::Result<()> = db.atomic(|| {
                db.set_setting("outer", Some("one"))?;
                db.atomic(|| {
                    db.set_setting("inner", Some("two"))?;
                    panic!("injected panic after writes")
                })
            });
        }));
        assert!(result.is_err());
        assert!(db.conn().is_autocommit());
        assert_eq!(db.setting("outer").unwrap(), None);
        assert_eq!(db.setting("inner").unwrap(), None);
        assert!(db.version_vector().unwrap().is_empty());
        db.set_setting("after", Some("ok")).unwrap();
        assert_eq!(db.setting("after").unwrap(), Some("ok".into()));
    }
}
