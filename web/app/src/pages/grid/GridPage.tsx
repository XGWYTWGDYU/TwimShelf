// A collection beside the sidebar (a folder, 图片, 视频, 外部导入, the recycle bin, …), as the native
// MacMediaGridPage: the zoomable grid and nothing else; the title (on glass), the zoom, 选择 and the
// selection's actions live in the toolbar (AppDelegate's grid / folderGrid / selecting modes).
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Ellipsis, FolderMinus, FolderPlus, Minus, Plus, Trash2, Undo2 } from 'lucide-react';
import { KEYWORDS, keywordWord, L, quoteSearchWord, type ExportReport, type FeedItem, type TrashItem } from '@twimshelf/core';
import { Toolbar, ToolButton, ToolGroup, ToolSegment } from '../../components/Toolbar';
import { openMenu, openMenuBelow, type MenuEntry } from '../../components/Menu';
import { alertMessage, choose, prompt } from '../../components/pickers';
import { toast } from '../../components/toast';
import { action, binChanged, binSnapshot, offerUndo, undo } from '../../lib/actions';
import { onCommand, setMenuState } from '../../lib/commands';
import { core } from '../../lib/core';
import { deleteFolder, renameFolder } from '../../lib/folderActions';
import { useAsync, useStore } from '../../lib/hooks';
import { folders, libraryChanged, libraryVersion } from '../../lib/library';
import { folderRoute, go, type GridPlace } from '../../lib/router';
import { cachedThumb } from '../../lib/thumbs';
import { openViewer } from '../../viewer/Viewer';
import { revealInBrowse } from '../browse/reveal';
import { exportFile, size } from '../settings/serverFiles';
import { ZoomGrid, type ZoomGridHandle } from './ZoomGrid';
import type { ZoomGridTile } from './scene';
import './grid.css';

function readPref(k: string): string | null { try { return localStorage.getItem(k); } catch { return null; } }
function writePref(k: string, v: string): void { try { localStorage.setItem(k, v); } catch { /* private window */ } }
export const grouped = () => readPref('grouped') !== '0';

const kw = (id: string) => keywordWord(KEYWORDS.find((k) => k.id === id)!);

/** The search in 浏览 that shows what a grid shows (its 在浏览中查看). */
function browseQuery(place: GridPlace, folder?: string): string {
  switch (place) {
    case 'photos': return kw('photo');
    case 'videos': return kw('video');
    case 'folder': return `${kw('folder')} ${quoteSearchWord(folder ?? '')}`;
    case 'loose': return kw('external');
    case 'album': return kw('album');
    case 'unreviewed': return kw('unreviewed');
    case 'reviewed': return kw('reviewed');
    case 'bad': return kw('damaged');
    default: return '';
  }
}

function title(place: GridPlace, folder?: string): string {
  return place === 'folder' ? folder ?? '' : L(`place.${place}`);
}

const fromTrash = (t: TrashItem): FeedItem => ({
  media_id: t.media_id, post_id: t.post_id, ordinal: t.ordinal, kind: t.kind, path: t.path, text: t.text, author_name: t.author_name,
  screen_name: t.screen_name, url: t.url, tags: t.tags, created_at: null, bad: null, recent: false, album: false, size: null,
});

const KEEP = [7, 30, 90, 365, 0];
const keepTitle = (days: number) => days === 0 ? L('trash.neverShort') : KEEP.includes(days) ? L(`trash.keep.${days}`) : L('trash.keep.days', days);

