//! Legacy import (ZIP or folder) with full accounting: every entry of the source ends up in
//! exactly one bucket — a new media, a duplicate, a sidecar, a system file, or an issue with its
//! path and reason. Nothing is dropped silently. The report is saved next to the library's logs
//! and the problem files can be exported unchanged.
use crate::library::{decode_text, kind_for, legacy_post_meta, Library};
use crate::legacy::SIDECAR_NAME;
use crate::model::MediaKind;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::fs::{self, File};
use std::io::{BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// One thing the import did not take as a normal new media.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ImportIssue {
    /// not_media · unsupported · unreadable · duplicate · in_bin · ignored_location · unsafe_path
    /// (files) · post_not_imported · post_hidden · post_merged · post_text_truncated (folders).
    pub category: String,
    /// Path inside the ZIP / folder.
    pub path: String,
    pub reason: String,
    /// For duplicates and hidden or merged posts: the file or folder it matches.
    pub same_as: Option<String>,
}

impl ImportIssue {
    pub fn is_file(&self) -> bool { !self.category.starts_with("post_") }
}

#[derive(Debug, Serialize, Deserialize, Default, Clone)]
pub struct ImportReport {
    /// Post folders imported (that produced a post) and media files stored (new + duplicates).
    pub posts: usize,
    pub media: usize,
    /// Paths of file-level issues (kept for older app versions).
    pub skipped: Vec<String>,
    /// Media left alone because they are in the recycle bin or were deleted.
    pub deleted: usize,
    /// Files whose content is identical to another file (stored once).
    pub duplicate_media: usize,
    /// Folders whose post ID was already in the library or in an earlier folder.
    pub merged_posts: usize,
    /// Imported posts that own no media of their own (all files duplicate other posts' files).
    pub posts_without_media: usize,
    // ---- full accounting ----
    /// Every non-folder entry in the source…
    pub entries: usize,
    /// …is a system file (hidden / __MACOSX), a sidecar, a new media, a duplicate, left in the
    /// bin, or a file issue: `entries == system_files + sidecars + new_media + duplicate_media + deleted + file issues`.
    pub system_files: usize,
    pub sidecars: usize,
    pub new_media: usize,
    pub folders: usize,
    pub issues: Vec<ImportIssue>,
    /// Absolute path of the saved report (for viewing and exporting the problem files).
    pub report_file: Option<String>,
    pub source: String,
    /// The folder the import put its posts into (every live media of every touched post).
    #[serde(default)] pub folder: Option<String>,
    #[serde(default)] pub folder_added: usize,
    /// Media a backup carried as "in the recycle bin" that were new here: put back into the bin.
    #[serde(default)] pub to_bin: usize,
    /// Rename rules and empty folders a backup restored.
    #[serde(default)] pub renames_restored: usize,
    #[serde(default)] pub folders_restored: usize,
    /// Why this import stopped short with something it could still do later (it was cancelled, or
    /// this device could not store a file): keep the source and try again. A source that is itself
    /// damaged does not get better: that is in `issues` only.
    #[serde(default)] pub incomplete: Option<String>,
    #[serde(skip)] pub ids: Vec<String>,
    #[serde(skip)] first_by_sha: HashMap<String, String>,
    #[serde(skip)] folder_by_post: HashMap<String, String>,
    #[serde(skip)] shas_by_post: HashMap<String, Vec<String>>,
}

impl ImportReport {
    /// Records where a stored file came from and which post it belongs to (for "already in
    /// the library as …" messages and for putting the import into a folder).
    pub(crate) fn note_file(&mut self, sha: &str, src: &str, post_id: &str) {
        self.shas_by_post.entry(post_id.to_string()).or_default().push(sha.to_string());
        self.first_by_sha.entry(sha.to_string()).or_insert_with(|| src.to_string());
    }

    pub fn file_issue_count(&self) -> usize { self.issues.iter().filter(|i| i.is_file() && i.category != "duplicate" && i.category != "in_bin").count() }
    pub(crate) fn issue(&mut self, category: &str, path: &str, reason: impl Into<String>, same_as: Option<String>) {
        let i = ImportIssue { category: category.into(), path: path.into(), reason: reason.into(), same_as };
        if i.is_file() && category != "duplicate" && category != "in_bin" { self.skipped.push(i.path.clone()); }
        self.issues.push(i);
    }
}

// ---------- progress ----------

#[derive(Debug, Clone, Serialize, Default)]
pub struct ImportProgress {
    pub outcome: String,
    pub running: bool,
    pub kind: String,
    pub folders_done: usize,
    pub folders_total: usize,
    pub files_done: usize,
    pub issues: usize,
    /// Absolute path of the most recently stored media (for the progress card's preview).
    pub current: Option<String>,
    /// Another import is running; this one starts when it finishes.
    pub waiting: bool,
}

static PROGRESS: Mutex<Option<ImportProgress>> = Mutex::new(None);
/// One import at a time: a second one waits (its progress says so) instead of interleaving.
static IMPORT_LOCK: Mutex<()> = Mutex::new(());
static CANCEL: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// Stops a running import after the current post folder (used by "clear all data").
pub fn cancel() { CANCEL.store(true, std::sync::atomic::Ordering::SeqCst); }
pub(crate) fn cancelled() -> bool { CANCEL.load(std::sync::atomic::Ordering::SeqCst) }

