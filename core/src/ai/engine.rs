//! The on-device engine: llama.cpp through `tl_llama` (flutter/tl_llama/src), loaded at run time so
//! the app still starts and uses services where it is missing. On the Apple devices MLX takes its
//! place through a function the app registers (`tl_ai_set_mlx`).
//!
//! One model is kept loaded (one job at a time) and unloaded 30 s after its last use.
use super::error::{AiError, AiResult, Kind};
use serde::Deserialize;
use std::ffi::{c_char, c_void, CStr, CString};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

#[cfg(target_os = "windows")]
const LIB_NAME: &str = "tl_llama.dll";
#[cfg(target_os = "macos")]
const LIB_NAME: &str = "libtl_llama.dylib";
#[cfg(not(any(target_os = "windows", target_os = "macos")))]
const LIB_NAME: &str = "libtl_llama.so";

#[cfg(unix)]
mod sys {
    use std::ffi::{c_char, c_int, c_void};
    extern "C" {
        fn dlopen(filename: *const c_char, flag: c_int) -> *mut c_void;
        fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    }
    pub unsafe fn open(path: &std::path::Path) -> *mut c_void {
        let Ok(c) = std::ffi::CString::new(path.to_string_lossy().as_bytes()) else { return std::ptr::null_mut() };
        dlopen(c.as_ptr(), 2 /* RTLD_NOW */)
    }
    pub unsafe fn symbol(lib: *mut c_void, name: &std::ffi::CStr) -> *mut c_void { dlsym(lib, name.as_ptr()) }
}

#[cfg(windows)]
mod sys {
    use std::ffi::c_void;
    use std::os::windows::ffi::OsStrExt;
    #[link(name = "kernel32")]
    extern "system" {
        fn LoadLibraryExW(name: *const u16, file: *mut c_void, flags: u32) -> *mut c_void;
        fn GetProcAddress(module: *mut c_void, name: *const std::ffi::c_char) -> *mut c_void;
    }
    // the library's own folder is searched for what it needs (ggml and the backends)
    const LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR: u32 = 0x100;
    const LOAD_LIBRARY_SEARCH_DEFAULT_DIRS: u32 = 0x1000;
    pub unsafe fn open(path: &std::path::Path) -> *mut c_void {
        let wide: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        LoadLibraryExW(wide.as_ptr(), std::ptr::null_mut(), LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS)
    }
    pub unsafe fn symbol(lib: *mut c_void, name: &std::ffi::CStr) -> *mut c_void { GetProcAddress(lib, name.as_ptr()) }
}

type InitFn = unsafe extern "C" fn(*const c_char);
type DevicesFn = unsafe extern "C" fn() -> *mut c_char;
type LoadFn = unsafe extern "C" fn(*const c_char, *const c_char, *const c_char, i32, i32, *mut *mut c_char) -> *mut c_void;
type DescribeFn = unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char, *const c_char, i32, *mut *mut c_char) -> *mut c_char;
type UnloadFn = unsafe extern "C" fn(*mut c_void);
type FreeFn = unsafe extern "C" fn(*mut c_char);

struct Llama { devices: DevicesFn, load: LoadFn, describe: DescribeFn, unload: UnloadFn, free: FreeFn }

/// The function the Apple apps register: MLX's answer about the picture at `image` from the model in
/// `model_dir`, or null with `*error` set. Strings it returns are freed with the second function.
pub type MlxDescribe = unsafe extern "C" fn(model_dir: *const c_char, image: *const c_char, system: *const c_char, question: *const c_char, max_tokens: i32, error: *mut *mut c_char) -> *mut c_char;
pub type MlxFree = unsafe extern "C" fn(*mut c_char);

#[derive(Clone, Copy)]
struct Mlx { describe: MlxDescribe, free: MlxFree }

/// Where the app keeps `tl_llama` and its backends (empty: next to the program, or found by name).
static DIR: Mutex<Option<PathBuf>> = Mutex::new(None);
static LLAMA: OnceLock<Option<Llama>> = OnceLock::new();
static MLX: Mutex<Option<Mlx>> = Mutex::new(None);

pub fn set_dir(dir: &str) { *DIR.lock().unwrap_or_else(|e| e.into_inner()) = (!dir.is_empty()).then(|| PathBuf::from(dir)); }

