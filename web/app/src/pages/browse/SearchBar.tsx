// The search field: finished words become capsules (a tag, 视频, 文件夹 Trips, -猫 …, see the
// core's search.ts). The list under it is the native apps' (SearchSuggestions in
// Apple/Shared/SearchQuery.swift): it opens with the field and offers the conditions, what to search
// for, matching tags and folders, recent searches, and a short guide with the library's totals.
import { useEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import {
  AlertTriangle, BadgeCheck, CheckCircle2, CircleDashed, CircleUser, Clock, Download, Folder, History, Image, Images,
  LayoutGrid, MinusCircle, Quote, Search, Sparkles, Tag, User, Video, X,
} from 'lucide-react';
import { KEYWORDS, folderKey, keyFor, keyTitle, keywordAliases, keywordHint, keywordWord, isExcluded, L, PENDING_FOLDER, quoteSearchWord, splitQuery, termKey, type SearchKeyword, type TagCount } from '@twimshelf/core';
import { core } from '../../lib/core';
import { useStore } from '../../lib/hooks';
import { folders, libraryVersion, stats } from '../../lib/library';
import { ClawdIcon, mascotEnabled } from '../../components/Mascot';
import './SearchBar.css';

type Action = { key: string } | { folder: string; excluded: boolean } | { clearHistory: true };
type Tint = 'accent' | 'folder' | 'secondary' | 'exclude';
interface Row { id: string; title: string; subtitle?: string; icon?: ReactNode; tint?: Tint; destructive?: boolean; action?: Action }
interface Section { title: string; rows: Row[] }

const SYMBOLS: Record<string, ReactNode> = {
  tags: <Tag size={14} />, text: <Quote size={14} />, author: <User size={14} />, mine: <CircleUser size={14} />,
  ai: <Sparkles size={14} />, common: <BadgeCheck size={14} />, all: <LayoutGrid size={14} />, video: <Video size={14} />,
  photo: <Image size={14} />, folder: <Folder size={14} />, recent: <Clock size={14} />, external: <Download size={14} />,
  album: <Images size={14} />, reviewed: <CheckCircle2 size={14} />, unreviewed: <CircleDashed size={14} />, damaged: <AlertTriangle size={14} />,
};

const HISTORY = 'search.history';
function history(): string[] {
  try { const v = JSON.parse(localStorage.getItem(HISTORY) ?? '[]'); return Array.isArray(v) ? v : []; }
  catch { return []; }
}
function remember(term: string) {
  const t = term.trim();
  if (!t) return;
  try { localStorage.setItem(HISTORY, JSON.stringify([t, ...history().filter((x) => x !== t)].slice(0, 12))); } catch { /* unavailable storage */ }
}
function forget() { try { localStorage.removeItem(HISTORY); } catch { /* unavailable storage */ } }

let tagCache: { version: number; tags: TagCount[] } | null = null;
async function allTags(version: number): Promise<TagCount[]> {
  if (tagCache?.version === version) return tagCache.tags;
  const tags = await core.read<TagCount[]>(core.b.tl_all_tags());
  tagCache = { version, tags };
  return tags;
}

const MINUS_SIGNS = ['-', '－', '−', '–'];
const byCount = (a: TagCount, b: TagCount) => b.count - a.count;

/** The sections of the list, as the native apps make them. */
function sectionsFor(raw: string, keys: string[], tags: TagCount[], folderList: { name: string; count: number }[]): Section[] {
  const typed = raw.trim();
  const present = new Set(keys);
  const terms = keys.filter((k) => k.startsWith('t:')).map((k) => k.slice(2).toLowerCase());
  const lone = typed.length === 1 && MINUS_SIGNS.includes(typed);
  const negative = lone || (typed.length > 1 && MINUS_SIGNS.includes(typed[0]));
  const q = (lone ? '' : negative ? typed.slice(1) : typed).toLowerCase();
  // 损坏 is offered with the maintenance rows of 关于 (typed, it always works)
  let extras = false;
  try { extras = localStorage.getItem('about.extras') === 'true'; } catch { /* unavailable storage */ }
  const matches = (k: SearchKeyword) => (k.id !== 'damaged' || extras)
    && (!q || [keywordWord(k), ...keywordAliases(k)].some((s) => s.toLowerCase().startsWith(q)));

  // right after 文件夹 / -文件夹: the folders (matching what is typed)
  const last = keys[keys.length - 1];
  if (last === PENDING_FOLDER || last === `-${PENDING_FOLDER}`) {
    const excluded = last !== PENDING_FOLDER;
    const shown = q ? folderList.filter((f) => f.name.toLowerCase().includes(q)) : folderList;
    const rows: Row[] = shown.length === 0
      ? [{ id: 'noFolder', title: L(folderList.length ? 'search.noMatchingFolders' : 'search.noFolders'), icon: <Folder size={14} /> }]
      : shown.map((f) => ({
        id: `folder-${f.name}`, title: f.name, subtitle: L('search.row.mediaCount', f.count),
        icon: excluded ? <MinusCircle size={14} /> : <Folder size={14} />, tint: excluded ? 'exclude' : 'folder', action: { folder: f.name, excluded },
      }));
    return [{ title: L(excluded ? 'search.section.pickExcludedFolder' : 'search.section.pickFolder'), rows }];
  }

  const out: Section[] = [];
  if (negative) {
    const kws = KEYWORDS.filter((k) => k.excludable && !present.has(`-${k.key}`) && matches(k));
    if (kws.length) {
      out.push({ title: L('search.section.exclude'), rows: kws.map((k) => ({
        id: `kw-minus-${k.id}`, title: `−${keywordWord(k)}`, subtitle: L(`search.kw.${k.id}.exclude`),
        icon: <MinusCircle size={14} />, tint: 'exclude', action: { key: `-${k.key}` },
      })) });
    }
    if (q) {
      out.push({ title: L('search.section.content'), rows: [
        { id: 'term-minus', title: L('search.row.exclude', q), icon: <MinusCircle size={14} />, tint: 'exclude', action: { key: `-${termKey(q)}` } },
        ...tags.filter((t) => t.label.toLowerCase().includes(q) && t.label !== q).sort(byCount).slice(0, 6).map((t): Row => ({
          id: `tag-minus-${t.label}`, title: L('search.row.excludeTag', t.label), subtitle: L('search.row.mediaCount', t.count),
          icon: <Tag size={14} />, tint: 'exclude', action: { key: `-${termKey(t.label.toLowerCase())}` },
        })),
      ] });
      const fs = folderList.filter((f) => f.name.toLowerCase().includes(q) && !present.has(`-${folderKey(f.name)}`));
      if (fs.length) {
        out.push({ title: L('search.section.folders'), rows: fs.map((f) => ({
          id: `folder-minus-${f.name}`, title: f.name, subtitle: L('search.row.mediaCount', f.count),
          icon: <MinusCircle size={14} />, tint: 'exclude', action: { folder: f.name, excluded: true },
        })) });
      }
    }
    return out;
  }

  const kws = KEYWORDS.filter((k) => !present.has(k.key) && matches(k));
  if (kws.length) {
    out.push({ title: L('search.section.conditions'), rows: kws.map((k) => ({
      id: `kw-${k.id}`, title: keywordWord(k), subtitle: keywordHint(k), icon: SYMBOLS[k.id], action: { key: k.key },
    })) });
  }
  if (typed) {
    out.push({ title: L('search.section.content'), rows: [
      { id: 'term', title: L('search.row.searchFor', typed), icon: <Search size={14} />, action: { key: termKey(q) } },
      ...tags.filter((t) => t.label.toLowerCase().includes(q) && !terms.includes(t.label)).sort(byCount).slice(0, 8).map((t): Row => ({
        id: `tag-${t.label}`, title: t.label, subtitle: L('search.row.mediaCount', t.count), icon: <Tag size={14} />, action: { key: termKey(t.label.toLowerCase()) },
      })),
    ] });
    const fs = folderList.filter((f) => f.name.toLowerCase().includes(q));
    if (fs.length) {
      out.push({ title: L('search.section.folders'), rows: fs.map((f) => ({
        id: `folder-${f.name}`, title: f.name, subtitle: L('search.row.onlyFolder', f.count), icon: <Folder size={14} />, tint: 'folder', action: { folder: f.name, excluded: false },
      })) });
    }
  } else {
    const recent = history().filter((t) => !terms.includes(t)).slice(0, 6);
    if (recent.length) {
      out.push({ title: L('search.section.recent'), rows: [
        ...recent.map((t): Row => ({ id: `recent-${t}`, title: t, icon: <History size={14} />, tint: 'secondary', action: { key: termKey(t) } })),
        { id: 'clearHistory', title: L('search.clearHistory'), destructive: true, action: { clearHistory: true } },
      ] });
    }
  }
  return out;
}

/** The search text as it goes into the route: keys' words joined (re-parsed on load). */
function wordOf(key: string): string {
  const ex = isExcluded(key) ? '-' : '';
  const bare = ex ? key.slice(1) : key;
  if (bare.startsWith('t:')) return ex + quoteSearchWord(bare.slice(2));
  if (bare.startsWith('d:')) return `${ex}${keywordWord(KEYWORDS.find((k) => k.key === PENDING_FOLDER)!)} ${quoteSearchWord(bare.slice(2))}`;
  const k = KEYWORDS.find((x) => x.key === bare);
  return k ? ex + keywordWord(k) : ex + bare;
}

export function SearchBar({ value, onSearch }: { value: string; onSearch: (q: string) => void }) {
  const [keys, setKeys] = useState<string[]>(() => splitQuery(`${value} `).keys);
  const [text, setText] = useState('');
  const [open, setOpen] = useState(false);
  const [pick, setPick] = useState(-1);
  const [tags, setTags] = useState<TagCount[]>([]);
  const [, redraw] = useState(0);
  const version = useStore(libraryVersion);
  const mascot = useStore(mascotEnabled);
  const f = useStore(folders);
  const totals = useStore(stats);
  const input = useRef<HTMLInputElement>(null);
  const root = useRef<HTMLDivElement>(null);
  // the press in the field that closed the list does not open it again as the field takes focus
  const keepClosed = useRef(false);

  useEffect(() => { setKeys(splitQuery(`${value} `).keys); setText(''); }, [value]);
  useEffect(() => { if (open) allTags(version).then(setTags, () => {}); }, [open, version]);
  useEffect(() => {
    if (!open) return;
    const place = () => redraw((n) => n + 1);
    window.addEventListener('resize', place);
    return () => window.removeEventListener('resize', place);
  }, [open]);

  const sections = useMemo(() => sectionsFor(text, keys, tags, f?.folders ?? []), [text, keys, tags, f, open]);
  const rows = useMemo(() => sections.flatMap((s) => s.rows).filter((r) => r.action), [sections]);
  useEffect(() => setPick(-1), [text, keys]);

  const commit = (words: string[], newKeys = keys) => {
    let ks = [...newKeys];
    for (const w of words) {
      const prev = ks.length ? ks[ks.length - 1] : null;
      const k = keyFor(w, prev);
      if (k.startsWith('t:')) remember(k.slice(2));
      if (prev === PENDING_FOLDER || prev === `-${PENDING_FOLDER}`) ks[ks.length - 1] = k; else ks.push(k);
    }
    ks = ks.filter((k, i) => ks.indexOf(k) === i);
    setKeys(ks);
    setText('');
    return ks;
  };
  const search = (ks: string[]) => onSearch(ks.filter((k) => k.replace(/^-/, '') !== PENDING_FOLDER).map(wordOf).join(' '));

  /** A row chosen: what was typed gives way to it, the search runs and the list stays. */
  const perform = (a: Action) => {
    input.current?.focus();
    if ('clearHistory' in a) { forget(); redraw((n) => n + 1); return; }
    let ks = [...keys];
    if ('key' in a) {
      if (a.key.startsWith('t:')) remember(a.key.slice(2));
      ks.push(a.key);
    } else {
      const last = ks[ks.length - 1]?.replace(/^-/, '');
      if (last === PENDING_FOLDER) ks.pop();
      if (!a.excluded) ks = ks.filter((k) => !k.startsWith('d:'));
      ks.push(`${a.excluded ? '-' : ''}${folderKey(a.folder)}`);
    }
    ks = ks.filter((k, i) => ks.indexOf(k) === i);
    setKeys(ks);
    setText('');
    search(ks);
  };

  const guide = `${totals ? `${L('activity.stats', totals.posts, totals.photos, totals.videos)}\n` : ''}${L('search.guide', KEYWORDS.map((k) => L('search.guide.quoted', keywordWord(k))).join(L('search.guide.separator')))}`;
  let index = -1;

  return (
    <div ref={root} className={`search${open ? ' focused' : ''}`} onClick={() => input.current?.focus()}
      onMouseDown={(e) => {
        if ((e.target as Element).closest('button')) return;
        // a click in the field opens the list, or closes it when it is open
        if (open) { keepClosed.current = true; setOpen(false); } else if (document.activeElement === input.current) setOpen(true);
      }}>
      {mascot && keys.length > 0 ? <ClawdIcon name="search" size={18} className="search-icon" /> : <Search size={15} className="search-icon" />}
      {keys.map((k, i) => (
        <span key={k + i} className={`capsule${isExcluded(k) ? ' excluded' : ''}`}>
          {keyTitle(k)}
          <button onClick={(e) => { e.stopPropagation(); const ks = keys.filter((_, j) => j !== i); setKeys(ks); search(ks); }} aria-label={L('common.clear')}><X size={10} /></button>
        </span>
      ))}
      <input ref={input} value={text} placeholder={keys.length ? '' : L('search.placeholder')}
        onFocus={() => { if (keepClosed.current) keepClosed.current = false; else setOpen(true); }}
        onBlur={() => { keepClosed.current = false; setOpen(false); }}
        onChange={(e) => {
          const v = e.target.value;
          setOpen(true);
          if (/[ 　]$/.test(v) && v.trim()) { commit(v.trim().split(/[ 　]+/)); return; }
          setText(v);
        }}
        onKeyDown={(e) => {
          if (e.nativeEvent.isComposing) return;
          if (e.key === 'ArrowDown' && rows.length) { e.preventDefault(); setOpen(true); setPick((pick + 1) % rows.length); }
          else if (e.key === 'ArrowUp' && rows.length) { e.preventDefault(); setOpen(true); setPick(pick <= 0 ? rows.length - 1 : pick - 1); }
          else if (e.key === 'Tab' && open && rows.length && (pick >= 0 || text.trim())) { e.preventDefault(); perform(rows[Math.max(pick, 0)].action!); }
          else if (e.key === 'Enter') {
            if (open && pick >= 0 && rows[pick]) { perform(rows[pick].action!); return; }
            const ks = text.trim() ? commit(text.trim().split(/[ 　]+/)) : keys;
            search(ks);
            input.current?.blur();
          } else if ((e.key === 'Backspace' || e.key === 'Delete') && !text && keys.length) {
            e.preventDefault();
            const remaining = keys.slice(0, -1);
            setKeys(remaining);
            search(remaining);
          } else if (e.key === 'Escape') {
            if (open) { setOpen(false); return; }
            setKeys([]); setText(''); search([]); input.current?.blur();
          }
        }} />
      {(keys.length > 0 || text) && <button className="search-clear" onClick={(e) => { e.stopPropagation(); setKeys([]); setText(''); search([]); }} aria-label={L('common.clear')}><X size={13} /></button>}
      {/* in the body: the toolbar's glass would otherwise clip it */}
      {open && createPortal(
        <div className="suggest" style={suggestPlace(root.current)} onMouseDown={(e) => e.preventDefault()} onMouseLeave={() => setPick(-1)}>
          {sections.map((s) => (
            <div className="suggest-section" key={s.title}>
              <div className="suggest-title">{s.title}</div>
              {s.rows.map((r) => {
                const at = r.action ? ++index : -1;
                return (
                  <button key={r.id} disabled={!r.action} className={`suggest-row${at >= 0 && at === pick ? ' on' : ''}${r.destructive ? ' destructive' : ''}`}
                    onMouseEnter={() => { if (at >= 0) setPick(at); }} onClick={() => { if (r.action) perform(r.action); }}>
                    <span className={`suggest-icon ${r.tint ?? 'accent'}`}>{r.icon}</span>
                    <span className="suggest-label">{r.title}</span>
                    {r.subtitle && <span className="suggest-hint">{r.subtitle}</span>}
                  </button>
                );
              })}
            </div>
          ))}
          <div className="suggest-guide">{guide}</div>
        </div>,
        document.body,
      )}
    </div>
  );
}

/** The list hangs under the field's capsule, at least 420 wide, inside the window. */
function suggestPlace(el: HTMLElement | null): CSSProperties {
  const box = el?.closest('.browse-search') ?? el;
  if (!box) return {};
  const r = box.getBoundingClientRect();
  const width = Math.min(Math.max(420, r.width), window.innerWidth - 16);
  const left = Math.min(Math.max(8, r.left + (r.width - width) / 2), window.innerWidth - width - 8);
  const top = r.bottom + 6;
  return { top, left, width, maxHeight: Math.min(520, window.innerHeight - top - 12) };
}
