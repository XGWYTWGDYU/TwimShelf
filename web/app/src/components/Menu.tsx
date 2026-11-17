// A context menu at the pointer, with submenus; any page can open one with openMenu(e, items).
import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { ChevronRight } from 'lucide-react';
import { store } from '@twimshelf/core';
import { useStore } from '../lib/hooks';
import './Menu.css';

export interface MenuItem { label: string; icon?: ReactNode; danger?: boolean; disabled?: boolean; run?: () => void; children?: MenuEntry[] }
export type MenuEntry = MenuItem | 'separator';

const open = store<{ x: number; y: number; items: MenuEntry[] } | null>(null);

/** Shows `items` at the pointer of `e` (groups separated by 'separator'; empty groups dropped). */
export function openMenu(e: { clientX: number; clientY: number; preventDefault?: () => void }, items: MenuEntry[]): void {
  e.preventDefault?.();
  const clean: MenuEntry[] = [];
  for (const it of items) if (it !== 'separator' || (clean.length && clean[clean.length - 1] !== 'separator')) clean.push(it);
  while (clean[clean.length - 1] === 'separator') clean.pop();
  open.set({ x: e.clientX, y: e.clientY, items: clean });
}

export function MenuHost() {
  const m = useStore(open);
  useEffect(() => {
    if (!m) return;
    const close = () => open.set(null);
    const key = (e: KeyboardEvent) => { if (e.key === 'Escape') { e.stopPropagation(); close(); } };
    window.addEventListener('keydown', key, true);
    window.addEventListener('blur', close);
    window.addEventListener('resize', close);
    return () => { window.removeEventListener('keydown', key, true); window.removeEventListener('blur', close); window.removeEventListener('resize', close); };
  }, [m]);
  if (!m) return null;
  return (
    <div className="menu-scrim" onMouseDown={() => open.set(null)} onContextMenu={(e) => { e.preventDefault(); open.set(null); }}>
      <MenuList x={m.x} y={m.y} items={m.items} />
    </div>
  );
}

function MenuList({ x, y, items, side }: { x: number; y: number; items: MenuEntry[]; side?: number }) {
  const box = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState({ x, y });
  const [sub, setSub] = useState<{ i: number; x: number; y: number; left: number } | null>(null);
  useLayoutEffect(() => {
    const r = box.current!.getBoundingClientRect();
    let nx = x, ny = y;
    if (nx + r.width > innerWidth - 6) nx = side !== undefined ? side - r.width : innerWidth - r.width - 6;
    if (ny + r.height > innerHeight - 6) ny = Math.max(6, innerHeight - r.height - 6);
    setPos({ x: Math.max(6, nx), y: ny });
  }, [x, y, side]);
  return (
    <div className="menu" ref={box} style={{ left: pos.x, top: pos.y }} onMouseDown={(e) => e.stopPropagation()}>
      {items.map((it, i) => it === 'separator' ? <div key={i} className="menu-sep" /> : (
        <button key={i} className={`menu-item${it.danger ? ' danger' : ''}${sub?.i === i ? ' on' : ''}`} disabled={it.disabled}
          onMouseEnter={(e) => {
            if (it.children) { const r = e.currentTarget.getBoundingClientRect(); setSub({ i, x: r.right - 4, y: r.top - 5, left: r.left + 4 }); }
            else setSub(null);
          }}
          onClick={() => { if (it.children) return; open.set(null); it.run?.(); }}>
          <span className="menu-icon">{it.icon}</span>
          <span className="menu-label">{it.label}</span>
          {it.children && <ChevronRight size={13} className="menu-more" />}
        </button>
      ))}
      {sub && (items[sub.i] as MenuItem).children && <MenuList x={sub.x} y={sub.y} side={sub.left} items={(items[sub.i] as MenuItem).children!} />}
    </div>
  );
}
