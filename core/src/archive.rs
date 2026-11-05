//! Zip-based interchange: legacy zip import and the `.tlpack` export format.
//!
//! `.tlpack` = zip { manifest.json, media/<sha256>.<ext> }. Media entries are stored uncompressed
//! (photos/MP4 are already compressed) so export is I/O-bound and import can verify hashes.
use crate::library::{FeedItem, ImportReport, Library};
use crate::model::{MediaKind, Origin, PostMeta};
use crate::store::Store;
use anyhow::{bail, Context};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::fs::{self, File};
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};

pub const FORMAT: &str = "twitter-library-pack";
pub const VERSION: u32 = 4;

/// What an export carries besides the media and post text.
#[derive(Debug, Clone, Copy, Deserialize)]
pub struct ExportOptions {
    /// Tags with their origin and the AI models, and analysed-by records.
    #[serde(default = "yes")] pub tags: bool,
    /// Folder memberships.
    #[serde(default = "yes")] pub folders: bool,
    /// A plain zip of the media files, readable without this app: all at its root, named after
    /// their post ("作者 - 帖子 ID - 1.jpg"). No manifest, so it cannot be imported back with
    /// tags or folders (use the .tlpack for that).
    #[serde(default)] pub media_only: bool,
}
fn yes() -> bool { true }
impl Default for ExportOptions { fn default() -> Self { ExportOptions { tags: true, folders: true, media_only: false } } }

/// A file or folder name that every system accepts: no path separators, reserved characters or
/// control characters, no leading/trailing dots or spaces, at most 60 characters.
fn plain_name(s: &str) -> String {
    let t: String = s.chars().map(|c| if c.is_control() || "/\\:*?\"<>|".contains(c) { '_' } else { c }).take(60).collect();
    let t = t.trim_matches(|c: char| c == '.' || c.is_whitespace()).to_string();
    if t.is_empty() { "_".into() } else { t }
}

/// Its name in a plain media zip: every file at the zip's root, so the post is in the name.
fn plain_entry(it: &FeedItem, index: usize, ext: &str) -> String {
    if it.post_id.starts_with(crate::import::LOOSE_PREFIX) {
        return format!("{}.{ext}", &it.media_id[..it.media_id.len().min(16)]);
    }
    let who = it.author_name.as_deref().filter(|s| !s.trim().is_empty())
        .or(it.screen_name.as_deref().filter(|s| !s.trim().is_empty()));
    let post = match who { Some(w) => format!("{} - {}", plain_name(w), plain_name(&it.post_id)), None => plain_name(&it.post_id) };
    format!("{post} - {}.{ext}", index + 1)
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Manifest {
    pub format: String,
    pub version: u32,
    pub created_at: u64,
    /// Selection used for this export (empty = whole library).
    #[serde(default)] pub include_tags: Vec<String>,
    #[serde(default)] pub exclude_tags: Vec<String>,
    /// "selection" (tags / folders chosen) or "backup" (the whole library, for cold storage).
    #[serde(default)] pub kind: String,
    /// Backup: media that also belong to other posts than the one they are listed under.
    #[serde(default, skip_serializing_if = "Vec::is_empty")] pub also_claimed: Vec<PackClaim>,
    /// Backup: every folder, also empty ones, and the tag rename rules (old name → shown name).
    #[serde(default)] pub folders_all: Vec<String>,
    #[serde(default)] pub renames: Vec<(String, String)>,
    pub posts: Vec<PackPost>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PackClaim { pub media: String, pub ordinal: i64, pub post: PostMeta }

#[derive(Debug, Serialize, Deserialize)]
pub struct PackPost {
    #[serde(flatten)] pub meta: PostMeta,
    pub media: Vec<PackMedia>,
    /// "最近添加" mark time (ms), 0 = none. Restored as is, so it expires on schedule.
    #[serde(default, skip_serializing_if = "is_zero")] pub recent_at: u64,
}
fn is_zero(v: &u64) -> bool { *v == 0 }

#[derive(Debug, Serialize, Deserialize)]
pub struct PackMedia {
    pub sha256: String,
    pub kind: MediaKind,
    pub ordinal: i64,
    pub file: String,
    /// Every tag with its origin (1 = mine, 2 = AI, 3 = endorsed) and the AI models that proposed it.
    pub tags: Vec<PackTag>,
    /// Models that already analysed this media (so the importer does not redo the work).
    #[serde(default)] pub ai_models: Vec<String>,
    /// Folders the media is in (restored on import).
    #[serde(default)] pub folders: Vec<String>,
    /// Backup: the media was in the recycle bin (it goes back there when it is new on import).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")] pub trashed: bool,
    /// Came in through a share extension (从相册导入).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")] pub album: bool,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PackTag { pub label: String, pub origin: u8, #[serde(default)] pub models: Vec<String> }

#[derive(Debug, Serialize, Default)]
pub struct ExportReport {
    pub posts: usize, pub media: usize, pub bytes: u64,
    /// Media from the recycle bin included (backup only).
    pub trashed: usize,
    /// Media left out because their file is missing or damaged here (each with the reason).
    pub skipped: Vec<ExportSkip>,
}

#[derive(Debug, Serialize, Clone)]
pub struct ExportSkip { pub media_id: String, pub post_id: String, pub reason: String }

/// Progress of the running export (one at a time).
#[derive(Debug, Serialize, Clone, Default)]
pub struct ExportProgress { pub running: bool, pub done: usize, pub total: usize, pub bytes: u64 }
static EXPORT_PROGRESS: std::sync::Mutex<Option<ExportProgress>> = std::sync::Mutex::new(None);
static EXPORT_CANCEL: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static EXPORT_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
pub fn export_progress() -> ExportProgress { EXPORT_PROGRESS.lock().unwrap().clone().unwrap_or_default() }
pub fn cancel_export() { EXPORT_CANCEL.store(true, std::sync::atomic::Ordering::SeqCst); }
fn set_export(f: impl FnOnce(&mut ExportProgress)) { f(EXPORT_PROGRESS.lock().unwrap().get_or_insert_with(Default::default)) }

/// The archive file, shared with the export loop so a cut-out entry can be truncated away.
#[derive(Clone)]
struct SharedFile(std::rc::Rc<std::cell::RefCell<BufWriter<File>>>);
impl Write for SharedFile {
    fn write(&mut self, b: &[u8]) -> io::Result<usize> { self.0.borrow_mut().write(b) }
    fn flush(&mut self) -> io::Result<()> { self.0.borrow_mut().flush() }
}
impl io::Seek for SharedFile {
    fn seek(&mut self, p: io::SeekFrom) -> io::Result<u64> { self.0.borrow_mut().seek(p) }
}
impl SharedFile {
    /// Drops everything past the current position (the bytes of an entry just cut out).
    fn truncate_here(&self) -> io::Result<()> {
        let mut w = self.0.borrow_mut();
        w.flush()?;
        let pos = io::Seek::stream_position(&mut *w)?;
        w.get_ref().set_len(pos)
    }
}

/// Writes everything it reads into the hash too (one read per media file).
struct Tee<'a, W: Write> { w: &'a mut W, h: Sha256, n: u64 }
impl<W: Write> Write for Tee<'_, W> {
    fn write(&mut self, b: &[u8]) -> io::Result<usize> { let k = self.w.write(b)?; self.h.update(&b[..k]); self.n += k as u64; Ok(k) }
    fn flush(&mut self) -> io::Result<()> { self.w.flush() }
}

/// Decodes a zip entry name: UTF-8 when valid, otherwise GBK (Chinese Windows zips).
pub fn entry_name(raw: &[u8]) -> String {
    match std::str::from_utf8(raw) {
        Ok(s) => s.to_string(),
        Err(_) => encoding_rs::GBK.decode(raw).0.into_owned(),
    }
}

/// Rejects absolute paths and `..` so an archive cannot write outside the target directory.
pub fn safe_relative(name: &str) -> Option<PathBuf> {
    let v = crate::rules::safe_relative_bytes(name.as_bytes())?;
    String::from_utf8(v).ok().map(PathBuf::from)
}

/// Imports a zip of legacy post folders (see `import`): entries stream straight into the blob
/// store, every entry is accounted for in the report.
pub fn import_legacy_zip(lib: &Library, zip_path: &Path) -> anyhow::Result<ImportReport> { crate::import::import_zip(lib, zip_path, None) }

fn now() -> u64 { std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs()) }

