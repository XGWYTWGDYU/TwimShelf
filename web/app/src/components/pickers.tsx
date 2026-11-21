// Dialogs the card menu and the selection bar share: choose a folder (or make one), type a tag.
import { useEffect, useMemo, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { Folder, FolderPlus, Plus, Sparkles, Tag, Undo2 } from 'lucide-react';
import { L, type FeedItem, type TagCount } from '@twimshelf/core';
import { core } from '../lib/core';
import { folders, libraryChanged, refreshLibrary } from '../lib/library';
import { useStore } from '../lib/hooks';
import { action, isUser, undo, type Receipt } from '../lib/actions';
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

export interface TagPickerOptions {
  item?: FeedItem;
  post?: FeedItem[];
  mediaIds?: string[];
  initialScope?: 'media' | 'post';
  title?: string;
}

/** Multi-tag picker with scope switcher (This Item / Whole Post), user-first suggestions,
 *  AI vs manual icons, n/m coverage counts, and inline "Just Added" undo. */
export function openTagPicker(opts: TagPickerOptions): Promise<void> {
  return ask<boolean>((done) => <RichTagPicker opts={opts} done={() => done(true)} />).then(() => {});
}

function RichTagPicker({ opts, done }: { opts: TagPickerOptions; done: () => void }) {
  const loose = opts.item ? opts.item.post_id.startsWith('loose:') : true;
  const postItems = opts.post && opts.post.length > 0 ? opts.post : (opts.item ? [opts.item] : []);
  const canSwitchScope = !loose && postItems.length > 1;
  const [scope, setScope] = useState<'media' | 'post'>(canSwitchScope && opts.initialScope === 'post' ? 'post' : 'media');
  const [text, setText] = useState('');
  const [tags, setTags] = useState<TagCount[]>([]);
  const [added, setAdded] = useState<Array<{ label: string; receipt: Receipt }>>([]);
  const [error, setError] = useState('');

  useEffect(() => { core.read<TagCount[]>(core.b.tl_all_tags()).then(setTags, () => {}); }, []);

  const targets = useMemo(() => {
    if (opts.mediaIds) return { ids: opts.mediaIds, items: [] as FeedItem[] };
    if (scope === 'post' && canSwitchScope) return { ids: postItems.map((m) => m.media_id), items: postItems };
    return { ids: opts.item ? [opts.item.media_id] : [], items: opts.item ? [opts.item] : [] };
  }, [opts.mediaIds, opts.item, postItems, scope, canSwitchScope]);

  const coverage = useMemo(() => {
    const map = new Map<string, number>();
    for (const m of targets.items) {
      for (const t of m.tags) {
        if (isUser(t.origin)) map.set(t.label, (map.get(t.label) ?? 0) + 1);
      }
    }
    for (const a of added) {
      map.set(a.label, targets.ids.length);
    }
    return map;
  }, [targets, added]);

  const totalTargets = Math.max(1, targets.ids.length);
  const q = text.trim().toLowerCase();

  const suggestions = useMemo(() => {
    const sorted = tags.slice().sort((a, b) => {
      const aUser = a.user > 0 ? 1 : 0;
      const bUser = b.user > 0 ? 1 : 0;
      if (aUser !== bUser) return bUser - aUser;
      if (a.count !== b.count) return b.count - a.count;
      return a.label.localeCompare(b.label);
    });
    return sorted
      .filter((t) => (coverage.get(t.label) ?? 0) < totalTargets)
      .filter((t) => !q || t.label.toLowerCase().includes(q))
      .slice(0, 40);
  }, [tags, coverage, totalTargets, q]);

  const exactExists = tags.some((t) => t.label.toLowerCase() === q) || added.some((a) => a.label.toLowerCase() === q);

  const applyTag = async (raw: string) => {
    const label = raw.trim().toLowerCase();
    if (!label || !targets.ids.length) return;
    setError('');
    try {
      const receipt = await action('tag', { media: targets.ids, label });
      setAdded((prev) => [...prev.filter((a) => a.label !== label), { label, receipt }]);
      setText('');
      libraryChanged();
      core.read<TagCount[]>(core.b.tl_all_tags()).then(setTags, () => {});
    } catch (e) {
      setError(e instanceof Error ? L(e.message) : L('tagPicker.error'));
    }
  };

  const undoAdded = async (entry: { label: string; receipt: Receipt }) => {
    try {
      await undo(entry.receipt);
      setAdded((prev) => prev.filter((a) => a.label !== entry.label));
      libraryChanged();
    } catch { /* ignore */ }
  };

  const title = opts.title ?? L('tagPicker.title');

  return (
    <Dialog
      title={title}
      onClose={done}
      actions={<Button kind="primary" onClick={done}>{L('common.done')}</Button>}
    >
      {canSwitchScope && (
        <div style={{ display: 'flex', gap: 6, marginBottom: 10 }}>
          <Button kind={scope === 'media' ? 'primary' : 'normal'} onClick={() => setScope('media')}>
            {L('tagPicker.thisMedia')}
          </Button>
          <Button kind={scope === 'post' ? 'primary' : 'normal'} onClick={() => setScope('post')}>
            {L('tagPicker.wholePost', postItems.length)}
          </Button>
        </div>
      )}

      <TextField
        value={text}
        onChange={setText}
        placeholder={L('tagPicker.placeholder')}
        autoFocus
        onEnter={() => { if (q) void applyTag(q); else done(); }}
      />

      {error && <p className="dialog-message" style={{ color: 'var(--red)', marginTop: 6 }}>{error}</p>}

      {added.length > 0 && (
        <div style={{ marginTop: 10 }}>
          <div style={{ fontSize: 11.5, fontWeight: 600, color: 'var(--fg-2)', marginBottom: 6 }}>
            {L('tagPicker.justAdded')}
          </div>
          <div className="picker-chips">
            {added.map((a) => (
              <button
                key={a.label}
                type="button"
                className="chip"
                title={L('common.undo')}
                onClick={() => void undoAdded(a)}
                style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}
              >
                <span>{a.label}</span>
                <Undo2 size={12} />
              </button>
            ))}
          </div>
        </div>
      )}

      <div style={{ marginTop: 10 }}>
        <div style={{ fontSize: 11.5, fontWeight: 600, color: 'var(--fg-2)', marginBottom: 6 }}>
          {q ? L('tagPicker.matching') : L('tagPicker.frequent')}
        </div>
        <div className="picker-list" style={{ maxHeight: 240, overflowY: 'auto' }}>
          {q && !exactExists && (
            <button type="button" className="picker-row" onClick={() => void applyTag(q)}>
              <Plus size={14} />
              <span>{L('tagPicker.create', q)}</span>
            </button>
          )}
          {suggestions.map((t) => {
            const cov = coverage.get(t.label) ?? 0;
            const aiOnly = t.user === 0 && t.ai > 0;
            return (
              <button key={t.label} type="button" className="picker-row" onClick={() => void applyTag(t.label)}>
                {aiOnly ? <Sparkles size={14} /> : <Tag size={14} />}
                <span>{t.label}</span>
                <span className="picker-count">
                  {totalTargets > 1 && cov > 0 ? L('tagPicker.tagged', cov, totalTargets) : t.count}
                </span>
              </button>
            );
          })}
        </div>
      </div>
    </Dialog>
  );
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
