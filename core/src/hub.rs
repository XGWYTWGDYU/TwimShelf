//! The model store every app shows: Hugging Face's public API, read anonymously, filtered down to
//! what this device's engine can run and ranked by what its memory can hold. No server of ours,
//! no account, no scraping. Results the engine could not use are never dropped silently: each
//! comes back in `hidden` with its reason.
//!
//! What can be told before downloading is limited: "supported" means the engine knows the
//! architecture and every file a tagger needs is there, not that the model was tried. Sizes in a
//! list are estimates from the parameter count; a repo's detail has the real ones.
use std::sync::OnceLock;
use crate::download::runtime;
use crate::models::slug;
use crate::net::{client, read_limited};
use anyhow::{bail, Context};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

const API: &str = "https://huggingface.co/api/models";
/// One page of results: enough to choose from, small over a metered connection.
const PAGE: u32 = 30;
const MAX_ANSWER: usize = 16 << 20;
/// Models above this are not offered (the store is for small models that run on a device).
const MAX_PARAMS: u64 = 28_000_000_000;
const CACHE_FOR: Duration = Duration::from_secs(600);
const CACHE_ANSWERS: usize = 32;
/// What a download must leave free on the disk.
const SPARE_BYTES: u64 = 256 << 20;

/// Architectures `MLXVLM` (mlx-swift-lm's `VLMTypeRegistry`) builds, by config.json `model_type`.
/// `glm_ocr` is left out: it reads text, it does not describe a picture.
const MLX_TYPES: &[&str] = &["paligemma", "qwen2_vl", "qwen2_5_vl", "qwen3_vl", "qwen3_vl_moe", "qwen3_5", "qwen3_5_moe", "idefics3", "gemma3", "gemma4",
    "gemma4_unified", "smolvlm", "fastvlm", "llava_qwen2", "pixtral", "mistral3", "lfm2_vl", "lfm2-vl", "muse_glimmer"];
/// Text architectures of the llama.cpp in use (`TL_LLAMA_TAG`, v0.8.0) that its vision code
/// (`mtmd`) pairs with a projector. Update together with that tag.
const GGUF_ARCHS: &[&str] = &["qwen3vl", "qwen35", "gemma4", "qwen2vl", "gemma3", "llama", "llama4", "qwen2", "qwen3", "lfm2", "internlm2", "phi2", "phi3", "glm4", "minicpm"];
/// What to look for before anything was asked: the families these engines run. The most
/// downloaded GGUF vision models are often newer than this llama.cpp, so a plain "most popular"
/// can come back with nothing it can load.
const GGUF_FAMILIES: &[&str] = &["qwen3-vl", "qwen2.5-vl", "gemma-3", "smolvlm", "internvl", "moondream"];
const MLX_FAMILIES: &[&str] = &["qwen3-vl", "qwen2.5-vl", "gemma-3", "smolvlm"];
/// A page of results with nothing usable goes on to the next, this many times at most.
const MAX_EMPTY_PAGES: usize = 3;
/// Words people use in a repo's name or tags for a model with its refusals removed. A claim of
/// the community, never something checked here.
const CLAIMS: &[&str] = &["abliterated", "uncensored", "unfiltered", "derestricted", "de-restricted"];

#[derive(Debug, Clone, Serialize)]
pub struct DeviceProfile {
    pub memory_bytes: Option<u64>,
    pub free_bytes: Option<u64>,
    /// Phones and tablets: the system ends an app well before all the memory is in use.
    pub mobile: bool,
}

pub fn device(models_dir: &Path) -> DeviceProfile { DeviceProfile { free_bytes: crate::storage::free_space(models_dir), ..memory_profile() } }

/// The device without its disk: all a catalog entry's fit depends on.
pub fn memory_profile() -> DeviceProfile { DeviceProfile { memory_bytes: physical_memory(), free_bytes: None, mobile: cfg!(any(target_os = "ios", target_os = "android")) } }

#[cfg(unix)]
fn physical_memory() -> Option<u64> {
    let (pages, size) = unsafe { (libc::sysconf(libc::_SC_PHYS_PAGES), libc::sysconf(libc::_SC_PAGESIZE)) };
    (pages > 0 && size > 0).then(|| pages as u64 * size as u64)
}

#[cfg(windows)]
fn physical_memory() -> Option<u64> {
    #[repr(C)]
    struct MemoryStatusEx { length: u32, load: u32, total_phys: u64, avail_phys: u64, total_page: u64, avail_page: u64, total_virtual: u64, avail_virtual: u64, avail_extended: u64 }
    extern "system" { fn GlobalMemoryStatusEx(buffer: *mut MemoryStatusEx) -> i32; }
    let mut m: MemoryStatusEx = unsafe { std::mem::zeroed() };
    m.length = std::mem::size_of::<MemoryStatusEx>() as u32;
    (unsafe { GlobalMemoryStatusEx(&mut m) } != 0).then_some(m.total_phys)
}