pub fn set_mlx(describe: MlxDescribe, free: MlxFree) { *MLX.lock().unwrap_or_else(|e| e.into_inner()) = Some(Mlx { describe, free }); }

pub fn has_mlx() -> bool { MLX.lock().unwrap_or_else(|e| e.into_inner()).is_some() }

fn candidates() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(d) = DIR.lock().unwrap_or_else(|e| e.into_inner()).clone() { out.push(d.join(LIB_NAME)); }
    if let Ok(d) = std::env::var("TL_LLAMA_DIR") { out.push(PathBuf::from(d).join(LIB_NAME)); }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(d) = exe.parent() {
            out.push(d.join(LIB_NAME));
            out.push(d.join("llama").join(LIB_NAME));
            out.push(d.join("../llama").join(LIB_NAME));
        }
    }
    out.push(PathBuf::from("/app/llama").join(LIB_NAME));
    // Android: the app's own native libraries are found by name
    out.push(PathBuf::from(LIB_NAME));
    out
}

fn llama() -> Option<&'static Llama> {
    LLAMA.get_or_init(|| unsafe {
        // Windows on ARM: its GPUs are Qualcomm's, which this app does not run models on (and
        // llama.cpp's backends there are untried): no on-device AI; services still tag
        if cfg!(all(target_os = "windows", target_arch = "aarch64")) { return None; }
        for path in candidates() {
            if path.components().count() > 1 && !path.exists() { continue; }
            let lib = sys::open(&path);
            if lib.is_null() { continue; }
            macro_rules! sym { ($n:literal, $t:ty) => {{
                let p = sys::symbol(lib, CStr::from_bytes_with_nul($n).unwrap());
                if p.is_null() { None } else { Some(std::mem::transmute::<*mut c_void, $t>(p)) }
            }} }
            let (Some(init), Some(devices), Some(load), Some(describe), Some(unload), Some(free)) = (
                sym!(b"tl_llama_init\0", InitFn), sym!(b"tl_llama_devices\0", DevicesFn), sym!(b"tl_llama_load\0", LoadFn),
                sym!(b"tl_llama_describe\0", DescribeFn), sym!(b"tl_llama_unload\0", UnloadFn), sym!(b"tl_llama_free_string\0", FreeFn),
            ) else { continue };
            let dir = path.parent().filter(|p| !p.as_os_str().is_empty()).map(|p| CString::new(p.to_string_lossy().as_bytes()).unwrap_or_default());
            init(dir.as_ref().map_or(std::ptr::null(), |d| d.as_ptr()));
            eprintln!("local ai: loaded {}", path.display());
            return Some(Llama { devices, load, describe, unload, free });
        }
        None
    }).as_ref()
}

unsafe fn take(l: &Llama, p: *mut c_char) -> Option<String> {
    if p.is_null() { return None; }
    let s = CStr::from_ptr(p).to_string_lossy().into_owned();
    (l.free)(p);
    Some(s)
}

/// A device llama.cpp found (`tl_llama_devices`).
#[derive(Debug, Clone, Deserialize, serde::Serialize, PartialEq, Eq)]
pub struct Device {
    pub name: String,
    pub backend: String,
    pub description: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub free: u64,
    pub total: u64,
    #[serde(default)]
    pub id: String,
}

impl Device {
    pub fn is_gpu(&self) -> bool { self.kind == "gpu" || self.kind == "igpu" }
}

/// Whether the engine is there at all.
pub fn available() -> bool { llama().is_some() }

/// The devices llama.cpp found, with their memory as of now.
pub fn devices() -> Vec<Device> {
    let Some(l) = llama() else { return Vec::new() };
    let raw = unsafe { take(l, (l.devices)()) }.unwrap_or_default();
    serde_json::from_str(&raw).unwrap_or_default()
}

struct Loaded { key: String, handle: *mut c_void }
unsafe impl Send for Loaded {}

struct State { loaded: Option<Loaded>, last_used: Instant }

fn state() -> &'static Mutex<State> {
    static S: OnceLock<Mutex<State>> = OnceLock::new();
    S.get_or_init(|| {
        std::thread::spawn(|| loop {
            std::thread::sleep(Duration::from_secs(5));
            let Some(l) = LLAMA.get().and_then(Option::as_ref) else { continue };
            let Ok(mut g) = state().lock() else { continue };
            if g.loaded.is_some() && g.last_used.elapsed() >= Duration::from_secs(30) {
                if let Some(m) = g.loaded.take() { unsafe { (l.unload)(m.handle) }; }
            }
        });
        Mutex::new(State { loaded: None, last_used: Instant::now() })
    })
}

