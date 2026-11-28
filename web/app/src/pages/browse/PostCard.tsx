// A post in 浏览 (FeedCard / MacCardLayout): the media on top in its own proportions (height/width
// clamped to 0.3–1.8; 4:5 until the size is known) with the counter, page buttons and play badge
// on it; then the author, the whole text, the link and a row of tag pills. A click on the media
// opens the viewer; a two-finger sideways swipe over it turns the page; a pill searches for its
// tag, right-click gives its menu, "+" adds a tag.
import { memo, useEffect, useRef, useState } from 'react';
import { ChevronLeft, ChevronRight, Plus, Star } from 'lucide-react';
import { cardAspectRatio, L, type FeedItem } from '@twimshelf/core';
import { cachedThumb, sideFor, thumb } from '../../lib/thumbs';
import { core } from '../../lib/core';
import { useStore } from '../../lib/hooks';
import { handedBack, position, savePosition } from '../../lib/videoPositions';
import type { Post } from './posts';
import { WheelStream } from '../../lib/wheelGesture';
import { viewerState } from '../../viewer/Viewer';
import { markMatches } from './SearchMarks';
import './PostCard.css';

interface Marks {
  text?: RegExp;
  author?: RegExp;
  tag?: RegExp;
  origins: number[];
}

export interface PostCardProps {
  marks?: Marks;
  post: Post;
  width: number;
  onOpen: (post: Post, media: number) => void;
  onContext?: (post: Post, media: number, e: React.MouseEvent) => void;
  onTag?: (label: string) => void;
  onTagMenu?: (item: FeedItem, label: string, e: React.MouseEvent) => void;
  onFavorite?: () => void;
  onFavoriteMenu?: (item: FeedItem, e: React.MouseEvent) => void;
  onAddTag?: (item: FeedItem) => void;
  /** Shown from elsewhere: turned to this page and briefly marked. */
  highlight?: number;
}

const savedPages = new Map<string, number>();

export const PostCard = memo(function PostCard({ post, width, onOpen, onContext, onTag, onTagMenu, onFavorite, onFavoriteMenu, onAddTag, marks, highlight }: PostCardProps) {
  const [page, setPageState] = useState(() => savedPages.get(post.id) ?? 0);
  const setPage = (to: number) => {
    savedPages.set(post.id, to);
    setPageState(to);
  };
  /** The page sliding out while the new one slides in (a push, 0.22 s, as FeedCard.slide). */
  const [leaving, setLeaving] = useState<{ index: number; dir: 'l' | 'r'; n: number } | null>(null);
  const [shake, setShake] = useState(0);
  useEffect(() => { if (highlight != null) setPage(highlight); }, [highlight]);
  const m = post.media[Math.min(page, post.media.length - 1)];
  const many = post.media.length > 1;
  const loose = m.post_id.startsWith('loose:');
  const turn = (d: number) => {
    const to = page + d;
    if (to < 0 || to >= post.media.length) { if (many) setShake((s) => s + 1); return; }
    setLeaving((l) => ({ index: page, dir: d > 0 ? 'r' : 'l', n: (l?.n ?? 0) + 1 }));
    setPage(to);
  };
  // a two-finger gesture on the media: clearly sideways (twice as much as vertical, after 10 px)
  // turns one page; anything else scrolls the feed. The momentum after a turn is swallowed, but
  // only until the fingers start a new gesture (another turn, or a scroll).
  const media = useRef<HTMLDivElement>(null);
  const turnRef = useRef(turn);
  turnRef.current = turn;
  useEffect(() => {
    const el = media.current!;
    const stream = new WheelStream();
    let mode: 'undecided' | 'page' | 'scroll' = 'undecided';
    let sx = 0, sy = 0;
    const wheel = (e: WheelEvent) => {
      if (e.ctrlKey || e.deltaMode !== 0) return;
      if (stream.next(e)) { mode = stream.momentum ? 'scroll' : 'undecided'; sx = 0; sy = 0; }
      if (mode === 'scroll') return;
      if (mode === 'page') {
        // a vertical movement now is a scroll the fingers started: let it through
        if (Math.abs(e.deltaY) > Math.abs(e.deltaX) && Math.abs(e.deltaY) > 2) { mode = 'scroll'; return; }
        e.preventDefault();
        return;
      }
      sx += e.deltaX; sy += e.deltaY;
      if (Math.hypot(sx, sy) < 10) { if (Math.abs(e.deltaX) > Math.abs(e.deltaY)) e.preventDefault(); return; }
      if (Math.abs(sx) > Math.abs(sy) * 2 && post.media.length > 1) { mode = 'page'; e.preventDefault(); turnRef.current(sx > 0 ? 1 : -1); }
      else mode = 'scroll';
    };
    el.addEventListener('wheel', wheel, { passive: false });
    return () => el.removeEventListener('wheel', wheel);
  }, [post.media.length]);

  // the media frame follows the page's proportions, with the native card's spring-like ease;
  // the masonry is told the height it is heading for, so the cards under it move in step
  const mediaH = Math.round(width / cardAspectRatio(m));
  const author = loose ? `◌ ${m.album ? L('card.album') : L('card.loose')}` : (
    <>
      {m.author_name && markMatches(m.author_name, marks?.author)}
      {m.author_name && m.screen_name && '  '}
      {m.screen_name && <>@{markMatches(m.screen_name, marks?.author)}</>}
    </>
  );
  const out = leaving ? post.media[leaving.index] : null;
  return (
    <article className={`card${highlight != null ? ' flash' : ''}`} onContextMenu={(e) => { if (onContext) { e.preventDefault(); onContext(post, page, e); } }}>
      <div ref={media} className="card-media" data-media-id={m.media_id} data-target-h={mediaH} style={{ height: mediaH }} onClick={() => onOpen(post, page)}>
        {out && leaving && (
          <div key={'out' + leaving.n} className={`card-page out-${leaving.dir}`} onAnimationEnd={() => setLeaving(null)}>
            <Picture item={out} width={width} />
          </div>
        )}
        <div key={m.media_id} className={`card-page${leaving ? ' in-' + leaving.dir : ''}${shake ? ' shake' + (shake % 2) : ''}`} data-current-media>
          <Picture item={m} width={width} />
          {m.kind === 'video' && <CardVideo item={m} />}
        </div>
        {m.bad && <span className="card-bad">{L('card.badge.damaged')}</span>}
        {many && <span className="card-counter">{page + 1}/{post.media.length}</span>}
        {many && page > 0 && <button className="card-nav left" aria-label={L('viewer.previous')} onClick={(e) => { e.stopPropagation(); turn(-1); }}><ChevronLeft size={15} strokeWidth={3} /></button>}
        {many && page < post.media.length - 1 && <button className="card-nav right" aria-label={L('viewer.next')} onClick={(e) => { e.stopPropagation(); turn(1); }}><ChevronRight size={15} strokeWidth={3} /></button>}
      </div>
      {(loose || m.author_name || m.screen_name || m.text || m.url) && (
        <div className="card-caption">
          {(loose || m.author_name || m.screen_name) && <div className={`card-author${loose ? ' loose' : ''}`}>{author}</div>}
          {m.text && <p className="card-text selectable">{markMatches(m.text, marks?.text)}</p>}
          {m.url && (/^https?:\/\//i.test(m.url)
            ? <a className="card-link" href={m.url} target="_blank" rel="noreferrer" onClick={(e) => e.stopPropagation()}>{m.url}</a>
            : <span className="card-link">{m.url}</span>)}
        </div>
      )}
      <TagStrip item={m} marks={marks} onTag={onTag} onTagMenu={onTagMenu} onFavorite={onFavorite} onFavoriteMenu={onFavoriteMenu} onAdd={onAddTag} />
    </article>
  );
});

