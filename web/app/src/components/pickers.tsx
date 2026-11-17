// Dialogs the card menu and the selection bar share: choose a folder (or make one), type a tag.
import { useEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { Folder, FolderPlus } from 'lucide-react';
import { L, type TagCount } from '@twimshelf/core';
import { core } from '../lib/core';
import { folders, refreshLibrary } from '../lib/library';
import { useStore } from '../lib/hooks';
import { Button, Dialog, TextField } from './ui';

/** Shows a dialog outside the React tree and resolves with its answer. */
function ask<T>(render: (done: (v: T | null) => void) => React.ReactNode): Promise<T | null> {
  return new Promise((resolve) => {
    const host = document.createElement('div');
    document.body.appendChild(host);
    const root = createRoot(host);
    const done = (v: T | null) => { root.unmount(); host.remove(); resolve(v); };
    root.render(render(done));
  });
}

export function pickFolder(): Promise<string | null> {
  return ask<string>((done) => <FolderPicker done={done} />);
}

function FolderPicker({ done }: { done: (v: string | null) => void }) {
  const f = useStore(folders);
  const [name, setName] = useState('');
  const create = async () => {
    const n = name.trim();
    if (!n) return;
    try { await core.read(core.b.tl_create_folder(n)); } catch { /* exists: use it */ }
    await refreshLibrary();
    done(n);
  };
  return (
    <Dialog title={L('common.addToFolder')} onClose={() => done(null)}
      actions={<Button onClick={() => done(null)}>{L('common.cancel')}</Button>}>
      <div className="picker-list">
        {(f?.folders ?? []).map((x) => (
          <button key={x.name} className="picker-row" onClick={() => done(x.name)}><Folder size={15} /> <span>{x.name}</span><span className="picker-count">{x.count}</span></button>
        ))}
      </div>
      <div className="picker-new">
        <FolderPlus size={15} />
        <TextField value={name} onChange={setName} placeholder={L('common.folderName')} onEnter={() => void create()} />
        <Button kind="primary" disabled={!name.trim()} onClick={() => void create()}>{L('common.create')}</Button>
      </div>
    </Dialog>
  );
}

/** A tag to add: typed, with the library's tags suggested. */
export function pickTag(title: string): Promise<string | null> {
  return ask<string>((done) => <TagPicker title={title} done={done} />);
}

function TagPicker({ title, done }: { title: string; done: (v: string | null) => void }) {
  const [text, setText] = useState('');
  const [tags, setTags] = useState<TagCount[]>([]);
  useEffect(() => { core.read<TagCount[]>(core.b.tl_all_tags()).then(setTags, () => {}); }, []);
  const q = text.trim().toLowerCase();
  const matches = q ? tags.filter((t) => t.label.toLowerCase().includes(q)).slice(0, 8) : tags.slice().sort((a, b) => b.count - a.count).slice(0, 8);
  return (
    <Dialog title={title} onClose={() => done(null)}
      actions={<><Button onClick={() => done(null)}>{L('common.cancel')}</Button><Button kind="primary" disabled={!q} onClick={() => done(text.trim())}>{L('common.done')}</Button></>}>
      <TextField value={text} onChange={setText} autoFocus onEnter={() => q && done(text.trim())} />
      <div className="picker-chips">
        {matches.map((t) => <button key={t.label} className="chip" onClick={() => done(t.label)}>{t.label}</button>)}
      </div>
    </Dialog>
  );
}

/** One line of text (a new name). */
export function askText(title: string, initial = ''): Promise<string | null> {
  return ask<string>((done) => <TextAsk title={title} initial={initial} done={done} />);
}

function TextAsk({ title, initial, done }: { title: string; initial: string; done: (v: string | null) => void }) {
  const [text, setText] = useState(initial);
  return (
    <Dialog title={title} onClose={() => done(null)}
      actions={<><Button onClick={() => done(null)}>{L('common.cancel')}</Button><Button kind="primary" disabled={!text.trim()} onClick={() => done(text.trim())}>{L('common.done')}</Button></>}>
      <TextField value={text} onChange={setText} autoFocus onEnter={() => text.trim() && done(text.trim())} />
    </Dialog>
  );
}
