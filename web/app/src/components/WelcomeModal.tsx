import { useEffect, useState, type ReactNode } from 'react';
import { L } from '@twimshelf/core';
import {
  ArrowDown,
  ArrowDownCircle,
  ArrowLeft,
  ArrowLeftRight,
  ArrowRight,
  Check,
  CheckCircle2,
  ChevronLeft,
  ChevronsRight,
  Clock,
  FileArchive,
  FileText,
  Folder,
  Globe,
  Image,
  Inbox,
  Laptop,
  Layers,
  LayoutGrid,
  Link2,
  Lock,
  Minus,
  Monitor,
  Network,
  Package,
  Play,
  Plus,
  RotateCw,
  Scan,
  Search,
  Settings,
  ShieldCheck,
  Shuffle,
  Smartphone,
  Sparkles,
  Square,
  Tag,
  Video,
  X,
  ZoomIn,
  ZoomOut,
} from 'lucide-react';
import './WelcomeModal.css';

const SEEN_KEY = 'web.welcome.seen';
const NEXT_LAUNCH_KEY = 'web.welcome.nextLaunch';

type Listener = (open: boolean) => void;
const listeners = new Set<Listener>();
const nextLaunchListeners = new Set<(v: boolean) => void>();
let modalOpen = false;

export function getWelcomeNextLaunch(): boolean {
  return localStorage.getItem(NEXT_LAUNCH_KEY) === 'true';
}

export function setWelcomeNextLaunch(v: boolean) {
  if (v) localStorage.setItem(NEXT_LAUNCH_KEY, 'true');
  else localStorage.removeItem(NEXT_LAUNCH_KEY);
  for (const fn of nextLaunchListeners) fn(v);
}

export function onWelcomeNextLaunchChange(fn: (v: boolean) => void): () => void {
  nextLaunchListeners.add(fn);
  return () => { nextLaunchListeners.delete(fn); };
}

export function showWelcomeModal() {
  modalOpen = true;
  for (const fn of listeners) fn(true);
}

export function closeWelcomeModal() {
  localStorage.setItem(SEEN_KEY, 'true');
  modalOpen = false;
  for (const fn of listeners) fn(false);
}

interface PageMeta {
  id: number;
  badge: () => string;
  title: () => string;
  body: () => string;
  accent: string;
  accentSoft: string;
  icon: ReactNode;
}

function isTouchDevice() {
  return typeof window !== 'undefined' && window.matchMedia?.('(pointer: coarse)').matches;
}

const PAGES: PageMeta[] = [
  {
    id: 0,
    badge: () => L('welcome.p1.badge'),
    title: () => L('welcome.p1.title'),
    body: () => L(isTouchDevice() ? 'welcome.p1.body.mobile' : 'welcome.p1.body.desktop'),
    accent: '#f97316',
    accentSoft: 'rgba(249, 115, 22, 0.14)',
    icon: <Shuffle size={12} />,
  },
  {
    id: 1,
    badge: () => L('welcome.p2.badge'),
    title: () => L('welcome.p2.title'),
    body: () => L('welcome.p2.body'),
    accent: '#0a66ff',
    accentSoft: 'rgba(10, 102, 255, 0.14)',
    icon: <LayoutGrid size={12} />,
  },
  {
    id: 2,
    badge: () => L('welcome.p3.badge'),
    title: () => L('welcome.p3.title'),
    body: () => L('welcome.p3.body'),
    accent: '#06b6d4',
    accentSoft: 'rgba(6, 182, 212, 0.14)',
    icon: <ArrowDownCircle size={12} />,
  },
  {
    id: 3,
    badge: () => L('welcome.p4.badge'),
    title: () => L('welcome.p4.title'),
    body: () => L('welcome.p4.body'),
    accent: '#9333ea',
    accentSoft: 'rgba(147, 51, 234, 0.14)',
    icon: <Sparkles size={12} />,
  },
  {
    id: 4,
    badge: () => L('welcome.p5.badge'),
    title: () => L('welcome.p5.title'),
    body: () => L('welcome.p5.body'),
    accent: '#16a34a',
    accentSoft: 'rgba(22, 163, 74, 0.14)',
    icon: <Tag size={12} />,
  },
  {
    id: 5,
    badge: () => L('welcome.p6.badge'),
    title: () => L('welcome.p6.title'),
    body: () => L('welcome.p6.body'),
    accent: '#4f46e5',
    accentSoft: 'rgba(79, 70, 229, 0.14)',
    icon: <Search size={12} />,
  },
  {
    id: 6,
    badge: () => L('welcome.p7.badge'),
    title: () => L('welcome.p7.title'),
    body: () => L('welcome.p7.body'),
    accent: '#0d9488',
    accentSoft: 'rgba(13, 148, 136, 0.14)',
    icon: <Network size={12} />,
  },
  {
    id: 7,
    badge: () => L('welcome.p8.badge'),
    title: () => L('welcome.p8.title'),
    body: () => L('welcome.p8.body'),
    accent: '#ec4899',
    accentSoft: 'rgba(236, 72, 153, 0.14)',
    icon: <ArrowLeftRight size={12} />,
  },
];

