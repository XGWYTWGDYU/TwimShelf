// The viewer: one media at a time over the whole window. ←/→ (or the side buttons) go through
// the list, Esc or a click on the backdrop closes it, Space plays/pauses a video, Delete moves
// the media to the bin. The text and tags of the post are in the panel on the right.
import { useCallback, useEffect, useRef, useState } from 'react';
import { ChevronLeft, ChevronRight, ExternalLink, PanelRight, Trash2, X } from 'lucide-react';
import { L, type FeedItem } from '@twimshelf/core';
import { core } from '../lib/core';
import { libraryChanged } from '../lib/library';
import { toast } from '../components/toast';
import { TagChip } from '../pages/browse/PostCard';
import { cachedThumb, sideFor } from '../lib/thumbs';
import { handBack, position } from '../lib/videoPositions';
import './Viewer.css';

let cacheDir: Promise<string> | null = null;
const cache = () => (cacheDir ??= fetch(`${core.transport.base}/api/info`, { credentials: 'same-origin' }).then((r) => r.json()).then((i: { cache: string }) => i.cache));

/** A photo's URL the browser can show: the original, or a JPEG of a HEIC (browsers cannot). */
async function displayUrl(item: FeedItem): Promise<string> {
  if (/\.(heic|heif)$/i.test(item.path)) {
    return core.fileUrl(await core.read<string>(core.b.tl_display_image(item.path, 4096, await cache())));
  }
  return core.fileUrl(item.path);
}

export function Viewer({ items, index, onClose }: { items: FeedItem[]; index: number; onClose: () => void }) {
  const [at, setAt] = useState(index);
  const [panel, setPanel] = useState(() => localStorageGet('viewer.panel') !== '0');
  const item = items[at];
  const video = useRef<HTMLVideoElement>(null);

  const step = useCallback((d: number) => setAt((i) => Math.min(items.length - 1, Math.max(0, i + d))), [items.length]);

  const trash = useCallback(async () => {
    if (!item) return;
    try {
      await core.readJson<number>('tl_trash', { media: [item.media_id], post: null });
      libraryChanged();
      toast(L('grid.moveToTrash'), {
        label: L('common.undo'),
        run: async () => { await core.readJson('tl_trash_restore', { media: [item.media_id] }); libraryChanged(); },
      });
      if (items.length <= 1) onClose(); else step(at >= items.length - 1 ? -1 : 0);
    } catch (e) {
      toast(L(String((e as Error).message)));
    }
  }, [item, items.length, at, step, onClose]);

  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if (e.target instanceof Element && e.target.closest('input, textarea')) return;
      switch (e.key) {
        case 'Escape': onClose(); break;
        case 'ArrowLeft': step(-1); break;
        case 'ArrowRight': step(1); break;
        case ' ': if (video.current) { e.preventDefault(); if (video.current.paused) void video.current.play(); else video.current.pause(); } break;
        case 'Delete': case 'Backspace': void trash(); break;
        default: return;
      }
      e.stopPropagation();
    };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, [onClose, step, trash]);

  if (!item) return null;
  return (
    <div className="viewer" role="dialog" aria-modal="true">
      <div className="viewer-stage" onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}>
        <Media key={item.media_id} item={item} videoRef={video} />
        {at > 0 && <button className="viewer-nav left" onClick={() => step(-1)} aria-label="Previous"><ChevronLeft size={26} /></button>}
        {at < items.length - 1 && <button className="viewer-nav right" onClick={() => step(1)} aria-label="Next"><ChevronRight size={26} /></button>}
        <div className="viewer-top">
          <span className="viewer-pos">{at + 1} / {items.length}</span>
          <div className="viewer-tools">
            {item.url && <a className="viewer-btn" href={item.url} target="_blank" rel="noreferrer" title={L('common.open')}><ExternalLink size={17} /></a>}
            <button className="viewer-btn" onClick={() => void trash()} title={L('common.delete')}><Trash2 size={17} /></button>
            <button className={`viewer-btn${panel ? ' on' : ''}`} onClick={() => { setPanel(!panel); localStorageSet('viewer.panel', panel ? '0' : '1'); }}><PanelRight size={17} /></button>
            <button className="viewer-btn" onClick={onClose} title={L('common.close')}><X size={18} /></button>
          </div>
        </div>
      </div>
      {panel && (
        <aside className="viewer-panel">
          <div className="viewer-author">
            <b>{item.author_name ?? L('common.unknownAuthor')}</b>
            {item.screen_name && <span>@{item.screen_name}</span>}
          </div>
          {item.created_at && <div className="viewer-date">{new Date(item.created_at).toLocaleString()}</div>}
          {item.text && <p className="viewer-text">{item.text}</p>}
          {item.tags.length > 0 && <div className="card-tags">{item.tags.map((t) => <TagChip key={t.label + t.origin} label={t.label} ai={(t.origin & 1) === 0} />)}</div>}
        </aside>
      )}
    </div>
  );
}

function Media({ item, videoRef }: { item: FeedItem; videoRef: React.RefObject<HTMLVideoElement | null> }) {
  // the card's picture first (already loaded), the full picture over it when it is ready
  const preview = cachedThumb(item, sideFor(400)) ?? cachedThumb(item, sideFor(250));
  const [full, setFull] = useState<string | null>(null);
  const [loaded, setLoaded] = useState(false);
  useEffect(() => {
    let live = true;
    if (item.kind === 'photo') displayUrl(item).then((u) => live && setFull(u), () => {});
    return () => { live = false; };
  }, [item]);
  // closing or going on to the next item: the card goes on from here
  useEffect(() => {
    const v = videoRef.current;
    if (item.kind !== 'video' || !v) return;
    // (a video that never started has nothing to hand back: React mounts twice in development)
    return () => { if (v.readyState >= 1 && v.currentTime > 0) handBack(item.media_id, v.currentTime); };
  }, [item, videoRef]);
  if (item.kind === 'video') {
    // goes on from the card's frame; hands its place back to the card when it closes
    return <video ref={videoRef} className="viewer-media" src={core.fileUrl(item.path)} poster={preview} controls autoPlay playsInline
      onLoadedMetadata={(e) => { e.currentTarget.currentTime = position(item.media_id); }}
      onPause={(e) => handBack(item.media_id, e.currentTarget.currentTime)}
      />;
  }
  return (
    <div className="viewer-photo">
      {preview && !loaded && <img className="viewer-media" src={preview} alt="" />}
      {full && <img className={`viewer-media${loaded ? '' : ' loading'}`} src={full} alt="" onLoad={() => setLoaded(true)} />}
    </div>
  );
}

function localStorageGet(k: string): string | null { try { return localStorage.getItem(k); } catch { return null; } }
function localStorageSet(k: string, v: string): void { try { localStorage.setItem(k, v); } catch { /* private window */ } }