/// Exports exactly these media (what a search showed). Each still carries its parent post's
/// text, author and link; tags and folder memberships only when `opts` say so. Nothing else
/// selects media: there is no filter of its own, the search is the filter.
pub fn export_media(lib: &Library, media_ids: &[String], opts: ExportOptions, out: &Path) -> anyhow::Result<ExportReport> {
    let (items, snap) = {
        let db = lib.db();
        let items = db.items_of(media_ids)?;
        let snap = snapshot(&db, items.iter(), &opts, false)?;
        (items, snap)
    };
    if items.is_empty() { bail!(tr!("export.nothing")); }
    let extras = Extras { kind: "selection", ..Default::default() };
    write_pack(lib, items, vec![], opts, extras, snap, out)
}

/// What an export carries besides the media list and tags, read in the same hold of the store as
/// the list: writing a large pack takes a long time, and tagging, sync or the user keep changing
/// things meanwhile. Read file by file, a backup could carry a media's "analysed by this model"
/// record without the tags that analysis wrote, and a restore would never add them.
#[derive(Default)]
struct Snapshot { ai_models: HashMap<String, Vec<String>>, folders: HashMap<String, Vec<String>>, recent: HashMap<String, u64> }

fn snapshot<'a>(db: &Store, items: impl Iterator<Item = &'a FeedItem>, opts: &ExportOptions, with_recent: bool) -> anyhow::Result<Snapshot> {
    // whole tables read once, not several queries per media: a large backup holds the store for
    // all of this, and every other part of the app waits for it
    let (mut media, mut posts) = (std::collections::HashSet::new(), std::collections::HashSet::new());
    for it in items { media.insert(it.media_id.as_str()); posts.insert(it.post_id.as_str()); }
    let mut s = Snapshot::default();
    if opts.tags {
        for (id, model) in db.all_ai_done()? { if media.contains(id.as_str()) { s.ai_models.entry(id).or_default().push(model); } }
        for id in &media { s.ai_models.entry(id.to_string()).or_default(); }
    }
    if opts.folders {
        for (id, folder) in db.all_folder_media()? { if media.contains(id.as_str()) { s.folders.entry(id).or_default().push(folder); } }
        for id in &media { s.folders.entry(id.to_string()).or_default(); }
    }
    if with_recent {
        for (post, at) in db.all_recent()? { if posts.contains(post.as_str()) { s.recent.insert(post, at); } }
    }
    Ok(s)
}

/// Cold backup of the whole library: every media (also those in the recycle bin), post text,
/// tags with origin and AI provenance, analysed-by records, folders (also empty ones), rename
/// rules and "最近添加" marks. Not included: AI models (local by design),
/// sync identity and device pairings, import reports.
pub fn export_backup(lib: &Library, out: &Path) -> anyhow::Result<ExportReport> {
    let (live, bin, folders_all, renames, pending, snap, also_claimed) = {
        let db = lib.db();
        let live = db.export_items(&[], &[])?;
        let bin: Vec<FeedItem> = db.trash_items()?.into_iter().map(|t| t.item).collect();
        // media this device knows of but whose file has not arrived yet are not in the backup: say so
        let pending: Vec<(String, String)> = {
            let mut st = db.conn().prepare("SELECT w.media_id, w.post_id FROM want_blob w WHERE NOT EXISTS(SELECT 1 FROM trash x WHERE x.media_id=w.media_id AND x.state=2)")?;
            let v = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_, _>>()?;
            v
        };
        let snap = snapshot(&db, live.iter().chain(bin.iter()), &ExportOptions::default(), true)?;
        let folders_all = db.folders()?.into_iter().map(|(n, _)| n).collect::<Vec<_>>();
        let also_claimed = db.secondary_claims()?.into_iter().map(|(media, ordinal, post)| PackClaim { media, ordinal, post }).collect::<Vec<_>>();
        (live, bin, folders_all, db.renames()?, pending, snap, also_claimed)
    };
    if live.is_empty() && bin.is_empty() { bail!(tr!("export.libraryEmpty")); }
    let mut rep = write_pack(lib, live, bin, ExportOptions::default(), Extras { kind: "backup", include: vec![], exclude: vec![], folders_all, renames, also_claimed }, snap, out)?;
    for (media_id, post_id) in pending {
        rep.skipped.push(ExportSkip { media_id, post_id, reason: tr!("export.notSyncedYet").into() });
    }
    Ok(rep)
}