export function WelcomeHost() {
  const [open, setOpen] = useState(modalOpen);
  const [page, setPage] = useState(0);
  const [dir, setDir] = useState<1 | -1>(1);

  useEffect(() => {
    const fn: Listener = (v) => {
      if (v) { setPage(0); setDir(1); }
      setOpen(v);
    };
    listeners.add(fn);
    const firstLaunch = localStorage.getItem(SEEN_KEY) !== 'true';
    const scheduled = getWelcomeNextLaunch();
    if (firstLaunch || scheduled) {
      if (scheduled) setWelcomeNextLaunch(false);
      const t = window.setTimeout(() => showWelcomeModal(), 350);
      return () => { window.clearTimeout(t); listeners.delete(fn); };
    }
    return () => { listeners.delete(fn); };
  }, []);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') { e.preventDefault(); closeWelcomeModal(); }
      else if (e.key === 'ArrowRight') {
        e.preventDefault();
        setDir(1);
        setPage((p) => Math.min(PAGES.length - 1, p + 1));
      } else if (e.key === 'ArrowLeft') {
        e.preventDefault();
        setDir(-1);
        setPage((p) => Math.max(0, p - 1));
      } else if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault();
        setPage((p) => {
          if (p >= PAGES.length - 1) { closeWelcomeModal(); return p; }
          setDir(1);
          return p + 1;
        });
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open]);

  if (!open) return null;

  const meta = PAGES[page];
  const isFirst = page === 0;
  const isLast = page === PAGES.length - 1;

  const goTo = (idx: number) => {
    if (idx === page) return;
    setDir(idx > page ? 1 : -1);
    setPage(idx);
  };

  return (
    <div className="welcome-backdrop" role="dialog" aria-modal="true" aria-label={L('welcome.windowTitle')}>
      <div className="welcome-dialog">
        <div
          className="welcome-wash"
          style={{ background: `radial-gradient(ellipse at top center, ${meta.accentSoft} 0%, transparent 62%)` }}
        />

        <div className="welcome-top">
          <span className="welcome-step">{L('welcome.step', page + 1, PAGES.length)}</span>
          <div className="welcome-top-right">
            <button type="button" className="welcome-close" onClick={closeWelcomeModal} aria-label={L('common.close')}>
              <X size={14} />
            </button>
          </div>
        </div>

        <div className="welcome-body">
          <div key={page} className={`welcome-page-anim${dir < 0 ? ' dir-back' : ''}`}>
            <div className="welcome-stage">
              <div
                className="welcome-stage-tint"
                style={{ background: `linear-gradient(135deg, ${meta.accentSoft}, transparent 68%)` }}
              />
              <div className="welcome-stage-inner">
                {page === 0 && <ShuffleMasonryStage />}
                {page === 1 && <GridZoomStage />}
                {page === 2 && <DownloadBatchStage />}
                {page === 3 && <AIModelTagStage />}
                {page === 4 && <TagTrioStage />}
                {page === 5 && <TokenSearchStage />}
                {page === 6 && <LanSyncStage />}
                {page === 7 && <ImportExportStage />}
              </div>
            </div>

            <div className="welcome-copy">
              <span className="welcome-badge" style={{ color: meta.accent, background: meta.accentSoft }}>
                {meta.icon}
                {meta.badge()}
              </span>
              <h2 className="welcome-title">{meta.title()}</h2>
              <p className="welcome-desc">{meta.body()}</p>
            </div>
          </div>
        </div>

        <div className="welcome-footer">
          {isFirst ? (
            <button type="button" className="welcome-btn-skip" onClick={closeWelcomeModal}>
              {L('welcome.skip')}
            </button>
          ) : (
            <button type="button" className="welcome-btn-back" onClick={() => goTo(page - 1)}>
              <ChevronLeft size={14} />
              {L('welcome.back')}
            </button>
          )}

          <div className="welcome-dots">
            {PAGES.map((p) => (
              <button
                key={p.id}
                type="button"
                className={`welcome-dot${p.id === page ? ' active' : ''}`}
                style={p.id === page ? { background: meta.accent } : undefined}
                aria-label={L('welcome.step', p.id + 1, PAGES.length)}
                onClick={() => goTo(p.id)}
              />
            ))}
          </div>

          <button
            type="button"
            className="welcome-btn-next"
            style={{ background: meta.accent }}
            onClick={() => (isLast ? closeWelcomeModal() : goTo(page + 1))}
          >
            {isLast ? L('welcome.done') : L('welcome.next')}
            {isLast ? <Check size={14} /> : <ArrowRight size={14} />}
          </button>
        </div>
      </div>
    </div>
  );
}

// ---- Shared Miniature TwimShelf App Shell ----

type SideId = 'browse' | 'photos' | 'videos' | 'folders' | 'settings';