export default function GridPage({ place, folder }: { place: GridPlace; folder?: string }) {
  const bin = place === 'trash';
  const version = useStore(libraryVersion);
  const grid = useRef<ZoomGridHandle>(null);
  const [level, setLevel] = useState(() => Math.min(2, Math.max(0, Number(readPref('grid.level') ?? 1))));
  const [selecting, setSelecting] = useState(false);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const data = useAsync(async () => {
    if (bin) {
      const [list, keep] = await Promise.all([core.read<TrashItem[]>(core.b.tl_trash_list()), core.read<number>(core.b.tl_trash_keep_days())]);
      return { items: list.map(fromTrash), trashedAt: new Map(list.map((t) => [t.media_id, t.trashed_at_ms])), keep };
    }
    const filter = {
      kind: place === 'photos' ? 'photo' as const : place === 'videos' ? 'video' as const : null,
      folder: place === 'folder' ? folder ?? null : null,
      loose_only: place === 'loose', album_only: place === 'album', bad_only: place === 'bad',
      review: place === 'unreviewed' ? 'unreviewed' as const : place === 'reviewed' ? 'reviewed' as const : 'any' as const,
    };
    return { items: await core.feed({ filter }), trashedAt: new Map<string, number>(), keep: 0 };
  }, [place, folder, version]);

  // media past the retention period leave the bin when it is opened
  useEffect(() => {
    if (bin) core.read<number>(core.b.tl_trash_expire()).then((n) => { if (n > 0) binChanged(); }, () => {});
  }, [bin]);

  const items = useMemo(() => data.data?.items ?? [], [data.data]);
  const entries = useMemo<FeedItem[][]>(() => {
    if (!grouped()) return items.map((m) => [m]);
    const order: string[] = [];
    const by = new Map<string, FeedItem[]>();
    for (const m of items) {
      let e = by.get(m.post_id);
      if (!e) { by.set(m.post_id, (e = [])); order.push(m.post_id); }
      e.push(m);
    }
    return order.map((id) => by.get(id)!.sort((a, b) => a.ordinal - b.ordinal));
  }, [items]);
  const tiles = useMemo<ZoomGridTile[]>(() => entries.map((e) => ({ item: e[0], count: e.length })), [entries]);
  const countsLine = useMemo(() => {
    const videos = items.filter((m) => m.kind === 'video').length, photos = items.length - videos;
    const parts: string[] = [];
    if (photos > 0) parts.push(L('grid.photos', photos));
    if (videos > 0) parts.push(L('grid.videos', videos));
    return parts.join(L('list.separator'));
  }, [items]);

  const selectedMedia = useMemo(() => entries.filter((e) => selected.has(e[0].media_id)).flat(), [entries, selected]);
  const selectedIds = selectedMedia.map((m) => m.media_id);
  const allSelected = entries.length > 0 && selected.size === entries.length;
  const setSel = useCallback((on: boolean) => { setSelecting(on); if (!on) setSelected(new Set()); }, []);

  // ⌘+ / ⌘− and the View menu; Esc ends selecting
  useEffect(() => onCommand('zoomIn', () => grid.current?.step(-1)), []);
  useEffect(() => onCommand('zoomOut', () => grid.current?.step(1)), []);
  useEffect(() => onCommand('select', () => setSelecting((s) => { if (s) setSelected(new Set()); return !s; })), []);
  useEffect(() => {
    if (!selecting) return;
    const k = (e: KeyboardEvent) => { if (e.key === 'Escape' && !document.querySelector('.viewer, .dialog-scrim, .menu-scrim')) setSel(false); };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [selecting, setSel]);

  // ── actions ──
  const afterTrash = (n: number, receipt: Awaited<ReturnType<typeof action>>) => { libraryChanged(); offerUndo(L('trash.moved', n), receipt); };
  const trash = async (o: { media?: string[]; posts?: string[] }) => {
    try { const r = await action('trash', o); if (r.changes.length) afterTrash(r.changes.length, r); } catch (e) { toast(L(String((e as Error).message))); }
  };
  const restore = async (ids?: string[]) => {
    try {
      const snap = await binSnapshot(ids ?? null);
      if (!snap.entries.length) return;
      const r = await action('restore', { expected: snap.entries, epoch: snap.epoch });
      setSel(false);
      binChanged();
      if (r.changes.length) toast(L('trash.restored', r.changes.length), { label: L('common.undo'), run: async () => { try { toast(L('undo.done', await undo(r))); } catch (e) { toast(L(String((e as Error).message))); } binChanged(); } });
    } catch (e) { toast(L(String((e as Error).message))); }
  };
  const purge = async (ids: string[] | null) => {
    try {
      const snap = await binSnapshot(ids);
      if (!snap.entries.length) return;
      const ok = await choose(ids == null ? L('trash.emptyTitle') : L('trash.purgeTitle'), L('trash.purgeMessage', L('trash.moved', snap.entries.length)), [L('common.deletePermanently')], { destructive: true });
      if (ok == null) return;
      const r = await action('purge', { expected: snap.entries, epoch: snap.epoch });
      setSel(false);
      binChanged();
      toast(L('trash.purged', r.changes.length) + (r.changes.length < snap.entries.length ? L('trash.purged.skipped') : ''));
    } catch (e) { await alertMessage(L('trash.unreadableShort'), L(String((e as Error).message))); }
  };
  const addTo = async (ids: string[], name: string) => {
    try {
      const r = await action('folder_add', { media: ids, folder: name });
      libraryChanged();
      setSel(false);
      toast(r.changes.length === 0 ? L('folder.allAlready', name) : L('folder.added', r.changes.length, name));
    } catch (e) { await alertMessage(L('common.couldNotAddToFolder'), L(String((e as Error).message))); }
  };
  const takeOut = async (ids: string[]) => {
    if (!folder) return;
    try {
      const r = await action('folder_remove', { media: ids, folder });
      libraryChanged();
      setSel(false);
      offerUndo(L('folder.removed', r.changes.length, folder), r);
    } catch (e) { toast(L(String((e as Error).message))); }
  };

  const daysLeft = (entry: FeedItem[]): string | null => {
    const at = entry.map((m) => data.data?.trashedAt.get(m.media_id)).filter((x): x is number => x != null);
    if (!at.length) return null;
    const keep = data.data?.keep ?? 30;
    if (keep === 0) return L('trash.keepForever');
    const d = keep - (Date.now() - Math.min(...at)) / 86_400_000;
    return d < 1 ? L('trash.deletingSoon') : L('trash.daysLeft', Math.ceil(d));
  };

  const tileMenu = (i: number): MenuEntry[] => {
    const entry = entries[i];
    if (!entry) return [];
    const first = entry[0];
    if (selecting) {
      const on = selected.has(first.media_id);
      return [{ label: on ? L('common.deselect') : L('common.select'), run: () => setSelected((s) => { const n = new Set(s); if (on) n.delete(first.media_id); else n.add(first.media_id); return n; }) }];
    }
    const ids = entry.map((m) => m.media_id);
    const m: MenuEntry[] = [];
    if (bin) {
      const left = daysLeft(entry);
      if (left) m.push({ label: left, disabled: true }, 'separator');
    }
    m.push({ label: L('common.select'), run: () => { setSelecting(true); setSelected(new Set([first.media_id])); } });
    if (bin) {
      const n = ids.length > 1 ? L('grid.countSuffix', ids.length) : '';
      m.push({ label: L('common.restore') + n, run: () => void restore(ids) }, 'separator', { label: L('common.deletePermanently') + n + '…', run: () => void purge(ids) });
      return m;
    }
    const loose = first.post_id.startsWith('loose:');
    m.push({ label: loose ? L('grid.revealMedia') : L('grid.revealPost'), run: () => revealInBrowse(first) });
    if (folder) m.push({ label: L('common.removeFromFolder'), run: async () => { await action('folder_remove', { media: ids, folder }).catch(() => null); libraryChanged(); } });
    m.push('separator');
    if (entry.length === 1) m.push({ label: L('grid.trashMedia'), run: () => void trash({ media: ids }) });
    if (!loose) m.push({ label: L('grid.trashPost'), run: () => void trash({ posts: [first.post_id] }) });
    return m;
  };

  const addToFolderMenu = (): MenuEntry[] => {
    const ids = selectedIds;
    const m: MenuEntry[] = (folders.get()?.folders ?? []).filter((f) => f.name !== folder).map((f) => ({ label: f.name, run: () => void addTo(ids, f.name) }));
    if (m.length) m.push('separator');
    m.push({ label: L('common.newFolderEllipsis'), run: async () => { const n = (await prompt(L('common.newFolder'), { placeholder: L('common.folderName') }))?.trim(); if (n) void addTo(ids, n); } });
    return m;
  };

  const exportFolderZip = async () => {
    if (!folder) return;
    const ids = entries.flatMap((e) => e.map((m) => m.media_id));
    if (!ids.length) { toast(L('export.search.none')); return; }
    toast(L('export.running', ids.length));
    try {
      const safe = folder.replace(/[\\/:*?"<>|]/g, '_');
      const report = await exportFile<ExportReport>(
        `${safe}.zip`,
        (out) => core.readJson<ExportReport>('tl_export_media', {
          media_ids: ids,
          options: { tags: false, folders: false, media_only: true },
          out,
        }),
      );
      if (!report) return;
      toast(`${L('export.done')} · ${L('export.summaryMedia', report.media, size(report.bytes))}`);
    } catch (e) {
      await alertMessage(L('export.failed'), e instanceof Error ? L(e.message) : L('common.notDone'));
    }
  };

  useEffect(() => {
    setMenuState({ onGrid: true, selecting });
    return () => setMenuState({ onGrid: false, selecting: false });
  }, [selecting]);

  const moreMenu = (): MenuEntry[] => {
    if (bin) {
      const keep = data.data?.keep ?? 30;
      return [
        { label: L('trash.autoDeleteMac', keepTitle(keep)), children: KEEP.map((d) => ({ label: keepTitle(d), checked: d === keep, run: async () => {
          await core.read(core.b.tl_set_trash_keep_days(d)).catch(() => null);
          await core.read(core.b.tl_trash_expire()).catch(() => null);
          binChanged();
        } })) },
        'separator',
        { label: L('trash.restoreAll'), run: () => void restore() },
        { label: L('trash.emptyEllipsis'), run: () => void purge(null) },
      ];
    }
    const m: MenuEntry[] = [{ label: L('grid.revealMedia'), run: () => go({ page: 'browse', q: browseQuery(place, folder) }) }];
    if (folder) m.push('separator',
      { label: L('folder.exportZip'), run: () => void exportFolderZip() },
      'separator',
      { label: L('folder.renameEllipsis'), run: () => void renameFolder(folder).then((n) => n && go(folderRoute(n))) },
      { label: L('folder.deleteEllipsis'), run: () => void deleteFolder(folder) });
    return m;
  };

  const trashSelected = async () => {
    if (!selectedIds.length) return;
    const ok = await choose(L('grid.trashConfirm.title'), L('grid.trashConfirm', selectedIds.length), [L('grid.moveToTrash')]);
    if (ok == null) return;
    try { const r = await action('trash', { media: selectedIds }); setSel(false); if (r.changes.length) afterTrash(r.changes.length, r); } catch (e) { toast(L(String((e as Error).message))); }
  };

  const subtitle = selecting ? (selectedMedia.length === 0 ? L('grid.selectItems') : L('grid.selected', selectedMedia.length)) : countsLine;
  const levels = grid.current?.levelCount() ?? 3;
  const has = selectedIds.length > 0;

  const toolbar = selecting ? (
    <>
      <ToolButton label={allSelected ? L('grid.deselectAll') : L('grid.selectAll')} onClick={() => setSelected(allSelected ? new Set() : new Set(entries.map((e) => e[0].media_id)))}>{allSelected ? L('grid.deselectAll') : L('grid.selectAll')}</ToolButton>
      {bin ? <>
        <ToolButton label={L('common.restore')} disabled={!has} onClick={() => void restore(selectedIds)}><Undo2 size={16} strokeWidth={1.9} /></ToolButton>
        <ToolButton label={L('common.deletePermanently')} disabled={!has} onClick={() => void purge(selectedIds)}><Trash2 size={16} strokeWidth={1.9} /></ToolButton>
      </> : <>
        <ToolButton label={L('common.addToFolder')} disabled={!has} onClick={(e) => openMenuBelow(e.currentTarget, addToFolderMenu())}><FolderPlus size={16} strokeWidth={1.9} /></ToolButton>
        {folder && <ToolButton label={L('common.removeFromFolder')} disabled={!has} onClick={() => void takeOut(selectedIds)}><FolderMinus size={16} strokeWidth={1.9} /></ToolButton>}
        <ToolButton label={L('grid.moveToTrash')} disabled={!has} onClick={() => void trashSelected()}><Trash2 size={16} strokeWidth={1.9} /></ToolButton>
      </>}
      <ToolButton label={L('common.done')} prominent onClick={() => setSel(false)}>{L('common.done')}</ToolButton>
    </>
  ) : (
    <>
      <ToolGroup>
        <ToolSegment label={L('grid.zoomOut')} disabled={level <= 0} onClick={() => grid.current?.step(1)}><Minus size={16} strokeWidth={2} /></ToolSegment>
        <ToolSegment label={L('grid.zoomIn')} disabled={level >= levels - 1} onClick={() => grid.current?.step(-1)}><Plus size={16} strokeWidth={2} /></ToolSegment>
      </ToolGroup>
      <ToolButton label={L('common.select')} disabled={!entries.length} onClick={() => setSelecting(true)}>{L('common.select')}</ToolButton>
      <ToolButton label={L('grid.more')} onClick={(e) => openMenuBelow(e.currentTarget, moreMenu())}><Ellipsis size={17} strokeWidth={2} /></ToolButton>
    </>
  );

  return (
    <div className="grid-page">
      <ZoomGrid ref={grid} tiles={tiles} footer={countsLine} selecting={selecting} selected={selected} initialLevel={level} insetTop={52}
        onOpen={(i) => {
          const list = grouped() ? entries.flat() : items;
          const first = entries[i]?.[0];
          if (!first) return;
          openViewer(list, Math.max(0, list.indexOf(first)), {
            source: (id) => {
              const cover = entries.find((entry) => entry.some((item) => item.media_id === id))?.[0];
              return cover && grid.current?.sourceFrame(cover.media_id);
            },
            squarePreview: cachedThumb(first, 1024) ?? cachedThumb(first, 512) ?? cachedThumb(first, 256),
            onClose: () => grid.current?.focus(),
          });
        }}
        onMenu={(i, e) => openMenu(e, tileMenu(i))}
        onSelected={setSelected}
        onSettle={(l) => { setLevel(l); writePref('grid.level', String(l)); }} />
      {data.data && !entries.length && <div className="grid-empty">{bin ? L('grid.trashEmpty') : L('grid.empty')}</div>}
      <Toolbar overlay pill title={title(place, folder)} subtitle={subtitle} back={place === 'folder' && !selecting ? () => go({ page: 'folders' }) : undefined}>
        {toolbar}
      </Toolbar>
    </div>
  );
}
