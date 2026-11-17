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

/** A card's height before it is measured: the picture, plus a guess at the text below it. */
export function estimateCard(p: Post, width: number): number {
  const first = p.media[0];
  const pic = width / cardAspectRatio(first);
  const text = first.text ?? '';
  const perLine = Math.max(10, Math.floor((width - 28) / 7.5));
  const lines = Math.min(6, Math.ceil(text.length / perLine));
  return pic + 14 + 20 + lines * 19 + (first.url ? 18 : 0) + (first.tags.length ? 34 : 0) + 14;
}
