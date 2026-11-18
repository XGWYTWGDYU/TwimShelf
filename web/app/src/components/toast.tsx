// Short messages at the bottom of the window ("Moved to the bin" · Undo).
import { store } from '@twimshelf/core';
import { useStore } from '../lib/hooks';
import './toast.css';

interface Toast { id: number; text: string; action?: { label: string; run: () => void }; leaving?: boolean }
const toasts = store<Toast[]>([]);
let next = 1;

export function toast(text: string, action?: Toast['action'], ms = 4000): void {
  const id = next++;
  toasts.set((t) => [...t, { id, text, action }]);
  // fades out, then goes
  setTimeout(() => toasts.set((t) => t.map((x) => x.id === id ? { ...x, leaving: true } : x)), ms);
  setTimeout(() => toasts.set((t) => t.filter((x) => x.id !== id)), ms + 200);
}

export function Toasts() {
  const list = useStore(toasts);
  return (
    <div className="toasts">
      {list.map((t) => (
        <div key={t.id} className={`toast${t.leaving ? ' leaving' : ''}`}>
          <span>{t.text}</span>
          {t.action && <button onClick={() => { t.action!.run(); toasts.set((l) => l.filter((x) => x.id !== t.id)); }}>{t.action.label}</button>}
        </div>
      ))}
    </div>
  );
}
