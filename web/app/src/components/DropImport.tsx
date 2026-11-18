// Files dropped anywhere on the window are imported: pictures and videos as loose media (all of a
// drop in one import), a .zip of the old app or loose media, a .tlpack backup. Asks for a folder
// first, as the apps do.
import { useEffect, useState } from 'react';
import { L, type ImportReport } from '@twimshelf/core';
import { core } from '../lib/core';
import { libraryChanged } from '../lib/library';
import { pickFolder } from './pickers';
import { toast } from './toast';
import { Progress } from './ui';
import './DropImport.css';

async function uploadFile(file: File): Promise<string> {
  const r = await fetch(`${core.transport.base}/api/upload?${new URLSearchParams({ name: file.name })}`, { method: 'POST', body: file, credentials: 'same-origin' });
  if (!r.ok) throw new Error(await r.text() || `HTTP ${r.status}`);
  return ((await r.json()) as { path: string }).path;
}

async function move(from: string, to: string): Promise<void> {
  const r = await fetch(`${core.transport.base}/api/move`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ from, to }), credentials: 'same-origin' });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
}

const dirOf = (p: string) => p.slice(0, p.lastIndexOf('/'));

export function DropImport() {
  const [over, setOver] = useState(false);
  const [busy, setBusy] = useState<{ done: number; total: number } | null>(null);

  useEffect(() => {
    let depth = 0;
    const hasFiles = (e: DragEvent) => [...(e.dataTransfer?.types ?? [])].includes('Files');
    const enter = (e: DragEvent) => { if (!hasFiles(e)) return; e.preventDefault(); depth++; setOver(true); };
    const leave = (e: DragEvent) => { if (!hasFiles(e)) return; depth = Math.max(0, depth - 1); if (!depth) setOver(false); };
    const dragover = (e: DragEvent) => { if (hasFiles(e)) e.preventDefault(); };
    const drop = (e: DragEvent) => {
      if (!hasFiles(e)) return;
      e.preventDefault(); depth = 0; setOver(false);
      const files = [...(e.dataTransfer?.files ?? [])];
      if (files.length) void run(files);
    };
    window.addEventListener('dragenter', enter);
    window.addEventListener('dragleave', leave);
    window.addEventListener('dragover', dragover);
    window.addEventListener('drop', drop);
    return () => { window.removeEventListener('dragenter', enter); window.removeEventListener('dragleave', leave); window.removeEventListener('dragover', dragover); window.removeEventListener('drop', drop); };
  }, []);

  async function run(files: File[]) {
    const folder = await pickFolder({ title: L('common.importToFolder'), none: true });
    if (folder == null) return;
    setBusy({ done: 0, total: files.length });
    let imported = 0, dup = 0;
    try {
      const archives = files.filter((f) => /\.(zip|tlpack)$/i.test(f.name));
      const media = files.filter((f) => !archives.includes(f));
      for (const f of archives) {
        const path = await uploadFile(f);
        const fn = /\.tlpack$/i.test(f.name) ? core.b.tl_import_pack(path, folder) : core.b.tl_import_loose_zip(path, folder);
        const r = await core.read<ImportReport>(fn);
        imported += r.new_media; dup += r.duplicate_media;
        setBusy((b) => b && { ...b, done: b.done + 1 });
      }
      if (media.length) {
        // every file of the drop into one folder of uploads, then one import of it
        let dir = '';
        for (const [i, f] of media.entries()) {
          const path = await uploadFile(f);
          if (!dir) dir = dirOf(path);
          else await move(path, `${dir}/drop${i}-${f.name}`);
          setBusy((b) => b && { ...b, done: b.done + 1 });
        }
        const r = await core.readJson<ImportReport>('tl_import_loose_dir', { dir, folder: folder || null, consume: true, keep_to: null, album: false });
        imported += r.new_media; dup += r.duplicate_media;
      }
      toast(L('shareInbox.imported', imported) + (dup ? L('shareInbox.dup', dup) : ''));
    } catch (e) {
      toast(`${L('common.notDone')}: ${L(String((e as Error).message))}`);
    } finally {
      setBusy(null);
      libraryChanged();
    }
  }

  return (
    <>
      {over && <div className="drop-over"><div className="drop-hint">{L('drop.hint')}</div></div>}
      {busy && (
        <div className="drop-busy">
          <span>{L('common.importing')} {busy.done}/{busy.total}</span>
          <Progress value={busy.total ? busy.done / busy.total : undefined} />
        </div>
      )}
    </>
  );
}