/// Serializes imports; returns the guard to hold while importing.
pub fn begin(kind: &str) -> std::sync::MutexGuard<'static, ()> {
    let g = match IMPORT_LOCK.try_lock() {
        Ok(g) => g,
        Err(_) => {
            set_progress(|p| { p.waiting = true; });
            IMPORT_LOCK.lock().unwrap_or_else(|e| e.into_inner())
        }
    };
    CANCEL.store(false, std::sync::atomic::Ordering::SeqCst);
    *PROGRESS.lock().unwrap() = Some(ImportProgress { running: true, outcome: "running".into(), kind: kind.into(), ..Default::default() });
    g
}
/// `begin` for an import into `lib`. An import that was queued behind another one while the
/// library was wiped is dropped: what it was going to import was meant for the library that is
/// gone, and must not fill the new one (the wipe cancels the running import and waits for the
/// lock, but an import already waiting for it would run after the wipe).
pub(crate) fn begin_in(lib: &Library, kind: &str) -> anyhow::Result<std::sync::MutexGuard<'static, ()>> {
    let epoch = lib.epoch();
    let g = begin(kind);
    if lib.epoch() != epoch { end(); anyhow::bail!(tr!("import.wipedWhileWaiting")); }
    Ok(g)
}
/// Stops a running import and waits until it has left the library (for "clear all data").
pub fn stop_and_wait() -> std::sync::MutexGuard<'static, ()> {
    cancel();
    IMPORT_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}
pub fn end() { set_progress(|p| { p.running = false; p.waiting = false; p.outcome = "cancelled".into(); }); }
pub(crate) fn finish<T>(result: &anyhow::Result<T>) {
    set_progress(|p| { p.running = false; p.waiting = false; p.outcome = if cancelled() { "cancelled" } else if result.is_err() { "failed" } else if p.issues > 0 { "partial" } else { "succeeded" }.into(); });
}
pub fn progress() -> ImportProgress { PROGRESS.lock().unwrap().clone().unwrap_or_default() }
pub(crate) fn set_progress(f: impl FnOnce(&mut ImportProgress)) { f(PROGRESS.lock().unwrap().get_or_insert_with(Default::default)) }

// ---------- planning (pure) ----------

/// Where each entry of a source goes, decided from paths alone.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Plan {
    pub root: Vec<String>,
    /// post folder name → (file name, entry key, path) in name order.
    pub posts: BTreeMap<String, Vec<(String, usize, String)>>,
    pub system: usize,
    /// (path, reason) of files that are not directly inside a post folder.
    pub ignored: Vec<(String, String)>,
    pub unsafe_paths: Vec<String>,
}

/// `entries`: (raw path, is_dir, key). Rules: hidden components and __MACOSX are system files;
/// unsafe paths (absolute, `..`, NUL, backslash) are rejected; single wrapper folders that hold
/// no post content (sidecar or media) are descended; posts are the folders directly under the root and their media are the
/// files directly inside them. Everything else is reported as ignored, with the reason.
pub fn plan(entries: &[(String, bool, usize)]) -> Plan {
    use std::collections::BTreeSet;
    let mut p = Plan::default();
    let mut files: Vec<(Vec<String>, usize, String)> = vec![];
    let mut dirs: BTreeSet<Vec<String>> = BTreeSet::new();
    for (raw, is_dir, key) in entries {
        let Some(rel) = crate::archive::safe_relative(raw) else { if !*is_dir { p.unsafe_paths.push(raw.clone()); } continue };
        let comps: Vec<String> = rel.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect();
        if comps.iter().any(|c| c.starts_with('.') || c == "__MACOSX") { if !*is_dir { p.system += 1; } continue; }
        // Folders count only through the files in them: empty folders, or ones holding only
        // system files, never change the layout (ZIPs may or may not list folders at all).
        if *is_dir { continue; }
        for k in 1..comps.len() { dirs.insert(comps[..k].to_vec()); }
        files.push((comps, *key, rel.to_string_lossy().into_owned()));
    }
    loop {
        let root = &p.root;
        let here: Vec<&Vec<String>> = dirs.iter().filter(|d| d.len() == root.len() + 1 && d.starts_with(root)).collect();
        let files_here = files.iter().filter(|(c, _, _)| c.len() == root.len() + 1 && c.starts_with(root)).count();
        if here.len() == 1 && files_here == 0 {
            let only = here[0].clone();
            // a folder holding a post's sidecar or media directly is a post, never a wrapper
            // (descending into it would turn its subfolders into posts); other files, like a
            // readme next to the post folders, do not stop the descent
            let is_post = files.iter().any(|(c, _, _)| c.len() == only.len() + 1 && c.starts_with(&only)
                && (c[c.len() - 1] == SIDECAR_NAME || kind_for(Path::new(&c[c.len() - 1])).is_some()));
            if !is_post && dirs.iter().any(|d| d.len() > only.len() && d.starts_with(&only)) { p.root = only; continue; }
        }
        break;
    }
    let r = p.root.len();
    for (c, key, path) in files {
        if !c.starts_with(&p.root) { p.ignored.push((path, tr!("import.notAtPostLevel").into())); continue; }
        match c.len() - r {
            1 => p.ignored.push((path, tr!("import.atRoot").into())),
            2 => p.posts.entry(c[r].clone()).or_default().push((c[c.len() - 1].clone(), key, path)),
            _ => p.ignored.push((path, tr!("import.inSubfolder", folder = c[r]))),
        }
    }
    for v in p.posts.values_mut() { v.sort(); }
    p
}

