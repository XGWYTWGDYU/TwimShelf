//! Diagnostics: core panics are recorded (with their source location) in the statistics log,
//! and `export` writes one ZIP with every log, crash report and a numbers-only summary of the
//! library, for sending to the developer. Nothing in it is library content: no media, post
//! text, tag names or file names (import records contribute counts per category only).
use crate::library::Library;
use std::fs::{self, File};
use std::io::Write;
use std::path::Path;
use std::sync::OnceLock;

static PANIC_LOG: OnceLock<std::path::PathBuf> = OnceLock::new();

/// Records every panic of the core in `logs/diagnostics.log` (the app keeps running: the FFI
/// turns panics into errors), then runs the default hook.
pub fn install_panic_hook(library_dir: &Path) {
    let _ = PANIC_LOG.set(library_dir.join("logs").join("diagnostics.log"));
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let default = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            if let Some(p) = PANIC_LOG.get() {
                let msg = info.payload().downcast_ref::<&str>().map(|s| s.to_string())
                    .or_else(|| info.payload().downcast_ref::<String>().cloned()).unwrap_or_default();
                let loc = info.location().map(|l| format!("{}:{}", l.file(), l.line())).unwrap_or_default();
                let ts = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
                let thread = std::thread::current().name().unwrap_or("?").to_string();
                let line = serde_json::json!({ "t": ts, "event": "panic", "data": { "message": scrub(&msg), "at": loc, "thread": thread } });
                append_capped(p, &line.to_string());
            }
            default(info);
        }));
    });
}

/// Records that the library could not be opened (there is no Library to log through yet).
pub fn log_open_failure(library_dir: &Path, err: &str) {
    let dir = library_dir.join("logs");
    let _ = fs::create_dir_all(&dir);
    let ts = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
    let line = serde_json::json!({ "t": ts, "event": "open_failed", "data": { "error": scrub(err) } });
    append_capped(&dir.join("diagnostics.log"), &line.to_string());
}

/// Appends a line to a log; past 2 MB the file becomes `<name>.1.log` (replacing the older one),
/// so every log stays under 4 MB in all.
pub fn append_capped(path: &Path, line: &str) {
    if let Some(d) = path.parent() { let _ = fs::create_dir_all(d); }
    if fs::metadata(path).map_or(false, |m| m.len() > 2 << 20) {
        let _ = fs::rename(path, path.with_extension("1.log"));
    }
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(path) { let _ = writeln!(f, "{line}"); }
}

/// Numbers-only summary of the saved import records.
fn import_summary(lib: &Library) -> serde_json::Value {
    let mut out = vec![];
    for (file, ms, source, _) in crate::import::reports(lib) {
        let Ok(r) = crate::import::load_report(Path::new(&file)) else { continue };
        let mut by: std::collections::BTreeMap<String, usize> = Default::default();
        for i in &r.issues { *by.entry(i.category.clone()).or_default() += 1; }
        let kind = if source.contains("/Shares/") { "share" } else if source.ends_with(".zip") || source.ends_with(".tlpack") { "archive" } else { "folder" };
        out.push(serde_json::json!({ "at_ms": ms, "source_kind": kind, "entries": r.entries, "new_media": r.new_media,
            "duplicates": r.duplicate_media, "posts": r.posts, "issues_by_category": by }));
    }
    serde_json::Value::Array(out)
}

/// Writes the diagnostics ZIP; returns how many files it holds.
pub fn export(lib: &Library, out: &Path, app_info: &str) -> anyhow::Result<usize> {
    let logs = lib.dir.join("logs");
    let tmp = out.with_extension("zip.partial");
    let mut z = zip::ZipWriter::new(std::io::BufWriter::new(File::create(&tmp)?));
    let o = zip::write::SimpleFileOptions::default();
    let mut n = 0;
    let mut add = |z: &mut zip::ZipWriter<std::io::BufWriter<File>>, name: &str, bytes: &[u8]| -> anyhow::Result<()> {
        z.start_file(name, o)?; z.write_all(bytes)?; n += 1; Ok(())
    };
    for f in ["app.log", "app.1.log", "diagnostics.log", "diagnostics.1.log"] {
        if let Ok(b) = fs::read(logs.join(f)) { add(&mut z, f, &b)?; }
    }
    if let Ok(rd) = fs::read_dir(logs.join("crashes")) {
        let mut files: Vec<_> = rd.filter_map(|e| e.ok()).map(|e| e.path()).filter(|p| p.is_file()).collect();
        files.sort();
        for p in files.iter().rev().take(40) {
            if let (Some(name), Ok(b)) = (p.file_name().and_then(|n| n.to_str()), fs::read(p)) { add(&mut z, &format!("crashes/{name}"), &b)?; }
        }
    }
    let app: serde_json::Value = serde_json::from_str(app_info).unwrap_or(serde_json::json!({ "raw": app_info }));
    let db = lib.db();
    let stats = db.stats()?;
    let jobs: (i64, i64) = (stats.pending_jobs, stats.failed_jobs);
    let schema: i64 = db.conn().query_row("PRAGMA user_version", [], |r| r.get(0))?;
    let ops: i64 = db.conn().query_row("SELECT count(*) FROM op", [], |r| r.get(0))?;
    drop(db);
    let summary = serde_json::json!({
        "app": app, "core_version": env!("CARGO_PKG_VERSION"), "schema": schema,
        "library": lib.counts(), "stats": stats, "op_log_entries": ops, "download_jobs": { "pending": jobs.0, "failed": jobs.1 },
        "import_records": import_summary(lib),
    });
    add(&mut z, "summary.json", serde_json::to_string_pretty(&summary)?.as_bytes())?;
    add(&mut z, &tr!("readme.name"), tr!("diag.readme").as_bytes())?;
    z.finish()?.flush()?;
    fs::rename(&tmp, out)?;
    Ok(n)
}

/// Error text for logs: links (which name the user's posts) become tr!("diag.link"), capped at 200 chars.
pub fn scrub(s: &str) -> String {
    // any URL (any scheme, any case), then any absolute path or home-relative path
    let re = regex_lite();
    let out = re.0.replace_all(s, tr!("diag.link"));
    let out = re.1.replace_all(&out, tr!("diag.path2"));
    out.chars().take(200).collect()
}

fn regex_lite() -> &'static (regex::Regex, regex::Regex) {
    static R: std::sync::OnceLock<(regex::Regex, regex::Regex)> = std::sync::OnceLock::new();
    R.get_or_init(|| (
        regex::Regex::new(r#"(?i)\b[a-z][a-z0-9+.-]{1,15}://[^\s)"']+"#).unwrap(),
        regex::Regex::new(r#"(?:~|/(?:Users|home|private|var|tmp|Volumes|mnt))/[^\s)"']*"#).unwrap(),
    ))
}

#[cfg(test)]
mod tests {
    #[test]
    fn scrub_removes_links() {
        assert_eq!(super::scrub("error sending request for url (https://api.fxtwitter.com/a/status/123): timeout"),
                   "error sending request for url (<链接>): timeout");
        assert_eq!(super::scrub("no links"), "no links");
    }
}