/// How a download of `bytes` fits this device: `recommended`, `usable`, `tooLarge` or `unknown`.
/// The memory a loaded model takes is the sum the engines check before they load one.
pub fn tier(bytes: u64, d: &DeviceProfile) -> &'static str {
    let Some(memory) = d.memory_bytes else { return "unknown" };
    let need = bytes as u128 + bytes as u128 / 4 + 500_000_000;
    let (good, possible) = if d.mobile { (60, 75) } else { (60, 85) };
    if need * 100 <= memory as u128 * good { "recommended" } else if need * 100 <= memory as u128 * possible { "usable" } else { "tooLarge" }
}

#[derive(Debug, Clone, Serialize)]
pub struct HubRepo {
    pub repo: String,
    pub format: String,
    pub architecture: Option<String>,
    pub params: Option<u64>,
    pub downloads: u64,
    pub likes: u64,
    pub license: Option<String>,
    /// A revision the files can be pinned to.
    pub sha: Option<String>,
    /// The name or tags claim the refusals were removed.
    pub claims_uncensored: bool,
    /// From the parameter count; None when the repo does not say.
    pub estimated_bytes: Option<u64>,
    pub tier: &'static str,
}

#[derive(Debug, Clone, Serialize)]
pub struct HubHidden { pub repo: String, pub reason: String }

#[derive(Debug, Clone, Serialize)]
pub struct HubPage { pub device: DeviceProfile, pub items: Vec<HubRepo>, pub hidden: Vec<HubHidden>, pub next: Option<String> }

#[derive(Debug, Clone, Serialize)]
pub struct HubVariant {
    /// The quantization, as the file names it (`Q4_K_M`), or what the repo name says for MLX.
    pub label: String,
    pub weights: Option<String>,
    pub projector: Option<String>,
    pub bytes: u64,
    pub tier: &'static str,
    /// The one to take when no one has an opinion: good quality that fits.
    pub suggested: bool,
    /// False when the disk has too little room for it.
    pub enough_space: bool,
    /// The folder it installs into.
    pub folder: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct HubSkipped { pub name: String, pub reason: String }

#[derive(Debug, Clone, Serialize)]
pub struct HubDetail {
    pub repo: HubRepo,
    pub revision: String,
    pub variants: Vec<HubVariant>,
    /// Files of the repo that are not offered, and why.
    pub skipped: Vec<HubSkipped>,
    /// Why nothing can be installed from this repo.
    pub problem: Option<String>,
}

/// `org/name` from what was typed: that itself, or the address of the model's page.
pub fn parse_repo_input(text: &str) -> Option<String> {
    let t = text.trim();
    let rest = t.strip_prefix("https://huggingface.co/").or_else(|| t.strip_prefix("http://huggingface.co/")).or_else(|| t.strip_prefix("huggingface.co/")).unwrap_or(t);
    let is_address = rest.len() != t.len();
    let mut parts = rest.split(['?', '#']).next()?.split('/').filter(|p| !p.is_empty());
    let (org, name) = (parts.next()?, parts.next()?);
    // a search for "a/b/c" is text; on the site the rest of an address is only the tab of the page
    if !is_address && parts.next().is_some() { return None; }
    let repo = format!("{org}/{name}");
    valid_repo(&repo).then_some(repo)
}

/// Goes into addresses and a folder name: nothing but what Hugging Face allows in a repo id.
pub fn valid_repo(repo: &str) -> bool {
    let Some((org, name)) = repo.split_once('/') else { return false };
    let part = |p: &str| !p.is_empty() && p.len() <= 96 && !p.starts_with(['.', '-']) && !p.contains("..") && !p.ends_with(".") && p.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'));
    part(org) && part(name)
}

fn valid_revision(r: &str) -> bool { r.len() == 40 && r.chars().all(|c| c.is_ascii_hexdigit()) }

fn is_shard(name: &str) -> bool {
    static RE: OnceLock<regex::Regex> = OnceLock::new();
    RE.get_or_init(|| regex::Regex::new(r"(?i)-\d{5}-of-\d{5}\.gguf$").expect("pattern")).is_match(name)
}
fn is_projector(name: &str) -> bool { name.to_ascii_lowercase().contains("mmproj") }
fn is_gguf(name: &str) -> bool { name.to_ascii_lowercase().ends_with(".gguf") }

fn claims_uncensored(repo: &str, tags: &[String]) -> bool {
    let id = repo.to_ascii_lowercase();
    CLAIMS.iter().any(|c| id.contains(c) || tags.iter().any(|t| t.to_ascii_lowercase() == *c))
}

/// The weights of a typical 4-bit model and what comes with them, per parameter (the catalog's
/// models take 0.7 to 0.9 byte; 8-bit about twice that).
fn estimate(repo: &str, params: u64) -> u64 {
    let name = repo.to_ascii_lowercase();
    let per_thousand: u64 = if name.contains("8bit") || name.contains("8-bit") || name.contains("q8") { 1250 }
        else if name.contains("16") && (name.contains("bf16") || name.contains("fp16") || name.contains("f16")) { 2200 }
        else { 750 };
    params / 1000 * per_thousand
}

fn strings(v: &Value) -> Vec<String> { v.as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect()).unwrap_or_default() }

