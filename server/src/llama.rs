//! On-device GGUF inference for Linux (`libtl_llama.so` built from `flutter/tl_llama/src`).
//! Dynamically loaded at run time so the server still starts and serves external AI when the
//! llama.cpp library is absent (e.g. a plain `cargo test` or a macOS dev build).
//!
//! One inference runs at a time; a loaded model stays warm between items and is unloaded 30 s
//! after the last call to free RAM/VRAM.
use anyhow::{anyhow, bail};
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

#[cfg(unix)]
extern "C" {
    fn dlopen(filename: *const c_char, flag: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
}

#[cfg(target_os = "linux")]
const RTLD_NOW: c_int = 2;
#[cfg(target_os = "macos")]
const RTLD_NOW: c_int = 2;
#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
const RTLD_NOW: c_int = 2;

#[cfg(target_os = "macos")]
const LIB_NAME: &str = "libtl_llama.dylib";
#[cfg(not(target_os = "macos"))]
const LIB_NAME: &str = "libtl_llama.so";

type InitFn = unsafe extern "C" fn(*const c_char) -> *mut c_char;
type LoadFn = unsafe extern "C" fn(*const c_char, *const c_char, i32, i32, i32, *mut *mut c_char) -> *mut c_void;
type DescribeFn = unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char, *const c_char, i32, *mut *mut c_char) -> *mut c_char;
type DimensionsFn = unsafe extern "C" fn(*mut c_void) -> i32;
type EmbedFn = unsafe extern "C" fn(*mut c_void, *const c_char, *mut f32, *mut *mut c_char) -> i32;
type UnloadFn = unsafe extern "C" fn(*mut c_void);
type FreeStringFn = unsafe extern "C" fn(*mut c_char);

struct Api {
    init: InitFn,
    load: LoadFn,
    describe: DescribeFn,
    dimensions: DimensionsFn,
    embed: EmbedFn,
    unload: UnloadFn,
    free_string: FreeStringFn,
    devices: String,
}

unsafe impl Send for Api {}
unsafe impl Sync for Api {}

struct Loaded {
    key: String,
    handle: *mut c_void,
}

unsafe impl Send for Loaded {}

struct State {
    tagger: Option<Loaded>,
    embedder: Option<Loaded>,
    last_used: Instant,
}

static API: OnceLock<Option<Api>> = OnceLock::new();
static STATE: OnceLock<Mutex<State>> = OnceLock::new();
static WATCHER: OnceLock<()> = OnceLock::new();

fn state() -> &'static Mutex<State> {
    STATE.get_or_init(|| Mutex::new(State { tagger: None, embedder: None, last_used: Instant::now() }))
}

fn start_watcher() {
    WATCHER.get_or_init(|| {
        std::thread::spawn(|| loop {
            std::thread::sleep(Duration::from_secs(5));
            let Some(Some(api)) = API.get() else { continue };
            let Ok(mut g) = state().lock() else { continue };
            if (g.tagger.is_some() || g.embedder.is_some()) && g.last_used.elapsed() >= Duration::from_secs(30) {
                if let Some(t) = g.tagger.take() { unsafe { (api.unload)(t.handle) }; }
                if let Some(e) = g.embedder.take() { unsafe { (api.unload)(e.handle) }; }
            }
        });
    });
}

fn cstr(s: &str) -> anyhow::Result<CString> {
    CString::new(s).map_err(|_| anyhow!("invalid string"))
}

unsafe fn take_string(api: &Api, p: *mut c_char) -> Option<String> {
    if p.is_null() { return None; }
    let s = CStr::from_ptr(p).to_string_lossy().replace('\u{FFFD}', "");
    (api.free_string)(p);
    Some(s)
}

#[cfg(unix)]
fn candidate_paths() -> Vec<(PathBuf, Option<PathBuf>)> {
    let mut out = Vec::new();
    if let Ok(dir) = std::env::var("TL_LLAMA_DIR") {
        let d = PathBuf::from(dir);
        out.push((d.join(LIB_NAME), Some(d)));
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let sub = dir.join("llama");
            out.push((sub.join(LIB_NAME), Some(sub)));
            out.push((dir.join(LIB_NAME), Some(dir.to_path_buf())));
        }
    }
    out.push((PathBuf::from(LIB_NAME), None));
    out
}

#[cfg(unix)]
unsafe fn sym<T>(handle: *mut c_void, name: &[u8]) -> Option<T> {
    let p = dlsym(handle, name.as_ptr().cast());
    if p.is_null() { None } else { Some(std::mem::transmute_copy(&p)) }
}

#[cfg(unix)]
fn load_api() -> Option<Api> {
    for (lib_path, backend_dir) in candidate_paths() {
        if backend_dir.is_some() && !lib_path.exists() { continue; }
        let Ok(cpath) = CString::new(lib_path.to_string_lossy().as_bytes()) else { continue };
        let handle = unsafe { dlopen(cpath.as_ptr(), RTLD_NOW) };
        if handle.is_null() { continue; }
        let loaded = unsafe {
            Some((
                sym::<InitFn>(handle, b"tl_llama_init\0")?,
                sym::<LoadFn>(handle, b"tl_llama_load\0")?,
                sym::<DescribeFn>(handle, b"tl_llama_describe\0")?,
                sym::<DimensionsFn>(handle, b"tl_llama_dimensions\0")?,
                sym::<EmbedFn>(handle, b"tl_llama_embed\0")?,
                sym::<UnloadFn>(handle, b"tl_llama_unload\0")?,
                sym::<FreeStringFn>(handle, b"tl_llama_free_string\0")?,
            ))
        };
        let Some((init, load, describe, dimensions, embed, unload, free_string)) = loaded else { continue };
        let cdir = backend_dir.as_ref().and_then(|d| CString::new(d.to_string_lossy().as_bytes()).ok());
        let dev_ptr = unsafe { init(cdir.as_ref().map_or(std::ptr::null(), |s| s.as_ptr())) };
        let devices = if dev_ptr.is_null() {
            String::new()
        } else {
            let s = unsafe { CStr::from_ptr(dev_ptr).to_string_lossy().into_owned() };
            unsafe { free_string(dev_ptr) };
            s
        };
        eprintln!("local ai: loaded {} ({})", lib_path.display(), if devices.is_empty() { "CPU" } else { &devices });
        return Some(Api { init, load, describe, dimensions, embed, unload, free_string, devices });
    }
    None
}

