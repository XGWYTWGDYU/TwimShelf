// The core for the React front end: the generated bindings plus the core's result envelope.
// Most C functions return `{"ok": value}` or `{"error": "<message key or text>"}` as a string;
// `read` unwraps that. The Dart wrapper (flutter/tl_core/lib/tl_core.dart) is the reference for
// which function takes which arguments: objects go as JSON strings, exactly as there.
import { CoreBindings } from './generated/bindings';
import type { FeedFilter, FeedItem, FeedRequest, SearchFields, TagView } from './generated/models';
import type { Transport } from './transport';

export class CoreError extends Error {}

export class Core {
  readonly b: CoreBindings;
  constructor(readonly transport: Transport) {
    this.b = new CoreBindings(transport);
  }

  /** The value of an `{"ok": …}` envelope; throws CoreError with the `error` text otherwise. */
  async read<T>(result: Promise<string | null>): Promise<T> {
    const raw = await result;
    if (raw == null) throw new CoreError('core.noResult');
    const envelope = JSON.parse(raw) as { ok?: T; error?: string };
    if (envelope.error !== undefined) throw new CoreError(envelope.error);
    if (!('ok' in envelope)) throw new CoreError('core.emptyResult');
    return envelope.ok as T;
  }

  /** A function whose one argument is a JSON object, its envelope unwrapped. */
  readJson<T>(name: keyof CoreBindings, arg: unknown): Promise<T> {
    const fn = this.b[name] as unknown as (a: string) => Promise<string | null>;
    return this.read<T>(fn.call(this.b, JSON.stringify(arg)));
  }

  /** The feed, in the core's compact form (PackedFeed in core/src/library.rs). */
  async feed(request: FeedQuery = {}): Promise<FeedItem[]> {
    return unpackFeed(await this.read<PackedFeed>(this.b.tl_feed_packed(JSON.stringify(feedRequest(request)))));
  }

  /** A library file's URL on the server (paths in the feed are absolute on the server). */
  fileUrl(path: string): string {
    return `${this.transport.base}/f/${path.split('/').map(encodeURIComponent).join('/').replace(/^\/+/, '')}`;
  }
}

/** A feed request with only the parts that differ from the defaults (as in the Dart models). */
export type FeedQuery = Partial<Omit<FeedRequest, 'fields' | 'filter'>> & {
  fields?: Partial<SearchFields>;
  filter?: Partial<FeedFilter>;
};

export function feedRequest(q: FeedQuery): FeedRequest {
  return {
    terms: [], scope: 'both', seed: null, newest_first: false, fuzzy: true, term_vectors: [],
    embed_model: null, threshold: 0.55, whole_posts: false, ...q,
    fields: { tags: true, text: false, author: false, ...q.fields },
    filter: {
      author: null, labels: [], review: 'any', bad_only: false, folder: null, loose_only: false,
      album_only: false, recent_only: false, kind: null, exclude_terms: [], origins: null,
      exclude_folders: [], exclude_recent: false, exclude_loose: false, ...q.filter,
    },
  };
}

export interface PackedFeed {
  root: string;
  posts: Array<{ id: string; text?: string | null; author_name?: string | null; screen_name?: string | null;
    url?: string | null; created_at?: string | null; recent?: boolean; album?: boolean }>;
  tag_lists: Array<Array<[string, number, string[]]>>;
  /** [media_id, post index, ordinal, 'p' | 'v', path, tag list index, bad, width, height] */
  media: Array<[string, number, number, string, string, number, string, number, number]>;
}

export function unpackFeed(packed: PackedFeed): FeedItem[] {
  const lists: TagView[][] = packed.tag_lists.map((l) => l.map(([label, origin, models]) => ({ label, origin, models })));
  return packed.media.map(([media_id, post, ordinal, kind, path, tags, bad, w, h]) => {
    const p = packed.posts[post];
    return {
      media_id, post_id: p.id, ordinal, kind: kind === 'v' ? 'video' : 'photo',
      path: path.startsWith('/') || path.includes(':') ? path : packed.root + path,
      text: p.text ?? null, author_name: p.author_name ?? null, screen_name: p.screen_name ?? null,
      url: p.url ?? null, created_at: p.created_at ?? null, tags: lists[tags],
      bad: bad === '' ? null : bad, recent: p.recent ?? false, album: p.album ?? false,
      size: w > 0 && h > 0 ? [w, h] : null,
    };
  });
}

/** A card's media, width per unit of height (as FeedItem.cardAspectRatio in the Dart models). */
export function cardAspectRatio(item: FeedItem): number {
  const [w, h] = item.size ?? [0, 0];
  return w > 0 && h > 0 ? Math.min(Math.max(w / h, 1 / 1.8), 1 / 0.3) : 4 / 5;
}
