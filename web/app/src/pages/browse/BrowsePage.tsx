// 浏览: the library as a masonry of post cards (MacFeedViewController), filtered by the toolbar's
// search. Random order that stays until 重新随机 (or newest first with 按添加时间排序); one card per
// post, or per media with 按帖子分组 off. The title and the totals on the left of the toolbar, the
// search capsule and its round buttons on the right; the cards scroll under the toolbar.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ArrowDown, Clock, Layers, Share, Shuffle, X } from 'lucide-react';
import { L, TokenQuery, quoteSearchWord, type FeedItem, type FeedQuery } from '@twimshelf/core';
import { Spinner } from '../../components/ui';
import { Toolbar } from '../../components/Toolbar';
import { openMenu } from '../../components/Menu';
import { toast } from '../../components/toast';
import { cardMenu, tagMenu } from './cardMenu';
import { core } from '../../lib/core';
import { onCommand, setMenuState } from '../../lib/commands';
import { useAsync, useStore } from '../../lib/hooks';
import { libraryVersion } from '../../lib/library';
import { go, type Route } from '../../lib/router';
import { openViewer } from '../../viewer/Viewer';
import { fitMedia, intersect } from '../../viewer/transition';
import { Masonry, type MasonryHandle } from './Masonry';
import { PostCard } from './PostCard';
import { estimateCard, groupPosts, type Post } from './posts';
import { SearchBar } from './SearchBar';
import { SearchExportDialog } from './SearchExport';
import { QuickDownload } from './QuickDownload';
import { cardDensity } from './density';
import { markPattern } from './SearchMarks';
import { revealRequest } from './reveal';
import { openTagPicker } from '../../components/pickers';
import './BrowsePage.css';

type BrowseRoute = Extract<Route, { page: 'browse' }>;

function pref(k: string): string | null { try { return localStorage.getItem(k); } catch { return null; } }
function setPref(k: string, v: string): void { try { localStorage.setItem(k, v); } catch { /* private window */ } }
function newSeed(): number { return Math.floor(Math.random() * 2 ** 31); }

/** What to ask the core: the search's words (and the old sidebar filters a link may carry). */
export function queryFor(r: BrowseRoute, order: { newest: boolean; seed: number | null }, wholePosts: boolean): FeedQuery | null {
  const q = TokenQuery.parse(r.q ?? '');
  if (q.isContradictory) return null;
  return q.request({
    newestFirst: order.newest,
    seed: order.seed,
    wholePosts: wholePosts && !r.kind && !q.kind,
    over: {
      kind: r.kind ?? null,
      folder: r.folder ?? null,
      loose_only: r.view === 'loose',
      album_only: r.view === 'album',
      review: r.view === 'unreviewed' ? 'unreviewed' : r.view === 'reviewed' ? 'reviewed' : 'any',
    },
  });
}

