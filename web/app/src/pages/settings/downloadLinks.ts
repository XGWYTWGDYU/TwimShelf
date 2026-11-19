// What the quick download card (the button beside the search field) and the 下载帖子 page share,
// as DownloadModel does in the native app: the links typed so far, how a link is recognised, and
// the saved download options.
import { store } from '@twimshelf/core';
import type { DownloadRoute } from '@twimshelf/core';
import { info, readText } from './serverFiles';

/** The links being typed, one per line: the same text on the card and on the page. */
export const downloadLinks = store('');

const POST_URL_RE = /^https?:\/\/(?:(?:www\.|mobile\.)?(?:x|twitter|fxtwitter|vxtwitter|fixupx)\.com)\/(?:[^/\s]+\/status|i\/(?:web\/)?status)\/\d+/i;

export function isPostLink(text: string): boolean {
  return POST_URL_RE.test(text);
}

export function parseLinks(raw: string): { goodUrls: string[]; badUrls: string[]; good: number; bad: number } {
  const lines = raw.split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
  const goodUrls: string[] = [];
  const badUrls: string[] = [];
  for (const line of lines) {
    if (isPostLink(line)) goodUrls.push(line);
    else badUrls.push(line);
  }
  return { goodUrls, badUrls, good: goodUrls.length, bad: badUrls.length };
}

/** The clipboard's post links that are not there yet, added on their own lines (a double click
 *  in the box, as on the native card). */
export function withPastedLinks(current: string, clipboard: string): string {
  const have = current.split(/\s+/).filter(Boolean);
  const fresh = clipboard.split(/\s+/).filter((t) => isPostLink(t) && !have.includes(t));
  return fresh.length ? [...have, ...fresh].join('\n') : current;
}

export type DownloadOptions = { route: DownloadRoute; concurrency: number; intervalMs: number; folder: string | null };
export const defaultDownloadOptions: DownloadOptions = { route: 'auto', concurrency: 3, intervalMs: 500, folder: null };
export const downloadRoutes = ['auto', 'fx', 'cookie'] as const;

export async function downloadOptionFile(): Promise<string> {
  return `${(await info()).library}/downloads.queue.json`;
}

export async function readDownloadOptionFile(path: string): Promise<Record<string, unknown>> {
  return JSON.parse((await readText(path)) ?? '{}') as Record<string, unknown>;
}

/** The options saved on the 下载帖子 page. */
export async function savedDownloadOptions(): Promise<DownloadOptions> {
  const saved = await readDownloadOptionFile(await downloadOptionFile());
  return {
    route: downloadRoutes.find((route) => route === saved.route) ?? defaultDownloadOptions.route,
    concurrency: Number(saved.concurrency) || defaultDownloadOptions.concurrency,
    intervalMs: saved.intervalMs == null ? defaultDownloadOptions.intervalMs : Number(saved.intervalMs),
    folder: typeof saved.folder === 'string' && saved.folder ? saved.folder : null,
  };
}
