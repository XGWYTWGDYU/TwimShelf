// The search field: finished words become capsules (a tag, 视频, 文件夹 Trips, -猫 …, see the
// core's search.ts); while typing, suggestions offer condition words, tags and folders. Enter
// searches, Backspace in an empty field takes the last capsule back, Esc clears.
import { useEffect, useMemo, useRef, useState } from 'react';
import { Folder, Search, Sparkles, Tag, X } from 'lucide-react';
import { KEYWORDS, keyFor, keyTitle, keywordAliases, keywordHint, keywordWord, isExcluded, L, PENDING_FOLDER, splitQuery, type TagCount } from '@twimshelf/core';
import { core } from '../../lib/core';
import { useStore } from '../../lib/hooks';
import { folders, libraryVersion } from '../../lib/library';
import './SearchBar.css';

interface Suggestion { word: string; label: string; hint?: string; icon: 'kw' | 'tag' | 'folder' | 'ai' }

let tagCache: { version: number; tags: TagCount[] } | null = null;
async function allTags(version: number): Promise<TagCount[]> {
  if (tagCache?.version === version) return tagCache.tags;
  const tags = await core.read<TagCount[]>(core.b.tl_all_tags());
  tagCache = { version, tags };
  return tags;
}

/** The search text as it goes into the route: keys' words joined (re-parsed on load). */
function wordOf(key: string): string {
  const ex = isExcluded(key) ? '-' : '';
  const bare = ex ? key.slice(1) : key;
  if (bare.startsWith('t:')) return ex + bare.slice(2);
  if (bare.startsWith('d:')) return `${ex}${keywordWord(KEYWORDS.find((k) => k.key === PENDING_FOLDER)!)} ${bare.slice(2)}`;
  const k = KEYWORDS.find((x) => x.key === bare);
  return k ? ex + keywordWord(k) : ex + bare;
}

