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

/** A folder (or a new one); with `none`, also "not into a folder" (answers ''). */
export function pickFolder(o: { title?: string; none?: boolean } = {}): Promise<string | null> {
  return ask<string>((done) => <FolderPicker done={done} title={o.title} none={o.none} />);
}

function FolderPicker({ done, title, none }: { done: (v: string | null) => void; title?: string; none?: boolean }) {
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
    <Dialog title={title ?? L('common.addToFolder')} onClose={() => done(null)}
      actions={<>{none && <Button onClick={() => done('')}>{L('common.notIntoFolder')}</Button>}<Button onClick={() => done(null)}>{L('common.cancel')}</Button></>}>
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

/** A question in the app's own dialog: the title, the message, then Cancel and the given options
 *  (the last is the default: Return picks it, Esc cancels). Resolves to the option's index, or null. */
export function choose(title: string, message: string, options: string[], o: { destructive?: boolean; cancel?: boolean } = {}): Promise<number | null> {
  return ask<number>((done) => <Choice title={title} message={message} options={options} destructive={o.destructive} cancel={o.cancel !== false} done={done} />);
}

/** A message with OK. */
export async function alertMessage(title: string, message = ''): Promise<void> {
  await choose(title, message, [L('common.ok')], { cancel: false });
}

/** One line of text in the app's own dialog: resolves to the text, or null. */
export function prompt(title: string, o: { message?: string; placeholder?: string; initial?: string; action?: string } = {}): Promise<string | null> {
  return ask<string>((done) => <TextPrompt title={title} message={o.message} placeholder={o.placeholder} initial={o.initial ?? ''} action={o.action ?? L('common.ok')} done={done} />);
}

function Choice({ title, message, options, destructive, cancel, done }: { title: string; message: string; options: string[]; destructive?: boolean; cancel: boolean; done: (v: number | null) => void }) {
  const last = options.length - 1;
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      // Return on a button that has the keyboard focus presses that button
      if (e.key === 'Enter' && !e.repeat && !e.isComposing && !(document.activeElement instanceof HTMLButtonElement)) done(last);
    };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, [done, last]);
  return (
    <Dialog modal title={title} onClose={() => { if (cancel || options.length === 1) done(null); }}
      actions={<>
        {cancel && <Button onClick={() => done(null)}>{L('common.cancel')}</Button>}
        {options.map((o, i) => <Button key={o} kind={i === last ? (destructive ? 'danger' : 'primary') : 'normal'} onClick={() => done(i)}>{o}</Button>)}
      </>}>
      {message ? <p className="dialog-message">{message}</p> : undefined}
    </Dialog>
  );
}

function TextPrompt({ title, message, placeholder, initial, action, done }: { title: string; message?: string; placeholder?: string; initial: string; action: string; done: (v: string | null) => void }) {
  const [text, setText] = useState(initial);
  const ok = () => { if (text.trim()) done(text); };
  return (
    <Dialog modal title={title} onClose={() => done(null)}
      actions={<><Button onClick={() => done(null)}>{L('common.cancel')}</Button><Button kind="primary" disabled={!text.trim()} onClick={ok}>{action}</Button></>}>
      {message && <p className="dialog-message">{message}</p>}
      <TextField value={text} onChange={setText} placeholder={placeholder} autoFocus selectOnFocus onEnter={ok} />
    </Dialog>
  );
}