export default function BrowsePage({ route, active }: { route: BrowseRoute; active: boolean }) {
  const version = useStore(libraryVersion);
  // the search: long at the top and while typing, narrower while reading down (as Windows' bar);
  // a little travel the same way first, so small jitters of the wheel don't flicker it
  const [narrow, setNarrow] = useState(false);
  const [typing, setTyping] = useState(false);
  const reading = useRef({ last: 0, travel: 0 });
  const onScrollTop = useCallback((y: number) => {
    const r = reading.current;
    const d = y - r.last;
    r.last = y;
    if (y < 40) { r.travel = 0; setNarrow(false); return; }
    r.travel = Math.sign(d) === Math.sign(r.travel) ? r.travel + d : d;
    if (r.travel > 24) setNarrow(true); else if (r.travel < -40) setNarrow(false);
  }, []);
  const density = useStore(cardDensity);
  const [byAdded, setByAdded] = useState(() => pref('feed.byAdded') === '1');
  const [seed, setSeed] = useState(() => { const v = Number(pref('feed.seed')); return v > 0 ? v : newSeed(); });
  const [grouped, setGrouped] = useState(() => pref('grouped') !== '0');
  useEffect(() => setPref('feed.seed', String(seed)), [seed]);
  const query = useMemo(() => queryFor(route, { newest: byAdded, seed: byAdded ? null : seed }, grouped),
    [route.q, route.kind, route.folder, route.view, byAdded, seed, grouped]);
  const feed = useAsync(async () => (query ? core.feed(query) : []), [query, version]);
  const marks = useMemo(() => {
    const pattern = markPattern(query?.terms ?? []);
    if (!query || !pattern) return;
    const { fields, scope, filter } = query;
    return {
      text: fields?.text ? pattern : undefined,
      author: fields?.author ? pattern : undefined,
      tag: fields?.tags ? pattern : undefined,
      origins: filter?.origins ?? { both: [1, 2, 3], mine: [1, 3], ai: [2, 3], common: [3] }[scope ?? 'both'],
    };
  }, [query]);
  const posts = useMemo<Post[]>(() => {
    const items = feed.data ?? [];
    return grouped ? groupPosts(items) : items.map((m) => ({ id: m.media_id, media: [m] }));
  }, [feed.data, grouped]);
  const items = useMemo(() => posts.flatMap((p) => p.media), [posts]);
  const masonry = useRef<MasonryHandle>(null);
  const browse = useRef<HTMLDivElement>(null);

  const searching = !!route.q;
  const reshuffle = useCallback(() => {
    if (searching) return;
    setByAdded(false);
    setPref('feed.byAdded', '0');
    setSeed(newSeed());
    masonry.current?.scrollToTop();
  }, [searching]);
  useEffect(() => setMenuState({ onBrowse: active, searching, grouped, byAdded }), [active, searching, grouped, byAdded]);
  useEffect(() => onCommand('reshuffle', () => { if (active && !searching && !byAdded) reshuffle(); }), [active, searching, byAdded, reshuffle]);
  useEffect(() => onCommand('groupByPost', () => setGrouped((g) => { setPref('grouped', g ? '0' : '1'); return !g; })), []);

  // a card's media opens the viewer; ← → go through every media of the feed
  const openPost = useCallback((p: Post, media: number) => {
    const at = items.indexOf(p.media[media]);
    openViewer(items, Math.max(0, at), {
      source: (id) => {
        const card = browse.current?.querySelector(`.card-media[data-media-id="${CSS.escape(id)}"]`);
        const scroller = card?.closest('.masonry-scroller');
        const page = card?.querySelector('[data-current-media]');
        if (!card || !scroller || !page) return;
        const image = page.querySelector('img');
        const video = page.querySelector<HTMLVideoElement>('video.playing');
        const size = items.find((item) => item.media_id === id)?.size;
        const frame = fitMedia(page.getBoundingClientRect(),
          video?.videoWidth || image?.naturalWidth || size?.[0] || 0,
          video?.videoHeight || image?.naturalHeight || size?.[1] || 0);
        const visible = intersect(intersect(frame, card.getBoundingClientRect()), scroller.getBoundingClientRect());
        if (visible.width && visible.height) return frame;
      },
      onClose: () => masonry.current?.focus(),
    });
  }, [items]);

  const search = useCallback((q: string) => go({ page: 'browse', q: q || undefined }), []);
  const addTerm = useCallback((w: string) => {
    const quoted = quoteSearchWord(w);
    const cur = (route.q ?? '').trim();
    if (!cur) { search(quoted); return; }
    if (cur.split(/\s+/).includes(quoted)) return;
    search(`${cur} ${quoted}`);
  }, [route.q, search]);
  const host = useMemo(() => ({ search, addTerm }), [search, addTerm]);
  const context = useCallback(async (p: Post, media: number, e: React.MouseEvent) => {
    const point = { clientX: e.clientX, clientY: e.clientY };
    openMenu(point, await cardMenu(p.media[media], p.media, host));
  }, [host]);
  const onTagMenu = useCallback((item: FeedItem, label: string, e: React.MouseEvent) => {
    const t = item.tags.find((x) => x.label === label);
    if (t) openMenu({ clientX: e.clientX, clientY: e.clientY }, tagMenu(item, t, host));
  }, [host]);
  const onAddTag = useCallback((item: FeedItem, post: FeedItem[]) => {
    void openTagPicker({ item, post, initialScope: 'media' });
  }, []);

  // "Show Post in Browse" from a grid: the search goes if it hides the post, then the card is shown
  const reveal = useStore(revealRequest);
  const [flash, setFlash] = useState<{ id: string; page: number } | null>(null);
  useEffect(() => {
    if (!reveal || !active || !feed.data) return;
    const key = grouped ? reveal.item.post_id : reveal.item.media_id;
    const i = posts.findIndex((p) => p.id === key);
    if (i < 0) {
      if (route.q) { search(''); return; }
      revealRequest.set(null);
      toast(L('feed.reveal.notFound'));
      return;
    }
    revealRequest.set(null);
    const page = Math.max(0, posts[i].media.findIndex((m) => m.media_id === reveal.item.media_id));
    setFlash({ id: key, page });
    masonry.current?.scrollToIndex(i);
    window.setTimeout(() => setFlash(null), 1600);
  }, [reveal, active, feed.data, posts, grouped, route.q, search]);

  const [quick, setQuick] = useState<HTMLElement | null>(null);
  const [exportOpen, setExportOpen] = useState(false);
  const closeQuick = useCallback(() => setQuick(null), []);
  const buttons = (
    <>
      {searching && (
        <>
          <button className="round-btn" aria-label={L('search.export')} title={L('search.export')} disabled={items.length === 0}
            onClick={() => setExportOpen(true)}><Share size={14} strokeWidth={2} /></button>
          <button className="round-btn" aria-label={L('search.exit')} title={L('search.exit')} onClick={() => search('')}><X size={14} strokeWidth={2.2} /></button>
        </>
      )}
      {!searching && <>
        <button className={`round-btn${byAdded ? ' on' : ''}`} aria-label={L('feed.sortByAdded')} title={L('feed.sortByAdded')}
          onClick={() => { const v = !byAdded; setByAdded(v); setPref('feed.byAdded', v ? '1' : '0'); masonry.current?.scrollToTop(); }}><Clock size={14} strokeWidth={2} /></button>
        <button className={`round-btn${grouped ? ' on' : ''}`} aria-label={L('feed.groupByPost')} title={L('feed.groupByPost')}
          onClick={() => { const v = !grouped; setGrouped(v); setPref('grouped', v ? '1' : '0'); }}><Layers size={14} strokeWidth={2} /></button>
        <button className={`round-btn${quick ? ' on' : ''}`} aria-label={L('search.download')} title={L('search.download')} aria-expanded={!!quick}
          onClick={(e) => { const el = e.currentTarget; setQuick((q) => (q ? null : el)); }}><ArrowDown size={14} strokeWidth={2.2} /></button>
        <div className={`shuffle-slot${byAdded ? ' gone' : ''}`}>
          <button className="round-btn" aria-label={L('feed.reshuffle')} title={L('feed.reshuffle')} disabled={byAdded} onClick={reshuffle}><Shuffle size={14} strokeWidth={2} /></button>
        </div>
      </>}
      {quick && <QuickDownload anchor={quick} onClose={closeQuick} />}
      {exportOpen && <SearchExportDialog mediaIds={items.map((m) => m.media_id)} queryLabel={route.q ?? ''} onClose={() => setExportOpen(false)} />}
    </>
  );

  const toolbar = (
    // no title or totals: the cards run up under the toolbar to the window's top edge
    <Toolbar overlay clear
      center={<div className={`browse-search glass${narrow && !typing ? ' narrow' : ''}`} style={{ '--search-buttons': `${(byAdded ? 3 : 4) * 34}px` } as React.CSSProperties} onFocus={() => setTyping(true)} onBlur={(e) => { if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setTyping(false); }}>
        <SearchBar value={route.q ?? ''} onSearch={search} />{buttons}</div>} />
  );

  const end = posts.length > 0 && (
    <div className="feed-end"><span>{grouped ? L('feed.end.posts', posts.length) : L('feed.end.media', posts.length)}</span></div>
  );

  return (
    <div ref={browse} className="browse-page">
      {feed.loading && !feed.data ? <div className="center"><Spinner /></div>
        : posts.length === 0 ? <div className="browse-empty">{L(route.q ? 'feed.empty.noMatch' : 'feed.empty.library')}</div>
        : <Masonry ref={masonry} items={posts} active={active} density={density} keyOf={(p) => p.id} estimate={estimateCard} top={52 + 12} footer={end} onScrollTop={onScrollTop}
          render={(p, w) => <PostCard post={p} width={w} onOpen={openPost} onContext={(post, m, e) => void context(post, m, e)}
            onTag={addTerm} onTagMenu={onTagMenu} onAddTag={(it) => onAddTag(it, p.media)}
            marks={marks} highlight={flash?.id === p.id ? flash.page : undefined} />} />}
      {toolbar}
    </div>
  );
}
