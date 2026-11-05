//! 检查更新 (GitHub builds only): the newest published release of the build's repository, and its
//! installer for this platform. The front ends decide what "install" means there (iOS: the
//! release page; elsewhere the downloaded installer is opened). Only GitHub's public API is
//! contacted, without credentials, and only by a build that names its repository.
use crate::download::runtime;
use crate::net::client;
use anyhow::bail;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use tokio::io::AsyncWriteExt;

/// What the front end looks for.
#[derive(Debug, Clone, Deserialize)]
pub struct UpdateQuery {
    /// `owner/name`, baked into GitHub builds only.
    pub repo: String,
    /// This build's version (`1.2.3`).
    pub current: String,
    /// Installer endings in order of preference (`.dmg`, `.apk`, `.msix`, `.exe`, `.AppImage`);
    /// empty: no installer (iOS opens the release page).
    #[serde(default)] pub suffixes: Vec<String>,
    /// The Flutter builds' installers carry "flutter" in their names; the native ones do not.
    #[serde(default)] pub flutter: bool,
    /// `x64` or `arm64`; an installer naming the other one is skipped.
    #[serde(default)] pub arch: Option<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct UpdateInfo {
    pub version: String,
    pub page_url: String,
    pub notes: String,
    pub asset_name: Option<String>,
    pub asset_url: Option<String>,
    pub asset_size: u64,
    /// `sha256:<hex>` as GitHub reports it, checked after the download.
    pub asset_digest: Option<String>,
}

#[derive(Deserialize)]
struct Release { tag_name: String, html_url: String, #[serde(default)] body: Option<String>, #[serde(default)] draft: bool, #[serde(default)] prerelease: bool, #[serde(default)] assets: Vec<Asset> }
#[derive(Deserialize)]
struct Asset { name: String, browser_download_url: String, #[serde(default)] size: u64, #[serde(default)] digest: Option<String> }

/// `v1.10.0` > `1.9.2`: numeric parts compared in order, missing ones are 0, build data after `+`
/// ignored. A test version (`1.2.0-beta`) comes before its final release, never after it.
pub fn newer(candidate: &str, current: &str) -> bool {
    fn pre(v: &str) -> bool { v.split('+').next().unwrap_or("").contains('-') }
    fn parts(v: &str) -> Vec<u64> {
        v.trim().trim_start_matches(['v', 'V']).split(['-', '+']).next().unwrap_or("")
            .split('.').map(|p| p.parse().unwrap_or(0)).collect()
    }
    let (a, b) = (parts(candidate), parts(current));
    for i in 0..a.len().max(b.len()) {
        let (x, y) = (a.get(i).copied().unwrap_or(0), b.get(i).copied().unwrap_or(0));
        if x != y { return x > y }
    }
    pre(current) && !pre(candidate)
}

fn valid_repo(r: &str) -> bool {
    let mut it = r.split('/');
    let ok = |s: Option<&str>| s.map_or(false, |s| !s.is_empty() && s.len() <= 100 && s.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c)) && s != "." && s != "..");
    ok(it.next()) && ok(it.next()) && it.next().is_none()
}

fn pick<'a>(q: &UpdateQuery, assets: &'a [Asset]) -> Option<&'a Asset> {
    let other_arch: &[&str] = match q.arch.as_deref() { Some("arm64") => &["x64", "x86_64", "amd64"], Some("x64") => &["arm64", "aarch64"], _ => &[] };
    for suffix in &q.suffixes {
        let found = assets.iter().find(|a| {
            let n = a.name.to_lowercase();
            n.ends_with(&suffix.to_lowercase()) && n.contains("flutter") == q.flutter && !other_arch.iter().any(|o| n.contains(o))
        });
        if found.is_some() { return found }
    }
    None
}

/// The newest release when it is newer than this build; None when this build is current.
pub fn check(q: &UpdateQuery) -> anyhow::Result<Option<UpdateInfo>> {
    if !valid_repo(&q.repo) { bail!(tr!("update.badRepo")) }
    let url = format!("https://api.github.com/repos/{}/releases/latest", q.repo);
    let r: Release = runtime().block_on(async {
        let resp = client().get(&url).header("Accept", "application/vnd.github+json").header("X-GitHub-Api-Version", "2022-11-28")
            .timeout(std::time::Duration::from_secs(20)).send().await?;
        if !resp.status().is_success() { bail!(tr!("update.http", code = resp.status().as_u16())) }
        Ok::<_, anyhow::Error>(resp.json().await?)
    })?;
    if r.draft || r.prerelease || !newer(&r.tag_name, &q.current) { return Ok(None) }
    let asset = pick(q, &r.assets);
    Ok(Some(UpdateInfo {
        version: r.tag_name.trim_start_matches(['v', 'V']).to_string(),
        page_url: r.html_url,
        notes: r.body.unwrap_or_default(),
        asset_name: asset.map(|a| a.name.clone()),
        asset_url: asset.map(|a| a.browser_download_url.clone()),
        asset_size: asset.map_or(0, |a| a.size),
        asset_digest: asset.and_then(|a| a.digest.clone()),
    }))
}

