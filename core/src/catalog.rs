//! The models every app offers to download, in one place: MLX folders for Apple devices, GGUF
//! files for llama.cpp (Android, Windows, Linux). Names and notes are catalog keys the front
//! ends translate; sizes are what a download takes.
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct CatalogModel {
    pub repo: &'static str,
    /// `mlx` or `gguf`.
    pub format: &'static str,
    /// `tagger` (a vision model) or `embedder`.
    pub role: &'static str,
    pub name_key: &'static str,
    pub note_key: &'static str,
    pub bytes: u64,
    pub uncensored: bool,
    /// The smallest device memory (GB) this tagger is recommended for: the largest that fits wins.
    /// More than any device has (100): offered in the list, but never picked by itself.
    pub recommend_gb: u32,
    /// GGUF: the files taken from the repo.
    pub weights: Option<&'static str>,
    pub projector: Option<&'static str>,
}

const fn mlx(repo: &'static str, role: &'static str, name_key: &'static str, note_key: &'static str, bytes: u64, uncensored: bool, recommend_gb: u32) -> CatalogModel {
    CatalogModel { repo, format: "mlx", role, name_key, note_key, bytes, uncensored, recommend_gb, weights: None, projector: None }
}
const fn gguf(repo: &'static str, role: &'static str, name_key: &'static str, note_key: &'static str, bytes: u64, recommend_gb: u32, weights: &'static str, projector: Option<&'static str>) -> CatalogModel {
    CatalogModel { repo, format: "gguf", role, name_key, note_key, bytes, uncensored: false, recommend_gb, weights: Some(weights), projector }
}

pub const ALL: &[CatalogModel] = &[
    mlx("EZCon/Huihui-Qwen3-VL-2B-Instruct-abliterated-4bit-mlx", "tagger", "catalog.qwen3vl2b", "catalog.note.iphone", 1_800_000_000, true, 0),
    mlx("mlx-community/Qwen2.5-VL-3B-Instruct-abliterated-4bit", "tagger", "catalog.qwen25vl3b", "catalog.note.iphonePro", 2_330_000_000, true, 100),
    mlx("EZCon/Huihui-Qwen3-VL-4B-Instruct-abliterated-4bit-mlx", "tagger", "catalog.qwen3vl4b", "catalog.note.ipad", 3_110_000_000, true, 7),
    mlx("alexgusevski/Huihui-Qwen3-VL-8B-Instruct-abliterated-q4-mlx", "tagger", "catalog.qwen3vl8b", "catalog.note.mac", 5_770_000_000, true, 15),
    mlx("mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ", "embedder", "catalog.qwen3embedding", "catalog.note.embedder", 350_000_000, false, 0),
    gguf("ggml-org/Qwen2.5-VL-3B-Instruct-GGUF", "tagger", "catalog.gguf.qwen25vl3b", "catalog.note.gguf.small", 2_860_000_000, 0,
         "Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf", Some("mmproj-Qwen2.5-VL-3B-Instruct-Q8_0.gguf")),
    gguf("ggml-org/Qwen2.5-VL-7B-Instruct-GGUF", "tagger", "catalog.gguf.qwen25vl7b", "catalog.note.gguf.large", 5_500_000_000, 15,
         "Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf", Some("mmproj-Qwen2.5-VL-7B-Instruct-Q8_0.gguf")),
    gguf("Qwen/Qwen3-Embedding-0.6B-GGUF", "embedder", "catalog.qwen3embedding", "catalog.note.embedder", 640_000_000, 0,
         "Qwen3-Embedding-0.6B-Q8_0.gguf", None),
];

/// The catalog for one format, in display order.
pub fn for_format(format: &str) -> Vec<CatalogModel> { ALL.iter().filter(|m| m.format == format).cloned().collect() }

/// The folder a catalog model installs into (models.rs names them the same way).
pub fn folder(m: &CatalogModel) -> String {
    match m.weights { None => crate::models::slug(m.repo), Some(w) => format!("{}--{}", crate::models::slug(m.repo), w.trim_end_matches(".gguf")) }
}

#[cfg(test)]
mod tests {
    #[test] fn names() {
        for m in super::ALL { assert!(m.bytes > 0); }
        assert_eq!(super::folder(&super::for_format("gguf")[0]), "ggml-org--Qwen2.5-VL-3B-Instruct-GGUF--Qwen2.5-VL-3B-Instruct-Q4_K_M");
    }
}
