// 浏览: the library as a masonry of post cards, filtered by the sidebar's place and the search.
import { useCallback, useMemo, useState } from 'react';
import { ArrowDownWideNarrow, Shuffle } from 'lucide-react';
import { L, TokenQuery, type FeedQuery } from '@twimshelf/core';
import { Empty, Spinner } from '../../components/ui';
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

  const header = (
    <div className="browse-head">
      <div className="browse-title">
        <h1>{title(route)}</h1>
        <span className="browse-count">{feed.data ? L('common.items', posts.length) : ''}</span>
      </div>
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
          render={(p, w, i) => <PostCard post={p} width={w} index={i} onOpen={openPost} />} />
      )}
      {open && <Viewer items={items} index={open.index} onClose={() => setOpen(null)} />}
    </>
  );
}