/// One result of the API: offered, or the reason it is not. Only what the answer itself shows;
/// a repo's detail checks further.
pub fn evaluate(format: &str, m: &Value, d: &DeviceProfile) -> Result<HubRepo, HubHidden> {
    let repo = m["id"].as_str().unwrap_or_default().to_string();
    let hide = |reason: String| HubHidden { repo: repo.clone(), reason };
    if !valid_repo(&repo) { return Err(hide(tr!("hub.hidden.badName"))); }
    // false, or the kind of access that has to be asked for ("auto", "manual")
    if !matches!(m["gated"], Value::Bool(false) | Value::Null) { return Err(hide(tr!("hub.hidden.gated"))); }
    let tags = strings(&m["tags"]);
    let (architecture, params) = if format == "gguf" {
        let arch = m["gguf"]["architecture"].as_str().map(str::to_string);
        match &arch {
            Some(a) if !GGUF_ARCHS.contains(&a.as_str()) => return Err(hide(tr!("hub.hidden.arch", arch = a))),
            None => return Err(hide(tr!("hub.hidden.noArch"))),
            _ => {}
        }
        let names: Vec<&str> = m["siblings"].as_array().map(|a| a.iter().filter_map(|s| s["rfilename"].as_str()).collect()).unwrap_or_default();
        let top: Vec<&str> = names.iter().copied().filter(|n| !n.contains('/') && is_gguf(n)).collect();
        if !names.iter().any(|n| !n.contains('/') && is_gguf(n) && is_projector(n)) { return Err(hide(tr!("hub.hidden.noVision"))); }
        if !top.iter().any(|n| !is_projector(n) && !is_shard(n)) { return Err(hide(tr!("hub.hidden.split"))); }
        (arch, m["gguf"]["total"].as_u64())
    } else {
        let t = m["config"]["model_type"].as_str().map(str::to_string);
        match &t {
            Some(a) if !MLX_TYPES.contains(&a.as_str()) => return Err(hide(tr!("hub.hidden.arch", arch = a))),
            None => return Err(hide(tr!("hub.hidden.noArch"))),
            _ => {}
        }
        // the engine's type alone does not make a tagger: some of these have a text-only form
        if matches!(m["pipeline_tag"].as_str(), Some("text-generation" | "feature-extraction" | "sentence-similarity")) { return Err(hide(tr!("hub.hidden.noVision"))); }
        (t, m["safetensors"]["total"].as_u64())
    };
    if params.map_or(false, |p| p > MAX_PARAMS) { return Err(hide(tr!("hub.hidden.tooManyParams"))); }
    let estimated_bytes = params.map(|p| estimate(&repo, p));
    let license = tags.iter().find_map(|t| t.strip_prefix("license:").map(str::to_string));
    Ok(HubRepo {
        claims_uncensored: claims_uncensored(&repo, &tags),
        tier: estimated_bytes.map_or("unknown", |b| tier(b, d)),
        format: format.into(), architecture, params, license, estimated_bytes,
        downloads: m["downloads"].as_u64().unwrap_or(0),
        likes: m["likes"].as_u64().unwrap_or(0),
        sha: m["sha"].as_str().filter(|s| valid_revision(s)).map(str::to_string),
        repo,
    })
}

fn expand(format: &str) -> &'static [&'static str] {
    if format == "gguf" { &["gguf", "siblings", "tags", "gated", "downloads", "likes", "sha", "pipeline_tag"] }
    else { &["safetensors", "config", "tags", "gated", "downloads", "likes", "sha", "pipeline_tag"] }
}

fn search_url(format: &str, query: &str, limit: u32) -> String {
    let mut u = url::Url::parse(API).expect("address");
    {
        let mut q = u.query_pairs_mut();
        if !query.is_empty() { q.append_pair("search", query); }
        q.append_pair("filter", if format == "gguf" { "gguf" } else { "mlx" });
        q.append_pair("sort", "downloads");
        q.append_pair("limit", &limit.to_string());
        for e in expand(format) { q.append_pair("expand[]", e); }
    }
    u.into()
}

fn repo_url(format: &str, repo: &str) -> String {
    let mut u = url::Url::parse(&format!("{API}/{repo}")).expect("address");
    { let mut q = u.query_pairs_mut(); for e in expand(format) { q.append_pair("expand[]", e); } }
    u.into()
}

/// The next page's address from a `Link` header. Comes back later from the app, so `is_own_page`
/// checks it again.
fn next_page(link: Option<&str>) -> Option<String> {
    link?.split(',').find(|p| p.contains("rel=\"next\""))?.split(';').next()?.trim().strip_prefix('<')?.strip_suffix('>').map(str::to_string)
}
fn is_own_page(address: &str) -> bool { address.starts_with("https://huggingface.co/api/models?") }

struct Answer { at: Instant, body: Value, next: Option<String> }
static CACHE: Mutex<Option<HashMap<String, Answer>>> = Mutex::new(None);