function isElectronApp() {
  return typeof window !== 'undefined' && Boolean(window.twimshelf);
}

function MiniAppWindow({
  selected,
  accent,
  accentSoft,
  toolbar,
  children,
}: {
  selected: SideId;
  accent: string;
  accentSoft: string;
  toolbar: ReactNode;
  children: ReactNode;
}) {
  const electron = isElectronApp();
  const items: Array<{ id: SideId; icon: ReactNode; label: string; sep?: boolean }> = [
    { id: 'browse', icon: <LayoutGrid size={10.5} />, label: L('place.browse'), sep: true },
    { id: 'photos', icon: <Image size={10.5} />, label: L('place.photos') },
    { id: 'videos', icon: <Video size={10.5} />, label: L('place.videos') },
    { id: 'folders', icon: <Folder size={10.5} />, label: L('place.folders'), sep: true },
    { id: 'settings', icon: <Settings size={10.5} />, label: L('place.settings') },
  ];
  const winControls = (
    <div className="w-win-btns">
      <span className="w-win-btn"><Minus size={8} /></span>
      <span className="w-win-btn"><Square size={7} /></span>
      <span className="w-win-btn"><X size={8} /></span>
    </div>
  );
  return (
    <div className="w-app">
      {electron ? (
        /* Electron: Linux desktop window chrome (title on left, − □ × on top-right) */
        <div className="w-linux-bar">
          <span className="w-linux-title">
            <span style={{ width: 6, height: 6, borderRadius: '50%', background: accent }} />
            {L('web.appName')}
          </span>
          {winControls}
        </div>
      ) : (
        /* Web: inside Chrome browser tab strip + omnibox */
        <div className="w-chrome-bar">
          <div className="w-chrome-tabs">
            <div className="w-chrome-tab-row">
              <span className="w-chrome-tab">
                <Globe size={8.5} color={accent} />
                {L('web.appName')}
              </span>
              <Plus size={9} color="var(--fg-3)" />
            </div>
            {winControls}
          </div>
          <div className="w-chrome-omni">
            <ArrowLeft size={8.5} />
            <ArrowRight size={8.5} />
            <RotateCw size={8} />
            <div className="w-chrome-url">
              <Lock size={7.5} />
              <span>twimshelf.local</span>
            </div>
          </div>
        </div>
      )}

      <div className="w-app-body">
        <div className="w-side">
          {items.map((it) => {
            const active = it.id === selected;
            return (
              <div key={it.id}>
                <div
                  className={`w-side-item${active ? ' active' : ''}`}
                  style={active ? { color: accent, background: accentSoft } : undefined}
                >
                  {it.icon}
                  <span>{it.label}</span>
                </div>
                {it.sep && <div className="w-side-sep" />}
              </div>
            );
          })}
        </div>
        <div className="w-main">
          <div className="w-bar">{toolbar}</div>
          <div className="w-content">{children}</div>
        </div>
      </div>
    </div>
  );
}

// ---- Page 1: Random Browse + Toolbar Reshuffle ----

const SHUFFLE_CARDS = [
  { id: 0, color: '#f97316', bg: 'rgba(249,115,22,0.22)', kind: 'photo', heights: [92, 68, 80] },
  { id: 1, color: '#ec4899', bg: 'rgba(236,72,153,0.22)', kind: 'video', heights: [68, 94, 72] },
  { id: 2, color: '#4f46e5', bg: 'rgba(79,70,229,0.22)', kind: 'stack', heights: [84, 74, 90] },
  { id: 3, color: '#0d9488', bg: 'rgba(13,148,136,0.22)', kind: 'photo', heights: [74, 86, 66] },
  { id: 4, color: '#9333ea', bg: 'rgba(147,51,234,0.22)', kind: 'video', heights: [86, 68, 84] },
  { id: 5, color: '#0a66ff', bg: 'rgba(10,102,255,0.22)', kind: 'photo', heights: [70, 82, 74] },
];

const SHUFFLE_ORDERS = [
  [0, 1, 2, 3, 4, 5],
  [4, 2, 5, 1, 0, 3],
  [2, 5, 0, 4, 3, 1],
];