#[cfg(not(unix))]
fn load_api() -> Option<Api> { None }

fn api() -> Option<&'static Api> {
    API.get_or_init(load_api).as_ref()
}

pub fn info() -> (bool, Option<String>) {
    match api() {
        Some(a) => (true, (!a.devices.is_empty()).then(|| a.devices.clone())),
        None => (false, None),
    }
}

pub fn describe(
    weights: &Path,
    projector: Option<&Path>,
    image: &Path,
    system: &str,
    question: &str,
    max_tokens: i32,
) -> anyhow::Result<String> {
    let api = api().ok_or_else(|| anyhow!("local ai unavailable"))?;
    start_watcher();
    let _ = api.init;
    let w_str = weights.to_string_lossy();
    let p_str = projector.map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
    let key = format!("{w_str}|{p_str}");
    let cw = cstr(&w_str)?;
    let cp = if p_str.is_empty() { None } else { Some(cstr(&p_str)?) };
    let ci = cstr(&image.to_string_lossy())?;
    let cs = cstr(system)?;
    let cq = cstr(question)?;

    let mut g = state().lock().map_err(|_| anyhow!("lock poisoned"))?;
    // Keep only one heavy model in RAM/VRAM at a time if switching
    if g.tagger.as_ref().is_none_or(|t| t.key != key) {
        if let Some(old) = g.tagger.take() { unsafe { (api.unload)(old.handle) }; }
        let mut err: *mut c_char = std::ptr::null_mut();
        let h = unsafe {
            (api.load)(
                cw.as_ptr(),
                cp.as_ref().map_or(std::ptr::null(), |s| s.as_ptr()),
                999,
                4096,
                0,
                &mut err,
            )
        };
        if h.is_null() {
            let msg = unsafe { take_string(api, err) }.unwrap_or_else(|| "?".into());
            bail!("load: {msg}");
        }
        g.tagger = Some(Loaded { key, handle: h });
    }
    let handle = g.tagger.as_ref().unwrap().handle;
    let mut err: *mut c_char = std::ptr::null_mut();
    let res = unsafe { (api.describe)(handle, ci.as_ptr(), cs.as_ptr(), cq.as_ptr(), max_tokens.clamp(16, 1024), &mut err) };
    g.last_used = Instant::now();
    match unsafe { take_string(api, res) } {
        Some(text) => Ok(text),
        None => {
            let msg = unsafe { take_string(api, err) }.unwrap_or_else(|| "?".into());
            bail!("describe: {msg}");
        }
    }
}

pub fn embed(weights: &Path, texts: &[String]) -> anyhow::Result<(usize, Vec<Vec<f32>>)> {
    let api = api().ok_or_else(|| anyhow!("local ai unavailable"))?;
    start_watcher();
    let w_str = weights.to_string_lossy();
    let key = w_str.into_owned();
    let cw = cstr(&key)?;

    let mut g = state().lock().map_err(|_| anyhow!("lock poisoned"))?;
    if g.embedder.as_ref().is_none_or(|e| e.key != key) {
        if let Some(old) = g.embedder.take() { unsafe { (api.unload)(old.handle) }; }
        let mut err: *mut c_char = std::ptr::null_mut();
        let h = unsafe { (api.load)(cw.as_ptr(), std::ptr::null(), 999, 2048, 1, &mut err) };
        if h.is_null() {
            let msg = unsafe { take_string(api, err) }.unwrap_or_else(|| "?".into());
            bail!("load: {msg}");
        }
        g.embedder = Some(Loaded { key, handle: h });
    }
    let handle = g.embedder.as_ref().unwrap().handle;
    let dim = unsafe { (api.dimensions)(handle) };
    if dim <= 0 { bail!("invalid embedding dimensions: {dim}"); }
    let dim = dim as usize;
    let mut out = Vec::with_capacity(texts.len());
    for t in texts {
        let ct = cstr(t)?;
        let mut vec = vec![0f32; dim];
        let mut err: *mut c_char = std::ptr::null_mut();
        let rc = unsafe { (api.embed)(handle, ct.as_ptr(), vec.as_mut_ptr(), &mut err) };
        if rc != 0 {
            let msg = unsafe { take_string(api, err) }.unwrap_or_else(|| format!("code {rc}"));
            bail!("embed: {msg}");
        }
        out.push(vec);
    }
    g.last_used = Instant::now();
    Ok((dim, out))
}

pub fn unload_all() {
    let Some(api) = api() else { return };
    if let Ok(mut g) = state().lock() {
        if let Some(t) = g.tagger.take() { unsafe { (api.unload)(t.handle) }; }
        if let Some(e) = g.embedder.take() { unsafe { (api.unload)(e.handle) }; }
    }
}
