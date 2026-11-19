use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use axum::extract::{Path as UrlPath, State};
use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use tl_core::sealed;

use crate::Shared;

pub struct Secrets {
    dir: PathBuf,
    lock: Mutex<()>,
}

impl Secrets {
    pub fn new(dir: PathBuf) -> Self { Self { dir, lock: Mutex::new(()) } }

    fn records(&self) -> anyhow::Result<BTreeMap<String, String>> {
        Ok(read_optional(&self.dir.join("secrets.json"))?
            .map(|json| serde_json::from_str(&json)).transpose()?.unwrap_or_default())
    }

    pub fn read<const N: usize>(&self, names: [&str; N]) -> anyhow::Result<[Option<String>; N]> {
        let _guard = self.lock.lock().map_err(|_| anyhow::anyhow!("secret store lock"))?;
        let records = self.records()?;
        let mut values = std::array::from_fn(|_| None);
        if names.iter().any(|name| records.contains_key(*name)) {
            let key = fs::read_to_string(self.dir.join("secrets.key"))?;
            for (name, value) in names.into_iter().zip(&mut values) {
                if let Some(blob) = records.get(name) { *value = Some(sealed::open(key.trim(), blob)?); }
            }
        }
        Ok(values)
    }

    fn update(&self, patch: BTreeMap<String, Option<String>>) -> anyhow::Result<()> {
        let _guard = self.lock.lock().map_err(|_| anyhow::anyhow!("secret store lock"))?;
        let mut records = self.records()?;
        let key_path = self.dir.join("secrets.key");
        let mut key = read_optional(&key_path)?;
        let mut new_key = false;
        for (name, value) in patch {
            if let Some(value) = value.filter(|value| !value.is_empty()) {
                if key.is_none() {
                    anyhow::ensure!(records.is_empty(), "the existing secret store has no key");
                    key = Some(sealed::new_key());
                    new_key = true;
                }
                let blob = sealed::seal(key.as_deref().unwrap_or_default().trim(), &value)?;
                records.insert(name, blob);
            } else {
                records.remove(&name);
            }
        }
        if new_key {
            // The key must survive any crash that leaves the corresponding ciphertext in place.
            write_atomic(&key_path, key.as_deref().unwrap_or_default().as_bytes())?;
        }
        write_atomic(&self.dir.join("secrets.json"), &serde_json::to_vec(&records)?)
    }

    fn clear(&self) -> anyhow::Result<()> {
        let _guard = self.lock.lock().map_err(|_| anyhow::anyhow!("secret store lock"))?;
        for name in ["secrets.json", "secrets.key"] {
            match fs::remove_file(self.dir.join(name)) {
                Ok(()) => sync_dir(&self.dir)?,
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
        }
        Ok(())
    }
}

fn read_optional(path: &Path) -> io::Result<Option<String>> {
    match fs::read_to_string(path) {
        Ok(value) => Ok(Some(value)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

fn sync_dir(dir: &Path) -> io::Result<()> {
    #[cfg(unix)]
    File::open(dir)?.sync_all()?;
    Ok(())
}

fn write_atomic(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    let dir = path.parent().ok_or_else(|| anyhow::anyhow!("secret store directory"))?;
    let temporary = dir.join(format!(".secrets-{:016x}.tmp", rand::random::<u64>()));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temporary)?;
    let result = (|| {
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, path)?;
        sync_dir(dir)
    })();
    if result.is_err() { let _ = fs::remove_file(&temporary); }
    result.map_err(Into::into)
}

pub async fn read(State(cfg): State<Shared>, UrlPath(name): UrlPath<String>) -> Response {
    match tokio::task::spawn_blocking(move || cfg.secrets.read([name.as_str()])).await {
        Ok(Ok([value])) => ([(header::CACHE_CONTROL, "no-store")], Json(value)).into_response(),
        _ => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

pub async fn update(State(cfg): State<Shared>, Json(patch): Json<BTreeMap<String, Option<String>>>) -> StatusCode {
    match tokio::task::spawn_blocking(move || cfg.secrets.update(patch)).await {
        Ok(Ok(())) => StatusCode::NO_CONTENT,
        _ => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

pub async fn clear(State(cfg): State<Shared>) -> StatusCode {
    match tokio::task::spawn_blocking(move || cfg.secrets.clear()).await {
        Ok(Ok(())) => StatusCode::NO_CONTENT,
        _ => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> Secrets {
        let dir = std::env::temp_dir().join(format!("tl-secret-store-{:016x}", rand::random::<u64>()));
        fs::create_dir(&dir).unwrap();
        Secrets::new(dir)
    }

    #[test]
    fn updates_keep_existing_sealed_records_and_their_key() {
        let store = store();
        let key = sealed::new_key();
        let account = sealed::seal(&key, "old account").unwrap();
        fs::write(store.dir.join("secrets.key"), format!("{key}\n")).unwrap();
        fs::write(store.dir.join("secrets.json"), serde_json::to_vec(&BTreeMap::from([("sync.key", &account)])).unwrap()).unwrap();
        store.update(BTreeMap::from([("ct0".into(), Some("new cookie".into()))])).unwrap();
        assert_eq!(store.read(["sync.key", "ct0"]).unwrap(), [Some("old account".into()), Some("new cookie".into())]);
        assert_eq!(fs::read_to_string(store.dir.join("secrets.key")).unwrap().trim(), key);
        assert_eq!(store.records().unwrap()["sync.key"], account);
        fs::remove_dir_all(store.dir).unwrap();
    }

    #[test]
    fn refuses_to_replace_records_when_their_key_is_missing() {
        let store = store();
        let records = r#"{"sync.key":"existing ciphertext"}"#;
        fs::write(store.dir.join("secrets.json"), records).unwrap();
        assert!(store.update(BTreeMap::from([("ct0".into(), Some("new cookie".into()))])).is_err());
        assert_eq!(fs::read_to_string(store.dir.join("secrets.json")).unwrap(), records);
        assert!(!store.dir.join("secrets.key").exists());
        fs::remove_dir_all(store.dir).unwrap();
    }
}