// ---------- sources ----------

trait Source {
    fn kind(&self) -> &'static str;
    fn path(&self) -> String;
    fn entries(&mut self) -> anyhow::Result<Vec<(String, bool, usize)>>;
    fn read_bytes(&mut self, key: usize, cap: u64) -> anyhow::Result<Vec<u8>>;
    fn store(&mut self, key: usize, lib: &Library, kind: &MediaKind, ext: &str) -> anyhow::Result<(String, String)>;
}

struct ZipSource { path: PathBuf, z: zip::ZipArchive<BufReader<File>> }
impl Source for ZipSource {
    fn kind(&self) -> &'static str { "legacy_zip" }
    fn path(&self) -> String { self.path.to_string_lossy().into_owned() }
    fn entries(&mut self) -> anyhow::Result<Vec<(String, bool, usize)>> {
        let mut v = vec![];
        for i in 0..self.z.len() { let e = self.z.by_index_raw(i)?; v.push((crate::archive::entry_name(e.name_raw()), e.is_dir(), i)); }
        Ok(v)
    }
    fn read_bytes(&mut self, key: usize, cap: u64) -> anyhow::Result<Vec<u8>> {
        let mut b = vec![]; self.z.by_index(key)?.take(cap).read_to_end(&mut b)?; Ok(b)
    }
    fn store(&mut self, key: usize, lib: &Library, kind: &MediaKind, ext: &str) -> anyhow::Result<(String, String)> {
        let mut e = self.z.by_index(key)?;
        // an entry can inflate to far more than its size in the archive: bounded, and stoppable
        lib.put_reader_limited(&mut e, kind, ext, crate::archive::MAX_MEDIA_BYTES, &cancelled)
    }
}

struct DirSource { root: PathBuf, files: Vec<PathBuf> }
impl Source for DirSource {
    fn kind(&self) -> &'static str { "folder" }
    fn path(&self) -> String { self.root.to_string_lossy().into_owned() }
    fn entries(&mut self) -> anyhow::Result<Vec<(String, bool, usize)>> {
        fn walk(root: &Path, d: &Path, files: &mut Vec<PathBuf>, out: &mut Vec<(String, bool, usize)>) -> anyhow::Result<()> {
            let mut kids: Vec<PathBuf> = fs::read_dir(d)?.filter_map(|e| e.ok()).map(|e| e.path()).collect();
            kids.sort();
            for k in kids {
                let rel = k.strip_prefix(root).unwrap_or(&k).to_string_lossy().into_owned();
                let ft = fs::symlink_metadata(&k)?.file_type();
                if ft.is_dir() { out.push((rel, true, usize::MAX)); walk(root, &k, files, out)?; }
                else { out.push((rel, false, files.len())); files.push(k); }
            }
            Ok(())
        }
        let mut out = vec![];
        let root = self.root.clone();
        walk(&root, &root, &mut self.files, &mut out)?;
        Ok(out)
    }
    fn read_bytes(&mut self, key: usize, cap: u64) -> anyhow::Result<Vec<u8>> {
        regular_file(&self.files[key])?;
        let mut b = vec![]; File::open(&self.files[key])?.take(cap).read_to_end(&mut b)?; Ok(b)
    }
    fn store(&mut self, key: usize, lib: &Library, kind: &MediaKind, ext: &str) -> anyhow::Result<(String, String)> {
        regular_file(&self.files[key])?;
        lib.put_file(&self.files[key], kind, ext)
    }
}

/// Only plain files are read from an imported folder: a symbolic link (say 推文内容.txt pointing at
/// a private file elsewhere) or a device/pipe (endless data) is listed as a problem instead.
fn regular_file(p: &Path) -> anyhow::Result<()> {
    if !fs::symlink_metadata(p)?.file_type().is_file() { anyhow::bail!(tr!("import.notRegular")); }
    Ok(())
}

pub fn import_zip(lib: &Library, path: &Path, folder: Option<&str>) -> anyhow::Result<ImportReport> {
    let z = zip::ZipArchive::new(BufReader::new(File::open(path)?))?;
    run(lib, &mut ZipSource { path: path.to_path_buf(), z }, folder)
}

/// Prefix of the post that holds one loose media (a file imported without any post around it).
pub const LOOSE_PREFIX: &str = "loose:";

/// Imports a ZIP of loose media: no structure, just files (at any depth). Every media file
/// becomes its own "loose media" post (id `loose:<sha256>`, no text, author or link). A file that
/// already belongs to a real post stays with that post and is reported as a duplicate.
pub fn import_loose_zip(lib: &Library, path: &Path, folder: Option<&str>) -> anyhow::Result<ImportReport> {
    let z = zip::ZipArchive::new(BufReader::new(File::open(path)?))?;
    let mut src = ZipSource { path: path.to_path_buf(), z };
    let _g = begin_in(lib, "loose_zip")?;
    lib.diag_import_start("loose_zip");
    let r = run_loose(lib, &mut src, folder);
    finish(&r);
    r
}

/// Imports a folder of loose media (the share extensions' inbox: one folder per share). With
/// `consume`, files that were imported (or that duplicate the library) are removed afterwards;
/// only problem files stay, so the report can still export them, and deleting the report
/// deletes them. An emptied folder is removed. With `keep_to`, a folder that still holds problem
/// files is moved there afterwards (out of the inbox, so it is not imported again) and the
/// saved report points at the new place.
pub fn import_loose_dir(lib: &Library, dir: &Path, folder: Option<&str>, consume: bool) -> anyhow::Result<ImportReport> {
    import_loose_dir_keep(lib, dir, folder, consume, None, true)
}