export function SearchBar({ value, onSearch }: { value: string; onSearch: (q: string) => void }) {
  const [keys, setKeys] = useState<string[]>(() => splitQuery(`${value} `).keys);
  const [text, setText] = useState('');
  const [focused, setFocused] = useState(false);
  const [pick, setPick] = useState(0);
  const [tags, setTags] = useState<TagCount[]>([]);
  const version = useStore(libraryVersion);
  const f = useStore(folders);
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => { setKeys(splitQuery(`${value} `).keys); setText(''); }, [value]);
  useEffect(() => { if (focused) allTags(version).then(setTags, () => {}); }, [focused, version]);

  const pendingFolder = keys.length > 0 && keys[keys.length - 1].replace(/^-/, '') === PENDING_FOLDER;
  const suggestions = useMemo<Suggestion[]>(() => {
    const raw = text.trim();
    const minus = /^[-－−–]/.test(raw);
    const q = (minus ? raw.slice(1) : raw).toLowerCase();
    const sign = minus ? '-' : '';
    if (pendingFolder) {
      return (f?.folders ?? []).filter((x) => x.name.toLowerCase().includes(q)).slice(0, 8)
        .map((x) => ({ word: x.name, label: x.name, icon: 'folder' as const }));
    }
    if (!q) return [];
    const out: Suggestion[] = [];
    for (const k of KEYWORDS) {
      if (minus && !k.excludable) continue;
      if ([keywordWord(k), ...keywordAliases(k)].some((s) => s.toLowerCase().startsWith(q))) {
        out.push({ word: sign + keywordWord(k), label: sign + keywordWord(k), hint: keywordHint(k), icon: 'kw' });
      }
    }
    for (const t of tags) {
      if (out.length >= 10) break;
      if (t.label.toLowerCase().includes(q)) out.push({ word: sign + t.label, label: sign + t.label, hint: String(t.count), icon: t.user > 0 ? 'tag' : 'ai' });
    }
    return out.slice(0, 10);
  }, [text, tags, f, pendingFolder]);

  useEffect(() => setPick(0), [text]);

  const commit = (words: string[], newKeys = keys) => {
    let ks = [...newKeys];
    for (const w of words) {
      const prev = ks.length ? ks[ks.length - 1] : null;
      const k = keyFor(w, prev);
      if (prev === PENDING_FOLDER || prev === `-${PENDING_FOLDER}`) ks[ks.length - 1] = k; else ks.push(k);
    }
    ks = ks.filter((k, i) => ks.indexOf(k) === i);
    setKeys(ks);
    setText('');
    return ks;
  };
  const search = (ks: string[]) => onSearch(ks.filter((k) => k.replace(/^-/, '') !== PENDING_FOLDER).map(wordOf).join(' '));

  const choose = (s: Suggestion) => {
    const ks = commit([s.word]);
    // a condition word or a tag searches at once; 文件夹 waits for its name
    if (ks[ks.length - 1]?.replace(/^-/, '') !== PENDING_FOLDER) search(ks);
    input.current?.focus();
  };

  return (
    <div className={`search${focused ? ' focused' : ''}`} onClick={() => input.current?.focus()}>
      <Search size={15} className="search-icon" />
      {keys.map((k, i) => (
        <span key={k + i} className={`capsule${isExcluded(k) ? ' excluded' : ''}`}>
          {keyTitle(k)}
          <button onClick={(e) => { e.stopPropagation(); const ks = keys.filter((_, j) => j !== i); setKeys(ks); search(ks); }} aria-label={L('common.clear')}><X size={10} /></button>
        </span>
      ))}
      <input ref={input} value={text} placeholder={keys.length ? '' : L('search.placeholder')}
        onFocus={() => setFocused(true)} onBlur={() => setTimeout(() => setFocused(false), 150)}
        onChange={(e) => {
          const v = e.target.value;
          if (/[ 　]$/.test(v) && v.trim()) { commit(v.trim().split(/[ 　]+/)); return; }
          setText(v);
        }}
        onKeyDown={(e) => {
          if (e.nativeEvent.isComposing) return;
          if (e.key === 'ArrowDown' && suggestions.length) { e.preventDefault(); setPick((pick + 1) % suggestions.length); }
          else if (e.key === 'ArrowUp' && suggestions.length) { e.preventDefault(); setPick((pick - 1 + suggestions.length) % suggestions.length); }
          else if (e.key === 'Tab' && suggestions.length) { e.preventDefault(); choose(suggestions[pick]); }
          else if (e.key === 'Enter') {
            const ks = text.trim() ? commit(text.trim().split(/[ 　]+/)) : keys;
            search(ks);
            input.current?.blur();
          } else if (e.key === 'Backspace' && !text && keys.length) {
            const last = keys[keys.length - 1];
            setKeys(keys.slice(0, -1));
            setText(last.startsWith('t:') ? last.slice(2) : '');
            e.preventDefault();
          } else if (e.key === 'Escape') { setKeys([]); setText(''); search([]); input.current?.blur(); }
        }} />
      {(keys.length > 0 || text) && <button className="search-clear" onClick={(e) => { e.stopPropagation(); setKeys([]); setText(''); search([]); }} aria-label={L('common.clear')}><X size={13} /></button>}
      {focused && suggestions.length > 0 && (
        <div className="suggest" onMouseDown={(e) => e.preventDefault()}>
          {suggestions.map((s, i) => (
            <button key={s.icon + s.word} className={`suggest-row${i === pick ? ' on' : ''}`} onMouseEnter={() => setPick(i)} onClick={() => choose(s)}>
              <span className="suggest-icon">{s.icon === 'folder' ? <Folder size={14} /> : s.icon === 'tag' ? <Tag size={14} /> : s.icon === 'ai' ? <Sparkles size={14} /> : <Search size={14} />}</span>
              <span className="suggest-label">{s.label}</span>
              {s.hint && <span className="suggest-hint">{s.hint}</span>}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