/// Downloads the release's installer into `dir`, checks its size and digest, and returns the
/// file. Only GitHub's own download hosts are accepted.
pub fn download(info: &UpdateInfo, dir: &Path) -> anyhow::Result<PathBuf> {
    let (Some(url), Some(name)) = (info.asset_url.as_deref(), info.asset_name.as_deref()) else { bail!(tr!("update.noInstaller")) };
    let u = reqwest::Url::parse(url).map_err(|_| anyhow::anyhow!(tr!("update.badUrl")))?;
    if u.scheme() != "https" || u.host_str() != Some("github.com") { bail!(tr!("update.badUrl")) }
    if name.contains(['/', '\\']) || name.starts_with('.') { bail!(tr!("update.badUrl")) }
    std::fs::create_dir_all(dir)?;
    let out = dir.join(name);
    let part = dir.join(format!("{name}.partial"));
    runtime().block_on(async {
        let resp = client().get(url).send().await?;
        if !resp.status().is_success() { bail!(tr!("update.http", code = resp.status().as_u16())) }
        let mut f = tokio::fs::File::create(&part).await?;
        let mut hash = Sha256::new();
        let mut n: u64 = 0;
        let mut body = resp.bytes_stream();
        while let Some(chunk) = body.next().await {
            let chunk = chunk?;
            hash.update(&chunk);
            n += chunk.len() as u64;
            f.write_all(&chunk).await?;
        }
        f.flush().await?;
        drop(f);
        if info.asset_size > 0 && n != info.asset_size { bail!(tr!("update.sizeMismatch")) }
        if let Some(d) = info.asset_digest.as_deref().and_then(|d| d.strip_prefix("sha256:")) {
            if !hex::encode(hash.finalize()).eq_ignore_ascii_case(d) { bail!(tr!("update.digestMismatch")) }
        }
        Ok(())
    }).map_err(|e| { let _ = std::fs::remove_file(&part); e })?;
    let _ = std::fs::remove_file(&out);
    std::fs::rename(&part, &out)?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn versions() {
        assert!(newer("v1.10.0", "1.9.2"));
        assert!(newer("1.0.1", "1.0"));
        assert!(!newer("v1.0.0", "1.0"));
        assert!(!newer("1.0.0-beta", "1.0.0"));
        assert!(newer("1.0.0", "1.0.0-beta"), "the final release replaces its test version");
        assert!(!newer("1.0.0+2", "1.0.0"));
        assert!(!newer("1.0.0-rc.2", "1.0.0-rc.1"));
        assert!(!newer("0.9", "1.0"));
    }
    #[test] fn repos() {
        assert!(valid_repo("owner/TwimShelf"));
        for bad in ["owner", "a/b/c", "../x", "a/..", "a b/c", ""] { assert!(!valid_repo(bad), "{bad}") }
    }
    #[test] fn assets() {
        let a = |n: &str| Asset { name: n.into(), browser_download_url: String::new(), size: 0, digest: None };
        let list = [a("App-1.2-macos.dmg"), a("App-Flutter-1.2-macos.dmg"), a("App-Flutter-1.2-windows-arm64.msix"), a("App-Flutter-1.2-windows-x64.msix"), a("App-Flutter-1.2-android.apk")];
        let q = |s: &[&str], flutter: bool, arch: Option<&str>| UpdateQuery { repo: "o/r".into(), current: "1".into(), suffixes: s.iter().map(|x| x.to_string()).collect(), flutter, arch: arch.map(Into::into) };
        assert_eq!(pick(&q(&[".dmg"], false, None), &list).unwrap().name, "App-1.2-macos.dmg");
        assert_eq!(pick(&q(&[".dmg"], true, None), &list).unwrap().name, "App-Flutter-1.2-macos.dmg");
        assert_eq!(pick(&q(&[".msix", ".exe"], true, Some("x64")), &list).unwrap().name, "App-Flutter-1.2-windows-x64.msix");
        assert!(pick(&q(&[".AppImage"], true, Some("x64")), &list).is_none());
    }
}