pub fn import_loose_dir_keep(lib: &Library, dir: &Path, folder: Option<&str>, consume: bool, keep_to: Option<&Path>, album: bool) -> anyhow::Result<ImportReport> {
    let mut src = DirSource { root: dir.to_path_buf(), files: vec![] };
    let _g = begin_in(lib, "loose_share")?;
    lib.diag_import_start("loose_share");
    let r = run_loose(lib, &mut src, folder);
    finish(&r);
    let rep = r?;
    // what was shared from another app is 从相册导入; what was dropped on a window is only loose
    if album { lib.mark_album(&rep)?; }
    if consume {
        let keep: std::collections::HashSet<PathBuf> = rep.issues.iter().filter(|i| i.is_file() && i.category != "duplicate" && i.category != "in_bin")
            .map(|i| dir.join(&i.path)).collect();
        fn sweep(d: &Path, keep: &std::collections::HashSet<PathBuf>) -> bool {
            let mut empty = true;
            for e in fs::read_dir(d).into_iter().flatten().filter_map(|e| e.ok()) {
                let p = e.path();
                let ft = match e.file_type() { Ok(t) => t, Err(_) => { empty = false; continue } };
                if ft.is_dir() { if sweep(&p, keep) { let _ = fs::remove_dir(&p); } else { empty = false; } }
                else if keep.contains(&p) { empty = false; }
                else if fs::remove_file(&p).is_err() { empty = false; }
            }
            empty
        }
        if sweep(dir, &keep) { let _ = fs::remove_dir(dir); }
    }
    let mut rep = rep;
    if let Some(to) = keep_to.filter(|_| dir.exists()) {
        if let Some(p) = to.parent() { fs::create_dir_all(p)?; }
        fs::rename(dir, to)?;
        rep.source = to.to_string_lossy().into_owned();
        if let Some(f) = &rep.report_file { fs::write(f, serde_json::to_vec_pretty(&rep)?)?; }
    }
    Ok(rep)
}

/// What deleting an import record removed.
#[derive(Debug, Serialize, Default)]
pub struct DeletedReport { pub reports: usize, pub sources: usize, pub bytes: u64 }

fn tree_size(p: &Path) -> u64 {
    match fs::symlink_metadata(p) {
        Ok(m) if m.is_dir() => fs::read_dir(p).into_iter().flatten().filter_map(|e| e.ok()).map(|e| tree_size(&e.path())).sum(),
        Ok(m) => m.len(),
        Err(_) => 0,
    }
}

/// Deletes saved import reports. A report's source (the ZIP or folder it read) is deleted too
/// when it lies inside one of `owned` — the app's own copies (iOS keeps a copy of a picked file;
/// shares wait in the app group's inbox) — never a file of the user's elsewhere. Only files in
/// the report folder can be deleted this way.
pub fn delete_reports(lib: &Library, reports: &[PathBuf], owned: &[PathBuf]) -> anyhow::Result<DeletedReport> {
    let dir = fs::canonicalize(lib.dir.join("logs").join("import-reports")).unwrap_or_default();
    let owned: Vec<PathBuf> = owned.iter().filter_map(|o| fs::canonicalize(o).ok()).collect();
    let comps = |p: &Path| -> Vec<std::ffi::OsString> { p.components().map(|c| c.as_os_str().to_os_string()).collect() };
    let mut out = DeletedReport::default();
    for r in reports {
        let Ok(rc) = fs::canonicalize(r) else { continue };
        if rc.parent() != Some(dir.as_path()) || !rc.file_name().and_then(|n| n.to_str()).map_or(false, |n| n.starts_with("import-") && n.ends_with(".json")) {
            anyhow::bail!(tr!("import.notARecord", path = r.display()));
        }
        if let Ok(rep) = load_report(&rc) {
            if let Ok(src) = fs::canonicalize(&rep.source) {
                if owned.iter().any(|o| crate::rules::strictly_inside(&comps(&src), &comps(o))) {
                    let n = tree_size(&src);
                    let gone = if src.is_dir() { fs::remove_dir_all(&src).is_ok() } else { fs::remove_file(&src).is_ok() };
                    if gone { out.sources += 1; out.bytes += n; }
                }
            }
        }
        out.bytes += tree_size(&rc);
        fs::remove_file(&rc)?;
        out.reports += 1;
    }
    Ok(out)
}