/** The tags as pills in one row that scrolls sideways (TagStripView): "★ Favorited" and "◷ Recently Added" first,
 *  then each tag with a dot in its colour (yours blue, an AI's purple, approved green), "+" last. */
function TagStrip({ item, marks, onTag, onTagMenu, onFavorite, onFavoriteMenu, onAdd }: {
  item: FeedItem; marks?: Marks; onTag?: (l: string) => void; onTagMenu?: (it: FeedItem, l: string, e: React.MouseEvent) => void;
  onFavorite?: () => void; onFavoriteMenu?: (it: FeedItem, e: React.MouseEvent) => void; onAdd?: (it: FeedItem) => void;
}) {
  const row = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = row.current!;
    // sideways two-finger scrolling (or Shift + wheel) moves the row; vertical goes to the feed
    const wheel = (e: WheelEvent) => {
      if (el.scrollWidth <= el.clientWidth) return;
      const dx = e.shiftKey ? e.deltaY : e.deltaX;
      if (Math.abs(dx) > Math.abs(e.shiftKey ? 0 : e.deltaY)) { el.scrollLeft += dx; e.preventDefault(); e.stopPropagation(); }
    };
    el.addEventListener('wheel', wheel, { passive: false });
    return () => el.removeEventListener('wheel', wheel);
  }, []);
  return (
    <div className="card-tags" ref={row}>
      {item.favorite && (
        <span className="pill pill-favorite" title={L('place.favorites')}
          onClick={(e) => { e.stopPropagation(); onFavorite?.(); }}
          onContextMenu={(e) => { e.preventDefault(); e.stopPropagation(); onFavoriteMenu?.(item, e); }}>
          <Star size={11} fill="#F5B800" color="#F5B800" strokeWidth={1.6} />
          <span>{L('card.favoritePill')}</span>
        </span>
      )}
      {item.recent && <span className="pill pill-recent">{L('card.recentPill')}</span>}
      {item.tags.map((t) => {
        const mine = (t.origin & 1) !== 0, ai = (t.origin & 2) !== 0;
        const kind = mine && ai ? 'approved' : ai ? 'ai' : 'mine';
        return (
          <span key={t.label} className={`pill pill-${kind}`} title={t.label}
            onClick={(e) => { e.stopPropagation(); onTag?.(t.label); }}
            onContextMenu={(e) => { e.preventDefault(); e.stopPropagation(); onTagMenu?.(item, t.label, e); }}>
            <span>{markMatches(t.label, marks?.origins.includes(t.origin) ? marks.tag : undefined)}</span>
          </span>
        );
      })}
      <span className="pill pill-add" role="button" aria-label={L('card.addTag')} title={L('card.addTag')} onClick={(e) => { e.stopPropagation(); onAdd?.(item); }}><Plus size={11} strokeWidth={3} /></span>
    </div>
  );
}