function ShuffleMasonryStage() {
  const [step, setStep] = useState(0);
  const [pulse, setPulse] = useState(false);

  useEffect(() => {
    const id = window.setInterval(() => {
      setPulse(true);
      setStep((s) => s + 1);
      window.setTimeout(() => setPulse(false), 320);
    }, 2200);
    return () => window.clearInterval(id);
  }, []);

  const order = SHUFFLE_ORDERS[step % SHUFFLE_ORDERS.length];
  const colY = [12, 12, 12];
  const rects: Record<number, { col: number; top: number; h: number }> = {};
  for (const cid of order) {
    let col = 0;
    if (colY[1] < colY[col]) col = 1;
    if (colY[2] < colY[col]) col = 2;
    const h = SHUFFLE_CARDS[cid].heights[step % 3];
    rects[cid] = { col, top: colY[col], h };
    colY[col] += h + 9;
  }

  return (
    <MiniAppWindow
      selected="browse"
      accent="#f97316"
      accentSoft="rgba(249,115,22,0.14)"
      toolbar={
        <>
          <span className="w-bar-title">{L('place.browse')}</span>
          <div style={{ flex: 1 }} />
          <div className="w-search-wire">
            <Search size={9.5} />
            <div className="w-wire-line" style={{ width: 56 }} />
          </div>
          <div style={{ flex: 1 }} />
          <span className="w-tbtn"><Clock size={10} /></span>
          <span className="w-tbtn"><Layers size={10} /></span>
          <span className="w-tbtn"><ArrowDownCircle size={10} /></span>
          <span className="w-shuffle-wrap">
            <span className={`w-shuffle-ring${pulse ? ' pulse' : ''}`} />
            <span
              className="w-tbtn active"
              style={{
                background: '#f97316',
                transform: `rotate(${step * 180}deg) scale(${pulse ? 0.86 : 1})`,
              }}
            >
              <Shuffle size={10} />
            </span>
          </span>
        </>
      }
    >
      <div className="w-masonry">
        {SHUFFLE_CARDS.map((c) => {
          const r = rects[c.id];
          return (
            <div
              key={c.id}
              className="w-mcard"
              style={{
                left: `calc(12px + ${r.col} * ((100% - 42px) / 3 + 9px))`,
                width: 'calc((100% - 42px) / 3)',
                top: r.top,
                height: r.h,
              }}
            >
              <div className="w-mcard-media" style={{ background: `linear-gradient(135deg, ${c.bg}, transparent)` }}>
                <span className="w-mcard-badge" style={{ color: c.color }}>
                  {c.kind === 'video' ? <Play size={9} fill="currentColor" /> : <Image size={9} />}
                </span>
              </div>
              <div className="w-mcard-cap">
                <div className="w-wire-line" style={{ width: '44%' }} />
                <div style={{ width: 18, height: 6, borderRadius: 999, background: c.bg }} />
              </div>
            </div>
          );
        })}
      </div>
    </MiniAppWindow>
  );
}

// ---- Page 2: Album Grid Zoom (Toolbar Zoom Out / Zoom In only — matching real app) ----

const GRID_LEVELS = [6, 4, 2, 4];
const GRID_TINTS = [
  'rgba(10,102,255,0.20)',
  'rgba(79,70,229,0.20)',
  'rgba(6,182,212,0.20)',
  'rgba(13,148,136,0.20)',
  'rgba(147,51,234,0.20)',
  'rgba(236,72,153,0.18)',
];

function GridZoomStage() {
  const [idx, setIdx] = useState(1);
  useEffect(() => {
    const id = window.setInterval(() => setIdx((i) => i + 1), 1850);
    return () => window.clearInterval(id);
  }, []);

  const cols = GRID_LEVELS[idx % GRID_LEVELS.length];
  const rows = cols === 6 ? 4 : cols === 4 ? 3 : 2;
  const anchorR = cols === 2 ? 0 : Math.floor(rows / 2) - 1;
  const anchorC = Math.floor(cols / 2);
  const gap = 3;
  const pad = 8;
  const availW = 480;
  const side = (availW - pad * 2 - gap * (cols - 1)) / cols;

  return (
    <MiniAppWindow
      selected="photos"
      accent="#0a66ff"
      accentSoft="rgba(10,102,255,0.14)"
      toolbar={
        <>
          <span className="w-bar-title">{L('place.photos')}</span>
          <div style={{ flex: 1 }} />
          <span className={`w-tbtn${cols === 6 ? ' active' : ''}`} style={cols === 6 ? { background: '#0a66ff' } : undefined}>
            <ZoomOut size={10} />
          </span>
          <span className={`w-tbtn${cols === 2 ? ' active' : ''}`} style={cols === 2 ? { background: '#0a66ff' } : undefined}>
            <ZoomIn size={10} />
          </span>
        </>
      }
    >
      <div className="w-grid-stage">
        {Array.from({ length: rows * cols }, (_, i) => {
          const r = Math.floor(i / cols);
          const c = i % cols;
          const anchor = r === anchorR && c === anchorC;
          return (
            <div
              key={`${cols}-${i}`}
              className="w-gtile"
              style={{
                left: `calc(8px + ${c} * ((100% - 16px - ${(cols - 1) * gap}px) / ${cols} + ${gap}px))`,
                top: 8 + r * (side + gap),
                width: `calc((100% - 16px - ${(cols - 1) * gap}px) / ${cols})`,
                height: side,
                background: anchor ? 'linear-gradient(135deg, #0a66ff, #3b82f6)' : GRID_TINTS[(r * 7 + c * 3) % GRID_TINTS.length],
                color: '#fff',
              }}
            >
              {anchor && <Scan size={Math.min(24, side * 0.34)} />}
            </div>
          );
        })}
      </div>
    </MiniAppWindow>
  );
}

