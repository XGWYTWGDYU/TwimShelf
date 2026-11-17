// Changes to media with Undo, as the apps make them (Core.action / Core.undo in tl_core.dart).
import { L, type ActionKind, type ActionReceipt, type FeedItem } from '@twimshelf/core';
import { core } from './core';
import { libraryChanged } from './library';
import { toast } from '../components/toast';

export async function runAction(kind: ActionKind, o: { media?: string[]; posts?: string[]; folder?: string | null; label?: string | null }, done: (n: number) => string): Promise<boolean> {
  let receipt: ActionReceipt;
  try {
    receipt = await core.readJson<ActionReceipt>('tl_action', {
      kind, media: o.media ?? [], posts: o.posts ?? [], folder: o.folder ?? null, label: o.label ?? null, expected: null, epoch: null,
    });
  } catch (e) {
    toast(L(String((e as Error).message)));
    return false;
  }
  libraryChanged();
  toast(done(receipt.changes.length), {
    label: L('common.undo'),
    run: async () => {
      const n = await core.readJson<number>('tl_action_undo', receipt);
      libraryChanged();
      toast(L('undo.done', n));
    },
  });
  return true;
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