/** A tag pill elsewhere (pickers, the viewer). */
export function TagChip({ label, origin, onClick }: { label: string; origin: number; onClick?: () => void }) {
  const mine = (origin & 1) !== 0, ai = (origin & 2) !== 0;
  const kind = mine && ai ? 'approved' : ai ? 'ai' : 'mine';
  return <span className={`pill pill-${kind}`} onClick={onClick}>{label}</span>;
}

function Picture({ item, width }: { item: FeedItem; width: number }) {
  const side = sideFor(width);
  const [url, setUrl] = useState(() => cachedThumb(item, side, 'whole'));
  const [fade, setFade] = useState(false);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    let live = true;
    setFailed(false);
    const hit = cachedThumb(item, side, 'whole');
    if (hit) { setUrl(hit); return; }
    setUrl(undefined);
    // a picture decoded later fades in, instead of popping onto an empty card
    thumb(item, side, 0, 'whole').then((u) => { if (live) { setFade(true); setUrl(u); } }, () => live && setFailed(true));
    return () => { live = false; };
    // the media, not the object: a library change (a sync) brings the same media as new objects,
    // and a picture then loaded again (blank meanwhile) made the card flash
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [item.media_id, item.path, side]);
  if (failed) return <div className="card-missing" />;
  return url ? <img className={fade ? 'fade-in' : undefined} src={url} alt="" draggable={false} decoding="async" /> : null;
}

/** A card's video follows native iOS InlineVideos' 3-state rhythm: plays muted when >= 50% in view,
 *  pauses in place on its current frame while 0%..50% in view (or while the viewer is open), and
 *  unloads only after leaving the viewport completely (0%). */
function CardVideo({ item }: { item: FeedItem }) {
  const video = useRef<HTMLVideoElement>(null);
  const back = useStore(handedBack);
  const covered = useStore(viewerState) != null;
  const [inView, setInView] = useState(false);
  const [wantsPlay, setWantsPlay] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const seekingRef = useRef(false);

  useEffect(() => {
    const el = video.current!.parentElement!;
    const io = new IntersectionObserver(
      ([e]) => {
        setInView(e.intersectionRatio > 0);
        setWantsPlay(e.intersectionRatio >= 0.5);
      },
      { threshold: [0, 0.5] },
    );
    io.observe(el);
    return () => io.disconnect();
  }, []);

  // Only start loading once >= 50% visible; stay loaded (paused on current frame) while partially
  // visible so scrolling back resumes in 0 ms; unload once completely out of view (0%).
  useEffect(() => {
    if (!inView) {
      setLoaded(false);
    } else if (wantsPlay && !covered) {
      setLoaded(true);
    }
  }, [inView, wantsPlay, covered]);

  useEffect(() => {
    const v = video.current!;
    if (!loaded) {
      v.pause();
      if (v.currentTime > 0) savePosition(item.media_id, v.currentTime);
      v.classList.remove('playing');
      seekingRef.current = false;
      return;
    }
    if (wantsPlay && !covered) {
      const target = position(item.media_id);
      if (v.readyState >= 1 && Math.abs(v.currentTime - target) > 0.5) {
        seekingRef.current = target > 0;
        v.currentTime = target;
      }
      void v.play().catch(() => {});
    } else {
      v.pause();
      if (v.currentTime > 0) savePosition(item.media_id, v.currentTime);
    }
  }, [loaded, wantsPlay, covered, item.media_id]);

  useEffect(() => {
    if (back?.id === item.media_id && video.current && loaded) {
      video.current.currentTime = back.at;
    }
  }, [back, item.media_id, loaded]);

  return (
    <video ref={video} className="card-video" muted loop playsInline preload="metadata" disablePictureInPicture disableRemotePlayback
      src={loaded ? core.fileUrl(item.path) : undefined}
      onLoadedMetadata={(e) => {
        const saved = position(item.media_id);
        if (saved > 0) {
          seekingRef.current = true;
          e.currentTarget.currentTime = saved;
        } else {
          seekingRef.current = false;
        }
      }}
      onSeeked={(e) => {
        seekingRef.current = false;
        if (loaded) e.currentTarget.classList.add('playing');
      }}
      onTimeUpdate={(e) => {
        const t = e.currentTarget.currentTime;
        if (t > 0) savePosition(item.media_id, t);
      }}
      onPlaying={(e) => {
        if (!seekingRef.current && loaded) e.currentTarget.classList.add('playing');
      }}
      onContextMenu={(e) => e.preventDefault()} />
  );
}
