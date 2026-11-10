//! TwimShelf core: data model, persistence and ingest parsing.
/// Messages for the apps in their language (`tr!`), declared first so every module can use it.
#[macro_use]
pub mod i18n;
pub mod model;
pub mod crdt;
pub mod rules;
pub mod oplog;
pub mod sync;
pub mod bookmarks;
pub mod legacy;
pub mod storage;
pub mod store;
pub mod library;
pub mod actions;
pub mod net;
pub mod download;
pub mod extension;
pub mod share;
pub mod archive;
pub mod models;
pub mod hub;
pub mod pet;
pub mod catalog;
pub mod semantic;
pub mod verify;
pub mod media_size;
pub mod import;
pub mod grid;
pub mod discovery;
/// Discovery on Apple devices: the system's Bonjour.
#[cfg(target_vendor = "apple")]
mod dnssd;
/// Discovery on Android, Windows and Linux: mDNS of its own.
#[cfg(not(target_vendor = "apple"))]
mod mdnssd;
/// Specification of tagging and sync, checked by tests and Kani proofs.
pub mod tagmodel;
pub mod diagnostics;
pub mod protected;
pub mod ffi;
pub mod heif;
pub mod thumbs;
pub mod update;
pub mod sealed;

/// Test fixtures: a tiny file with a real JPEG signature (imports check content, not extensions).
#[cfg(test)]
pub mod testutil {
    pub fn jpg(b: &[u8]) -> Vec<u8> { let mut v = vec![0xFF, 0xD8, 0xFF, 0xE0]; v.extend_from_slice(b); v }
}
