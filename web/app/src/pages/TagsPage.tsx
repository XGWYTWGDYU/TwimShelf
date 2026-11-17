import { useState } from 'react';
import { L, type TagCount } from '@twimshelf/core';
import { Tags } from 'lucide-react';
import { Button, Empty, Page, Row, Section, TextField } from '../components/ui';
import { change, Confirm, LoadState, NameDialog, Select } from '../components/libraryControls';
import { toast } from '../components/toast';
import { core } from '../lib/core';
import { useAsync, useStore } from '../lib/hooks';
import { libraryVersion } from '../lib/library';
import { go } from '../lib/router';

const sortKeys = ['count', 'user', 'ai', 'label'] as const;
type Sort = typeof sortKeys[number];
type Edit = { kind: 'rename' | 'delete' | 'folder'; tag: TagCount } | { kind: 'ai' };

export default function TagsPage({ back }: { back?: () => void }) {
  const version = useStore(libraryVersion);
  const { data, error, reload } = useAsync(() => core.read<TagCount[]>(core.b.tl_all_tags()), [version]);
  const [sort, setSort] = useState<Sort>('count');
  const [filter, setFilter] = useState('');
  const [edit, setEdit] = useState<Edit>();
  const close = () => setEdit(undefined);
  const aiCount = data?.filter((tag) => tag.ai > 0).length ?? 0;
  const visible = data?.filter((tag) => tag.label.toLowerCase().includes(filter.trim().toLowerCase()))
    .sort((a, b) => (sort === 'label' ? 0 : b[sort] - a[sort]) || a.label.localeCompare(b.label));

  return <Page title={L('common.tags')} back={back} actions={<Button disabled={!aiCount} onClick={() => setEdit({ kind: 'ai' })}>
    {L('tags.deleteAIEllipsis')}
  </Button>}>
    {!data || error ? <LoadState error={error} reload={reload} /> : !data.length
      ? <Empty icon={<Tags />} title={L('tags.none')}>{L('tags.none.message')}</Empty>
      : <>
        <Section>
          <Row title={L('tags.filter')} trailing={<TextField value={filter} onChange={setFilter} placeholder={L('tags.filter')} />} />
          <Row title={L('tags.sortBy')} trailing={<Select label={L('tags.sortBy')} value={sort}
            options={sortKeys.map((value, i) => ({ value, label: L(['tags.sort.count', 'tags.sort.mine', 'tags.sort.ai', 'common.name'][i]) }))}
            onChange={(value) => setSort(value as Sort)} />} />
        </Section>
        {visible?.length ? <Section>{visible.map((tag) => <Row key={tag.label} title={tag.label}
          subtitle={L('tags.cell.detail', tag.count, tag.user, tag.ai)} trailing={<div className="control-actions">
            <Button kind="plain" onClick={() => go({ page: 'browse', q: `"${tag.label}"` })}>{L('place.browse')}</Button>
            <Button onClick={() => setEdit({ kind: 'rename', tag })}>{L('tags.renameOrMerge')}</Button>
            <Button onClick={() => setEdit({ kind: 'folder', tag })}>{L('common.addToFolder')}</Button>
            <Button onClick={() => setEdit({ kind: 'delete', tag })}>{L('common.delete')}</Button>
          </div>} />)}</Section> : <Empty title={L('tags.noMatch')}>{L('tags.noMatch.message')}</Empty>}
      </>}
    {edit?.kind === 'rename' && <NameDialog title={L('tags.rename.title', edit.tag.label)} action={L('common.done')}
      initial={edit.tag.label} onClose={close} onSave={async (name) => {
        const to = name.toLowerCase();
        if (to === edit.tag.label) return;
        await change(core.read(core.b.tl_rename_tag(edit.tag.label, to)));
        toast(L('tags.renamed'));
      }}><p>{L('tags.rename.countMessage', edit.tag.count)} {L('tags.rename.message')}</p></NameDialog>}
    {edit?.kind === 'folder' && <NameDialog title={L('tags.toFolder.title', edit.tag.label, edit.tag.count)}
      action={L('common.addToFolder')} onClose={close} onSave={async (folder) => {
        await change((async () => {
          await core.read(core.b.tl_create_folder(folder));
          const n = await core.readJson<number>('tl_tag_to_folder', { label: edit.tag.label, folder });
          toast(n < edit.tag.count ? L('tags.toFolder.partly', n) : L('tags.toFolder.done', folder));
        })());
      }}><p>{L('tags.toFolder.message')}</p></NameDialog>}
    {edit?.kind === 'delete' && <Confirm title={L('tags.delete.title', edit.tag.label)} action={L('common.delete')}
      danger onClose={close} onConfirm={() => change(core.read(core.b.tl_delete_tag(edit.tag.label)))}>
      {L('tags.delete.message', edit.tag.count)}
    </Confirm>}
    {edit?.kind === 'ai' && <Confirm title={L('tags.deleteAI.title', aiCount)} action={L('tags.deleteAI.confirm')}
      danger onClose={close} onConfirm={() => change(core.read(core.b.tl_remove_ai_tags()))}>{L('tags.deleteAI.message')}</Confirm>}
  </Page>;
}