/// A GET of the API, kept a few minutes: going back and forth on a metered connection, and the
/// API's rate limit, should not pay for what was just asked.
fn get_json(address: &str) -> anyhow::Result<(Value, Option<String>)> {
    if let Some(a) = CACHE.lock().unwrap_or_else(|e| e.into_inner()).as_ref().and_then(|c| c.get(address)).filter(|a| a.at.elapsed() < CACHE_FOR) {
        return Ok((a.body.clone(), a.next.clone()));
    }
    let (body, next) = runtime().block_on(async {
        let resp = tokio::time::timeout(Duration::from_secs(30), client().get(address).send()).await.map_err(|_| anyhow::anyhow!(tr!("hub.err.network")))?.context(tr!("hub.err.network"))?;
        match resp.status().as_u16() {
            429 => bail!(tr!("hub.err.rateLimited")),
            401 | 403 | 404 => bail!(tr!("hub.err.notFound")),
            s if !(200..300).contains(&s) => bail!(tr!("hub.err.server", code = s)),
            _ => {}
        }
        let next = next_page(resp.headers().get("link").and_then(|l| l.to_str().ok()));
        let bytes = read_limited(resp, MAX_ANSWER).await.context(tr!("hub.err.network"))?;
        Ok::<_, anyhow::Error>((serde_json::from_slice::<Value>(&bytes).context(tr!("hub.err.answer"))?, next))
    })?;
    let mut g = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    let c = g.get_or_insert_with(HashMap::new);
    if c.len() >= CACHE_ANSWERS { c.clear(); }
    c.insert(address.into(), Answer { at: Instant::now(), body: body.clone(), next: next.clone() });
    Ok((body, next))
}

/// Splits answers into what is offered and what is not, best fit first. Popularity orders only
/// models that fit equally well: it says nothing of how well a model tags.
pub fn assemble(format: &str, results: impl IntoIterator<Item = Value>, d: &DeviceProfile, next: Option<String>) -> HubPage {
    let (mut items, mut hidden, mut seen) = (vec![], vec![], HashSet::new());
    for m in results {
        // the same repo found by two of the searches is one result
        if !seen.insert(m["id"].as_str().unwrap_or_default().to_string()) { continue; }
        match evaluate(format, &m, d) { Ok(r) => items.push(r), Err(h) => hidden.push(h) }
    }
    let rank = |t: &str| match t { "recommended" => 0, "usable" => 1, "unknown" => 2, _ => 3 };
    items.sort_by(|a: &HubRepo, b: &HubRepo| rank(a.tier).cmp(&rank(b.tier)).then(b.downloads.cmp(&a.downloads)));
    HubPage { device: d.clone(), items, hidden, next }
}

/// A search: `next` continues an earlier one; text shaped like a repo or its address is that repo.
pub fn search(models_dir: &Path, format: &str, query: &str, uncensored: bool, next: Option<&str>) -> anyhow::Result<HubPage> {
    if format != "gguf" && format != "mlx" { bail!(tr!("hub.err.answer")); }
    let d = device(models_dir);
    let q = query.trim();
    if let Some(address) = next {
        if !is_own_page(address) { bail!(tr!("hub.err.answer")); }
        return walk(format, address.to_string(), &d);
    }
    if let Some(repo) = parse_repo_input(q) {
        let (body, _) = get_json(&repo_url(format, &repo))?;
        return Ok(assemble(format, [body], &d, None));
    }
    if uncensored {
        // the API has no such field: what people call it in repo names, in vision models unless
        // something else was asked for. The searches merge into one list, with no further page.
        let families = if format == "gguf" { GGUF_FAMILIES } else { MLX_FAMILIES };
        let bases: Vec<&str> = if q.is_empty() { families.iter().copied().take(2).chain(["vl"]).collect() } else { vec![q] };
        let mut all = vec![];
        for base in bases {
            for word in ["abliterated", "uncensored"] {
                let (body, _) = get_json(&search_url(format, &format!("{base} {word}"), PAGE))?;
                all.extend(body.as_array().cloned().unwrap_or_default());
            }
        }
        return Ok(assemble(format, all, &d, None));
    }
    if q.is_empty() {
        let families = if format == "gguf" { GGUF_FAMILIES } else { MLX_FAMILIES };
        let mut all = vec![];
        for family in families {
            let (body, _) = get_json(&search_url(format, family, PAGE / 3))?;
            all.extend(body.as_array().cloned().unwrap_or_default());
        }
        return Ok(assemble(format, all, &d, None));
    }
    walk(format, search_url(format, q, PAGE), &d)
}

/// Follows a search's pages until one has something to offer: a page can be all architectures the
/// engine cannot run, and the next one does not have to be asked for by hand to find out.
fn walk(format: &str, first: String, d: &DeviceProfile) -> anyhow::Result<HubPage> {
    let mut address = first;
    let mut all = HubPage { device: d.clone(), items: vec![], hidden: vec![], next: None };
    for _ in 0..MAX_EMPTY_PAGES {
        let (body, more) = get_json(&address)?;
        let page = assemble(format, body.as_array().cloned().unwrap_or_default(), d, more.filter(|n| is_own_page(n)));
        all.items.extend(page.items);
        all.hidden.extend(page.hidden);
        all.next = page.next;
        match (&all.next, all.items.is_empty()) { (Some(n), true) => address = n.clone(), _ => break }
    }
    Ok(all)
}

/// The quantization in a GGUF file's name.
fn quant_label(file: &str) -> String {
    static RE: OnceLock<regex::Regex> = OnceLock::new();
    RE.get_or_init(|| regex::Regex::new(r"(?i)(?:^|[-_.])((?:IQ|Q)\d+(?:_[A-Z0-9]+)*|BF16|F16|F32)(?:\.[a-z]+)?\.gguf$").expect("pattern")).captures(file).map_or_else(|| file.trim_end_matches(".gguf").to_string(), |c| c[1].to_ascii_uppercase())
}

