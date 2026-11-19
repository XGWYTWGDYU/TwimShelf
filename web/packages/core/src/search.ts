// The search field's language, as the apps have it (flutter/app/lib/search/query.dart, Swift's
// SearchQuery): words are tag/text/author terms; condition words (视频, 文件夹 名字, 用户, 标签,
// 我的, AI, …, in the current language) narrow the search; a minus excludes ("-视频", "-猫").
// Each word becomes a stable key (t:猫, k:video, d:Trips, -t:狗) that does not depend on the language.
import type { FeedFilter, MediaKind, ReviewFilter, SearchFields, SearchScope } from './generated/models';
import type { FeedQuery } from './core';
import { L } from './i18n';

export type SearchField = 'tags' | 'text' | 'author';

export interface SearchKeyword { id: string; key: string; excludable: boolean }

export const KEYWORDS: SearchKeyword[] = [
  ['tags', 'f:tags'], ['text', 'f:text'], ['author', 'f:author'],
  ['mine', 's:mine'], ['ai', 's:ai'], ['common', 's:common'], ['all', 's:both'],
  ['video', 'k:video'], ['photo', 'k:photo'], ['folder', 'p:folder'], ['recent', 'r:recent'],
  ['external', 'x:external'], ['album', 'a:album'], ['reviewed', 'v:reviewed'],
  ['unreviewed', 'v:unreviewed'], ['damaged', 'b:damaged'],
].map(([id, key]) => ({ id, key, excludable: !['all', 'album', 'reviewed', 'unreviewed', 'damaged'].includes(id) }));

export function keywordWord(k: SearchKeyword): string { return L(`search.kw.${k.id}.word`); }
export function keywordAliases(k: SearchKeyword): string[] {
  const a = L(`search.kw.${k.id}.aliases`);
  return a === `search.kw.${k.id}.aliases` ? [] : a.split(',').map((s) => s.trim()).filter(Boolean);
}
export function keywordHint(k: SearchKeyword): string { return L(`search.kw.${k.id}.hint`); }

export function keywordFrom(value: string): SearchKeyword | undefined {
  const q = value.trim().toLowerCase();
  if (!q) return undefined;
  return KEYWORDS.find((k) => [keywordWord(k), ...keywordAliases(k)].some((s) => s.toLowerCase() === q));
}

export const PENDING_FOLDER = 'p:folder';
const MINUS = new Set(['-', '－', '−', '–']);
export const termKey = (t: string) => `t:${t}`;
export const folderKey = (n: string) => `d:${n}`;
export const isExcluded = (k: string) => k.startsWith('-');
function negated(word: string): string | null {
  return word.length > 1 && MINUS.has(word[0]) ? word.slice(1) : null;
}

export function keyFor(word: string, after?: string | null): string {
  if (after === PENDING_FOLDER) return folderKey(word);
  if (after === `-${PENDING_FOLDER}`) return `-${folderKey(negated(word) ?? word)}`;
  const rest = negated(word);
  if (rest != null) {
    const k = keywordFrom(rest);
    return `-${k && k.excludable ? k.key : termKey(rest.toLowerCase())}`;
  }
  return keywordFrom(word)?.key ?? termKey(word);
}

