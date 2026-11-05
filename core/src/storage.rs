//! 存储空间: what the app takes on this device, in groups every front end shows the same way.
//! Media are counted from the library's own records (a file counts once, by what it is, wherever
//! it sits); everything else is the size of its folder on disk. Only sizes are read, never
//! contents.
use crate::library::Library;
use crate::store::LIVE_SQL;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// A folder the front end knows about and the core does not (the app itself, caches it keeps).
#[derive(Debug, Clone, Deserialize)]
pub struct ExtraPlace { pub key: String, pub path: String }

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct StorageGroup {
    /// Catalog key of the group's name (`storage.group.<key>`) and of its description
    /// (`storage.group.<key>.detail`).
    pub key: String,
    pub bytes: u64,
    pub files: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct StorageUsage { pub groups: Vec<StorageGroup>, pub total: u64 }

/// Free space for this user on the volume `p` is on; None when the system does not say.
#[cfg(unix)]
pub fn free_space(p: &Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt;
    let path = std::ffi::CString::new(p.as_os_str().as_bytes()).ok()?;
    let mut v: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(path.as_ptr(), &mut v) } != 0 { return None; }
    Some(v.f_bavail as u64 * v.f_frsize as u64)
}

#[cfg(windows)]
pub fn free_space(p: &Path) -> Option<u64> {
    use std::os::windows::ffi::OsStrExt;
    extern "system" { fn GetDiskFreeSpaceExW(path: *const u16, free: *mut u64, total: *mut u64, all_free: *mut u64) -> i32; }
    let path: Vec<u16> = p.as_os_str().encode_wide().chain(Some(0)).collect();
    let mut free = 0u64;
    if unsafe { GetDiskFreeSpaceExW(path.as_ptr(), &mut free, std::ptr::null_mut(), std::ptr::null_mut()) } == 0 { return None; }
    Some(free)
}

/// Bytes and files under `p` (a file or a folder); symbolic links are not followed, and what
/// cannot be read counts as nothing rather than failing the whole report.
pub fn size_of(p: &Path) -> (u64, u64) {
    let Ok(meta) = std::fs::symlink_metadata(p) else { return (0, 0) };
    if meta.is_file() { return (meta.len(), 1); }
    if !meta.is_dir() { return (0, 0); }
    let (mut bytes, mut files) = (0, 0);
    let mut stack = vec![p.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else { continue };
        for e in rd.flatten() {
            let Ok(m) = e.metadata() else { continue };
            let ft = m.file_type();
            if ft.is_symlink() { continue }
            if ft.is_dir() { stack.push(e.path()) } else if ft.is_file() { bytes += m.len(); files += 1 }
        }
    }
    (bytes, files)
}

/// The groups, in the order they are shown: photos, videos, the recycle bin, the database, other
/// library data, AI models, then the front end's places (the app first). Empty groups stay so
/// the list does not change shape from device to device.
pub fn usage(lib: &Library, extra: &[ExtraPlace]) -> anyhow::Result<StorageUsage> {
    let rows: Vec<(String, bool, String)> = {
        let db = lib.db();
        let mut st = db.conn().prepare(&format!("SELECT m.kind, {LIVE_SQL}, m.path FROM media m WHERE m.path IS NOT NULL"))?;
        let v = st.query_map([], |r| Ok((r.get::<_, Option<String>>(0)?.unwrap_or_default(), r.get::<_, bool>(1)?, r.get::<_, String>(2)?)))?
            .collect::<Result<_, _>>()?;
        v
    };
    let mut counted: HashSet<PathBuf> = HashSet::new();
    let (mut photos, mut videos, mut bin) = (group("photos"), group("videos"), group("bin"));
    for (kind, live, rel) in rows {
        let path = lib.dir.join(&rel);
        if !counted.insert(path.clone()) { continue }
        let Ok(m) = std::fs::metadata(&path) else { continue };
        let g = if !live { &mut bin } else if kind == "video" { &mut videos } else { &mut photos };
        g.bytes += m.len();
        g.files += 1;
    }
    let mut database = group("database");
    for name in ["library.sqlite", "library.sqlite-wal", "library.sqlite-shm"] {
        let p = lib.dir.join(name);
        let (b, f) = size_of(&p);
        database.bytes += b; database.files += f;
        counted.insert(p);
    }
    // the rest of the library folder: import reports, sync state, downloads in progress, logs…
    let models = lib.models_dir();
    let extra_paths: Vec<PathBuf> = extra.iter().map(|e| PathBuf::from(&e.path)).collect();
    let mut other = group("libraryOther");
    let mut stack = vec![lib.dir.clone()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else { continue };
        for e in rd.flatten() {
            let p = e.path();
            // places shown as groups of their own are not counted twice
            if p == models || extra_paths.iter().any(|x| x == &p) { continue }
            let Ok(m) = e.metadata() else { continue };
            if m.file_type().is_symlink() { continue }
            if m.is_dir() { stack.push(p) } else if m.is_file() && !counted.contains(&p) { other.bytes += m.len(); other.files += 1 }
        }
    }
    let (b, f) = size_of(&models);
    let mut groups = vec![photos, videos, bin, database, other, StorageGroup { key: "models".into(), bytes: b, files: f }];
    for e in extra {
        let (b, f) = size_of(Path::new(&e.path));
        match groups.iter_mut().find(|g| g.key == e.key) {
            Some(g) => { g.bytes += b; g.files += f }
            None => groups.push(StorageGroup { key: e.key.clone(), bytes: b, files: f }),
        }
    }
    let total = groups.iter().map(|g| g.bytes).sum();
    Ok(StorageUsage { groups, total })
}

fn group(key: &str) -> StorageGroup { StorageGroup { key: key.into(), bytes: 0, files: 0 } }

#[cfg(test)]
mod free_space_tests {
    #[test]
    fn free_space_of_a_real_folder_and_of_nothing() {
        assert!(super::free_space(&std::env::temp_dir()).unwrap() > 0);
        assert_eq!(super::free_space(std::path::Path::new("/no/such/place/at/all")), None);
    }
}
