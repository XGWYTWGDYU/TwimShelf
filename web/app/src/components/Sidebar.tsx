import { useEffect, type ReactNode } from 'react';
import { CheckCircle2, Folder, GalleryVerticalEnd, Image, Images, Layers2, LogOut, Settings, SquareDashed, TriangleAlert, Trash2, Video, BadgeCheck } from 'lucide-react';
import { L, store } from '@twimshelf/core';
import { useStore } from '../lib/hooks';
import { folders, stats } from '../lib/library';
import { folderRoute, go, href, useRoute, type Route } from '../lib/router';
import { openMenu, type MenuEntry } from './Menu';
import { createFolder, deleteFolder, renameFolder } from '../lib/folderActions';
import { MascotSwap, useMascotPress, type MascotName } from './Mascot';
import './Sidebar.css';

function readNumber(k: string, d: number): number { try { const v = Number(localStorage.getItem(k)); return v > 0 ? v : d; } catch { return d; } }
function save(k: string, v: string): void { try { localStorage.setItem(k, v); } catch { /* private window */ } }

const width = store(Math.min(320, Math.max(190, readNumber('sidebar.width', 242))));

function same(a: Route, b: Route): boolean {
  return href(a) === href(b);
}

function Row({ to, icon, mascotName, label, count, tint, menu }: { to: Route; icon: ReactNode; mascotName?: MascotName; label: string; count?: number | null; tint?: string; menu?: () => MenuEntry[] }) {
  const r = useRoute();
  const on = same(r, to) || (to.page === 'settings' && r.page === 'settings');
  const { mascot, phase, pulse } = useMascotPress(mascotName);
  const activate = () => { pulse(); go(to); };
  return (
    <div className={`side-row${on ? ' on' : ''}`} role="treeitem" tabIndex={0} aria-selected={on}
      onMouseDown={(e) => { if (e.button === 0) activate(); }}
      onClick={(e) => { if (e.detail === 0) activate(); }}
      onKeyDown={(e) => {
        if (e.key !== 'Enter' && e.key !== ' ') return;
        e.preventDefault();
        activate();
      }}
      onContextMenu={menu ? (e) => openMenu(e, menu()) : undefined}>
      <span className="side-icon" style={tint ? { color: tint } : undefined}><MascotSwap name={mascot} phase={phase} size={20}>{icon}</MascotSwap></span>
      <span className="side-label">{label}</span>
      {count != null && <span className="side-count">{count}</span>}
    </div>
  );
}

function Section({ title, children, menu }: { title: string; children: ReactNode; menu?: () => MenuEntry[] }) {
  return (
    <div className="side-section" role="group">
      <div className="side-title" onContextMenu={menu ? (e) => openMenu(e, menu()) : undefined}>{title}</div>
      {children}
    </div>
  );
}

const newFolderMenu = (): MenuEntry[] => [{ label: L('common.newFolderEllipsis'), run: () => void createFolder().then((n) => n && go(folderRoute(n))) }];

export function Sidebar() {
  const s = useStore(stats);
  const f = useStore(folders);
  const w = useStore(width);
  const r = useRoute();
  const z = 16, sw = 2;

  // a folder that was open and is gone: back to all folders
  useEffect(() => {
    if (r.page === 'grid' && r.place === 'folder' && f && !f.folders.some((x) => x.name === r.folder)) go({ page: 'folders' });
  }, [f, r]);

  const folderMenu = (name: string) => (): MenuEntry[] => [
    { label: L('folder.renameShort'), run: () => void renameFolder(name).then((n) => { if (n && r.page === 'grid' && r.folder === name) go(folderRoute(n)); }) },
    { label: L('folder.deleteNamed', name), run: () => void deleteFolder(name) },
    'separator',
    ...newFolderMenu(),
  ];
  const trashed = s?.trashed ?? 0;
  return (
    <nav className="sidebar" style={{ width: w }} role="tree" aria-label="sidebar">
      <div className="side-top" />
      <div className="side-scroll">
        <Section title={L('sidebar.library')}>
          <Row to={{ page: 'browse' }} mascotName="home" icon={<Layers2 size={z} strokeWidth={sw} />} label={L('place.browse')} />
          <Row to={{ page: 'settings' }} mascotName="settings" icon={<Settings size={z} strokeWidth={sw} />} label={L('place.settings')} />
        </Section>
        <Section title={L('sidebar.mediaTypes')}>
          <Row to={{ page: 'grid', place: 'photos' }} mascotName="image" icon={<Image size={z} strokeWidth={sw} />} label={L('place.photos')} count={f?.photos ?? s?.photos} />
          <Row to={{ page: 'grid', place: 'videos' }} mascotName="video" icon={<Video size={z} strokeWidth={sw} />} label={L('place.videos')} count={f?.videos ?? s?.videos} />
        </Section>
        <Section title={L('place.folders')} menu={newFolderMenu}>
          <Row to={{ page: 'folders' }} mascotName="folder" icon={<GalleryVerticalEnd size={z} strokeWidth={sw} />} label={L('place.folders')} menu={newFolderMenu} />
          {f?.folders.map((x) => (
            <Row key={x.name} to={folderRoute(x.name)} mascotName="folder" icon={<Folder size={z} strokeWidth={sw} />} label={x.name} count={x.count} menu={folderMenu(x.name)} />
          ))}
        </Section>
        <Section title={L('sidebar.other')}>
          <Row to={{ page: 'grid', place: 'loose' }} icon={<SquareDashed size={z} strokeWidth={sw} />} label={L('place.loose')} />
          <Row to={{ page: 'grid', place: 'album' }} icon={<Images size={z} strokeWidth={sw} />} label={L('place.album')} />
          <Row to={{ page: 'grid', place: 'unreviewed' }} icon={<BadgeCheck size={z} strokeWidth={sw} className="seal-open" />} label={L('place.unreviewed')} />
          <Row to={{ page: 'grid', place: 'reviewed' }} icon={<CheckCircle2 size={z} strokeWidth={sw} />} label={L('place.reviewed')} />
          {(s?.bad ?? 0) > 0 && <Row to={{ page: 'grid', place: 'bad' }} icon={<TriangleAlert size={z} strokeWidth={sw} />} label={L('place.bad')} count={s?.bad} tint="var(--danger)" />}
          <Row to={{ page: 'grid', place: 'trash' }} icon={<Trash2 size={z} strokeWidth={sw} />} label={L('place.trash')} count={trashed > 0 ? trashed : null} />
        </Section>
      </div>
      {!window.twimshelf && (
        <div className="side-footer">
          <button
            type="button"
            className="side-row side-logout"
            onClick={() => { location.href = '/logout'; }}
          >
            <span className="side-icon"><LogOut size={z} strokeWidth={sw} /></span>
            <span className="side-label">{L('settings.signOut')}</span>
          </button>
        </div>
      )}
      <div className="side-resize" onMouseDown={(e) => {
        const x = e.clientX;
        const move = (ev: MouseEvent) => width.set(Math.min(320, Math.max(190, w + ev.clientX - x)));
        const up = () => { save('sidebar.width', String(width.get())); window.removeEventListener('mousemove', move); window.removeEventListener('mouseup', up); };
        window.addEventListener('mousemove', move);
        window.addEventListener('mouseup', up);
      }} />
    </nav>
  );
}
