// 浏览: the library as a masonry of post cards, filtered by the sidebar's place and the search.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ArrowDownWideNarrow, FolderPlus, Shuffle, Tags, Trash2, X } from 'lucide-react';
import { L, TokenQuery, type FeedQuery } from '@twimshelf/core';
import { Button, Empty, Spinner } from '../../components/ui';
import { openMenu } from '../../components/Menu';
import { runAction } from '../../lib/actions';
import { cardMenu, selectionMenu, tagMany, toFolder } from './cardMenu';
import { core } from '../../lib/core';
import { useAsync, useStore } from '../../lib/hooks';
import { libraryVersion } from '../../lib/library';
import { go, type Route } from '../../lib/router';
import { Viewer } from '../../viewer/Viewer';
import { Masonry } from './Masonry';
import { PostCard } from './PostCard';
import { estimateCard, groupPosts, type Post } from './posts';
import { SearchBar } from './SearchBar';
import './BrowsePage.css';

type BrowseRoute = Extract<Route, { page: 'browse' }>;

function title(r: BrowseRoute): string {
  if (r.folder) return r.folder;
  if (r.kind === 'photo') return L('place.photos');
  if (r.kind === 'video') return L('place.videos');
  if (r.view) return L(`place.${r.view}`);
  return L('place.browse');
}

/** What to ask the core: the sidebar's place, then the search's words over it. */
export function queryFor(r: BrowseRoute, order: { newest: boolean; seed: number | null }): FeedQuery | null {
  const q = TokenQuery.parse(r.q ?? '');
  if (q.isContradictory) return null;
  return q.request({
    newestFirst: order.newest,
    seed: order.seed,
    wholePosts: !r.kind && !q.kind,
    over: {
      kind: r.kind ?? null,
      folder: r.folder ?? null,
      loose_only: r.view === 'loose',
      album_only: r.view === 'album',
      review: r.view === 'unreviewed' ? 'unreviewed' : r.view === 'reviewed' ? 'reviewed' : 'any',
    },
  });
}

export default function BrowsePage({ route }: { route: BrowseRoute }) {
  const version = useStore(libraryVersion);
  const [newest, setNewest] = useState(true);
  const [seed, setSeed] = useState<number | null>(null);
  const feed = useAsync(async () => { const q = queryFor(route, { newest, seed }); return q ? core.feed(q) : []; }, [route.q, route.kind, route.folder, route.view, newest, seed, version]);
  const posts = useMemo(() => groupPosts(feed.data ?? []), [feed.data]);
  const [open, setOpen] = useState<{ index: number } | null>(null);
  const items = feed.data ?? [];

  const openPost = useCallback((p: Post, media: number) => {
    const at = items.indexOf(p.media[media]);
    setOpen({ index: Math.max(0, at) });
  }, [items]);

  // selection: ⌘/Ctrl-click toggles a post, Shift-click selects up to it, Esc clears
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const anchor = useRef<number | null>(null);
  useEffect(() => setSelected(new Set()), [route.q, route.kind, route.folder, route.view]);
  useEffect(() => {
    if (!selected.size) return;
    const key = (e: KeyboardEvent) => { if (e.key === 'Escape' && !document.querySelector('.dialog, .menu, .viewer')) setSelected(new Set()); };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, [selected.size]);
  const select = useCallback((p: Post, e: React.MouseEvent) => {
    const i = posts.indexOf(p);
    setSelected((old) => {
      const next = new Set(old);
      if (e.shiftKey && anchor.current != null) {
        const [a, b] = [Math.min(anchor.current, i), Math.max(anchor.current, i)];
        for (let j = a; j <= b; j++) next.add(posts[j].id);
      } else if (next.has(p.id)) next.delete(p.id);
      else next.add(p.id);
      return next;
    });
    anchor.current = i;
  }, [posts]);
  const clear = useCallback(() => setSelected(new Set()), []);
  const chosen = posts.filter((p) => selected.has(p.id));
  const chosenMedia = chosen.flatMap((p) => p.media.map((m) => m.media_id));
  const chosenPosts = chosen.map((p) => p.id);

  const host = useMemo(() => ({
    search: (q: string) => go({ ...route, q }),
    addTerm: (w: string) => go({ ...route, q: `${route.q ?? ''} ${w}`.trim() }),
  }), [route]);
  const context = useCallback(async (p: Post, media: number, e: React.MouseEvent) => {
    const point = { clientX: e.clientX, clientY: e.clientY };
    if (selected.size > 1 && selected.has(p.id)) { openMenu(point, selectionMenu(chosenMedia, chosenPosts, clear)); return; }
    openMenu(point, await cardMenu(p.media[media], p.media, host));
  }, [selected, chosenMedia, chosenPosts, clear, host]);

  const bar = selected.size > 0 && (
    <div className="select-bar">
      <span>{L('common.items', selected.size)}</span>
      <div className="select-actions">
        <Button onClick={() => void tagMany(chosenMedia, L('card.menu.tagMedia'))}><Tags size={14} /> {L('common.tags')}</Button>
        <Button onClick={() => void toFolder({ posts: chosenPosts })}><FolderPlus size={14} /> {L('common.addToFolder')}</Button>
        <Button kind="danger" onClick={async () => { if (await runAction('trash', { posts: chosenPosts }, (n) => L('trash.moved', n))) clear(); }}><Trash2 size={14} /> {L('common.delete')}</Button>
        <button className="icon-btn" onClick={clear} aria-label={L('common.deselect')}><X size={16} /></button>
      </div>
    </div>
  );

  const header = (
    <div className="browse-head">
      <div className="browse-title">
        <h1>{title(route)}</h1>
        <span className="browse-count">{feed.data ? L('common.items', posts.length) : ''}</span>
      </div>
      {bar}
      <div className="browse-tools">
        <SearchBar value={route.q ?? ''} onSearch={(q) => go({ ...route, q: q || undefined })} />
        <button className={`icon-btn${newest && seed == null ? ' active' : ''}`} title={L('feed.sortByAdded')}
          onClick={() => { setSeed(null); setNewest(true); }}><ArrowDownWideNarrow size={17} /></button>
        <button className={`icon-btn${seed != null ? ' active' : ''}`} title={L('feed.reshuffle')}
          onClick={() => setSeed(Math.floor(Math.random() * 2 ** 31))}><Shuffle size={17} /></button>
      </div>
    </div>
  );

  return (
    <>
      {feed.loading && !feed.data ? (
        <div className="browse-wait">{header}<div className="center"><Spinner /></div></div>
      ) : posts.length === 0 ? (
        <div className="browse-wait">{header}<Empty title={L(route.q || route.folder || route.kind || route.view ? 'feed.empty.noMatch' : 'feed.empty.library')} /></div>
      ) : (
        <Masonry items={posts} keyOf={(p) => p.id} estimate={estimateCard} header={header}
          render={(p, w, i) => <PostCard post={p} width={w} index={i} onOpen={openPost} selected={selected.has(p.id)}
            selecting={selected.size > 0} onSelect={select} onContext={(post, m, e) => void context(post, m, e)} />} />
      )}
      {open && <Viewer items={items} index={open.index} onClose={() => setOpen(null)} />}
    </>
  );
}