fn run_loose(lib: &Library, src: &mut dyn Source, folder: Option<&str>) -> anyhow::Result<ImportReport> {
    let entries = src.entries()?;
    let mut rep = ImportReport { source: src.path(), ..Default::default() };
    rep.entries = entries.iter().filter(|e| !e.1).count();
    let files: Vec<(String, usize)> = entries.iter().filter(|e| !e.1).filter_map(|(raw, _, key)| {
        match crate::archive::safe_relative(raw) {
            None => { rep.issue("unsafe_path", raw, tr!("import.unsafePath"), None); None }
            Some(rel) => {
                let comps: Vec<String> = rel.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect();
                if comps.iter().any(|c| c.starts_with('.') || c == "__MACOSX") { rep.system_files += 1; None }
                else { Some((rel.to_string_lossy().into_owned(), *key)) }
            }
        }
    }).collect();
    // a folder that holds a 推文内容.txt directly is a post (as in an old-format import): its
    // text, author and link stay with its media; everything else is loose media
    let post_dirs: std::collections::BTreeSet<String> = files.iter()
        .filter_map(|(p, _)| p.rsplit_once('/').map_or((p.as_str() == SIDECAR_NAME).then_some(""), |(d, f)| (f == SIDECAR_NAME).then_some(d)))
        .map(str::to_string).collect();
    let mut posts: BTreeMap<String, Vec<(String, usize, String)>> = BTreeMap::new();
    let files: Vec<(String, usize)> = files.into_iter().filter(|(p, key)| {
        let (dir, fname) = p.rsplit_once('/').unwrap_or(("", p.as_str()));
        if !post_dirs.contains(dir) { return true; }
        posts.entry(dir.to_string()).or_default().push((fname.to_string(), *key, p.clone()));
        false
    }).collect();
    for v in posts.values_mut() { v.sort(); }
    rep.folders = posts.len();
    set_progress(|p| p.folders_total = files.len() + posts.len());
    for (dir, list) in &posts {
        if cancelled() { anyhow::bail!(tr!("import.cancelled")); }
        // a sidecar at the archive's root: the post is named after the archive
        let name = dir.rsplit('/').next().filter(|n| !n.is_empty()).map(str::to_string)
            .unwrap_or_else(|| Path::new(&rep.source).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default());
        let folder_path = if dir.is_empty() { ".".to_string() } else { dir.clone() };
        import_post_folder(lib, src, &mut rep, &name, &folder_path, list)?;
        set_progress(|p| { p.folders_done += 1; p.issues = rep.issues.len(); });
    }
    for (path, key) in files {
        if cancelled() { anyhow::bail!(tr!("import.cancelled")); }
        let fname = path.rsplit('/').next().unwrap_or(&path).to_string();
        let Some((kind, ext)) = kind_for(Path::new(&fname)) else {
            let e = fname.rsplit_once('.').map(|x| x.1.to_lowercase()).unwrap_or_default();
            rep.issue("unsupported", &path, if e.is_empty() { tr!("import.noExtension").to_string() } else { tr!("import.unsupportedExt", e = e) }, None);
            set_progress(|p| p.folders_done += 1);
            continue;
        };
        match src.store(key, lib, &kind, ext) {
            Ok((sha, rel)) => {
                set_progress(|p| { p.files_done += 1; p.current = Some(lib.dir.join(&rel).to_string_lossy().into_owned()); });
                let meta = crate::model::PostMeta { id: format!("{LOOSE_PREFIX}{sha}"), ..Default::default() };
                lib.record_import(&meta, &[Stored { sha, rel, kind, src: path.clone() }], &path, &mut rep)?;
            }
            Err(e) => {
                let msg = format!("{e:#}");
                let cat = if crate::library::is_not_media(&e) { "not_media" } else { "unreadable" };
                rep.issue(cat, &path, msg, None);
            }
        }
        set_progress(|p| { p.folders_done += 1; p.issues = rep.issues.len(); });
    }
    lib.import_into_folder(&mut rep, folder)?;
    lib.finish_report(&mut rep)?;
    Ok(rep)
}

pub fn import_dir(lib: &Library, root: &Path, folder: Option<&str>) -> anyhow::Result<ImportReport> {
    run(lib, &mut DirSource { root: root.to_path_buf(), files: vec![] }, folder)
}

/// A file the import stored, with where it came from.
pub struct Stored { pub sha: String, pub rel: String, pub kind: MediaKind, pub src: String }

fn run(lib: &Library, src: &mut dyn Source, folder: Option<&str>) -> anyhow::Result<ImportReport> {
    let _g = begin_in(lib, src.kind())?;
    lib.diag_import_start(src.kind());
    let r = run_inner(lib, src, folder);
    finish(&r);
    r
}

fn run_inner(lib: &Library, src: &mut dyn Source, folder: Option<&str>) -> anyhow::Result<ImportReport> {
    let entries = src.entries()?;
    let plan = plan(&entries);
    let mut rep = ImportReport { source: src.path(), ..Default::default() };
    rep.entries = entries.iter().filter(|e| !e.1).count();
    rep.system_files = plan.system;
    for u in &plan.unsafe_paths { rep.issue("unsafe_path", u, tr!("import.unsafePath"), None); }
    for (p, why) in &plan.ignored { rep.issue("ignored_location", p, why.clone(), None); }
    rep.folders = plan.posts.len();
    set_progress(|p| p.folders_total = plan.posts.len());
    for (name, files) in &plan.posts {
        if cancelled() { anyhow::bail!(tr!("import.cancelled")); }
        let folder_path = format!("{}{}", if plan.root.is_empty() { String::new() } else { plan.root.join("/") + "/" }, name);
        import_post_folder(lib, src, &mut rep, name, &folder_path, files)?;
        set_progress(|p| { p.folders_done += 1; p.issues = rep.issues.len(); });
    }
    lib.import_into_folder(&mut rep, folder)?;
    lib.finish_report(&mut rep)?;
    Ok(rep)
}