fn cstr(s: &str) -> CString { CString::new(s.replace('\0', "")).unwrap_or_default() }
fn cpath(p: &Path) -> CString { cstr(&p.to_string_lossy()) }

/// The files of a GGUF vision model.
#[derive(Debug, Clone)]
pub struct Gguf { pub weights: PathBuf, pub projector: Option<PathBuf> }

/// The model's answer about the picture at `image`, from the model loaded on `device`.
pub fn describe_gguf(model: &Gguf, device: &str, image: &Path, system: &str, question: &str, max_tokens: i32) -> AiResult<String> {
    let l = llama().ok_or_else(|| AiError::new(Kind::NoGpu))?;
    let key = format!("{device}\n{}\n{}", model.weights.display(), model.projector.as_deref().map(|p| p.display().to_string()).unwrap_or_default());
    let mut g = state().lock().unwrap_or_else(|e| e.into_inner());
    if g.loaded.as_ref().map(|m| &m.key) != Some(&key) {
        if let Some(m) = g.loaded.take() { unsafe { (l.unload)(m.handle) }; }
        let (w, p, d) = (cpath(&model.weights), model.projector.as_deref().map(cpath), cstr(device));
        let mut err: *mut c_char = std::ptr::null_mut();
        let handle = unsafe { (l.load)(w.as_ptr(), p.as_ref().map_or(std::ptr::null(), |p| p.as_ptr()), d.as_ptr(), 4096, 0, &mut err) };
        if handle.is_null() {
            let why = unsafe { take(l, err) }.unwrap_or_default();
            return Err(AiError::detail(Kind::Engine, why));
        }
        g.loaded = Some(Loaded { key, handle });
    }
    let handle = g.loaded.as_ref().map(|m| m.handle).unwrap_or(std::ptr::null_mut());
    let (i, s, q) = (cpath(image), cstr(system), cstr(question));
    let mut err: *mut c_char = std::ptr::null_mut();
    let answer = unsafe { (l.describe)(handle, i.as_ptr(), s.as_ptr(), q.as_ptr(), max_tokens, &mut err) };
    g.last_used = Instant::now();
    match unsafe { take(l, answer) } {
        // a token budget can end inside a character: what is half a character is dropped
        Some(a) => Ok(a.replace('\u{FFFD}', "")),
        None => {
            let why = unsafe { take(l, err) }.unwrap_or_default();
            // a GPU that gave up leaves the model unusable: loaded afresh next time
            if let Some(m) = g.loaded.take() { unsafe { (l.unload)(m.handle) }; }
            Err(AiError::detail(Kind::Engine, why))
        }
    }
}

/// MLX's answer about the picture at `image` from the model in `dir` (the Apple apps).
pub fn describe_mlx(dir: &Path, image: &Path, system: &str, question: &str, max_tokens: i32) -> AiResult<String> {
    let Some(m) = *MLX.lock().unwrap_or_else(|e| e.into_inner()) else { return Err(AiError::new(Kind::NoGpu)) };
    let (d, i, s, q) = (cpath(dir), cpath(image), cstr(system), cstr(question));
    let mut err: *mut c_char = std::ptr::null_mut();
    let answer = unsafe { (m.describe)(d.as_ptr(), i.as_ptr(), s.as_ptr(), q.as_ptr(), max_tokens, &mut err) };
    let take = |p: *mut c_char| -> Option<String> {
        if p.is_null() { return None; }
        let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
        unsafe { (m.free)(p) };
        Some(s)
    };
    take(answer).ok_or_else(|| AiError::detail(Kind::Engine, take(err).unwrap_or_default()))
}

/// Frees the loaded model now (the app goes to the background, the library closes).
pub fn unload() {
    let Some(l) = LLAMA.get().and_then(Option::as_ref) else { return };
    let mut g = state().lock().unwrap_or_else(|e| e.into_inner());
    if let Some(m) = g.loaded.take() { unsafe { (l.unload)(m.handle) }; }
}
