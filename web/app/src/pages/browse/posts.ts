import { cardAspectRatio, type FeedItem } from '@twimshelf/core';

/** A card: one post and its media in order (the feed gives a post's media together). */
export interface Post { id: string; media: FeedItem[] }

export function groupPosts(items: FeedItem[]): Post[] {
  const out: Post[] = [];
  const at = new Map<string, Post>();
  for (const m of items) {
    let p = at.get(m.post_id);
    if (!p) { p = { id: m.post_id, media: [] }; at.set(m.post_id, p); out.push(p); }
    p.media.push(m);
  }
  for (const p of out) p.media.sort((a, b) => a.ordinal - b.ordinal);
  return out;
}

/** A card's height before it is measured, as MacCardLayout adds it up: the media, 10, the author
 *  (17), the text, the link (16), each 5 apart and only when there, then 8 + the tag row (20) + 14. */
export function estimateCard(p: Post, width: number): number {
  const it = p.media[0];
  const media = Math.round(width / cardAspectRatio(it));
  let y = media + 10;
  let gap = 0;
  const loose = it.post_id.startsWith('loose:');
  if (loose || it.author_name || it.screen_name) { y += 17; gap = 5; }
  if (it.text) {
    const perLine = Math.max(10, Math.floor((width - 28) / 7.2));
    const lines = it.text.split('\n').reduce((n, l) => n + Math.max(1, Math.ceil(l.length / perLine)), 0);
    y += gap + lines * 16;
    gap = 5;
  }
  if (it.url) y += gap + 16;
  if (y === media + 10) y = media;
  return Math.ceil(y + 8 + 20 + 14);
}