/// One post folder: its sidecar (推文内容.txt) gives the post, the media directly inside are
/// stored under it. `files`: (file name, entry key, path) in name order.
fn import_post_folder(lib: &Library, src: &mut dyn Source, rep: &mut ImportReport, name: &str, folder_path: &str,
                      files: &[(String, usize, String)]) -> anyhow::Result<()> {
    // every entry lands in exactly one bucket: the sidecar read (sidecars), a sidecar that
    // could not be read or a second one (issues), media or problems below
    let chosen = files.iter().find(|(n, _, _)| n == SIDECAR_NAME).map(|(_, k, _)| *k);
    let sidecar = match files.iter().find(|(n, _, _)| n == SIDECAR_NAME) {
        Some((_, key, path)) => match src.read_bytes(*key, 4 << 20) {
            Ok(b) => { rep.sidecars += 1; Some(decode_text(&b)) }
            Err(e) => { rep.issue("unreadable", path, tr!("import.sidecarFailed", e = e), None); None }
        },
        None => None,
    };
    let meta = legacy_post_meta(name, sidecar);
    let mut stored = vec![];
    for (fname, key, path) in files {
        if fname == SIDECAR_NAME {
            if Some(*key) != chosen { rep.issue("ignored_location", path, tr!("import.manySidecars"), None); }
            continue;
        }
        let Some((kind, ext)) = kind_for(Path::new(fname)) else {
            let ext = fname.rsplit_once('.').map(|x| x.1.to_lowercase()).unwrap_or_default();
            rep.issue("unsupported", path, if ext.is_empty() { tr!("import.noExtension").to_string() } else { tr!("import.unsupportedExt", e = ext) }, None);
            continue;
        };
        match src.store(*key, lib, &kind, ext) {
            Ok((sha, rel)) => {
                set_progress(|p| { p.files_done += 1; p.current = Some(lib.dir.join(&rel).to_string_lossy().into_owned()); });
                stored.push(Stored { sha, rel, kind, src: path.clone() });
            }
            Err(e) => {
                let msg = format!("{e:#}");
                let cat = if crate::library::is_not_media(&e) { "not_media" } else { "unreadable" };
                rep.issue(cat, path, msg, None);
            }
        }
    }
    if stored.is_empty() {
        rep.issue("post_not_imported", folder_path, tr!("import.noMediaInFolder"), None);
    } else {
        lib.record_import(&meta, &stored, folder_path, rep)?;
    }
    Ok(())
}

impl Library {
    /// Records one imported post and its stored files in one short transaction. Media in the
    /// recycle bin or deleted are not brought back (a deleted file's copy is removed again).
    pub fn record_import(&self, meta: &crate::model::PostMeta, stored: &[Stored], folder: &str, rep: &mut ImportReport) -> anyhow::Result<()> {
        // fields beyond their limits are cut (see `PostMeta::clamped`), and the report says so
        let (clamped, cut) = meta.clamped();
        let meta = &clamped;
        for field in cut { rep.issue("post_text_truncated", folder, tr!("import.fieldCut", id = meta.id, field = crate::i18n::text(field)), None); }
        {
            let db = self.db();
            let tx = db.conn().unchecked_transaction()?;
            let mut drop_files = vec![];
            let merged_with = rep.folder_by_post.get(&meta.id).cloned();
            let existed = db.post_meta(&meta.id)?.is_some();
            if existed {
                rep.merged_posts += 1;
                // a loose media's "post" is its content: a repeat is already listed as a duplicate file
                if !meta.id.starts_with(LOOSE_PREFIX) { rep.issue("post_merged", folder, tr!("import.merged", id = meta.id),
                          Some(merged_with.unwrap_or_else(|| tr!("import.existingPost").into()))); }
            } else {
                rep.folder_by_post.insert(meta.id.clone(), folder.to_string());
            }
            db.upsert_post_checked(meta, |id, ext| self.dir.join(crate::oplog::blob_rel(id, ext)).exists())?;
            for (ordinal, f) in stored.iter().enumerate() {
                let known = db.media_row(&f.sha)?.is_some();
                rep.shas_by_post.entry(meta.id.clone()).or_default().push(f.sha.clone());
                if db.add_media(&f.sha, &meta.id, ordinal as i64, &f.kind, &f.rel, false)? {
                    rep.media += 1;
                    if known {
                        rep.duplicate_media += 1;
                        let same = rep.first_by_sha.get(&f.sha).cloned().unwrap_or_else(|| tr!("import.existingFile").into());
                        rep.issue("duplicate", &f.src, tr!("import.duplicate"), Some(same));
                    } else {
                        rep.new_media += 1;
                    }
                } else {
                    rep.deleted += 1;
                    rep.issue("in_bin", &f.src, tr!("import.inBin"), None);
                    if db.trash_reg(&f.sha)?.state == crate::rules::PURGED {
                        drop_files.push((f.sha.clone(), f.rel.clone()));
                    } else {
                        db.blob_arrived(&f.sha)?;
                    }
                }
                rep.first_by_sha.entry(f.sha.clone()).or_insert_with(|| f.src.clone());
            }
            tx.commit()?;
            // still under the store lock: the state is checked again as each copy is removed
            for (sha, rel) in drop_files { self.drop_purged_copy(&db, &sha, &rel); }
        }
        rep.posts += 1;
        rep.ids.push(meta.id.clone());
        Ok(())
    }

