// 文件夹: all folders as cover tiles, like the albums in Photos (MacFoldersOverview): as many columns
// as the width allows (tiles of at least 170), each a square cover with the name and the count
// beneath. A click opens the folder; its menu opens, renames or deletes it; the toolbar's button
// makes a new one.
import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { FolderPlus } from 'lucide-react';
import { L, type FeedItem, type Folder, type FolderOverview } from '@twimshelf/core';
import { Toolbar, ToolButton } from '../components/Toolbar';
import { openMenu } from '../components/Menu';
import { core } from '../lib/core';
import { createFolder, deleteFolder, renameFolder } from '../lib/folderActions';
import { useAsync, useStore } from '../lib/hooks';
import { libraryVersion } from '../lib/library';
import { folderRoute, go } from '../lib/router';
import { thumb } from '../lib/thumbs';
import './FoldersPage.css';

const MARGIN = 20, GAP = 16, MIN_TILE = 170;

export default function FoldersPage() {
  const version = useStore(libraryVersion);
  const { data } = useAsync(() => core.read<FolderOverview>(core.b.tl_folder_overview()), [version]);
  const list = data?.folders ?? [];
  const box = useRef<HTMLDivElement>(null);
  const [side, setSide] = useState(MIN_TILE);
  // tiles as wide as the columns that fit, so rows always fill the width
  useLayoutEffect(() => {
    const el = box.current!;
    const fit = () => {
      const w = Math.max(el.clientWidth - 2 * MARGIN, MIN_TILE);
      const cols = Math.max(1, Math.floor((w + GAP) / (MIN_TILE + GAP)));
      setSide(Math.floor((w - GAP * (cols - 1)) / cols));
    };
    fit();
    const ro = new ResizeObserver(fit);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return (
    <div className="folders-page">
      <Toolbar title={L('place.folders')} subtitle={list.length ? L('folders.count', list.length) : undefined}>
        <ToolButton label={L('common.newFolder')} onClick={() => void createFolder().then((n) => n && go(folderRoute(n)))}><FolderPlus size={17} strokeWidth={1.8} /></ToolButton>
      </Toolbar>
      <div className="folders-scroll" ref={box}>
        {data && !list.length && <div className="folders-empty">{L('folders.empty.mac')}</div>}
        <div className="folders-tiles" style={{ gridTemplateColumns: `repeat(auto-fill, ${side}px)` }}>
          {list.map((f) => <FolderTile key={f.name} f={f} side={side} />)}
        </div>
      </div>
    </div>
  );
}

function FolderTile({ f, side }: { f: Folder; side: number }) {
  const [url, setUrl] = useState<string>();
  useEffect(() => {
    setUrl(undefined);
    if (!f.cover_path || !f.cover_id) return;
    let live = true;
    const item = { media_id: f.cover_id, path: f.cover_path, kind: f.cover_video ? 'video' : 'photo' } as FeedItem;
    thumb(item, 512).then((u) => live && setUrl(u), () => {});
    return () => { live = false; };
  }, [f.cover_id, f.cover_path, f.cover_video]);
  return (
    <div className="folder-tile" role="button" aria-label={f.name} style={{ width: side }}
      onClick={() => go(folderRoute(f.name))}
      onContextMenu={(e) => openMenu(e, [
        { label: L('common.open'), run: () => go(folderRoute(f.name)) },
        'separator',
        { label: L('folder.renameShort'), run: () => void renameFolder(f.name) },
        { label: L('folder.deleteEllipsis'), run: () => void deleteFolder(f.name) },
      ])}>
      <div className="folder-cover" style={{ height: side }}>{url && <img src={url} alt="" draggable={false} />}</div>
      <div className="folder-name">{f.name}</div>
      <div className="folder-detail">{L('search.row.mediaCount', f.count) + (f.videos > 0 ? L('folders.videosSuffix', f.videos) : '')}</div>
    </div>
  );
}
