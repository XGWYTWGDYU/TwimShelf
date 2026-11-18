import { useEffect, useRef, useState, type ReactNode } from 'react';
import { store } from '@twimshelf/core';
import { useStore } from '../lib/hooks';
import { clawdIcons } from './clawdIcons.generated';
import './Mascot.css';

const preference = 'mascot.enabled';

function readMascot(): boolean {
  try { return localStorage.getItem(preference) === 'true'; }
  catch { return false; }
}

export const mascotEnabled = store(readMascot());

export async function loadMascotPreference() {
  const enabled = await window.twimshelf?.getMascotEnabled?.();
  if (enabled !== undefined) mascotEnabled.set(enabled);
}

export function setMascotEnabled(enabled: boolean) {
  const save = window.twimshelf?.setMascotEnabled;
  if (save) void save(enabled).catch(() => {});
  else {
    try { localStorage.setItem(preference, String(enabled)); } catch { /* unavailable storage */ }
  }
  mascotEnabled.set(enabled);
}

window.addEventListener('storage', (event) => {
  if (event.key === preference || event.key === null) mascotEnabled.set(readMascot());
});

export type MascotName = keyof typeof clawdIcons;

export function ClawdIcon({ name, size = 24, className }: { name: MascotName; size?: number; className?: string }) {
  return (
    <svg aria-hidden="true" className={className} width={size} height={size} viewBox="0 0 24 24">
      {clawdIcons[name].map(([fill, stroke, d], i) => (
        <path key={i} d={d} fill={stroke ? 'none' : fill === null ? 'currentColor' : `#${fill.toString(16).padStart(6, '0')}`}
          stroke={stroke ? 'currentColor' : undefined} strokeWidth={0.7} strokeLinecap="round" strokeLinejoin="round" />
      ))}
    </svg>
  );
}

/** How long Clawd stays after a press, and how long the way back takes (the other apps' timing). */
const HOLD_MS = 700;
const RETURN_MS = 320;

type PressPhase = 'rest' | 'in' | 'out';

export function useMascotPress(name?: MascotName) {
  const enabled = useStore(mascotEnabled);
  const [phase, setPhase] = useState<PressPhase>('rest');
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => () => clearTimeout(timer.current), []);

  function pulse() {
    if (!name || !enabled) return;
    clearTimeout(timer.current);
    setPhase('in');
    timer.current = setTimeout(() => {
      setPhase('out');
      timer.current = setTimeout(() => setPhase('rest'), RETURN_MS);
    }, HOLD_MS);
  }

  return { mascot: enabled && phase !== 'rest' ? name : undefined, phase: enabled ? phase : 'rest' as PressPhase, pulse };
}

/** An icon that becomes Clawd for a moment when pressed (`useMascotPress`). */
export function MascotSwap({ name, phase, size, children }: { name?: MascotName; phase: PressPhase; size: number; children: ReactNode }) {
  return (
    <span className={`mascot-swap ${phase}`}>
      <span className="mascot-swap-normal">{children}</span>
      {name && phase !== 'rest' && <span className="mascot-swap-clawd"><ClawdIcon name={name} size={size} /></span>}
    </span>
  );
}