#[derive(Default)]
struct Extras { kind: &'static str, include: Vec<String>, exclude: Vec<String>, folders_all: Vec<String>, renames: Vec<(String, String)>, also_claimed: Vec<PackClaim> }

/// Streams media into a `.tlpack`, verifying each file against its id (the SHA-256 of its
/// content) on the way; a missing or damaged file is left out and listed with its reason.
fn write_pack(lib: &Library, live: Vec<FeedItem>, bin: Vec<FeedItem>, opts: ExportOptions, extras: Extras, snap: Snapshot, out: &Path) -> anyhow::Result<ExportReport> {
    // one export at a time: a second one waits for the first (like imports)
    let _one = EXPORT_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    EXPORT_CANCEL.store(false, std::sync::atomic::Ordering::SeqCst);
    *EXPORT_PROGRESS.lock().unwrap() = Some(ExportProgress { running: true, total: live.len() + bin.len(), ..Default::default() });
    let r = write_pack_inner(lib, live, bin, opts, extras, snap, out);
    set_export(|p| p.running = false);
    if r.is_err() { let _ = fs::remove_file(out.with_extension("tlpack.partial")); }
    r
}

fn write_pack_inner(lib: &Library, live: Vec<FeedItem>, bin: Vec<FeedItem>, opts: ExportOptions, extras: Extras, snap: Snapshot, out: &Path) -> anyhow::Result<ExportReport> {
    if live.len() + bin.len() >= MAX_PACK_ENTRIES { bail!(tr!("export.tooLarge", detail = live.len() + bin.len())); }
    let mut by_post: BTreeMap<String, Vec<(FeedItem, bool)>> = BTreeMap::new();
    for it in live { by_post.entry(it.post_id.clone()).or_default().push((it, false)); }
    for it in bin { by_post.entry(it.post_id.clone()).or_default().push((it, true)); }

    let tmp = out.with_extension("tlpack.partial");
    let archive = SharedFile(std::rc::Rc::new(std::cell::RefCell::new(BufWriter::with_capacity(1 << 20, File::create(&tmp)?))));
    let mut zw = zip::ZipWriter::new(archive.clone());
    let stored = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored).large_file(true);
    let mut rep = ExportReport::default();
    let mut posts = vec![];
    for (_, mut group) in by_post {
        if EXPORT_CANCEL.load(std::sync::atomic::Ordering::SeqCst) { bail!(tr!("export.cancelled")); }
        group.sort_by_key(|(it, _)| it.ordinal);
        let f = &group[0].0;
        let meta = PostMeta { id: f.post_id.clone(), author_name: f.author_name.clone(), screen_name: f.screen_name.clone(),
            text: f.text.clone(), created_at: f.created_at.clone(), url: f.url.clone() };
        let mut media = vec![];
        for (index, (it, trashed)) in group.iter().enumerate() {
            set_export(|p| p.done += 1);
            let ext = Path::new(&it.path).extension().and_then(|e| e.to_str()).unwrap_or("bin");
            let file = if opts.media_only { plain_entry(it, index, ext) } else { format!("media/{}.{}", it.media_id, ext) };
            let opened = if crate::rules::is_blob_path(it.path.as_bytes()) { File::open(lib.dir.join(&it.path)) } else { Err(std::io::Error::other("not a library file")) };
            let mut src = match opened {
                Ok(f) => f,
                Err(_) => { rep.skipped.push(ExportSkip { media_id: it.media_id.clone(), post_id: it.post_id.clone(), reason: tr!("export.notHere").into() }); continue; }
            };
            zw.start_file(&file, stored)?;
            let (n, sha) = { let mut tee = Tee { w: &mut zw, h: Sha256::new(), n: 0 }; io::copy(&mut src, &mut tee)?; (tee.n, hex::encode(tee.h.finalize())) };
            if sha != it.media_id {
                // cut the entry out and drop its bytes (later entries continue from here)
                zw.abort_file()?;
                archive.truncate_here()?;
                rep.skipped.push(ExportSkip { media_id: it.media_id.clone(), post_id: it.post_id.clone(), reason: tr!("export.damaged").into() });
                continue;
            }
            rep.bytes += n;
            set_export(|p| p.bytes += n);
            rep.media += 1;
            if *trashed { rep.trashed += 1; }
            if opts.media_only { media.push(PackMedia { sha256: it.media_id.clone(), kind: it.kind.clone(), ordinal: it.ordinal, file, ai_models: vec![], tags: vec![], folders: vec![], trashed: false, album: false }); continue; }
            let ai_models = if opts.tags { snap.ai_models.get(&it.media_id).cloned().unwrap_or_default() } else { vec![] };
            let tags = if opts.tags { it.tags.iter().map(|t| PackTag { label: t.label.clone(), origin: t.origin, models: t.models.clone() }).collect() } else { vec![] };
            let folders = if opts.folders { snap.folders.get(&it.media_id).cloned().unwrap_or_default() } else { vec![] };
            media.push(PackMedia { sha256: it.media_id.clone(), kind: it.kind.clone(), ordinal: it.ordinal, file, ai_models, tags, folders, trashed: *trashed, album: it.album });
        }
        if media.is_empty() { continue; }
        let recent_at = if extras.kind == "backup" { snap.recent.get(&meta.id).copied().unwrap_or(0) } else { 0 };
        posts.push(PackPost { meta, media, recent_at });
        rep.posts += 1;
    }
    if rep.media == 0 { bail!(tr!("export.nothingDamaged", n = rep.skipped.len())); }
    if !opts.media_only {
        let manifest = Manifest { format: FORMAT.into(), version: VERSION, created_at: now(), include_tags: extras.include, exclude_tags: extras.exclude,
            kind: extras.kind.into(), also_claimed: extras.also_claimed, folders_all: extras.folders_all, renames: extras.renames, posts };
        let bytes = serde_json::to_vec(&manifest)?;
        if bytes.len() as u64 > MAX_MANIFEST_BYTES { bail!(tr!("export.tooLarge", detail = bytes.len())); }
        zw.start_file("manifest.json", zip::write::SimpleFileOptions::default())?;
        zw.write_all(&bytes)?;
    }
    let mut w = zw.finish()?;
    w.flush()?;
    drop(w);
    let inner = std::rc::Rc::try_unwrap(archive.0).map_err(|_| anyhow::anyhow!("archive still in use"))?.into_inner();
    inner.into_inner().map_err(|e| e.into_error())?.sync_all()?;
    fs::rename(&tmp, out)?;
    Ok(rep)
}

/// Imports a `.tlpack`, verifying every media hash. Tags merge by OR-ing origins.
pub fn import_pack(lib: &Library, path: &Path) -> anyhow::Result<ImportReport> { import_pack_into(lib, path, None) }

/// Imports a `.tlpack`, restoring tags and folders it carries; with `folder`, every post it
/// touches also goes into that folder.
pub fn import_pack_into(lib: &Library, path: &Path, folder: Option<&str>) -> anyhow::Result<ImportReport> {
    let _g = crate::import::begin_in(lib, "tlpack")?;
    let r = import_pack_inner(lib, path, folder);
    crate::import::finish(&r);
    r
}

// What a package may hold when imported; an export that would pass them is refused at once, so
// the app never makes a backup it cannot restore.
const MAX_MANIFEST_BYTES: u64 = 1024 * 1024 * 1024;
const MAX_PACK_ENTRIES: usize = 2_000_000;
/// Longer than any real post id: a post id is in every record of the post and in the sync log.
const MAX_POST_ID_BYTES: usize = 512;
pub(crate) const MAX_MEDIA_BYTES: u64 = 8 * 1024 * 1024 * 1024;
const MAX_PACK_BYTES: u64 = 1024 * 1024 * 1024 * 1024;

fn read_bounded(input: impl Read, limit: u64) -> anyhow::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    input.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit { bail!(tr!("pack.manifestTooBig")); }
    Ok(bytes)
}