// ---- Page 3: Quick Download Popover (tucked right under toolbar button) + Settings JSON Import ----

function DownloadBatchStage() {
  const [phase, setPhase] = useState(0);
  useEffect(() => {
    const id = window.setInterval(() => setPhase((p) => (p + 1) % 4), 1650);
    return () => window.clearInterval(id);
  }, []);

  const inSettings = phase >= 2;
  return (
    <MiniAppWindow
      selected={inSettings ? 'settings' : 'browse'}
      accent="#06b6d4"
      accentSoft="rgba(6,182,212,0.14)"
      toolbar={
        <>
          <span className="w-bar-title">{L(inSettings ? 'place.settings' : 'place.browse')}</span>
          <div style={{ flex: 1 }} />
          {!inSettings ? (
            <>
              <span className="w-tbtn"><Clock size={10} /></span>
              <span
                className="w-tbtn active"
                style={{ background: '#06b6d4', transform: phase === 0 ? 'scale(1.12)' : 'scale(1)' }}
              >
                <ArrowDownCircle size={11} />
              </span>
              <span className="w-tbtn"><Shuffle size={10} /></span>
            </>
          ) : (
            <span
              style={{
                fontSize: 9.5,
                fontWeight: 700,
                fontFamily: 'var(--font-mono)',
                color: '#06b6d4',
                padding: '2px 7px',
                borderRadius: 999,
                background: 'rgba(6,182,212,0.15)',
              }}
            >
              JSON
            </span>
          )}
        </>
      }
    >
      {!inSettings ? (
        <>
          <div className="w-dl-bg">
            {Array.from({ length: 6 }, (_, i) => (
              <div key={i} className="w-dl-bg-card" />
            ))}
          </div>
          <div className="w-popover-wrap">
            <div className="w-popover-caret" />
            <div className="w-popover">
              <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                <ArrowDownCircle size={13} color="#06b6d4" />
                <div className="w-wire-line" style={{ width: 74, height: 6 }} />
              </div>
              {[120, 92].map((w, row) => (
                <div key={row} className="w-link-row">
                  <Link2 size={10} color="#06b6d4" />
                  <div className="w-wire-line" style={{ width: w, height: 5 }} />
                  <div style={{ flex: 1 }} />
                  {phase === 1 && <CheckCircle2 size={11} color="#16a34a" />}
                </div>
              ))}
              <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
                <span
                  style={{
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: 4,
                    padding: '4px 10px',
                    borderRadius: 999,
                    background: phase === 1 ? '#16a34a' : '#06b6d4',
                    color: '#fff',
                  }}
                >
                  {phase === 1 ? <Check size={10} /> : <ArrowDown size={10} />}
                  <span style={{ width: 28, height: 4, borderRadius: 2, background: 'rgba(255,255,255,0.85)' }} />
                </span>
              </div>
            </div>
          </div>
        </>
      ) : (
        <div className="w-json-card">
          <div className="w-json-drop">
            <FileText size={24} color="#06b6d4" />
            <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
              <span style={{ fontSize: 11, fontWeight: 600, fontFamily: 'var(--font-mono)', color: 'var(--fg)' }}>
                bookmarks.json
              </span>
              <div className="w-wire-line" style={{ width: 92 }} />
            </div>
          </div>
          {[0, 1, 2].map((i) => (
            <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              {phase === 3 ? <CheckCircle2 size={12} color="#16a34a" /> : <ArrowDownCircle size={12} color="#06b6d4" />}
              <div className="w-bar-track">
                <div
                  className="w-bar-fill"
                  style={{
                    width: phase === 3 ? '100%' : `${38 + i * 20}%`,
                    background: phase === 3 ? '#16a34a' : '#06b6d4',
                  }}
                />
              </div>
            </div>
          ))}
        </div>
      )}
    </MiniAppWindow>
  );
}

// ---- Page 4: Settings -> AI Models Download & Auto-Tagging ----