/// Which GGUF to take: `Q4_K_M` (the usual balance) when it fits, otherwise the largest that is
/// recommended, otherwise the smallest. Nothing is suggested when only too-large ones exist.
fn suggest(v: &mut [HubVariant]) {
    let good = |x: &HubVariant| x.tier == "recommended" || x.tier == "unknown";
    let pick = v.iter().position(|x| x.label == "Q4_K_M" && good(x))
        .or_else(|| v.iter().enumerate().filter(|(_, x)| good(x)).max_by_key(|(_, x)| x.bytes).map(|(i, _)| i))
        .or_else(|| v.iter().enumerate().filter(|(_, x)| x.tier == "usable").min_by_key(|(_, x)| x.bytes).map(|(i, _)| i));
    if let Some(i) = pick { v[i].suggested = true; }
}

#[derive(Deserialize, Clone)]
struct TreeEntry { #[serde(rename = "type")] kind: String, path: String, #[serde(default)] size: u64 }

/// What can be installed from a repo's files. `vision` is what its config.json says (MLX).
fn offer(format: &str, repo: &HubRepo, tree: &[TreeEntry], vision: Option<bool>, d: &DeviceProfile) -> (Vec<HubVariant>, Vec<HubSkipped>, Option<String>) {
    let enough = |bytes: u64| d.free_bytes.map_or(true, |f| f >= bytes.saturating_add(SPARE_BYTES));
    let mut skipped = vec![];
    let mut variants = vec![];
    if format == "gguf" {
        let ggufs: Vec<&TreeEntry> = tree.iter().filter(|e| e.kind == "file" && is_gguf(&e.path)).collect();
        // the smallest projector: it only reads the picture, and takes little from the result
        let projector = ggufs.iter().filter(|e| is_projector(&e.path)).min_by_key(|e| e.size);
        for e in &ggufs {
            if is_projector(&e.path) { continue; }
            if is_shard(&e.path) { skipped.push(HubSkipped { name: e.path.clone(), reason: tr!("hub.skipped.split") }); continue; }
            let Some(p) = projector else { continue };
            let bytes = e.size.saturating_add(p.size);
            variants.push(HubVariant {
                label: quant_label(&e.path), weights: Some(e.path.clone()), projector: Some(p.path.clone()), bytes, tier: tier(bytes, d), suggested: false, enough_space: enough(bytes),
                folder: format!("{}--{}", slug(&repo.repo), e.path.trim_end_matches(".gguf")),
            });
        }
        for e in tree.iter().filter(|e| e.kind == "directory") { skipped.push(HubSkipped { name: e.path.clone(), reason: tr!("hub.skipped.folder") }); }
        variants.sort_by_key(|v| v.bytes);
        suggest(&mut variants);
        let problem = if projector.is_none() { Some(tr!("hub.hidden.noVision")) } else if variants.is_empty() { Some(tr!("hub.hidden.split")) } else { None };
        return (variants, skipped, problem);
    }
    if vision != Some(true) { return (vec![], skipped, Some(tr!("hub.hidden.noVision"))); }
    let files: Vec<&TreeEntry> = tree.iter().filter(|e| e.kind == "file" && crate::models::is_wanted_file(&e.path)).collect();
    if !files.iter().any(|e| e.path.ends_with(".safetensors")) { return (vec![], skipped, Some(tr!("models.noWeights"))); }
    let bytes = files.iter().fold(0u64, |a, e| a.saturating_add(e.size));
    let name = repo.repo.to_ascii_lowercase();
    let label = ["4bit", "5bit", "6bit", "8bit", "bf16", "fp16"].iter().find(|b| name.contains(*b)).map_or_else(|| "MLX".to_string(), |b| b.to_string());
    let t = tier(bytes, d);
    variants.push(HubVariant { label, weights: None, projector: None, bytes, tier: t, suggested: t != "tooLarge", enough_space: enough(bytes), folder: slug(&repo.repo) });
    (variants, skipped, None)
}

/// A repo's detail: its real files and sizes, at one revision.
pub fn detail(models_dir: &Path, format: &str, repo: &str) -> anyhow::Result<HubDetail> {
    if !valid_repo(repo) { bail!(tr!("hub.err.notFound")); }
    let d = device(models_dir);
    let (body, _) = get_json(&repo_url(format, repo))?;
    // shown even when the list would not offer it: someone who typed its address gets the reason
    let (info, hidden) = match evaluate(format, &body, &d) { Ok(r) => (r, None), Err(h) => (bare_repo(format, repo, &body), Some(h.reason)) };
    let revision = info.sha.clone().with_context(|| tr!("hub.err.answer"))?;
    if let Some(reason) = hidden {
        return Ok(HubDetail { repo: info, revision, variants: vec![], skipped: vec![], problem: Some(reason) });
    }
    let (tree, _) = get_json(&format!("{API}/{repo}/tree/{revision}"))?;
    let tree: Vec<TreeEntry> = serde_json::from_value(tree).context(tr!("hub.err.answer"))?;
    let vision = if format == "mlx" {
        let (config, _) = get_json(&format!("https://huggingface.co/{repo}/resolve/{revision}/config.json"))?;
        Some(config.get("vision_config").map_or(false, |v| !v.is_null()))
    } else { None };
    let (variants, skipped, problem) = offer(format, &info, &tree, vision, &d);
    let mut info = info;
    if let Some(v) = variants.iter().find(|v| v.suggested).or(variants.first()) { info.tier = v.tier; info.estimated_bytes = Some(v.bytes); }
    Ok(HubDetail { repo: info, revision, variants, skipped, problem })
}

fn bare_repo(format: &str, repo: &str, m: &Value) -> HubRepo {
    let tags = strings(&m["tags"]);
    HubRepo { repo: repo.into(), format: format.into(), architecture: None, params: None, downloads: m["downloads"].as_u64().unwrap_or(0), likes: m["likes"].as_u64().unwrap_or(0),
        license: tags.iter().find_map(|t| t.strip_prefix("license:").map(str::to_string)), sha: m["sha"].as_str().filter(|s| valid_revision(s)).map(str::to_string),
        claims_uncensored: claims_uncensored(repo, &tags), estimated_bytes: None, tier: "unknown" }
}

#[derive(Debug, Deserialize)]
pub struct InstallRequest {
    pub format: String,
    pub repo: String,
    /// Absent for the catalog's models, which follow their repo.
    #[serde(default)] pub revision: Option<String>,
    #[serde(default)] pub weights: Option<String>,
    #[serde(default)] pub projector: Option<String>,
    /// What the files take, for the check of the disk.
    #[serde(default)] pub bytes: u64,
    /// The folder it installs into: what an earlier, interrupted try already left there counts.
    #[serde(default)] pub folder: Option<String>,
}

/// Starts a download after the checks that can be done before it. Goes through the same download
/// as every model: sizes and SHA-256 checked, one at a time, cancellable, resumable.
pub fn install(models_dir: &Path, r: InstallRequest) -> anyhow::Result<()> {
    if !valid_repo(&r.repo) { bail!(tr!("models.badName")); }
    if r.revision.as_deref().map_or(false, |v| !valid_revision(v)) { bail!(tr!("models.badName")); }
    let have = r.folder.as_deref().filter(|f| crate::models::checked_id(f).is_ok()).map_or(0, |f| crate::storage::size_of(&models_dir.join(f)).0);
    let needed = r.bytes.saturating_sub(have).saturating_add(SPARE_BYTES);
    if let Some(free) = crate::storage::free_space(models_dir) {
        if r.bytes > 0 && free < needed { bail!(tr!("hub.err.noSpace", need = gb(needed), free = gb(free))); }
    }
    match (r.format.as_str(), r.weights) {
        ("gguf", Some(w)) => crate::models::start_download_gguf(r.repo, r.revision, w, r.projector, models_dir.to_path_buf()),
        ("mlx", None) => crate::models::start_download(r.repo, r.revision, models_dir.to_path_buf()),
        _ => bail!(tr!("models.badName")),
    }
}

fn gb(bytes: u64) -> String { format!("{:.1} GB", bytes as f64 / 1e9) }

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn device_with(memory_gb: u64, mobile: bool) -> DeviceProfile { DeviceProfile { memory_bytes: Some(memory_gb * 1_000_000_000), free_bytes: Some(100_000_000_000), mobile } }