    /// Puts every live media of every post the import touched into `folder` — also media of those
    /// posts that were already in the library and not part of this import.
    pub fn import_into_folder(&self, rep: &mut ImportReport, folder: Option<&str>) -> anyhow::Result<()> {
        let Some(f) = folder.map(str::trim).filter(|f| !f.is_empty()) else { return Ok(()) };
        let mut ids = rep.ids.clone();
        ids.sort(); ids.dedup();
        let db = self.db();
        let tx = db.conn().unchecked_transaction()?;
        let name = db.create_folder(f)?;
        // every live media of every touched post, plus every live file of this import (also one
        // owned by another post) — `rules::import_folder_member`
        let mut files: Vec<String> = vec![];
        for sha in rep.first_by_sha.keys() { if db.trash_reg(sha)?.state == crate::rules::LIVE && db.media_row(sha)?.is_some() { files.push(sha.clone()); } }
        rep.folder_added = db.add_posts_to_folder(&name, &ids)? + db.add_to_folder(&name, &files)?;
        tx.commit()?;
        rep.folder = Some(name);
        Ok(())
    }

    /// The media of a share (not those of a post folder in it, nor a repeat in the bin) are 从相册导入.
    pub fn mark_album(&self, rep: &ImportReport) -> anyhow::Result<()> {
        let db = self.db();
        let tx = db.conn().unchecked_transaction()?;
        for (post, shas) in &rep.shas_by_post {
            if !post.starts_with(LOOSE_PREFIX) { continue; }
            for sha in shas {
                if db.trash_reg(sha)?.state == crate::rules::LIVE { db.mark_album(sha)?; }
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Lists posts that ended up without media of their own, logs the counts and saves the report.
    pub fn finish_report(&self, rep: &mut ImportReport) -> anyhow::Result<()> {
        let mut ids = rep.ids.clone();
        ids.sort(); ids.dedup();
        let mut hidden = vec![];
        {
            let db = self.db();
            for id in &ids {
                if db.post_live_count(id)? > 0 { continue; }
                // whose files are they now?
                let mut owners: Vec<String> = vec![];
                for sha in rep.shas_by_post.get(id).into_iter().flatten() {
                    if let Some((owner, _, _, _)) = db.media_row(sha)? {
                        let o = rep.folder_by_post.get(&owner).cloned().unwrap_or_else(|| tr!("import.postOwner", owner = owner));
                        if !owners.contains(&o) { owners.push(o); }
                    }
                }
                hidden.push((rep.folder_by_post.get(id).cloned().unwrap_or_else(|| id.clone()), owners));
            }
        }
        rep.posts_without_media = hidden.len();
        for (folder, owners) in hidden {
            rep.issue("post_hidden", &folder, tr!("import.hidden"),
                      (!owners.is_empty()).then(|| owners.join(&tr!("list.separator"))));
        }
        // save the full report
        let dir = self.dir.join("logs").join("import-reports");
        let _ = fs::create_dir_all(&dir);
        let ts = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis());
        let path = dir.join(format!("import-{ts}.json"));
        rep.report_file = Some(path.to_string_lossy().into_owned());
        fs::write(&path, serde_json::to_vec_pretty(rep)?)?;
        // keep the 30 newest reports; an older one whose source is still on disk (files a share
        // kept for the user to look at) stays until it is deleted from the list, which also
        // removes those files: dropping it here would leave them with no way to reach them
        if let Ok(rd) = fs::read_dir(&dir) {
            let mut all: Vec<PathBuf> = rd.filter_map(|e| e.ok()).map(|e| e.path()).collect();
            all.sort();
            let excess = all.len().saturating_sub(30);
            for old in all.into_iter().take(excess) {
                let holds_files = load_report(&old).map_or(false, |r| !r.source.is_empty() && Path::new(&r.source).exists());
                if !holds_files { let _ = fs::remove_file(old); }
            }
        }
        let by_cat = rep.issues.iter().fold(BTreeMap::<String, usize>::new(), |mut m, i| { *m.entry(i.category.clone()).or_default() += 1; m });
        self.diag("import_done", serde_json::json!({
            "entries": rep.entries, "system_files": rep.system_files, "sidecars": rep.sidecars, "folders": rep.folders,
            "posts_imported": rep.posts, "distinct_post_ids": ids.len(), "new_media": rep.new_media, "duplicate_files": rep.duplicate_media,
            "left_deleted": rep.deleted, "issues_by_category": by_cat, "after": self.counts() }));
        Ok(())
    }
}

/// Saved import reports, newest first: (report file, created ms, source, issue count).
pub fn reports(lib: &Library) -> Vec<(String, u64, String, usize)> {
    let dir = lib.dir.join("logs").join("import-reports");
    let mut v: Vec<(String, u64, String, usize)> = fs::read_dir(&dir).into_iter().flatten().filter_map(|e| e.ok()).filter_map(|e| {
        let p = e.path();
        let ts: u64 = p.file_stem()?.to_str()?.strip_prefix("import-")?.parse().ok()?;
        let r: ImportReport = serde_json::from_slice(&fs::read(&p).ok()?).ok()?;
        Some((p.to_string_lossy().into_owned(), ts, r.source, r.issues.len()))
    }).collect();
    v.sort_by(|a, b| b.1.cmp(&a.1));
    v
}

pub fn load_report(path: &Path) -> anyhow::Result<ImportReport> { Ok(serde_json::from_slice(&fs::read(path)?)?) }

pub fn category_title(c: &str) -> String {
    match c {
        "not_media" => tr!("import.cat.not_media"), "unsupported" => tr!("import.cat.unsupported"), "unreadable" => tr!("import.cat.unreadable"),
        "duplicate" => tr!("import.cat.duplicate"), "in_bin" => tr!("import.cat.in_bin"), "ignored_location" => tr!("import.cat.ignored_location"),
        "unsafe_path" => tr!("import.cat.unsafe_path"), "post_not_imported" => tr!("import.cat.post_not_imported"), "post_hidden" => tr!("import.cat.post_hidden"),
        "post_merged" => tr!("import.cat.post_merged"), "post_text_truncated" => tr!("import.cat.post_text_truncated"), _ => tr!("import.cat.other"),
    }
}

/// Writes the problem files of a report, byte for byte as they are in the source, into a ZIP:
/// `<类别>/<原路径>` plus `说明.txt` listing every issue (also the folder-level ones).
/// Returns how many files were written.
#[cfg(unix)]
fn open_report_file(root: &Path, name: &str) -> std::io::Result<File> {
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::os::unix::fs::OpenOptionsExt;
    use std::os::unix::ffi::OsStrExt;
    let invalid = || std::io::Error::new(std::io::ErrorKind::InvalidInput, "unsafe report path");
    let rel = crate::archive::safe_relative(name).ok_or_else(invalid)?;
    let mut dir = fs::OpenOptions::new().read(true).custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC).open(root)?;
    let components: Vec<_> = rel.components().collect();
    if components.is_empty() { return Err(invalid()); }
    for (index, component) in components.iter().enumerate() {
        let name = std::ffi::CString::new(component.as_os_str().as_bytes()).map_err(|_| invalid())?;
        let last = index + 1 == components.len();
        let flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK | if last { 0 } else { libc::O_DIRECTORY };
        // dir remains alive throughout openat; a successful descriptor is owned exactly once.
        let fd = unsafe { libc::openat(dir.as_raw_fd(), name.as_ptr(), flags) };
        if fd < 0 { return Err(std::io::Error::last_os_error()); }
        dir = unsafe { File::from_raw_fd(fd) };
    }
    if !dir.metadata()?.is_file() { return Err(invalid()); }
    Ok(dir)
}

/// Windows has no `openat`: each component is checked not to be a link or another reparse point
/// (junction, mount point) before going on, and the file itself is opened without following one.
#[cfg(windows)]
fn open_report_file(root: &Path, name: &str) -> std::io::Result<File> {
    use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    let invalid = || std::io::Error::new(std::io::ErrorKind::InvalidInput, "unsafe report path");
    let rel = crate::archive::safe_relative(name).ok_or_else(invalid)?;
    if rel.components().next().is_none() { return Err(invalid()); }
    let mut path = root.to_path_buf();
    if fs::symlink_metadata(&path)?.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 { return Err(invalid()); }
    for component in rel.components() {
        path.push(component);
        if fs::symlink_metadata(&path)?.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 { return Err(invalid()); }
    }
    let file = fs::OpenOptions::new().read(true).custom_flags(FILE_FLAG_OPEN_REPARSE_POINT).open(&path)?;
    let m = file.metadata()?;
    if !m.is_file() || m.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 { return Err(invalid()); }
    Ok(file)
}

pub fn export_issues(report: &Path, out: &Path) -> anyhow::Result<usize> {
    let rep = load_report(report)?;
    let wanted: Vec<&ImportIssue> = rep.issues.iter().filter(|i| i.is_file() && i.category != "unsafe_path").collect();
    let src_path = PathBuf::from(&rep.source);
    if !src_path.exists() { anyhow::bail!(tr!("import.sourceGone", source = rep.source)); }
    let mut zip_src = if src_path.is_file() { Some(zip::ZipArchive::new(BufReader::new(File::open(&src_path)?))?) } else { None };
    let tmp = out.with_extension("zip.partial");
    let _cleanup = crate::library::TempFile(tmp.clone());
    let mut zw = zip::ZipWriter::new(std::io::BufWriter::new(File::create(&tmp)?));
    let opts = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored).large_file(true);
    let mut n = 0;
    // map archive path → entry index (names decoded the same way as on import)
    let mut index: HashMap<String, usize> = HashMap::new();
    if let Some(z) = zip_src.as_mut() {
        for i in 0..z.len() {
            let e = z.by_index_raw(i)?;
            if let Some(rel) = crate::archive::safe_relative(&crate::archive::entry_name(e.name_raw())) { index.insert(rel.to_string_lossy().into_owned(), i); }
        }
    }
    let mut readme = tr!("import.readme.head", source = rep.source);
    for i in &rep.issues {
        readme += &tr!("import.readme.item", category = category_title(&i.category), path = i.path, reason = i.reason);
        if let Some(s) = &i.same_as { readme += &tr!("import.readme.match", s = s); }
    }
    for i in wanted {
        if crate::archive::safe_relative(&i.path).is_none() { continue; }
        let name = format!("{}/{}", category_title(&i.category), i.path);
        let copied = match zip_src.as_mut() {
            Some(z) => match index.get(&i.path) {
                Some(&k) => { zw.start_file(&name, opts)?; std::io::copy(&mut z.by_index(k)?, &mut zw)?; true }
                None => false,
            },
            None => match open_report_file(&src_path, &i.path) {
                Ok(mut f) => { zw.start_file(&name, opts)?; std::io::copy(&mut f, &mut zw)?; true }
                Err(_) => false,
            },
        };
        if copied { n += 1; } else { readme += &tr!("import.readme.notTaken", error = i.path); }
    }
    zw.start_file(tr!("readme.name"), zip::write::SimpleFileOptions::default())?;
    zw.write_all(readme.as_bytes())?;
    zw.finish()?.flush()?;
    fs::rename(&tmp, out)?;
    Ok(n)
}