function AIModelTagStage() {
  const [step, setStep] = useState(0);
  useEffect(() => {
    const id = window.setInterval(() => setStep((s) => (s + 1) % 3), 1600);
    return () => window.clearInterval(id);
  }, []);

  const ringOffset = step === 0 ? 34 : 0;
  return (
    <MiniAppWindow
      selected="settings"
      accent="#9333ea"
      accentSoft="rgba(147,51,234,0.14)"
      toolbar={
        <>
          <Sparkles size={11} color="#9333ea" />
          <span className="w-bar-title">{L('common.aiModels')}</span>
        </>
      }
    >
      <div className="w-ai-layout">
        <div className="w-ai-left">
          <div className="w-ai-row">
            <div style={{ position: 'relative', width: 32, height: 32, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
              <svg width="32" height="32" viewBox="0 0 32 32" style={{ transform: 'rotate(-90deg)' }}>
                <circle cx="16" cy="16" r="13" fill="none" stroke="rgba(147,51,234,0.2)" strokeWidth="3" />
                <circle
                  cx="16"
                  cy="16"
                  r="13"
                  fill="none"
                  stroke="#9333ea"
                  strokeWidth="3"
                  strokeLinecap="round"
                  strokeDasharray="81.68"
                  strokeDashoffset={ringOffset}
                  style={{ transition: 'stroke-dashoffset 0.5s ease' }}
                />
              </svg>
              <span style={{ position: 'absolute', color: '#9333ea', display: 'flex' }}>
                {step === 0 ? <ArrowDown size={12} /> : <Check size={12} />}
              </span>
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
              <div className="w-wire-line" style={{ width: 82, height: 6 }} />
              <div style={{ width: 52, height: 4.5, borderRadius: 2, background: 'rgba(147,51,234,0.38)' }} />
            </div>
          </div>

          <div className="w-ai-row" style={{ justifyContent: 'space-between' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
              <Sparkles size={12} color="#9333ea" />
              <div className="w-wire-line" style={{ width: 62, height: 5.5 }} />
            </div>
            <div className={`w-switch${step >= 1 ? ' on' : ''}`}>
              <div className="w-switch-knob" />
            </div>
          </div>
        </div>

        <div className="w-ai-card">
          <div className="w-ai-media">
            <Image size={26} color="rgba(147,51,234,0.52)" />
            <div
              className="w-ai-beam"
              style={{
                transform: `translateY(${step === 1 ? 36 : -44}px)`,
                opacity: step === 1 ? 1 : 0,
              }}
            />
          </div>
          <div className="w-ai-tags">
            {[20, 26, 32].map((w, idx) => (
              <span
                key={idx}
                className="w-ai-pill"
                style={{
                  transform: `scale(${step === 2 ? 1 : 0.5})`,
                  opacity: step === 2 ? 1 : 0,
                  transitionDelay: `${idx * 80}ms`,
                }}
              >
                <Sparkles size={8} />
                <span style={{ width: w, height: 4, borderRadius: 2, background: 'rgba(147,51,234,0.7)' }} />
              </span>
            ))}
          </div>
        </div>
      </div>
    </MiniAppWindow>
  );
}

// ---- Page 5: Three Tag Types Inside Real Card Tag Strip ----

function TagTrioStage() {
  const [phase, setPhase] = useState(0);
  useEffect(() => {
    const id = window.setInterval(() => setPhase((p) => (p + 1) % 3), 1800);
    return () => window.clearInterval(id);
  }, []);

  const approved = phase === 2;
  return (
    <div className="w-tag-stage">
      <div className="w-tag-card">
        <div className="w-tag-card-media">
          <Image size={22} />
        </div>
        <div className="w-tag-card-body">
          <div style={{ display: 'flex', gap: 7 }}>
            <div className="w-wire-line" style={{ width: 76, height: 6 }} />
            <div className="w-wire-line" style={{ width: 48, height: 6, opacity: 0.5 }} />
          </div>
          <div className="w-tag-strip">
            <span
              className="w-tag-pill"
              style={{
                color: approved ? '#16a34a' : '#9333ea',
                background: approved ? 'rgba(22,163,74,0.16)' : 'rgba(147,51,234,0.16)',
                borderColor: approved ? 'rgba(22,163,74,0.55)' : 'rgba(147,51,234,0.55)',
                transform: phase === 0 || phase === 2 ? 'scale(1.06)' : 'scale(1)',
              }}
            >
              {approved ? <Check size={11} /> : <Sparkles size={11} />}
              {L(approved ? 'welcome.p5.chip.common' : 'welcome.p5.chip.ai')}
            </span>

            {phase >= 1 && (
              <span
                className="w-tag-pill"
                style={{
                  color: '#0a66ff',
                  background: 'rgba(10,102,255,0.16)',
                  borderColor: 'rgba(10,102,255,0.55)',
                  animation: 'welcome-pop-in 0.25s var(--ease) both',
                }}
              >
                <Tag size={10} />
                {L('welcome.p5.chip.mine')}
              </span>
            )}

            <span
              className="w-tag-plus"
              style={{
                color: phase === 1 ? '#0a66ff' : undefined,
                transform: phase === 1 ? 'scale(0.9)' : 'scale(1)',
              }}
            >
              <Plus size={11} />
            </span>
          </div>
        </div>
      </div>

      <div className="w-legend-row">
        {[
          { idx: 0, icon: <Sparkles size={11} />, label: L('welcome.p5.chip.ai'), color: '#9333ea', soft: 'rgba(147,51,234,0.18)', dim: 'rgba(147,51,234,0.09)' },
          { idx: 1, icon: <Tag size={11} />, label: L('welcome.p5.chip.mine'), color: '#0a66ff', soft: 'rgba(10,102,255,0.18)', dim: 'rgba(10,102,255,0.09)' },
          { idx: 2, icon: <CheckCircle2 size={11} />, label: L('welcome.p5.chip.common'), color: '#16a34a', soft: 'rgba(22,163,74,0.18)', dim: 'rgba(22,163,74,0.09)' },
        ].map((item) => {
          const active = phase === item.idx;
          return (
            <span
              key={item.idx}
              className="w-tag-pill"
              style={{
                color: item.color,
                background: active ? item.soft : item.dim,
                borderColor: active ? item.color : 'transparent',
                transform: active ? 'scale(1.06)' : 'scale(0.96)',
              }}
            >
              {item.icon}
              {item.label}
            </span>
          );
        })}
      </div>
    </div>
  );
}

// ---- Page 6: Multi-Faceted Token Search Inside Browse Toolbar ----

const SEARCH_CARDS = [
  { id: 0, ai: true, video: true, excl: false },
  { id: 1, ai: true, video: false, excl: false },
  { id: 2, ai: true, video: true, excl: true },
  { id: 3, ai: false, video: true, excl: false },
  { id: 4, ai: true, video: true, excl: false },
  { id: 5, ai: true, video: false, excl: true },
];

function TokenSearchStage() {
  const [tokens, setTokens] = useState(1);
  useEffect(() => {
    const id = window.setInterval(() => setTokens((n) => (n % 3) + 1), 1550);
    return () => window.clearInterval(id);
  }, []);

  const hit = (c: (typeof SEARCH_CARDS)[number]) => {
    if (tokens >= 1 && !c.ai) return false;
    if (tokens >= 2 && !c.video) return false;
    if (tokens >= 3 && c.excl) return false;
    return true;
  };

  return (
    <MiniAppWindow
      selected="browse"
      accent="#4f46e5"
      accentSoft="rgba(79,70,229,0.14)"
      toolbar={
        <div className="w-search-bar">
          <Search size={10} color="var(--fg-2)" />
          {tokens >= 1 && (
            <span className="w-token" style={{ color: '#9333ea', background: 'rgba(147,51,234,0.16)' }}>
              <Sparkles size={9} />
              {L('search.kw.ai.word')}
            </span>
          )}
          {tokens >= 2 && (
            <span className="w-token" style={{ color: '#0a66ff', background: 'rgba(10,102,255,0.16)' }}>
              <Video size={9} />
              {L('search.kw.video.word')}
            </span>
          )}
          {tokens >= 3 && (
            <span className="w-token" style={{ color: '#e11d48', background: 'rgba(225,29,72,0.15)' }}>
              <Folder size={9} />
              -{L('search.kw.folder.word')}
            </span>
          )}
        </div>
      }
    >
      <div className="w-search-grid">
        {SEARCH_CARDS.map((c) => {
          const ok = hit(c);
          return (
            <div
              key={c.id}
              className="w-scard"
              style={{
                borderColor: ok ? 'rgba(79,70,229,0.72)' : undefined,
                transform: ok ? 'scale(1.02)' : 'scale(0.94)',
                opacity: ok ? 1 : 0.34,
              }}
            >
              <div
                style={{
                  flex: 1,
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  gap: 5,
                  background: ok ? 'rgba(79,70,229,0.13)' : 'var(--bg-subtle)',
                }}
              >
                {c.video ? <Play size={12} color={ok ? '#4f46e5' : 'var(--fg-3)'} /> : <Image size={12} color={ok ? '#4f46e5' : 'var(--fg-3)'} />}
                {c.ai && <Sparkles size={10} color={ok ? '#9333ea' : 'var(--fg-3)'} />}
                {c.excl && <Folder size={10} color={tokens >= 3 ? 'rgba(225,29,72,0.65)' : 'var(--fg-3)'} />}
              </div>
              <div style={{ height: 18, padding: '0 7px', display: 'flex', alignItems: 'center' }}>
                <div className="w-wire-line" style={{ width: 42, opacity: ok ? 1 : 0.4 }} />
              </div>
            </div>
          );
        })}
      </div>
    </MiniAppWindow>
  );
}

// ---- Page 7: Decentralized LAN Peer-to-Peer Sync ----

function LanSyncStage() {
  const [t, setT] = useState(0);
  useEffect(() => {
    let raf = 0;
    const start = performance.now();
    const tick = (now: number) => {
      setT((now - start) / 1000);
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, []);

  const p1 = (t * 0.45) % 1;
  const p2 = (t * 0.45 + 0.33) % 1;
  const p3 = (t * 0.45 + 0.66) % 1;
  const ripple = (t * 0.55) % 1;

  const top = { x: 320, y: 74 };
  const left = { x: 186, y: 214 };
  const right = { x: 454, y: 214 };
  const lerp = (a: { x: number; y: number }, b: { x: number; y: number }, p: number) => ({
    x: a.x + (b.x - a.x) * p,
    y: a.y + (b.y - a.y) * p,
  });
  const d1 = lerp(top, left, p1);
  const d2 = lerp(left, right, p2);
  const d3 = lerp(right, top, p3);

  return (
    <div style={{ position: 'relative', width: '100%', height: '100%' }}>
      <svg className="w-sync-svg" viewBox="0 0 640 300" preserveAspectRatio="xMidYMid meet">
        <circle
          cx="320"
          cy="154"
          r={44 + ripple * 88}
          fill="none"
          stroke={`rgba(13, 148, 136, ${(1 - ripple) * 0.3})`}
          strokeWidth="1.5"
        />
        <line x1={top.x} y1={top.y} x2={left.x} y2={left.y} stroke="rgba(13,148,136,0.36)" strokeWidth="1.8" strokeDasharray="5 5" />
        <line x1={left.x} y1={left.y} x2={right.x} y2={right.y} stroke="rgba(13,148,136,0.36)" strokeWidth="1.8" strokeDasharray="5 5" />
        <line x1={right.x} y1={right.y} x2={top.x} y2={top.y} stroke="rgba(13,148,136,0.36)" strokeWidth="1.8" strokeDasharray="5 5" />
        <circle cx={d1.x} cy={d1.y} r="4.5" fill="#0d9488" />
        <circle cx={d2.x} cy={d2.y} r="4.5" fill="#0a66ff" />
        <circle cx={d3.x} cy={d3.y} r="4.5" fill="#10b981" />
      </svg>

      {[
        { pos: { left: '50%', top: '25%' }, icon: <Laptop size={22} color="#0d9488" /> },
        { pos: { left: '29%', top: '71%' }, icon: <Smartphone size={22} color="#0d9488" /> },
        { pos: { left: '71%', top: '71%' }, icon: <Monitor size={22} color="#0d9488" /> },
      ].map((node, i) => (
        <div
          key={i}
          style={{
            position: 'absolute',
            ...node.pos,
            transform: 'translate(-50%, -50%)',
            width: 58,
            height: 58,
            borderRadius: '50%',
            background: 'var(--card)',
            border: '1.5px solid rgba(13,148,136,0.45)',
            boxShadow: '0 8px 20px rgba(0,0,0,0.08)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          {node.icon}
          <span
            style={{
              position: 'absolute',
              right: 2,
              bottom: 2,
              width: 10,
              height: 10,
              borderRadius: '50%',
              background: '#16a34a',
              border: '2px solid var(--card)',
            }}
          />
        </div>
      ))}
    </div>
  );
}

// ---- Page 8: Import & Export Inside Settings Layout ----

function ImportExportStage() {
  const [phase, setPhase] = useState(0);
  useEffect(() => {
    const id = window.setInterval(() => setPhase((p) => (p + 1) % 3), 1600);
    return () => window.clearInterval(id);
  }, []);

  return (
    <MiniAppWindow
      selected="settings"
      accent="#ec4899"
      accentSoft="rgba(236,72,153,0.14)"
      toolbar={
        <>
          <ArrowLeftRight size={11} color="#ec4899" />
          <span className="w-bar-title">{L('welcome.p8.badge')}</span>
        </>
      }
    >
      <div className="w-io-row">
        <div
          className="w-io-sources"
          style={{ transform: `translateX(${phase === 0 ? 10 : 0}px)`, opacity: phase === 0 ? 1 : 0.55 }}
        >
          <div className="w-io-chip" style={{ background: 'rgba(10,102,255,0.14)', border: '1px solid rgba(10,102,255,0.35)', color: '#0a66ff' }}>
            <Folder size={20} />
          </div>
          <div className="w-io-chip" style={{ background: 'rgba(249,115,22,0.14)', border: '1px solid rgba(249,115,22,0.35)', color: '#f97316' }}>
            <FileArchive size={20} />
          </div>
        </div>

        <ChevronsRight size={15} color="#0a66ff" style={{ opacity: phase === 0 ? 0.9 : 0.25, transition: 'opacity 0.3s' }} />

        <div
          className="w-io-vault"
          style={{
            border: phase === 1 ? '1.8px solid rgba(236,72,153,0.65)' : '1px solid rgba(236,72,153,0.28)',
            transform: phase === 1 ? 'scale(1.07)' : 'scale(1)',
            color: '#ec4899',
          }}
        >
          <Inbox size={30} />
        </div>

        <ChevronsRight size={15} color="#ec4899" style={{ opacity: phase === 2 ? 0.9 : 0.25, transition: 'opacity 0.3s' }} />

        <div
          className="w-io-pack"
          style={{ transform: `translateX(${phase === 2 ? 6 : -4}px)`, opacity: phase === 2 ? 1 : 0.55 }}
        >
          <div className="w-io-box">
            <Package size={24} />
            <span
              className="w-io-shield"
              style={{ transform: `scale(${phase === 2 ? 1 : 0.4})`, opacity: phase === 2 ? 1 : 0 }}
            >
              <ShieldCheck size={14} />
            </span>
          </div>
          <span
            style={{
              fontSize: 10.5,
              fontWeight: 700,
              fontFamily: 'var(--font-mono)',
              color: '#ec4899',
              padding: '2px 8px',
              borderRadius: 999,
              background: 'rgba(236,72,153,0.14)',
            }}
          >
            .tlpack
          </span>
        </div>
      </div>
    </MiniAppWindow>
  );
}
