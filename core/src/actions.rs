//! UI operations share one whole-post scope and carry receipts for conditional undo.
use crate::{library::Library, store::Store, rules::{self, TrashAction}, model::Origin};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, BTreeMap};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionKind { Trash, Restore, Purge, FolderAdd, FolderRemove, Tag }
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Stamp { pub id: String, pub hlc: u64, pub inc: u32, pub state: u8 }
impl Stamp {
    fn trash(db: &Store, id: &str) -> rusqlite::Result<Self> { let r = db.trash_reg(id)?; Ok(Self { id: id.into(), hlc: r.hlc, inc: r.inc, state: r.state }) }
    fn member(db: &Store, folder: &str, id: &str) -> rusqlite::Result<Self> { let r = db.member_reg(folder, id)?; Ok(Self { id: id.into(), hlc: r.map_or(0, |r| r.hlc), inc: 0, state: r.map_or(0, |r| r.origin) }) }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Receipt { pub kind: ActionKind, pub folder: Option<String>, pub folder_hlc: Option<u64>, pub epoch: u64, pub changes: Vec<Stamp> }
#[derive(Debug, Deserialize)]
pub struct ActionRequest {
    pub kind: ActionKind,
    #[serde(default)] pub media: Vec<String>,
    #[serde(default)] pub posts: Vec<String>,
    pub folder: Option<String>,
    pub label: Option<String>,
    /// A bin confirmation captures both the ids and their state. A later restore/redelete
    /// must not let an old confirmation delete the new incarnation.
    pub expected: Option<Vec<Stamp>>,
    pub epoch: Option<u64>,
}
#[derive(Debug, Serialize)]
pub struct MediaScope { pub ids: Vec<String>, pub pending_count: usize, pub user_tags: BTreeMap<String, Vec<String>> }
#[derive(Debug, Serialize, Deserialize)]
pub struct BinSnapshot { pub entries: Vec<Stamp>, pub pending_count: usize, pub epoch: u64 }

impl Store {
    pub fn action_ids(&self, media: &[String], posts: &[String]) -> rusqlite::Result<Vec<String>> {
        let mut ids: BTreeSet<String> = media.iter().cloned().collect();
        for p in posts { ids.extend(self.live_media_of_post(p)?); ids.extend(self.pending_media_of_post(p)?); }
        Ok(ids.into_iter().collect())
    }
    pub fn post_scope(&self, post: &str) -> rusqlite::Result<MediaScope> {
        let ids = self.action_ids(&[], &[post.into()])?;
        let pending_count = ids.iter().filter(|id| self.media_row(id).ok().flatten().is_none()).count();
        let mut user_tags = BTreeMap::new();
        for id in &ids { user_tags.insert(id.clone(), self.media_tags(id)?.into_iter().filter(|(_, o)| o & 1 != 0).map(|(l, _)| l).collect()); }
        Ok(MediaScope { ids, pending_count, user_tags })
    }
}
impl Library {
    pub fn bin_snapshot(&self) -> anyhow::Result<BinSnapshot> {
        let db = self.db();
        let mut entries = vec![]; let mut pending_count = 0;
        for (id, _) in db.trashed_ids()? { if db.media_row(&id)?.is_none() { pending_count += 1; } entries.push(Stamp::trash(&db, &id)?); }
        Ok(BinSnapshot { entries, pending_count, epoch: self.epoch() })
    }
    pub fn apply_action(&self, a: &ActionRequest) -> anyhow::Result<Receipt> {
        match self.apply_action_once(a) {
            Err(e) if Self::is_disk_full(&e) && self.reserve_path().exists() => { let _ = std::fs::remove_file(self.reserve_path()); self.apply_action_once(a) }
            result => result,
        }
    }
    fn apply_action_once(&self, a: &ActionRequest) -> anyhow::Result<Receipt> {
        let mut receipt = Receipt { kind: a.kind, folder: a.folder.as_ref().map(|f| f.trim().to_string()), folder_hlc: None, epoch: self.epoch(), changes: vec![] };
        {
            let db = self.db_at(a.epoch.unwrap_or(receipt.epoch))?;
            let tx = db.conn().unchecked_transaction()?;
            let ids = if let Some(expected) = &a.expected { expected.iter().map(|s| s.id.clone()).collect::<BTreeSet<_>>().into_iter().collect() } else { db.action_ids(&a.media, &a.posts)? };
            let folder = receipt.folder.as_deref().unwrap_or("");
            if matches!(a.kind, ActionKind::FolderAdd | ActionKind::FolderRemove) && folder.is_empty() { anyhow::bail!(tr!("action.folderEmpty")); }
            if a.kind == ActionKind::Tag && a.label.as_deref().unwrap_or("").trim().is_empty() { anyhow::bail!(tr!("action.tagEmpty")); }
            for id in ids {
                if let Some(expected) = &a.expected { if !expected.contains(&Stamp::trash(&db, &id)?) { continue; } }
                let changed = match a.kind {
                    ActionKind::Trash => db.trash_action(&id, TrashAction::Trash)?,
                    ActionKind::Restore => db.trash_action(&id, TrashAction::Restore)?,
                    ActionKind::Purge => db.trash_action(&id, TrashAction::Purge)?,
                    ActionKind::FolderAdd => db.add_to_folder(folder, &[id.clone()])? > 0,
                    ActionKind::FolderRemove => db.remove_from_folder(folder, &[id.clone()])? > 0,
                    ActionKind::Tag => {
                        if db.trash_reg(&id)?.state != rules::LIVE { continue; }
                        db.tag_media(&id, a.label.as_deref().unwrap(), Origin::USER)?; true
                    }
                };
                if changed { receipt.changes.push(if matches!(a.kind, ActionKind::FolderAdd | ActionKind::FolderRemove) { Stamp::member(&db, folder, &id)? } else { Stamp::trash(&db, &id)? }); }
            }
            if matches!(a.kind, ActionKind::FolderAdd | ActionKind::FolderRemove) { receipt.folder_hlc = db.folder_reg(folder)?.map(|r| r.hlc); }
            tx.commit()?;
        }
        if a.kind == ActionKind::Purge { self.settle()?; }
        Ok(receipt)
    }
    pub fn undo_action(&self, receipt: &Receipt) -> anyhow::Result<usize> {
        let db = self.db_at(receipt.epoch)?;
        let tx = db.conn().unchecked_transaction()?;
        let mut n = 0;
        if matches!(receipt.kind, ActionKind::FolderAdd | ActionKind::FolderRemove) {
            let current = db.folder_reg(receipt.folder.as_deref().unwrap_or(""))?;
            if current.map_or(true, |r| r.origin != 0 || Some(r.hlc) != receipt.folder_hlc) { return Ok(0); }
        }
        for stamp in &receipt.changes {
            match receipt.kind {
                ActionKind::Trash | ActionKind::Restore if Stamp::trash(&db, &stamp.id)? == *stamp => {
                    let a = if receipt.kind == ActionKind::Trash { TrashAction::Restore } else { TrashAction::Trash };
                    if db.trash_action(&stamp.id, a)? { n += 1; }
                }
                ActionKind::FolderAdd | ActionKind::FolderRemove => {
                    let f = receipt.folder.as_deref().unwrap_or("");
                    if Stamp::member(&db, f, &stamp.id)? == *stamp {
                        n += if receipt.kind == ActionKind::FolderAdd { db.remove_from_folder(f, &[stamp.id.clone()])? } else { db.add_to_folder(f, &[stamp.id.clone()])? };
                    }
                }
                _ => {}
            }
        }
        tx.commit()?; Ok(n)
    }
}