export function quoteSearchWord(word: string): string {
  if (!/[ 　\n\t"]/.test(word)) return word;
  return `"${word.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

/** The finished words of `text` as keys, and the word still being typed. */
export function splitQuery(text: string): { keys: string[]; rest: string } {
  const isSep = (c: string) => c === ' ' || c === '　' || c === '\n' || c === '\t';
  const words: string[] = [];
  let i = 0;
  let rest = '';
  while (i < text.length) {
    while (i < text.length && isSep(text[i])) i++;
    if (i >= text.length) break;
    const start = i;
    let buf = '';
    let inQuote = false;
    let closed = false;
    while (i < text.length) {
      const ch = text[i];
      if (inQuote) {
        if (ch === '\\' && i + 1 < text.length) { buf += text[i + 1]; i += 2; continue; }
        if (ch === '"') { inQuote = false; closed = true; i++; continue; }
        buf += ch; i++;
      } else {
        if (isSep(ch)) break;
        if (ch === '"') { inQuote = true; i++; continue; }
        buf += ch; i++;
      }
    }
    if (i < text.length && isSep(text[i])) {
      if (buf || closed) words.push(buf);
    } else {
      rest = text.slice(start);
    }
  }
  const keys: string[] = [];
  for (const word of words) {
    const previous = keys.length ? keys[keys.length - 1] : null;
    const key = keyFor(word, previous);
    if (previous === PENDING_FOLDER || previous === `-${PENDING_FOLDER}`) keys[keys.length - 1] = key;
    else keys.push(key);
  }
  return { keys, rest };
}

/** A key as shown in its capsule. */
export function keyTitle(key: string): string {
  const bare = isExcluded(key) ? key.slice(1) : key;
  if (bare.startsWith('t:')) return bare.slice(2);
  if (bare.startsWith('d:')) return L('search.token.folder', bare.slice(2));
  if (bare === PENDING_FOLDER) return L('search.token.folderPending');
  const k = KEYWORDS.find((x) => x.key === bare);
  return k ? keywordWord(k) : bare;
}

/** The keys of a search, read into what the core is asked. */
export class TokenQuery {
  readonly terms: string[] = [];
  private fields = new Set<SearchField>(); private exFields = new Set<SearchField>();
  private scopes = new Set<SearchScope>(); private exScopes = new Set<SearchScope>();
  private kinds = new Set<MediaKind>(); private exKinds = new Set<MediaKind>();
  private exTerms: string[] = []; private exFolders: string[] = [];
  folder: string | null = null;
  private reviews = new Set<ReviewFilter>();
  private album = false; private damaged = false;
  recent = false; private external = false; private exRecent = false; private exExternal = false;

  static parse(text: string): TokenQuery { return new TokenQuery(splitQuery(`${text} `).keys); }

  constructor(readonly keys: string[]) {
    for (let key of keys) {
      const ex = isExcluded(key);
      if (ex) key = key.slice(1);
      if (key.startsWith('f:')) {
        const f = key.slice(2) as SearchField;
        if (['tags', 'text', 'author'].includes(f)) (ex ? this.exFields : this.fields).add(f);
      } else if (key.startsWith('s:')) {
        const s = key.slice(2) as SearchScope;
        if (['mine', 'ai', 'both', 'common'].includes(s) && (!ex || s !== 'both')) (ex ? this.exScopes : this.scopes).add(s);
      } else if (key.startsWith('t:')) {
        const t = key.slice(2).toLowerCase();
        const target = ex ? this.exTerms : this.terms;
        if ((!ex || t) && !target.includes(t)) target.push(t);
      } else if (key.startsWith('d:')) {
        const n = key.slice(2);
        if (ex) { if (!this.exFolders.includes(n)) this.exFolders.push(n); } else this.folder = n;
      } else if (key === 'r:recent') { if (ex) this.exRecent = true; else this.recent = true; }
      else if (key === 'x:external') { if (ex) this.exExternal = true; else this.external = true; }
      else if (key.startsWith('k:')) {
        const k = key.slice(2) as MediaKind;
        if (k === 'photo' || k === 'video') (ex ? this.exKinds : this.kinds).add(k);
      } else if (!ex && key === 'a:album') this.album = true;
      else if (!ex && key === 'v:reviewed') this.reviews.add('reviewed');
      else if (!ex && key === 'v:unreviewed') this.reviews.add('unreviewed');
      else if (!ex && key === 'b:damaged') this.damaged = true;
    }
  }

  get allowedKinds(): MediaKind[] {
    const base: MediaKind[] = this.kinds.size ? [...this.kinds] : ['photo', 'video'];
    return base.filter((k) => !this.exKinds.has(k));
  }
  get kind(): MediaKind | null { const a = this.allowedKinds; return a.length === 1 ? a[0] : null; }

  get scope(): SearchScope {
    if (this.scopes.has('common')) return 'common';
    if (this.scopes.has('mine') && this.scopes.has('ai')) return 'both';
    if (this.scopes.has('mine')) return 'mine';
    if (this.scopes.has('ai')) return 'ai';
    return 'both';
  }

  get searchFields(): SearchFields {
    const tagsOnly = [...this.scopes].some((s) => s !== 'both');
    const has = (f: SearchField, dflt: boolean) => (this.fields.size === 0 ? dflt : this.fields.has(f)) && !this.exFields.has(f);
    return { tags: has('tags', true), text: has('text', !tagsOnly), author: has('author', !tagsOnly) };
  }

  get origins(): number[] | null {
    if (this.exScopes.size === 0) return null;
    const mask = { common: 4, mine: 1, ai: 2, both: 3 }[this.scope];
    return [1, 2, 3].filter((o) => (mask === 4 ? o === 3 : (o & mask & 3) !== 0)
      && !(this.exScopes.has('mine') && (o & 1) !== 0)
      && !(this.exScopes.has('ai') && (o & 2) !== 0)
      && !(this.exScopes.has('common') && o === 3));
  }

  /** Nothing can match (a word and its opposite): the caller shows nothing without asking. */
  get isContradictory(): boolean {
    const f = this.searchFields;
    return this.allowedKinds.length === 0 || this.reviews.size > 1 || (this.recent && this.exRecent)
      || (this.external && this.exExternal) || (this.folder != null && this.exFolders.includes(this.folder))
      || (this.terms.length > 0 && !f.tags && !f.text && !f.author);
  }

  filter(over: Partial<FeedFilter> = {}): Partial<FeedFilter> {
    const f: Partial<FeedFilter> = { ...over };
    if (this.album) f.album_only = true;
    if (this.damaged) f.bad_only = true;
    if (this.reviews.size === 1) f.review = [...this.reviews][0];
    if (this.folder != null) f.folder = this.folder;
    if (this.recent) f.recent_only = true;
    if (this.external) f.loose_only = true;
    if (this.kind) f.kind = this.kind;
    const fl = this.searchFields;
    if (fl.tags || fl.text || fl.author) f.exclude_terms = this.exTerms;
    f.origins = this.origins;
    f.exclude_folders = this.exFolders;
    f.exclude_recent = this.exRecent;
    f.exclude_loose = this.exExternal;
    return f;
  }

  request(o: {
    over?: Partial<FeedFilter>;
    seed?: number | null;
    newestFirst?: boolean;
    wholePosts?: boolean;
    fuzzy?: boolean;
    termVectors?: number[][];
    embedModel?: string | null;
  } = {}): FeedQuery {
    return {
      terms: this.terms,
      scope: this.scope,
      seed: o.seed ?? null,
      newest_first: o.newestFirst ?? false,
      fuzzy: o.fuzzy ?? false,
      term_vectors: o.termVectors ?? [],
      embed_model: o.embedModel ?? null,
      fields: this.searchFields,
      filter: this.filter(o.over),
      whole_posts: o.wholePosts ?? false,
    };
  }
}