    fn gguf_repo(id: &str, arch: &str, total: u64, files: &[&str]) -> Value {
        json!({"id": id, "gated": false, "downloads": 5, "likes": 1, "sha": "f982a07559d4a2f6c8744d840bf6fccab30eea96", "tags": ["gguf", "license:apache-2.0"],
               "gguf": {"architecture": arch, "total": total}, "siblings": files.iter().map(|f| json!({"rfilename": f})).collect::<Vec<_>>()})
    }

    #[test]
    fn memory_decides_how_a_model_fits() {
        // the catalog's own picks: 2B on a phone, 4B from 7 GB, 8B from 15 GB
        assert_eq!(tier(1_800_000_000, &device_with(6, true)), "recommended");
        assert_eq!(tier(3_110_000_000, &device_with(8, true)), "recommended");
        assert_eq!(tier(5_770_000_000, &device_with(16, false)), "recommended");
        assert_eq!(tier(5_770_000_000, &device_with(8, true)), "tooLarge");
        assert_eq!(tier(5_770_000_000, &device_with(10, false)), "usable");
        assert_eq!(tier(20_000_000_000, &device_with(16, false)), "tooLarge");
        assert_eq!(tier(1, &DeviceProfile { memory_bytes: None, free_bytes: None, mobile: false }), "unknown");
    }

    #[test]
    fn more_memory_never_fits_worse_and_a_larger_model_never_fits_better() {
        let rank = |t: &str| match t { "recommended" => 0, "usable" => 1, _ => 2 };
        for gb in 1..128 {
            for bytes in [1u64 << 30, 3 << 30, 8 << 30, 20 << 30] {
                for mobile in [false, true] {
                    assert!(rank(tier(bytes, &device_with(gb + 1, mobile))) <= rank(tier(bytes, &device_with(gb, mobile))));
                    assert!(rank(tier(bytes * 2, &device_with(gb, mobile))) >= rank(tier(bytes, &device_with(gb, mobile))));
                }
            }
        }
    }

