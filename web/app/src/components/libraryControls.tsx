import { useEffect, useRef, useState, type ReactNode } from 'react';
import { L } from '@twimshelf/core';
import { toast } from './toast';
import { Button, Dialog, Empty, Spinner, TextField } from './ui';
import { core } from '../lib/core';
import { libraryChanged } from '../lib/library';
import './libraryControls.css';

export function errorText(error: unknown): string {
  return L(error instanceof Error ? error.message : 'common.notDone');
}

export function useTask() {
  const inFlight = useRef(false);
  const [busy, setBusy] = useState(false);
  async function run<T>(work: () => Promise<T>): Promise<T | undefined> {
    if (inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    try {
      return await work();
    } catch (error) {
      toast(errorText(error));
    } finally {
      inFlight.current = false;
      setBusy(false);
    }
  }
  return { busy, run };
}

export async function change<T>(work: Promise<T>): Promise<T> {
  try {
    return await work;
  } finally {
    libraryChanged();
  }
}

export function LoadState({ error, reload }: { error?: unknown; reload: () => void }) {
  return error ? <Empty title={errorText(error)}><Button onClick={reload}>{L('models.retry')}</Button></Empty>
    : <Empty title={<Spinner />} />;
}

export interface Option {
  value: string;
  label: string;
}

export function Select({ label, value, options, onChange, disabled }: {
  label: string; value: string; options: Option[]; onChange: (value: string) => void; disabled?: boolean;
}) {
  // Chromium can match :focus-visible even when a native select was clicked.
  const [pointerFocus, setPointerFocus] = useState(false);
  return <select className="field control-select" aria-label={label} value={value} disabled={disabled}
    data-pointer-focus={pointerFocus || undefined}
    onPointerDown={() => setPointerFocus(true)}
    onBlur={() => setPointerFocus(false)}
    onKeyDown={(event) => { if (event.key !== 'Escape') setPointerFocus(false); }}
    onChange={(event) => onChange(event.target.value)}>
    {options.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
  </select>;
}

export function Confirm({ title, children, action, danger, onClose, onConfirm }: {
  title: ReactNode; children: ReactNode; action: string; danger?: boolean; onClose: () => void;
  onConfirm: () => Promise<unknown>;
}) {
  const task = useTask();
  return <Dialog title={title} onClose={() => { if (!task.busy) onClose(); }} actions={<>
    <Button onClick={onClose} disabled={task.busy}>{L('common.cancel')}</Button>
    <Button kind={danger ? 'danger' : 'primary'} disabled={task.busy} onClick={() => void task.run(async () => {
      await onConfirm();
      onClose();
    })}>{task.busy ? <Spinner /> : action}</Button>
  </>}>{children}</Dialog>;
}

export function NameDialog({ title, children, action, initial = '', onClose, onSave }: {
  title: string; children?: ReactNode; action: string; initial?: string; onClose: () => void;
  onSave: (name: string) => Promise<unknown>;
}) {
  const [name, setName] = useState(initial);
  const task = useTask();
  const nameValue = name.trim();
  const save = () => {
    if (nameValue) void task.run(async () => { if (await onSave(nameValue) !== false) onClose(); });
  };
  return <Dialog title={title} onClose={() => { if (!task.busy) onClose(); }} actions={<>
    <Button onClick={onClose} disabled={task.busy}>{L('common.cancel')}</Button>
    <Button kind="primary" disabled={!nameValue || task.busy} onClick={save}>{action}</Button>
  </>}>
    <div className="control-stack">
      {children}
      <TextField value={name} onChange={setName} placeholder={L('common.name')} autoFocus onEnter={save} />
    </div>
  </Dialog>;
}

export function FileButton({ label, accept, onPick, disabled }: {
  label: string; accept: string; onPick: (file: File) => void; disabled?: boolean;
}) {
  const input = useRef<HTMLInputElement>(null);
  return <>
    <input ref={input} type="file" accept={accept} hidden onChange={(event) => {
      const file = event.target.files?.[0];
      event.target.value = '';
      if (file) onPick(file);
    }} />
    <Button onClick={() => input.current?.click()} disabled={disabled}>{label}</Button>
  </>;
}

export function CardGrid({ children }: { children: ReactNode }) {
  return <div className="control-grid">{children}</div>;
}

export function MediaCard({ path, video, icon, title, subtitle, actions, onOpen }: {
  path?: string | null; video?: boolean; icon: ReactNode; title: string; subtitle?: string;
  actions: ReactNode; onOpen?: () => void;
}) {
  const Tag = onOpen ? 'button' : 'div';
  const cover = useRef<HTMLDivElement>(null);
  const [visible, setVisible] = useState(false);
  const [resolved, setResolved] = useState<{ key: string; url: string }>();
  const [failed, setFailed] = useState<string>();
  const key = path ? `${video ? 'video' : 'photo'}:${path}` : '';
  useEffect(() => {
    if (!cover.current || visible) return;
    const observer = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) setVisible(true);
    }, { rootMargin: '160px' });
    observer.observe(cover.current);
    return () => observer.disconnect();
  }, [visible]);

  useEffect(() => {
    if (!path || !visible) return;
    const controller = new AbortController();
    let objectUrl: string | undefined;
    const options = { signal: controller.signal };
    const query = new URLSearchParams({ path, side: video ? '384' : '512' });
    const load = async () => {
      let url = `${core.transport.base}/api/${video ? 'poster' : 'scaled'}?${query}`;
      if (video) {
        const result = await fetch(url, options);
        if (!result.ok) return;
        url = core.fileUrl(((await result.json()) as { path: string }).path);
      }
      if (!controller.signal.aborted) setResolved({ key, url });
    };
    void load().catch(() => {});
    return () => {
      controller.abort();
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [key, path, video, visible]);

  const src = resolved?.key === key ? resolved.url : undefined;
  return <article className="control-card">
    <Tag className="control-card-content" onClick={onOpen}>
      <div className="control-cover" ref={cover}>{src && failed !== src
        ? <img src={src} alt="" loading="lazy" onError={() => setFailed(src)} /> : icon}</div>
      <div className="control-caption"><strong>{title}</strong>{subtitle && <small>{subtitle}</small>}</div>
    </Tag>
    <div className="control-actions">{actions}</div>
  </article>;
}
