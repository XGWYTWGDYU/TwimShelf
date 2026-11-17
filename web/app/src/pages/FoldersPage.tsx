import { useState } from 'react';
import { L, type FolderOverview } from '@twimshelf/core';
import { Folder, FolderPlus, Images, Video } from 'lucide-react';
import { Button, Empty, Page, Row, Section } from '../components/ui';
import { CardGrid, change, Confirm, LoadState, MediaCard, NameDialog } from '../components/libraryControls';
import { core } from '../lib/core';
import { useAsync, useStore } from '../lib/hooks';
import { libraryVersion } from '../lib/library';
import { go } from '../lib/router';

type Edit = { kind: 'create' } | { kind: 'rename' | 'delete'; name: string } | { kind: 'merge'; name: string; to: string };

export default function FoldersPage() {
  const version = useStore(libraryVersion);
  const { data, error, reload } = useAsync(() => core.read<FolderOverview>(core.b.tl_folder_overview()), [version]);
  const [edit, setEdit] = useState<Edit>();
  const close = () => setEdit(undefined);
  const rename = (from: string, to: string) => change(core.readJson('tl_rename_folder', { old: from, new: to }));
  const makeFolder = () => setEdit({ kind: 'create' });

  return <Page title={L('place.folders')} actions={<Button kind="primary" onClick={makeFolder}>
    {L('common.newFolder')}
  </Button>}>
    {!data || error ? <LoadState error={error} reload={reload} /> : <>
      <Section title={L('sidebar.mediaTypes')}>
        <Row icon={<Images size={17} />} title={L('search.kw.photo.word')} trailing={data.photos.toLocaleString()}
          onClick={() => go({ page: 'browse', kind: 'photo' })} />
        <Row icon={<Video size={17} />} title={L('place.videos')} trailing={data.videos.toLocaleString()}
          onClick={() => go({ page: 'browse', kind: 'video' })} />
      </Section>
      {!data.folders.length ? <Empty icon={<FolderPlus />} title={L('search.noFolders')}>{L('folders.empty.hint')}</Empty>
        : <CardGrid>{data.folders.map((folder) => <MediaCard key={folder.name} icon={<Folder size={36} />}
          path={folder.cover_path} video={folder.cover_video} title={folder.name}
          subtitle={L('grid.countSuffix', folder.count).trim()}
          onOpen={() => go({ page: 'browse', folder: folder.name })} actions={<>
            <Button kind="plain" onClick={() => setEdit({ kind: 'rename', name: folder.name })}>{L('common.rename')}</Button>
            <Button onClick={() => setEdit({ kind: 'delete', name: folder.name })}>{L('common.delete')}</Button>
          </>} />)}</CardGrid>}
    </>}
    {edit?.kind === 'create' && <NameDialog title={L('common.newFolder')} action={L('common.create')} onClose={close}
      onSave={(name) => change(core.read(core.b.tl_create_folder(name)))} />}
    {edit?.kind === 'rename' && <NameDialog title={L('folder.rename.title')} action={L('common.rename')} initial={edit.name} onClose={close}
      onSave={async (name) => {
        if (name === edit.name) return;
        if (data?.folders.some((folder) => folder.name === name)) {
          setEdit({ kind: 'merge', name: edit.name, to: name });
          return false;
        }
        await rename(edit.name, name);
      }} />}
    {edit?.kind === 'merge' && <Confirm title={L('folder.merge.title', edit.to)} action={L('folder.merge')} onClose={close}
      onConfirm={() => rename(edit.name, edit.to)}>{L('folder.merge.message', edit.to, edit.name, edit.name)}</Confirm>}
    {edit?.kind === 'delete' && <Confirm title={L('folder.delete.title', edit.name)} action={L('folder.delete.confirm')}
      danger onClose={close} onConfirm={() => change(core.read(core.b.tl_delete_folder(edit.name)))}>
      {L('folder.delete.message')}
    </Confirm>}
  </Page>;
}
