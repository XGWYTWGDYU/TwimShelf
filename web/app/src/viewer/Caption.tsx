// The post a media belongs to, over the bottom of the viewer as X does (PostCaptionView.swift):
// the author, then the text cut to three lines. A click on cut text opens all of it (scrollable
// when long, selectable, with the date), another click closes it. Loose media and posts without
// author or text show nothing. No shade behind it: the text has a soft shadow of its own.
import { useLayoutEffect, useRef, useState } from 'react';
import { L, type FeedItem } from '@twimshelf/core';
import { language } from '../lib/core';

export function captionShows(item: FeedItem | null | undefined): boolean {
  if (!item || item.post_id.startsWith('loose:')) return false;
  return !!item.text || item.author_name != null || item.screen_name != null;
}

export function Caption({ item, maxHeight, trailing, bottom, opacity }: { item: FeedItem; maxHeight: number; trailing: number; bottom: number; opacity: number }) {
  // a new post starts closed
  return <CaptionContent key={item.post_id} item={item} maxHeight={maxHeight} trailing={trailing} bottom={bottom} opacity={opacity} />;
}

function CaptionContent({ item, maxHeight, trailing, bottom, opacity }: { item: FeedItem; maxHeight: number; trailing: number; bottom: number; opacity: number }) {
  const [open, setOpen] = useState(false);
  const [cut, setCut] = useState(false);
  const text = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const el = text.current;
    if (!el || open) return;
    const check = () => setCut(el.scrollHeight > el.clientHeight + 1);
    check();
    const ro = new ResizeObserver(check);
    ro.observe(el);
    return () => ro.disconnect();
  }, [item.text, open]);
  const date = dateText(item.created_at);
  return (
    <div className="caption" style={{ paddingRight: trailing, bottom, opacity }}
      onClick={(e) => { e.stopPropagation(); if (cut || open) setOpen(!open); }}
      onMouseDown={(e) => e.stopPropagation()} onDoubleClick={(e) => e.stopPropagation()}>
      <div className="caption-inner">
        <div className="caption-author">
          {item.author_name && <span className="caption-name">{item.author_name}</span>}
          {item.screen_name && <span className="caption-handle">@{item.screen_name}</span>}
        </div>
        {item.text && (open ? (
          <div className="caption-scroll selectable" style={{ maxHeight }} onWheel={(e) => e.stopPropagation()}>
            <div className="caption-text">{linked(item.text)}</div>
            {date && <div className="caption-date">{date}</div>}
          </div>
        ) : (
          <div ref={text} className="caption-text caption-cut">{item.text}</div>
        ))}
        {item.text && (cut || open) && <div className="caption-more">{open ? L('caption.less') : L('caption.more')}</div>}
      </div>
    </div>
  );
}

/** The text with its web links clickable (they open in the browser). */
function linked(text: string) {
  const parts = text.split(/(https?:\/\/[^\s]+)/g);
  return parts.map((p, i) => i % 2 ? <a key={i} className="caption-link" href={p} target="_blank" rel="noreferrer" onClick={(e) => e.stopPropagation()}>{p}</a> : p);
}

/** "3 hours ago" for the last week, then the date and time in the user's format. */
function dateText(raw?: string | null): string | null {
  const d = parseDate(raw);
  if (!d) return null;
  const ago = Date.now() - d.getTime();
  if (ago >= 0 && ago < 7 * 86_400_000) {
    const f = new Intl.RelativeTimeFormat(language, { numeric: 'auto' });
    const s = ago / 1000;
    if (s < 60) return f.format(-Math.round(s), 'second');
    if (s < 3600) return f.format(-Math.round(s / 60), 'minute');
    if (s < 86400) return f.format(-Math.round(s / 3600), 'hour');
    return f.format(-Math.round(s / 86400), 'day');
  }
  return d.toLocaleString(language, { dateStyle: 'long', timeStyle: 'short' });
}

/** X's "Fri Oct 24 08:13:11 +0000 2025", ISO 8601, or seconds since 1970 (PostDate.parse). */
function parseDate(raw?: string | null): Date | null {
  const s = raw?.trim();
  if (!s) return null;
  const x = /^\w{3} (\w{3}) (\d{1,2}) (\d\d:\d\d:\d\d) ([+-]\d{4}) (\d{4})$/.exec(s);
  if (x) {
    const d = new Date(`${x[1]} ${x[2]} ${x[5]} ${x[3]} GMT${x[4]}`);
    if (!isNaN(d.getTime())) return d;
  }
  if (/^\d+(\.\d+)?$/.test(s)) { const n = Number(s); if (n > 1e9) return new Date(n > 1e12 ? n : n * 1000); }
  const d = new Date(s);
  return isNaN(d.getTime()) ? null : d;
}
