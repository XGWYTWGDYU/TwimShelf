// The window: the sidebar and the page beside it (each page has its toolbar on top); when the
// media viewer is open, it fills only the content pane beside the sidebar.
import { Suspense, useEffect, useRef, useState } from 'react';
import { Sidebar } from './components/Sidebar';
import { Toasts } from './components/toast';
import { MenuHost } from './components/Menu';
import { DropImport } from './components/DropImport';
import { PetLayer } from './components/PetLayer';
import { ActivityPanel } from './components/ActivityPanel';
import { WelcomeHost } from './components/WelcomeModal';
import { go, useRoute, type GridPlace, type Route } from './lib/router';
import { installAppMenu } from './lib/commands';
import { core, desktop } from './lib/core';
import { useStore } from './lib/hooks';
import { folders } from './lib/library';
import { checkExtensionUpdate, checkForUpdate, requestExtensionAutoCheck } from './lib/update';
import { enableAutoTagging } from './pages/settings/aiTagging';
import { closeViewerImmediately, ViewerHost } from './viewer/Viewer';
import BrowsePage from './pages/browse/BrowsePage';
import './App.css';

import GridPage from './pages/grid/GridPage';
import FoldersPage from './pages/FoldersPage';
import TagsPage from './pages/TagsPage';
import SettingsPage from './pages/settings/SettingsPage';

type PageSlot =
  | { key: string; kind: 'grid'; place: GridPlace; folder?: string }
  | { key: 'folders'; kind: 'folders' }
  | { key: 'tags'; kind: 'tags' }
  | { key: 'settings'; kind: 'settings' };

function slotOf(r: Route): PageSlot | null {
  switch (r.page) {
    case 'browse': return null;
    case 'grid': return { key: `grid:${r.place}:${r.folder ?? ''}`, kind: 'grid', place: r.place, folder: r.folder };
    case 'folders': return { key: 'folders', kind: 'folders' };
    case 'tags': return { key: 'tags', kind: 'tags' };
    case 'settings': return { key: 'settings', kind: 'settings' };
  }
}

export default function App() {
  const r = useRoute();
  const folderList = useStore(folders);
  useEffect(installAppMenu, []);
  useEffect(() => {
    enableAutoTagging();
    void core.read(core.b.tl_trash_expire()).catch(() => {});
    const t = window.setTimeout(() => void checkForUpdate(false), 4000);
    const tExt = desktop ? window.setTimeout(() => void checkExtensionUpdate(false), 5500) : 0;
    const poll = desktop
      ? window.setInterval(() => {
        void core.b.tl_ext_take_open_settings().then((open) => {
          if (!open) return;
          window.twimshelf?.focusWindow?.();
          requestExtensionAutoCheck();
          go({ page: 'settings', sub: 'extension' });
        }).catch(() => {});
      }, 1200)
      : 0;
    return () => {
      window.clearTimeout(t);
      if (tExt) window.clearTimeout(tExt);
      if (poll) window.clearInterval(poll);
    };
  }, []);
  // 浏览 keeps its search while another page is shown; every other visited page stays mounted too
  const lastBrowse = useRef<Extract<Route, { page: 'browse' }>>({ page: 'browse' });
  if (r.page === 'browse') lastBrowse.current = r;
  const lastSettingsSub = useRef<string | undefined>(undefined);
  if (r.page === 'settings') lastSettingsSub.current = r.sub;
  const currentSlot = slotOf(r);
  const [mounted, setMounted] = useState<PageSlot[]>(() => (currentSlot ? [currentSlot] : []));
  useEffect(() => {
    if (!currentSlot) return;
    setMounted((prev) => (prev.some((s) => s.key === currentSlot.key) ? prev : [...prev, currentSlot]));
  }, [currentSlot?.key]);
  // evict cached folder pages once their folder is deleted
  useEffect(() => {
    if (!folderList) return;
    const live = new Set(folderList.folders.map((f) => f.name));
    setMounted((prev) => {
      const next = prev.filter((s) => !(s.kind === 'grid' && s.place === 'folder' && s.folder && !live.has(s.folder)));
      return next.length === prev.length ? prev : next;
    });
  }, [folderList]);
  const prevRoute = useRef(r);
  useEffect(() => {
    if (prevRoute.current !== r) {
      prevRoute.current = r;
      closeViewerImmediately();
    }
  }, [r]);
  return (
    <div className="app">
      <Sidebar />
      <main className="main">
        {/* Every visited page stays mounted (hidden when inactive) for instant sidebar switching */}
        <div className="main-page" hidden={r.page !== 'browse'}><BrowsePage route={lastBrowse.current} active={r.page === 'browse'} /></div>
        {mounted.map((slot) => {
          const active = currentSlot?.key === slot.key;
          return (
            <div key={slot.key} className="main-page" hidden={!active}>
              <Suspense fallback={null}>
                {slot.kind === 'grid' && <GridPage place={slot.place} folder={slot.folder} active={active} />}
                {slot.kind === 'folders' && <FoldersPage />}
                {slot.kind === 'tags' && <TagsPage />}
                {slot.kind === 'settings' && <SettingsPage sub={active && r.page === 'settings' ? r.sub : lastSettingsSub.current} active={active} />}
              </Suspense>
            </div>
          );
        })}
        <ActivityPanel />
        <ViewerHost />
      </main>
      <PetLayer />
      <Toasts />
      <MenuHost />
      <DropImport />
      <WelcomeHost />
    </div>
  );
}