    #[test]
    fn only_what_the_engine_can_tag_with_is_offered_and_the_rest_says_why() {
        let d = device_with(16, false);
        let ok = gguf_repo("a/vl-GGUF", "qwen2vl", 3_000_000_000, &["m-Q4_K_M.gguf", "mmproj-m.gguf"]);
        assert_eq!(evaluate("gguf", &ok, &d).unwrap().tier, "recommended");
        // an architecture this llama.cpp does not have: its files would download and then not load
        assert!(evaluate("gguf", &gguf_repo("a/new-GGUF", "qwen9vl", 4_000_000_000, &["m.gguf", "mmproj.gguf"]), &d).unwrap_err().reason.contains("qwen9vl"));
        assert!(evaluate("gguf", &gguf_repo("a/text-GGUF", "qwen2", 4_000_000_000, &["m.gguf"]), &d).is_err(), "no projector: it cannot see a picture");
        assert!(evaluate("gguf", &gguf_repo("a/split-GGUF", "qwen2vl", 4_000_000_000, &["m-00001-of-00002.gguf", "mmproj.gguf"]), &d).is_err());
        assert!(evaluate("gguf", &gguf_repo("a/big-GGUF", "qwen2vl", 40_000_000_000, &["m.gguf", "mmproj.gguf"]), &d).is_err(), "above the store's size");
        let mut gated = ok.clone();
        gated["gated"] = json!("manual");
        assert!(evaluate("gguf", &gated, &d).is_err());
        let mlx = |t: &str, pipe: &str| json!({"id": "a/m-mlx", "config": {"model_type": t}, "pipeline_tag": pipe, "safetensors": {"total": 4_000_000_000u64}, "sha": "f982a07559d4a2f6c8744d840bf6fccab30eea96", "gated": false});
        assert!(evaluate("mlx", &mlx("qwen3_vl", "image-text-to-text"), &d).is_ok());
        assert!(evaluate("mlx", &mlx("glm_ocr", "image-text-to-text"), &d).is_err());
        assert!(evaluate("mlx", &mlx("qwen3_5", "text-generation"), &d).is_err());
    }

    #[test]
    fn nothing_is_dropped_silently() {
        let d = device_with(16, false);
        let results = vec![gguf_repo("a/ok", "qwen2vl", 3_000_000_000, &["m.gguf", "mmproj.gguf"]), gguf_repo("a/no", "bert", 3_000_000_000, &["m.gguf"]), gguf_repo("a/ok", "qwen2vl", 3_000_000_000, &["m.gguf", "mmproj.gguf"])];
        let p = assemble("gguf", results, &d, None);
        assert_eq!(p.items.len() + p.hidden.len(), 2, "the same repo twice is one result; the others are all accounted for");
        assert_eq!(p.hidden[0].repo, "a/no");
    }

    #[test]
    fn what_fits_comes_first_whatever_its_popularity() {
        let d = device_with(8, false);
        let mut big = gguf_repo("a/big", "qwen2vl", 14_000_000_000, &["m.gguf", "mmproj.gguf"]);
        big["downloads"] = json!(1_000_000);
        let small = gguf_repo("a/small", "qwen2vl", 3_000_000_000, &["m.gguf", "mmproj.gguf"]);
        let p = assemble("gguf", [big, small], &d, None);
        assert_eq!(p.items[0].repo, "a/small");
        assert_eq!(p.items[1].tier, "tooLarge");
    }

    #[test]
    fn a_claim_is_read_from_the_name_or_tags_and_nothing_else() {
        assert!(claims_uncensored("a/Huihui-Qwen3-VL-abliterated-4bit", &[]));
        assert!(claims_uncensored("a/b", &["Uncensored".to_string()]));
        assert!(!claims_uncensored("a/Qwen3-VL-4B", &["license:apache-2.0".to_string()]));
    }

    #[test]
    fn typed_repos_and_addresses() {
        assert_eq!(parse_repo_input("ggml-org/Qwen2.5-VL-3B-Instruct-GGUF").as_deref(), Some("ggml-org/Qwen2.5-VL-3B-Instruct-GGUF"));
        assert_eq!(parse_repo_input(" https://huggingface.co/a/b/tree/main?x=1 ").as_deref(), Some("a/b"));
        assert_eq!(parse_repo_input("qwen vl"), None);
        assert_eq!(parse_repo_input("a/b/c"), None);
        for bad in ["../etc", "a/..", "a/.git", "a/b c", "a\\b/c", "-a/b", "/", "a/", "a/b/"] { assert!(!valid_repo(bad), "{bad}"); }
        assert!(valid_repo("mlx-community/Qwen2.5-VL-3B_x"));
    }

    #[test]
    fn a_next_page_stays_on_the_api() {
        assert_eq!(next_page(Some("<https://huggingface.co/api/models?cursor=x>; rel=\"next\"")).as_deref(), Some("https://huggingface.co/api/models?cursor=x"));
        assert_eq!(next_page(Some("<https://huggingface.co/api/models?cursor=x>; rel=\"prev\"")), None);
        assert!(is_own_page("https://huggingface.co/api/models?cursor=x"));
        assert!(!is_own_page("https://example.com/api/models?cursor=x"));
        assert!(!is_own_page("https://huggingface.co.example.com/api/models?x"));
    }

