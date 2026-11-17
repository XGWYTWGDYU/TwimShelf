import { useState } from 'react';
import { L, type ActionReceipt, type ActionStamp, type BinSnapshot, type TrashItem } from '@twimshelf/core';
import { Image, Trash2, Video } from 'lucide-react';
import { Button, Empty, Page, Row, Section } from '../components/ui';
import { CardGrid, change, Confirm, LoadState, MediaCard, Select, useTask } from '../components/libraryControls';
import { toast } from '../components/toast';
import { core } from '../lib/core';
import { useAsync, useStore } from '../lib/hooks';
import { libraryVersion } from '../lib/library';

type WireStamp = Omit<ActionStamp, 'hlc'> & { hlc: string };
type WireSnapshot = Omit<BinSnapshot, 'entries'> & { entries: WireStamp[] };
type WireReceipt = Omit<ActionReceipt, 'changes' | 'folder_hlc'> & { changes: WireStamp[]; folder_hlc?: string | null };

// Core timestamps encode milliseconds and a counter in one u64, beyond JS's exact integer range.
function readStamped<T>(response: Promise<string | null>): Promise<T> {
  return core.read<T>(response.then((raw) => raw?.replace(/("(?:folder_)?hlc"\s*:\s*)(\d+)/g, '$1"$2"') ?? null));
}

function stampJson(value: object): string {
  return JSON.stringify(value).replace(/("(?:folder_)?hlc":)"(\d+)"/g, '$1$2');
}

const keepChoices = [7, 30, 90, 365, 0];
const keepLabel = (days: number) => days === 0 ? L('trash.never') : L('trash.after',
  keepChoices.includes(days) ? L(`trash.keep.${days}`) : L('trash.keep.days', days));

export default function BinPage() {
  const version = useStore(libraryVersion);
  const task = useTask();
  const { data, error, reload } = useAsync(async () => {
    const [items, days] = await Promise.all([
      core.read<TrashItem[]>(core.b.tl_trash_list()),
      core.read<number>(core.b.tl_trash_keep_days()),
    ]);
    return { items, days };
  }, [version]);
  const [pending, setPending] = useState<{ ids: string[]; snapshot: WireSnapshot; all: boolean }>();
  const ids = data?.items.map((item) => item.media_id) ?? [];

  const restore = (media: string[]) => void task.run(async () => {
    const receipt = await change(readStamped<WireReceipt>(core.b.tl_action(JSON.stringify({ kind: 'restore', media }))));
    if (!receipt.changes.length) return;
    toast(L('trash.restored', receipt.changes.length), { label: L('common.undo'), run: () => {
      void task.run(() => change(core.read(core.b.tl_action_undo(stampJson(receipt)))));
    } });
  });
  const askPurge = (media: string[], all = false) => void task.run(async () => {
    const snapshot = await readStamped<WireSnapshot>(core.b.tl_bin_snapshot());
    const selected = new Set(media);
    snapshot.entries = snapshot.entries.filter((entry) => selected.has(entry.id));
    setPending({ ids: snapshot.entries.map((entry) => entry.id), snapshot, all });
  });

  return <Page title={L('place.trash')} actions={<>
    <Button disabled={!ids.length || task.busy} onClick={() => restore(ids)}>{L('trash.restoreAll')}</Button>
    <Button disabled={!ids.length || task.busy} onClick={() => askPurge(ids, true)}>{L('trash.emptyEllipsis')}</Button>
  </>}>
    {!data || error ? <LoadState error={error} reload={reload} /> : <>
      <Section>
        <Row title={L('trash.autoDeleteMac', '')} trailing={<Select label={L('trash.autoDeleteMac', '')} value={String(data.days)}
          disabled={task.busy} options={[...new Set([...keepChoices, data.days])].map((days) => ({ value: String(days), label: keepLabel(days) }))}
          onChange={(days) => void task.run(() => change((async () => {
            await core.read(core.b.tl_set_trash_keep_days(Number(days)));
            await core.read(core.b.tl_trash_expire());
          })()))} />} />
      </Section>
      {!ids.length ? <Empty icon={<Trash2 />} title={L('grid.empty')} />
        : <CardGrid>{data.items.map((item) => <MediaCard key={item.media_id} path={item.path} video={item.kind === 'video'}
          icon={item.kind === 'video' ? <Video /> : <Image />} title={item.author_name || item.screen_name || item.text || item.path.split('/').pop() || item.media_id}
          subtitle={new Date(item.trashed_at_ms).toLocaleDateString()} actions={<>
            <Button kind="plain" disabled={task.busy} onClick={() => restore([item.media_id])}>{L('common.restore')}</Button>
            <Button disabled={task.busy} onClick={() => askPurge([item.media_id])}>{L('common.deletePermanently')}</Button>
          </>} />)}</CardGrid>}
    </>}
    {pending && <Confirm title={L(pending.all ? 'trash.emptyTitle' : 'trash.purgeTitle')} action={L('common.deletePermanently')}
      danger onClose={() => setPending(undefined)} onConfirm={async () => {
        if (!pending.ids.length) return;
        const request = stampJson({ kind: 'purge', expected: pending.snapshot.entries, epoch: pending.snapshot.epoch });
        const receipt = await change(readStamped<WireReceipt>(core.b.tl_action(request)));
        toast(L('trash.purged', receipt.changes.length) + (receipt.changes.length < pending.ids.length ? L('trash.purged.skipped') : ''));
      }}>{L('trash.purgeMessage', L('trash.moved', pending.ids.length))}</Confirm>}
  </Page>;
}
