// A post in the grid: its picture (with a pager for several), author, text, link and tags.
import { memo, useEffect, useState } from 'react';
import { ChevronLeft, ChevronRight, Play, Sparkles, Tag } from 'lucide-react';
import { cardAspectRatio, L, type FeedItem } from '@twimshelf/core';
import { cachedThumb, sideFor, thumb } from '../../lib/thumbs';
import type { Post } from './posts';
import './PostCard.css';

export interface PostCardProps {
  post: Post;
  width: number;
  index: number;
  selected?: boolean;
  /** Something is selected: a plain click selects too. */
  selecting?: boolean;
  onOpen: (post: Post, media: number) => void;
  onSelect?: (post: Post, e: React.MouseEvent) => void;
  onContext?: (post: Post, media: number, e: React.MouseEvent) => void;
}

export const PostCard = memo(function PostCard({ post, width, selected, selecting, onOpen, onSelect, onContext }: PostCardProps) {
  const [page, setPage] = useState(0);
  const m = post.media[Math.min(page, post.media.length - 1)];
  const first = post.media[0];
  const many = post.media.length > 1;
  return (
    <article className={`card${selected ? ' selected' : ''}`}
      onClick={(e) => { if ((selecting || e.metaKey || e.ctrlKey || e.shiftKey) && onSelect) { e.preventDefault(); onSelect(post, e); } }}
      onContextMenu={(e) => { if (onContext) { e.preventDefault(); onContext(post, page, e); } }}>
      <div className="card-media" style={{ aspectRatio: String(cardAspectRatio(m)) }}
        onClick={(e) => { if (!(selecting || e.metaKey || e.ctrlKey || e.shiftKey)) onOpen(post, page); }}>
        {selecting && <span className={`card-check${selected ? ' on' : ''}`}>{selected ? '✓' : ''}</span>}
        <Picture item={m} width={width} />
        {m.kind === 'video' && <span className="card-play"><Play size={18} fill="currentColor" /></span>}
        {many && <span className="card-pager">{page + 1}/{post.media.length}</span>}
        {many && page > 0 && <button className="card-nav left" onClick={(e) => { e.stopPropagation(); setPage(page - 1); }} aria-label="Previous"><ChevronLeft size={18} /></button>}
        {many && page < post.media.length - 1 && <button className="card-nav right" onClick={(e) => { e.stopPropagation(); setPage(page + 1); }} aria-label="Next"><ChevronRight size={18} /></button>}
      </div>
      <div className="card-body">
        <div className="card-author">
          <span className="card-name">{first.author_name ?? L('common.unknownAuthor')}</span>
          {first.screen_name && <span className="card-handle">@{first.screen_name}</span>}
        </div>
        {first.text && <p className="card-text">{first.text}</p>}
        {first.url && <a className="card-link" href={first.url} target="_blank" rel="noreferrer" onClick={(e) => e.stopPropagation()}>{first.url}</a>}
        {first.tags.length > 0 && (
          <div className="card-tags">
            {first.tags.map((t) => <TagChip key={t.label + t.origin} label={t.label} ai={(t.origin & 1) === 0} />)}
          </div>
        )}
      </div>
    </article>
  );
});

export function TagChip({ label, ai, onClick }: { label: string; ai: boolean; onClick?: () => void }) {
  return (
    <span className={`chip${ai ? ' chip-ai' : ''}`} onClick={onClick}>
      {ai ? <Sparkles size={11} /> : <Tag size={11} />}{label}
    </span>
  );
}

function Picture({ item, width }: { item: FeedItem; width: number }) {
  const side = sideFor(width);
  const [url, setUrl] = useState(() => cachedThumb(item, side));
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    let live = true;
    const hit = cachedThumb(item, side);
    if (hit) { setUrl(hit); return; }
    setUrl(undefined);
    thumb(item, side).then((u) => live && setUrl(u), () => live && setFailed(true));
    return () => { live = false; };
  }, [item, side]);
  if (failed) return <div className="card-missing" />;
  return url ? <img src={url} alt="" draggable={false} decoding="async" /> : <div className="card-placeholder" />;
}