    fn entry(path: &str, size: u64) -> TreeEntry { TreeEntry { kind: "file".into(), path: path.into(), size } }
    fn info(repo: &str, format: &str) -> HubRepo {
        HubRepo { repo: repo.into(), format: format.into(), architecture: None, params: None, downloads: 0, likes: 0, license: None, sha: None, claims_uncensored: false, estimated_bytes: None, tier: "unknown" }
    }

    #[test]
    fn a_gguf_repo_offers_each_quantization_with_the_smallest_projector() {
        let d = device_with(16, false);
        let tree = vec![entry("README.md", 10), entry("m-Q4_K_M.gguf", 2_000_000_000), entry("m-Q8_0.gguf", 3_300_000_000), entry("m-f16.gguf", 6_200_000_000),
            entry("mmproj-m-f16.gguf", 1_300_000_000), entry("mmproj-m-Q8_0.gguf", 800_000_000), entry("big-00001-of-00002.gguf", 9),
            TreeEntry { kind: "directory".into(), path: "Q2".into(), size: 0 }];
        let (v, skipped, problem) = offer("gguf", &info("a/m", "gguf"), &tree, None, &d);
        assert!(problem.is_none());
        assert_eq!(v.iter().map(|x| x.label.as_str()).collect::<Vec<_>>(), ["Q4_K_M", "Q8_0", "F16"]);
        assert!(v.iter().all(|x| x.projector.as_deref() == Some("mmproj-m-Q8_0.gguf")));
        assert_eq!(v[0].bytes, 2_800_000_000);
        assert!(v[0].suggested && !v[1].suggested && !v[2].suggested);
        assert_eq!(v[0].folder, "a--m--m-Q4_K_M", "the folder the download makes");
        assert_eq!(skipped.len(), 2, "what is not offered is listed");
    }

    #[test]
    fn the_suggestion_follows_the_device() {
        // too small a device for Q4_K_M: the smallest that can run is offered instead
        let tree = vec![entry("m-Q2_K.gguf", 1_500_000_000), entry("m-Q4_K_M.gguf", 4_000_000_000), entry("mmproj.gguf", 500_000_000)];
        let (v, ..) = offer("gguf", &info("a/m", "gguf"), &tree, None, &device_with(6, true));
        assert_eq!(v.iter().find(|x| x.suggested).unwrap().label, "Q2_K");
        // nothing that fits: nothing suggested, and still all shown
        let (v, ..) = offer("gguf", &info("a/m", "gguf"), &tree, None, &device_with(1, true));
        assert!(v.iter().all(|x| !x.suggested) && v.len() == 2);
    }

    #[test]
    fn a_full_disk_is_said_before_the_download() {
        let d = DeviceProfile { memory_bytes: Some(16_000_000_000), free_bytes: Some(1_000_000_000), mobile: false };
        let (v, ..) = offer("gguf", &info("a/m", "gguf"), &[entry("m.gguf", 2_000_000_000), entry("mmproj.gguf", 1)], None, &d);
        assert!(!v[0].enough_space);
    }

    #[test]
    fn an_mlx_repo_must_be_a_vision_model_with_weights() {
        let d = device_with(16, false);
        let tree = vec![entry("config.json", 100), entry("model.safetensors", 3_000_000_000), entry("README.md", 10)];
        let (v, _, p) = offer("mlx", &info("a/m", "mlx"), &tree, Some(true), &d);
        assert!(p.is_none());
        assert_eq!((v[0].bytes, v[0].folder.as_str()), (3_000_000_100, "a--m"));
        // installed, a config without a vision part would count as an embedder
        assert!(offer("mlx", &info("a/m", "mlx"), &tree, Some(false), &d).2.is_some());
        assert!(offer("mlx", &info("a/m", "mlx"), &[entry("config.json", 1)], Some(true), &d).2.is_some());
    }

    #[test]
    fn labels_from_file_names() {
        assert_eq!(quant_label("Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf"), "Q4_K_M");
        assert_eq!(quant_label("Qwen2.5-VL-3B-Instruct-f16.gguf"), "F16");
        assert_eq!(quant_label("model.Q8_0.gguf"), "Q8_0");
        assert_eq!(quant_label("model-IQ3_S.gguf"), "IQ3_S");
        assert_eq!(quant_label("plain.gguf"), "plain");
    }

    #[test]
    fn an_install_is_refused_before_anything_starts() {
        let dir = std::env::temp_dir();
        let r = |repo: &str, revision: Option<&str>| InstallRequest { format: "mlx".into(), repo: repo.into(), revision: revision.map(Into::into), weights: None, projector: None, bytes: 0, folder: None };
        assert!(install(&dir, r("../up", None)).is_err());
        assert!(install(&dir, r("a/b", Some("main/../x"))).is_err());
        let huge = InstallRequest { bytes: u64::MAX / 2, ..r("a/b", None) };
        assert!(install(&dir, huge).unwrap_err().to_string().contains("GB"), "no room: it says how much is missing");
    }
}
