// Changes to media with Undo, as the apps make them (Core.action / Core.undo in tl_core.dart).
// Receipts carry hybrid-clock stamps (a u64 of milliseconds and a counter) beyond JavaScript's
// exact integers: they are read as strings and written back as numbers, untouched.
import { L, type ActionKind, type FeedItem } from '@twimshelf/core';
import { core } from './core';
import { libraryChanged, refreshLibrary } from './library';
import { toast } from '../components/toast';

export interface Receipt { changes: unknown[]; [k: string]: unknown }
export interface BinSnapshot { entries: { id: string; [k: string]: unknown }[]; epoch: unknown; [k: string]: unknown }

/** A core result whose stamps stay exact. */
export function readStamped<T>(response: Promise<string | null>): Promise<T> {
  return core.read<T>(response.then((raw) => raw?.replace(/("(?:folder_)?hlc"\s*:\s*)(\d+)/g, '$1"$2"') ?? null));
}
export function stampJson(value: object): string {
  return JSON.stringify(value).replace(/("(?:folder_)?hlc":)"(\d+)"/g, '$1$2');
}

/** One action (trash, restore, purge, folder_add, folder_remove…); throws with the core's message. */
export function action(kind: ActionKind | 'restore' | 'purge', o: { media?: string[]; posts?: string[]; folder?: string | null; label?: string | null; expected?: unknown; epoch?: unknown }): Promise<Receipt> {
  return readStamped<Receipt>(core.b.tl_action(stampJson({
    kind, media: o.media ?? [], posts: o.posts ?? [], folder: o.folder ?? null, label: o.label ?? null, expected: o.expected ?? null, epoch: o.epoch ?? null,
  })));
}

export async function undo(receipt: Receipt): Promise<number> {
  return core.read<number>(core.b.tl_action_undo(stampJson(receipt)));
}

/** A toast with Undo for a receipt. */
export function offerUndo(text: string, receipt: Receipt): void {
  toast(text, {
    label: L('common.undo'),
    run: async () => {
      try { const n = await undo(receipt); toast(L('undo.done', n)); } catch (e) { toast(L(String((e as Error).message))); }
      libraryChanged();
    },
  });
}

export async function runAction(kind: ActionKind, o: { media?: string[]; posts?: string[]; folder?: string | null; label?: string | null }, done: (n: number) => string): Promise<boolean> {
  let receipt: Receipt;
  try {
    receipt = await action(kind, o);
  } catch (e) {
    toast(L(String((e as Error).message)));
    return false;
  }
  libraryChanged();
  offerUndo(done(receipt.changes.length), receipt);
  return true;
}

/** What is in the bin now (all of it, or these media), for a purge or restore that knows what it deletes. */
export async function binSnapshot(media?: string[] | null): Promise<BinSnapshot> {
  const s = await readStamped<BinSnapshot>(core.b.tl_bin_snapshot());
  if (media) { const keep = new Set(media); s.entries = s.entries.filter((e) => keep.has(e.id)); }
  return s;
}

export function binChanged(): void {
  libraryChanged();
  void refreshLibrary();
}

export async function addTag(item: FeedItem | string, label: string, ai = false): Promise<void> {
  const id = typeof item === 'string' ? item : item.media_id;
  await core.read(core.b.tl_tag(id, label, ai ? 2 : 1));
}

export async function removeTag(item: FeedItem | string, label: string): Promise<void> {
  const id = typeof item === 'string' ? item : item.media_id;
  await core.read(core.b.tl_untag(id, label));
}

export const isAI = (origin: number) => (origin & 2) !== 0;
export const isUser = (origin: number) => (origin & 1) !== 0;
