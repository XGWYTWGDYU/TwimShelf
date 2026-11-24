//! Which GPU a model runs on, and whether a model fits this device.
//!
//! * Never the processor: without a GPU the engine can use, on-device AI is off.
//! * A phone or tablet has one GPU: Adreno (Qualcomm) through OpenCL, the backend Qualcomm makes
//!   for it, anything else (Mali, MediaTek) through Vulkan.
//! * A computer with more than one (an integrated and a discrete GPU, or an NVIDIA card, which shows
//!   up through CUDA and through Vulkan): the first real job runs on each, and the one that gives
//!   usable tags soonest is used from then on. The choice is remembered with the GPUs it was made
//!   among; when one goes (unplugged, or switched off on battery) or another comes, the next job
//!   chooses again.
use super::engine::Device;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// The GPUs llama.cpp can run a model on, as the engine reports them now.
pub fn gpus() -> Vec<Device> { super::engine::devices().into_iter().filter(Device::is_gpu).collect() }

/// The one GPU of a phone or tablet.
pub fn mobile_gpu(gpus: &[Device]) -> Option<&Device> {
    gpus.iter().find(|d| d.backend == "OpenCL").or_else(|| gpus.iter().find(|d| d.backend == "Vulkan")).or_else(|| gpus.first())
}

/// Whether this device chooses among its GPUs by trying them (computers), or has one (phones).
pub fn chooses() -> bool { !cfg!(any(target_os = "android", target_os = "ios")) }

/// What a choice was made among: every GPU, by its backend, model, place and memory.
pub fn fingerprint(gpus: &[Device]) -> Vec<String> {
    let mut v: Vec<String> = gpus.iter().map(|d| format!("{}|{}|{}|{}", d.backend, d.description, d.id, d.total)).collect();
    v.sort();
    v
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Choice {
    pub among: Vec<String>,
    /// The device's name (`Vulkan1`, `CUDA0`).
    pub device: String,
    /// What each took, from loading to usable tags (ms); `None`: it failed or had no room.
    pub trials: Vec<(String, Option<u64>)>,
}

fn choice_file(models_dir: &Path) -> PathBuf { models_dir.join(".gpu-choice.json") }

/// The remembered choice, if it was made among the GPUs there are now.
pub fn remembered(models_dir: &Path, gpus: &[Device]) -> Option<String> {
    let c: Choice = serde_json::from_slice(&std::fs::read(choice_file(models_dir)).ok()?).ok()?;
    (c.among == fingerprint(gpus) && gpus.iter().any(|d| d.name == c.device)).then_some(c.device)
}

pub fn remember(models_dir: &Path, choice: &Choice) {
    let _ = std::fs::create_dir_all(models_dir);
    if let Ok(b) = serde_json::to_vec_pretty(choice) { let _ = std::fs::write(choice_file(models_dir), b); }
}

/// Chooses again at the next job (the chosen GPU failed).
pub fn forget(models_dir: &Path) { let _ = std::fs::remove_file(choice_file(models_dir)); }

// ---- memory ----

/// The memory the app reports for its own GPU (Apple: Metal's recommended working set).
static MEMORY: std::sync::Mutex<Option<u64>> = std::sync::Mutex::new(None);
pub fn set_memory(bytes: u64) { *MEMORY.lock().unwrap_or_else(|e| e.into_inner()) = (bytes > 0).then_some(bytes); }

/// The memory of the largest GPU this device runs models on.
pub fn memory() -> Option<u64> {
    if let Some(m) = *MEMORY.lock().unwrap_or_else(|e| e.into_inner()) { return Some(m); }
    gpus().iter().map(|d| d.total).max().filter(|&m| m > 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dev(name: &str, backend: &str, total: u64) -> Device {
        Device { name: name.into(), backend: backend.into(), description: format!("{name} gpu"), kind: "gpu".into(), free: total, total, id: String::new() }
    }

    #[test]
    fn mobile_prefers_opencl_then_vulkan() {
        let g = [dev("Vulkan0", "Vulkan", 8), dev("GPUOpenCL", "OpenCL", 8)];
        assert_eq!(mobile_gpu(&g).unwrap().name, "GPUOpenCL");
        assert_eq!(mobile_gpu(&g[..1]).unwrap().name, "Vulkan0");
    }

    #[test]
    fn a_choice_holds_only_among_the_same_gpus() {
        let dir = std::env::temp_dir().join(format!("tl-gpu-{}", rand::random::<u64>()));
        let g = vec![dev("CUDA0", "CUDA", 32), dev("Vulkan0", "Vulkan", 32)];
        remember(&dir, &Choice { among: fingerprint(&g), device: "CUDA0".into(), trials: vec![] });
        assert_eq!(remembered(&dir, &g).as_deref(), Some("CUDA0"));
        // the card went (a laptop on battery): choose again
        assert_eq!(remembered(&dir, &g[1..]), None);
        // another came
        let mut more = g.clone();
        more.push(dev("Vulkan1", "Vulkan", 8));
        assert_eq!(remembered(&dir, &more), None);
        let _ = std::fs::remove_dir_all(dir);
    }
}
