import { Folder, Folders, Image, Images, Layers, Settings, Trash2, Video, Shapes, CircleAlert, CircleCheck, Tags } from 'lucide-react';
import type { ReactNode } from 'react';
import { L } from '@twimshelf/core';
import { useStore } from '../lib/hooks';
import { folders, stats } from '../lib/library';
import { href, useRoute, type Route } from '../lib/router';
import './Sidebar.css';

function same(a: Route, b: Route): boolean {
  return href(a) === href(b);
}

function Item({ to, icon, label, count }: { to: Route; icon: ReactNode; label: string; count?: number }) {
  const r = useRoute();
  const on = same(r, to) || (to.page === 'settings' && r.page === 'settings');
  return (
    <a className={`side-item${on ? ' on' : ''}`} href={href(to)}>
      <span className="side-icon">{icon}</span>
      <span className="side-label">{label}</span>
      {count !== undefined && <span className="side-count">{count}</span>}
    </a>
  );
}

export function Sidebar() {
  const s = useStore(stats);
  const f = useStore(folders);
  const z = 16;
  return (
    <nav className="sidebar">
      <div className="side-group">
        <Item to={{ page: 'browse' }} icon={<Layers size={z} />} label={L('place.browse')} />
        <Item to={{ page: 'settings' }} icon={<Settings size={z} />} label={L('place.settings')} />
      </div>
      <div className="side-title">{L('sidebar.mediaTypes')}</div>
      <div className="side-group">
        <Item to={{ page: 'browse', kind: 'photo' }} icon={<Image size={z} />} label={L('place.photos')} count={s?.photos} />
        <Item to={{ page: 'browse', kind: 'video' }} icon={<Video size={z} />} label={L('place.videos')} count={s?.videos} />
      </div>
      <div className="side-title">{L('place.folders')}</div>
      <div className="side-group">
        <Item to={{ page: 'folders' }} icon={<Folders size={z} />} label={L('place.folders')} />
        {f?.folders.map((x) => (
          <Item key={x.name} to={{ page: 'browse', folder: x.name }} icon={<Folder size={z} />} label={x.name} count={x.count} />
        ))}
      </div>
      <div className="side-title">{L('sidebar.other')}</div>
      <div className="side-group">
        <Item to={{ page: 'browse', view: 'loose' }} icon={<Shapes size={z} />} label={L('place.loose')} />
        <Item to={{ page: 'browse', view: 'album' }} icon={<Images size={z} />} label={L('place.album')} />
        <Item to={{ page: 'browse', view: 'unreviewed' }} icon={<CircleAlert size={z} />} label={L('place.unreviewed')} />
        <Item to={{ page: 'browse', view: 'reviewed' }} icon={<CircleCheck size={z} />} label={L('place.reviewed')} />
        <Item to={{ page: 'tags' }} icon={<Tags size={z} />} label={L('common.tags')} />
        <Item to={{ page: 'bin' }} icon={<Trash2 size={z} />} label={L('place.trash')} count={s?.trashed || undefined} />
      </div>
    </nav>
  );
}