fn import_pack_inner(lib: &Library, path: &Path, folder: Option<&str>) -> anyhow::Result<ImportReport> {
    lib.diag_import_start("tlpack");
    let mut z = zip::ZipArchive::new(BufReader::new(File::open(path)?))?;
    if z.len() > MAX_PACK_ENTRIES { bail!(tr!("pack.tooManyFiles")); }
    let manifest: Manifest = serde_json::from_slice(&read_bounded(z.by_name("manifest.json").context(tr!("pack.noManifest"))?, MAX_MANIFEST_BYTES)?)?;
    if manifest.posts.len() > MAX_PACK_ENTRIES || manifest.posts.iter().map(|p| p.media.len()).sum::<usize>() > MAX_PACK_ENTRIES { bail!(tr!("pack.tooManyRecords")); }
    let mut remaining = MAX_PACK_BYTES;
    if manifest.format != FORMAT { bail!(tr!("pack.notPack")); }
    if manifest.version > VERSION { bail!(tr!("pack.newer", version = manifest.version)); }
    let mut rep = ImportReport::default();
    rep.source = path.to_string_lossy().into_owned();
    crate::import::set_progress(|pr| pr.folders_total = manifest.posts.len());
    for p in &manifest.posts {
        if crate::import::cancelled() { rep.incomplete = Some(tr!("import.cancelled")); break; }
        if p.meta.id.len() > MAX_POST_ID_BYTES { rep.issue("unreadable", &p.meta.id.chars().take(40).collect::<String>(), tr!("pack.badPostId"), None); continue; }
        let mut stored = vec![];
        for m in &p.media {
            rep.entries += 1;
            if safe_relative(&m.file).is_none() { rep.issue("unsafe_path", &m.file, tr!("pack.unsafePath"), None); continue; }
            let ext = Path::new(&m.file).extension().and_then(|e| e.to_str()).unwrap_or("bin").to_ascii_lowercase();
            if !crate::rules::valid_ext(ext.as_bytes()) { rep.issue("unsupported", &m.file, tr!("pack.badExt"), None); continue; }
            let tmp = lib.tmp_path();
            let _cleanup = crate::library::TempFile(tmp.clone());
            let mut h = Sha256::new();
            let mut head: Vec<u8> = Vec::with_capacity(16);
            let mut store_failed = None;
            let read = (|| -> anyhow::Result<()> {
                let mut e = z.by_name(&m.file).with_context(|| tr!("pack.missingFile", file = m.file))?;
                if e.size() > MAX_MEDIA_BYTES || e.size() > remaining { bail!(tr!("pack.mediaTooBig")); }
                let mut media_bytes = 0u64;
                let file = File::create(&tmp).inspect_err(|e| store_failed = Some(e.to_string()))?;
                let mut w = BufWriter::new(file);
                let mut buf = vec![0u8; 1 << 20];
                loop {
                    let n = e.read(&mut buf)?;
                    if n == 0 { break; }
                    media_bytes += n as u64;
                    if media_bytes > MAX_MEDIA_BYTES || n as u64 > remaining { bail!(tr!("pack.mediaTooBig")); }
                    remaining -= n as u64;
                    if head.len() < 16 { head.extend_from_slice(&buf[..n.min(16 - head.len())]); }
                    h.update(&buf[..n]); w.write_all(&buf[..n]).inspect_err(|e| store_failed = Some(e.to_string()))?;
                }
                w.flush().and_then(|_| w.get_ref().sync_all()).inspect_err(|e| store_failed = Some(e.to_string()))?;
                Ok(())
            })();
            if let Some(why) = store_failed { rep.incomplete = Some(why); }
            if let Err(e) = read { let _ = fs::remove_file(&tmp); rep.issue("unreadable", &m.file, format!("{e:#}"), None); continue; }
            let sha = hex::encode(h.finalize());
            if sha != m.sha256 { let _ = fs::remove_file(&tmp); rep.issue("unreadable", &m.file, tr!("pack.damaged"), None); continue; }
            // the same content check as downloads and imports: a matching checksum only proves the
            // file is what the package says, not that it is a picture or a video
            let photo = m.kind == MediaKind::Photo;
            let sn = crate::rules::sniff(&head);
            if !crate::rules::sniff_ok(sn, photo) { let _ = fs::remove_file(&tmp); rep.issue("not_media", &m.file, Library::not_media_reason(sn, photo), None); continue; }
            let rel = lib.commit_tmp(&tmp, &sha, &ext)?;
            crate::import::set_progress(|pr| { pr.files_done += 1; pr.current = Some(lib.dir.join(&rel).to_string_lossy().into_owned()); });
            stored.push((m, rel));
        }
        crate::import::set_progress(|pr| { pr.folders_done += 1; pr.issues = rep.issues.len(); });
        if stored.is_empty() { continue; }
        {
            let db = lib.db();
            let tx = db.conn().unchecked_transaction()?;
            let mut drop_files = vec![];
            if db.post_meta(&p.meta.id)?.is_some() { rep.merged_posts += 1; }
            // fields beyond their limits are cut (see `PostMeta::clamped`), and the report says so
            let (meta, cut) = p.meta.clamped();
            for field in cut { rep.issue("post_text_truncated", &p.meta.id, tr!("import.fieldCut", id = p.meta.id, field = crate::i18n::text(field)), None); }
            db.upsert_post_checked(&meta, |id, ext| lib.dir.join(crate::oplog::blob_rel(id, ext)).exists())?;
            for (m, rel) in &stored {
                rep.note_file(&m.sha256, &m.file, &p.meta.id);
                let existed = db.media_row(&m.sha256)?.is_some();
                // a backup's binned media goes back to the bin only when it is new here
                let new_here = crate::rules::restore_to_bin(true, db.media_row(&m.sha256)?.is_some(), db.trash_reg(&m.sha256)?);
                if db.media_row(&m.sha256)?.is_some() && db.trash_reg(&m.sha256)?.state == crate::rules::LIVE { rep.duplicate_media += 1; }
                // Media in the recycle bin or deleted stay that way (restore them from the bin).
                if !db.add_media(&m.sha256, &p.meta.id, m.ordinal, &m.kind, rel, false)? {
                    rep.deleted += 1;
                    if db.trash_reg(&m.sha256)?.state == crate::rules::PURGED { drop_files.push((m.sha256.clone(), rel.clone())); }
                    else { db.blob_arrived(&m.sha256)?; }
                    continue;
                }
                for t in &m.tags {
                    db.tag_media(&m.sha256, &t.label, Origin(t.origin & 3))?;
                    for model in &t.models { db.set_tag_source(&m.sha256, &t.label, model, true)?; }
                }
                if !existed { rep.new_media += 1; }
                for model in &m.ai_models { db.mark_ai_done(&m.sha256, model)?; }
                for f in &m.folders { db.add_to_folder(f, &[m.sha256.clone()])?; }
                if m.album { db.mark_album(&m.sha256)?; }
                if m.trashed && new_here { db.trash_action(&m.sha256, crate::rules::TrashAction::Trash)?; rep.to_bin += 1; }
                rep.media += 1;
            }
            if p.recent_at != 0 { db.mark_recent(&p.meta.id, p.recent_at)?; }
            tx.commit()?;
            // still under the store lock: the state is checked again as each copy is removed
            for (sha, rel) in drop_files { lib.drop_purged_copy(&db, &sha, &rel); }
        }
        rep.posts += 1;
        rep.ids.push(p.meta.id.clone());
    }
    // the other posts a media belongs to, for media that came in
    for c in &manifest.also_claimed {
        if c.post.id.len() > MAX_POST_ID_BYTES { continue; }
        let db = lib.db();
        let Some((_, _, kind, rel)) = db.media_row(&c.media)? else { continue };
        let kind = if kind == "video" { MediaKind::Video } else { MediaKind::Photo };
        let tx = db.conn().unchecked_transaction()?;
        let (meta, _) = c.post.clamped();
        db.upsert_post_checked(&meta, |id, ext| lib.dir.join(crate::oplog::blob_rel(id, ext)).exists())?;
        db.add_media(&c.media, &meta.id, c.ordinal, &kind, &rel, false)?;
        tx.commit()?;
    }
    {
        let db = lib.db();
        let tx = db.conn().unchecked_transaction()?;
        let have: Vec<String> = db.folders()?.into_iter().map(|(n, _)| n).collect();
        for f in &manifest.folders_all {
            if !have.contains(f) { db.create_folder(f)?; rep.folders_restored += 1; }
        }
        for (old, shown) in &manifest.renames {
            // only where this library has no rule of its own for that name
            if db.restore_rename(old, shown)? { rep.renames_restored += 1; }
        }
        tx.commit()?;
    }
    lib.import_into_folder(&mut rep, folder)?;
    lib.finish_report(&mut rep)?;
    Ok(rep)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A share's package goes away only when what is missing cannot come in later: a device that
    /// cannot store a file says so in `incomplete`, a damaged package only in `issues`.
    #[test]
    fn a_package_says_when_it_can_be_tried_again() {
        use std::os::unix::fs::PermissionsExt;
        let d = tmpdir("incomplete");
        let lib = Library::open(d.join("a")).unwrap();
        let file = d.join("x.png");
        fs::write(&file, b"\x89PNG\r\n\x1a\nsynthetic").unwrap();
        let (sha, rel) = lib.put_file(&file, &MediaKind::Photo, "png").unwrap();
        {
            let db = lib.db();
            db.upsert_post_checked(&PostMeta { id: "1".into(), ..Default::default() }, |_, _| true).unwrap();
            db.add_media(&sha, "1", 0, &MediaKind::Photo, &rel, false).unwrap();
        }
        let out = d.join("p.tlpack");
        export_backup(&lib, &out).unwrap();

        let other = Library::open(d.join("b")).unwrap();
        let tmp = other.dir.join("tmp");
        fs::create_dir_all(&tmp).unwrap();
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o500)).unwrap();
        let blocked = import_pack(&other, &out).unwrap();
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(blocked.incomplete.is_some(), "{blocked:?}");
        let again = import_pack(&other, &out).unwrap();
        assert_eq!((again.incomplete.clone(), again.new_media), (None, 1), "{again:?}");

        let damaged = d.join("damaged.tlpack");
        let (input, output) = (File::open(&out).unwrap(), File::create(&damaged).unwrap());
        let mut z = zip::ZipArchive::new(input).unwrap();
        let mut w = zip::ZipWriter::new(output);
        let stored = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        for i in 0..z.len() {
            let mut e = z.by_index(i).unwrap();
            let name = e.name().to_string();
            let mut bytes = vec![];
            e.read_to_end(&mut bytes).unwrap();
            if name != "manifest.json" { bytes.push(0); }
            w.start_file(name, stored).unwrap();
            w.write_all(&bytes).unwrap();
        }
        w.finish().unwrap();
        let third = Library::open(d.join("c")).unwrap();
        let bad = import_pack(&third, &damaged).unwrap();
        assert!(bad.incomplete.is_none() && !bad.issues.is_empty(), "{bad:?}");
    }

    /// Two posts share one file: the backup keeps both, though a feed lists it under one.
    #[test]
    fn a_backup_keeps_every_post_a_media_belongs_to() {
        let d = tmpdir("claims");
        let lib = Library::open(d.join("a")).unwrap();
        let file = d.join("x.png");
        fs::write(&file, b"\x89PNG\r\n\x1a\nsynthetic").unwrap();
        let kind = MediaKind::Photo;
        let (sha, rel) = lib.put_file(&file, &kind, "png").unwrap();
        {
            let db = lib.db();
            for id in ["1", "2"] {
                let meta = PostMeta { id: id.into(), text: Some(format!("post {id}")), ..Default::default() };
                db.upsert_post_checked(&meta, |_, _| true).unwrap();
                db.add_media(&sha, id, 0, &kind, &rel, false).unwrap();
            }
        }
        let out = d.join("b.tlpack");
        export_backup(&lib, &out).unwrap();
        let back = Library::open(d.join("b")).unwrap();
        import_pack(&back, &out).unwrap();
        let db = back.db();
        assert!(db.post_meta("1").unwrap().is_some());
        assert_eq!(db.post_meta("2").unwrap().and_then(|m| m.text).as_deref(), Some("post 2"));
        let claims: i64 = db.conn().query_row("SELECT count(*) FROM media_claim", [], |r| r.get(0)).unwrap();
        assert_eq!(claims, 2);
    }
    use crate::model::SearchScope;
    use crate::library::FeedRequest;

    fn tmpdir(n: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("tl-arch-{}-{}", n, std::process::id()));
        let _ = fs::remove_dir_all(&d); fs::create_dir_all(&d).unwrap(); d
    }

    #[test]
    fn safe_paths() {
        assert!(safe_relative("../x").is_none());
        assert!(safe_relative("/etc/passwd").is_none());
        assert_eq!(safe_relative("a/./b").unwrap(), PathBuf::from("a/b"));
    }

    #[test]
    fn zip_with_wrapper_and_gbk() {
        let d = tmpdir("zip");
        let zp = d.join("in.zip");
        {
            let mut z = zip::ZipWriter::new(File::create(&zp).unwrap());
            let o = zip::write::SimpleFileOptions::default();
            z.start_file("根文件夹/帖子A/1.jpg", o).unwrap(); z.write_all(&crate::testutil::jpg(b"x")).unwrap();
            z.start_file("根文件夹/帖子B/2.mp4", o).unwrap(); z.write_all(b"\0\0\0\x18ftypisomY").unwrap();
            z.start_file("根文件夹/帖子B/推文内容.txt", o).unwrap(); z.write_all("推文 ID: 5\n【推文完整正文】\n正文".as_bytes()).unwrap();
            z.start_file("__MACOSX/根文件夹/._x", o).unwrap(); z.write_all(b"junk").unwrap();
            z.finish().unwrap();
        }
        let lib = Library::open(d.join("lib")).unwrap();
        let r = import_legacy_zip(&lib, &zp).unwrap();
        assert_eq!((r.posts, r.media), (2, 2));
        assert_eq!(entry_name(&encoding_rs::GBK.encode("帖子").0), "帖子");
    }

    /// The zip importer streams entries (no extracted copy), reads GBK sidecars, ignores hidden
    /// and __MACOSX entries, and never brings back media from the recycle bin or deleted ones.
    #[test]
    fn zip_import_streams_and_respects_the_bin() {
        use crate::rules::TrashAction;
        let d = tmpdir("zipbin");
        let zp = d.join("in.zip");
        {
            let mut z = zip::ZipWriter::new(File::create(&zp).unwrap());
            let o = zip::write::SimpleFileOptions::default();
            z.start_file("包/帖子A/1.jpg", o).unwrap(); z.write_all(&crate::testutil::jpg(b"one")).unwrap();
            z.start_file("包/帖子A/2.mp4", o).unwrap(); z.write_all(b"\0\0\0\x18ftypisomTWO").unwrap();
            z.start_file("包/帖子A/.DS_Store", o).unwrap(); z.write_all(b"x").unwrap();
            z.start_file("包/帖子A/推文内容.txt", o).unwrap(); z.write_all(&encoding_rs::GBK.encode("推文 ID: 77\n【推文完整正文】\n中文正文").0).unwrap();
            z.start_file("包/.hidden/3.jpg", o).unwrap(); z.write_all(&crate::testutil::jpg(b"no")).unwrap();
            z.start_file("__MACOSX/包/._1.jpg", o).unwrap(); z.write_all(&crate::testutil::jpg(b"junk")).unwrap();
            z.finish().unwrap();
        }
        let lib = Library::open(d.join("lib")).unwrap();
        let r = import_legacy_zip(&lib, &zp).unwrap();
        assert_eq!((r.posts, r.media, r.deleted), (1, 2, 0));
        let tmp_left = fs::read_dir(lib.dir.join("tmp")).map_or(0, |rd| rd.count());
        assert_eq!(tmp_left, 0, "nothing extracted or left behind");
        let req = FeedRequest { newest_first: false, terms: vec![], scope: SearchScope::Both, seed: None, fuzzy: true, term_vectors: vec![], embed_model: None, threshold: 0.7, fields: Default::default(), filter: Default::default() };
        let items = lib.feed(&req).unwrap();
        assert!(items.iter().all(|i| i.post_id == "77" && i.text.as_deref() == Some("中文正文")));
        let one = hex::encode(Sha256::digest(crate::testutil::jpg(b"one")));
        lib.trash_apply(&[one.clone()], TrashAction::Trash).unwrap();
        let r = import_legacy_zip(&lib, &zp).unwrap();
        assert_eq!((r.media, r.deleted), (1, 1), "binned media stay in the bin");
        assert_eq!(lib.feed(&req).unwrap().len(), 1);
        lib.trash_apply(&[one.clone()], TrashAction::Purge).unwrap();
        let blob = lib.dir.join(crate::oplog::blob_rel(&one, "jpg"));
        assert!(!blob.exists());
        let r = import_legacy_zip(&lib, &zp).unwrap();
        assert_eq!(r.deleted, 1);
        assert!(!blob.exists(), "a deleted file is not left behind by a re-import");
        // retention: nothing expires early; a month later it does
        let two = hex::encode(Sha256::digest(crate::testutil::jpg(b"\0\0\0\x18ftypisomTWO")));
        lib.trash_apply(&[two.clone()], TrashAction::Trash).unwrap();
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64;
        assert_eq!(lib.expire_trash(now).unwrap(), 0);
        lib.set_trash_keep_days(0).unwrap();
        assert_eq!(lib.expire_trash(now + 400 * 86_400_000).unwrap(), 0, "0 = keep forever");
        lib.set_trash_keep_days(30).unwrap();
        assert_eq!(lib.expire_trash(now + 31 * 86_400_000).unwrap(), 1);
        assert_eq!(lib.db().stats().unwrap().trashed, 0);
    }

    /// What is shared from another app is 从相册导入; what is dropped on a window is only loose.
    #[test]
    fn dropped_media_is_loose_without_the_album_mark() {
        let d = tmpdir("dropped");
        for (name, album) in [("shared", true), ("dropped", false)] {
            let src = d.join(name);
            fs::create_dir_all(&src).unwrap();
            fs::write(src.join("1.jpg"), crate::testutil::jpg(name.as_bytes())).unwrap();
            let lib = Library::open(d.join(format!("lib-{name}"))).unwrap();
            crate::import::import_loose_dir_keep(&lib, &src, None, true, None, album).unwrap();
            let all = lib.feed(&FeedRequest { newest_first: false, terms: vec![], scope: SearchScope::Both, seed: Some(0), fuzzy: true, term_vectors: vec![], embed_model: None, threshold: 0.7, fields: Default::default(), filter: Default::default() }).unwrap();
            assert_eq!(all.len(), 1);
            assert!(all[0].post_id.starts_with("loose:"), "both are loose");
            assert_eq!(all[0].album, album);
        }
    }

    /// Re-download of a damaged media from a post without a link falls back to peers.
    #[test]
    fn repair_without_link_asks_peers() {
        let d = tmpdir("repair");
        let src = d.join("src/没有链接的帖子");
        fs::create_dir_all(&src).unwrap();
        fs::write(src.join("1.jpg"), crate::testutil::jpg(b"orig")).unwrap();
        let lib = Library::open(d.join("lib")).unwrap();
        lib.import_legacy_dir(&d.join("src")).unwrap();
        let id = hex::encode(Sha256::digest(crate::testutil::jpg(b"orig")));
        let rt = crate::download::runtime();
        assert!(rt.block_on(crate::download::repair(&lib, &id)).is_err(), "intact file without a link: nothing to do");
        fs::write(lib.dir.join(crate::oplog::blob_rel(&id, "jpg")), b"damaged").unwrap();
        assert_eq!(rt.block_on(crate::download::repair(&lib, &id)).unwrap(), crate::download::Repair::FromPeers);
        assert_eq!(lib.db().bad_reason(&id).unwrap().as_deref(), Some("hash"));
        assert_eq!(lib.db().wanted_blobs(10).unwrap(), vec![(id.clone(), "jpg".to_string())], "a verified copy is requested from peers");
        // The app reporting an undecodable but intact file marks it 'decode' (not re-fetched).
        fs::write(lib.dir.join(crate::oplog::blob_rel(&id, "jpg")), crate::testutil::jpg(b"orig")).unwrap();
        assert_eq!(lib.report_bad(&id).unwrap().as_deref(), Some("decode"));
        assert!(lib.db().wanted_blobs(10).unwrap().is_empty());
    }

    #[test]
    fn export_only_the_given_media_with_post_text() {
        let d = tmpdir("pack");
        let src = d.join("src/帖子");
        fs::create_dir_all(&src).unwrap();
        for (n, b) in [("1.jpg", "a"), ("2.jpg", "b"), ("3.jpg", "c")] { fs::write(src.join(n), crate::testutil::jpg(b.as_bytes())).unwrap(); }
        let lib = Library::open(d.join("lib")).unwrap();
        lib.import_legacy_dir(&d.join("src")).unwrap();
        let all = lib.feed(&FeedRequest { newest_first: false, terms: vec![], scope: SearchScope::Both, seed: Some(0), fuzzy: true, term_vectors: vec![], embed_model: None, threshold: 0.7, fields: Default::default(), filter: Default::default() }).unwrap();
        let mut ids: Vec<_> = all.iter().map(|i| (i.ordinal, i.media_id.clone())).collect(); ids.sort();
        lib.tag(&ids[0].1, "A", Origin::USER).unwrap();
        lib.tag(&ids[1].1, "A", Origin::AI).unwrap();
        let out = d.join("a.tlpack");
        let rep = export_media(&lib, &[ids[0].1.clone(), ids[1].1.clone()], Default::default(), &out).unwrap();
        assert_eq!((rep.posts, rep.media), (1, 2), "only the media asked for are exported, not the third");

        let lib2 = Library::open(d.join("lib2")).unwrap();
        let r = import_pack(&lib2, &out).unwrap();
        assert_eq!(r.media, 2);
        let got = lib2.feed(&FeedRequest { newest_first: false, terms: vec!["a".into()], scope: SearchScope::Ai, seed: Some(0), fuzzy: false, term_vectors: vec![], embed_model: None, threshold: 0.7, fields: Default::default(), filter: Default::default() }).unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].text.as_deref(), Some("帖子"));
    }

    #[test]
    fn export_media_leaves_out_binned_and_unknown_ids_and_honours_the_switches() {
        let d = tmpdir("pack3");
        let src = d.join("src/帖子");
        fs::create_dir_all(&src).unwrap();
        for (n, b) in [("1.jpg", "a"), ("2.jpg", "b"), ("3.jpg", "c")] { fs::write(src.join(n), crate::testutil::jpg(b.as_bytes())).unwrap(); }
        let lib = Library::open(d.join("lib")).unwrap();
        lib.import_legacy_dir(&d.join("src")).unwrap();
        let ids: Vec<String> = lib.db().export_items(&[], &[]).unwrap().into_iter().map(|i| i.media_id).collect();
        lib.tag(&ids[0], "海", Origin::USER).unwrap();
        lib.db().add_to_folder("旅行", &[ids[0].clone()]).unwrap();
        lib.db().trash_action(&ids[1], crate::rules::TrashAction::Trash).unwrap();
        let asked = vec![ids[0].clone(), ids[1].clone(), "不存在".to_string()];
        // both switches off: the media and the post, nothing about tags or folders
        let out = d.join("plain.tlpack");
        let rep = export_media(&lib, &asked, ExportOptions { tags: false, folders: false, media_only: false }, &out).unwrap();
        assert_eq!(rep.media, 1, "the binned and the unknown id are not exported");
        let lib2 = Library::open(d.join("lib2")).unwrap();
        import_pack(&lib2, &out).unwrap();
        assert!(lib2.db().media_tags(&ids[0]).unwrap().is_empty() && lib2.db().folders_of(&ids[0]).unwrap().is_empty());
        // both on
        let out2 = d.join("full.tlpack");
        export_media(&lib, &asked, ExportOptions::default(), &out2).unwrap();
        let lib3 = Library::open(d.join("lib3")).unwrap();
        import_pack(&lib3, &out2).unwrap();
        assert_eq!(lib3.db().media_tags(&ids[0]).unwrap().len(), 1);
        assert_eq!(lib3.db().folders_of(&ids[0]).unwrap(), vec!["旅行".to_string()]);
        // nothing to export is an error, not an empty file
        assert!(export_media(&lib, &["不存在".to_string()], Default::default(), &d.join("none.tlpack")).is_err());
    }

    #[test]
    fn tags_and_provenance_roundtrip() {
        let d = tmpdir("pack2");
        let src = d.join("src/帖子");
        fs::create_dir_all(&src).unwrap();
        for (n, b) in [("1.jpg", "a"), ("2.jpg", "b"), ("3.jpg", "c")] { fs::write(src.join(n), crate::testutil::jpg(b.as_bytes())).unwrap(); }
        let lib = Library::open(d.join("lib")).unwrap();
        lib.import_legacy_dir(&d.join("src")).unwrap();
        let req = FeedRequest { newest_first: false, terms: vec![], scope: SearchScope::Both, seed: Some(0), fuzzy: true, term_vectors: vec![], embed_model: None, threshold: 0.7, fields: Default::default(), filter: Default::default() };
        let mut ids: Vec<_> = lib.feed(&req).unwrap().iter().map(|i| (i.ordinal, i.media_id.clone())).collect(); ids.sort();
        // media0: A (AI, by model m1, endorsed) ; media1: A + B ; media2: B
        lib.apply_ai_tags(&ids[0].1, "m1", &["a".into()], false).unwrap();
        lib.tag(&ids[0].1, "a", Origin::USER).unwrap();
        lib.tag(&ids[1].1, "a", Origin::USER).unwrap();
        lib.tag(&ids[1].1, "b", Origin::USER).unwrap();
        lib.tag(&ids[2].1, "b", Origin::USER).unwrap();
        let out = d.join("x.tlpack");
        let rep = export_media(&lib, &[ids[0].1.clone()], Default::default(), &out).unwrap();
        assert_eq!(rep.media, 1);

        let lib2 = Library::open(d.join("lib2")).unwrap();
        import_pack(&lib2, &out).unwrap();
        let got = lib2.feed(&req).unwrap();
        assert_eq!(got.len(), 1);
        let t = &got[0].tags[0];
        assert_eq!((t.label.as_str(), t.origin, t.models.clone()), ("a", 3, vec!["m1".to_string()]), "origin and model provenance survive");
        assert!(lib2.db().media_needing_ai(10).unwrap().is_empty(), "analysed-by record survives");
    }

    /// However a repeat arrives (inside one import, against the library, part of it new, in the
    /// bin), each file is one media, nothing is lost, and the report accounts for every repeat.
    #[test]
    fn repeats_inside_an_import_and_against_the_library() {
        use crate::rules::TrashAction::Trash;
        let d = tmpdir("repeats");
        let lib = Library::open(d.join("lib")).unwrap();
        let live = |l: &Library| l.db().export_items(&[], &[]).unwrap().len();
        let (a, b, c) = (crate::testutil::jpg(b"a"), crate::testutil::jpg(b"b"), crate::testutil::jpg(b"c"));
        let zip_of = |name: &str, files: &[(&str, &Vec<u8>)]| {
            let zp = d.join(name);
            let mut z = zip::ZipWriter::new(File::create(&zp).unwrap());
            let o = zip::write::SimpleFileOptions::default();
            for (n, bytes) in files { z.start_file(*n, o).unwrap(); z.write_all(bytes).unwrap(); }
            z.finish().unwrap();
            zp
        };
        // the same file twice inside one post, and in two posts of one archive
        let r = crate::import::import_zip(&lib, &zip_of("self.zip", &[("根/甲/1.jpg", &a), ("根/甲/2.jpg", &a), ("根/乙/1.jpg", &a), ("根/乙/2.jpg", &b)]), None).unwrap();
        assert_eq!(r.new_media, 2);
        assert_eq!(live(&lib), 2);
        assert_eq!(r.new_media + r.duplicate_media, r.media, "every file counted once");
        assert!(r.duplicate_media >= 2 && r.issues.iter().filter(|i| i.category == "duplicate").count() == r.duplicate_media, "each repeat listed");
        // all of it again: nothing new, nothing lost
        let r = crate::import::import_zip(&lib, &zip_of("again.zip", &[("根/甲/1.jpg", &a), ("根/甲/2.jpg", &a), ("根/乙/1.jpg", &a), ("根/乙/2.jpg", &b)]), None).unwrap();
        assert_eq!(r.new_media, 0);
        assert_eq!(live(&lib), 2);
        // partly new, under another extension too
        let r = crate::import::import_zip(&lib, &zip_of("part.zip", &[("根/丙/1.jpeg", &a), ("根/丙/2.jpg", &c)]), None).unwrap();
        assert_eq!(r.new_media, 1);
        assert_eq!(live(&lib), 3);
        // loose: repeats inside the zip, and of what the library has
        let r = crate::import::import_loose_zip(&lib, &zip_of("loose.zip", &[("x.jpg", &a), ("y/x.jpg", &a), ("z.jpg", &crate::testutil::jpg(b"d")), ("w.jpg", &crate::testutil::jpg(b"d"))]), None).unwrap();
        assert_eq!(r.new_media, 1);
        assert_eq!(live(&lib), 4);
        // a media in the bin stays there, its repeat is reported
        let sha = hex::encode(Sha256::digest(&c));
        lib.trash_apply(&[sha.clone()], Trash).unwrap();
        let r = crate::import::import_loose_zip(&lib, &zip_of("bin.zip", &[("c.jpg", &c)]), None).unwrap();
        assert_eq!((r.new_media, r.deleted), (0, 1));
        assert_eq!(live(&lib), 3);
        assert!(lib.dir.join(lib.db().media_row(&sha).unwrap().unwrap().3).exists(), "its file is kept for a restore");
        // a pack of this library, imported into itself and into a library sharing part of it
        let out = d.join("all.tlpack");
        export_backup(&lib, &out).unwrap();
        let r = import_pack(&lib, &out).unwrap();
        assert_eq!(r.new_media, 0);
        assert_eq!(live(&lib), 3);
        let other = Library::open(d.join("other")).unwrap();
        crate::import::import_zip(&other, &zip_of("o.zip", &[("根/甲/1.jpg", &a), ("根/新/1.jpg", &crate::testutil::jpg(b"own"))]), None).unwrap();
        let r = import_pack(&other, &out).unwrap();
        assert!(r.new_media >= 2, "{}", r.new_media);
        assert_eq!(live(&other), 4, "theirs, ours, the repeat once");
        // an import with a folder takes in the repeats too
        let r = crate::import::import_zip(&lib, &zip_of("f.zip", &[("根/甲/1.jpg", &a)]), Some("夹")).unwrap();
        assert_eq!(r.new_media, 0);
        assert!(r.folder_added >= 1);
    }

    #[test]
    fn media_only_zip_has_every_file_at_its_root_and_no_manifest() {
        let d = tmpdir("plainzip");
        let src = d.join("src/今天/的帖子");
        fs::create_dir_all(&src).unwrap();
        let files = [("1.jpg", "a"), ("2.jpg", "b")];
        for (n, b) in files { fs::write(src.join(n), crate::testutil::jpg(b.as_bytes())).unwrap(); }
        let lib = Library::open(d.join("lib")).unwrap();
        lib.import_legacy_dir(&d.join("src/今天")).unwrap();
        let out = d.join("m.zip");
        let opts = ExportOptions { media_only: true, ..Default::default() };
        let all: Vec<String> = lib.db().export_items(&[], &[]).unwrap().into_iter().map(|i| i.media_id).collect();
        let rep = export_media(&lib, &all, opts, &out).unwrap();
        assert_eq!(rep.media, 2);
        let mut z = zip::ZipArchive::new(File::open(&out).unwrap()).unwrap();
        let mut names: Vec<String> = (0..z.len()).map(|i| z.by_index(i).unwrap().name().to_string()).collect();
        names.sort();
        assert_eq!(names.len(), 2, "{names:?}");
        assert!(names.iter().all(|n| !n.contains("manifest") && n.ends_with(".jpg") && !n.contains('/')), "{names:?}");
        assert!(names[0].ends_with(" - 1.jpg") && names[1].ends_with(" - 2.jpg"), "numbered in post order: {names:?}");
        // the files are the originals, byte for byte
        let mut got = vec![];
        z.by_name(&names[0]).unwrap().read_to_end(&mut got).unwrap();
        assert_eq!(got, crate::testutil::jpg(b"a"));
        assert_eq!(plain_name("a/b:c?.. "), "a_b_c_");
        assert_eq!(plain_name("..."), "_");
    }

    #[test]
    fn folder_overview_counts_covers_and_kind_filter() {
        let d = tmpdir("overview");
        let src = d.join("src/帖子");
        fs::create_dir_all(&src).unwrap();
        for (n, b) in [("1.jpg", "a"), ("2.jpg", "b")] { fs::write(src.join(n), crate::testutil::jpg(b.as_bytes())).unwrap(); }
        let lib = Library::open(d.join("lib")).unwrap();
        lib.import_legacy_dir(&d.join("src")).unwrap();
        let req = |kind| FeedRequest { newest_first: false, terms: vec![], scope: SearchScope::Both, seed: Some(0), fuzzy: true, term_vectors: vec![], embed_model: None, threshold: 0.7, fields: Default::default(),
            filter: crate::library::FeedFilter { kind, ..Default::default() } };
        let all = lib.feed(&req(None)).unwrap();
        assert_eq!(all.len(), 2);
        assert_eq!(lib.feed(&req(Some(MediaKind::Photo))).unwrap().len(), 2);
        assert_eq!(lib.feed(&req(Some(MediaKind::Video))).unwrap().len(), 0);
        lib.db().create_folder("空").unwrap();
        lib.db().add_to_folder("夹", &[all[0].media_id.clone()]).unwrap();
        lib.db().add_to_folder("夹", &[all[1].media_id.clone()]).unwrap();
        let v = lib.folder_overview().unwrap();
        assert_eq!((v["photos"].as_i64(), v["videos"].as_i64()), (Some(2), Some(0)));
        let f = &v["folders"];
        assert_eq!(f[0]["name"], "夹");
        assert_eq!(f[0]["count"], 2);
        assert_eq!(f[0]["cover_id"], all[1].media_id.as_str(), "the cover is the media added last");
        assert!(Path::new(f[0]["cover_path"].as_str().unwrap()).exists(), "cover path resolved to the file");
        assert_eq!((f[1]["name"].as_str(), f[1]["count"].as_i64()), (Some("空"), Some(0)));
        assert!(f[1]["cover_path"].is_null(), "an empty folder has no cover");
        // a binned media no longer counts and is no longer the cover
        lib.trash_apply(&[all[1].media_id.clone()], crate::rules::TrashAction::Trash).unwrap();
        let v = lib.folder_overview().unwrap();
        assert_eq!(v["folders"][0]["count"], 1);
        assert_eq!(v["folders"][0]["cover_id"], all[0].media_id.as_str());
    }
}

#[cfg(test)]
mod chatgpt_limit_tests {
    use super::*;
    #[test]
    fn manifest_read_limit_is_enforced_on_actual_bytes() {
        assert_eq!(read_bounded(&b"1234"[..], 4).unwrap(), b"1234");
        assert!(read_bounded(&b"12345"[..], 4).is_err());
        assert!(read_bounded(std::io::repeat(0), 16).is_err());
    }
}
