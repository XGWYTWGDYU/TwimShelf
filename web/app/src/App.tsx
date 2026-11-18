// The window: the sidebar and the page beside it (each page has its toolbar on top), and over
// both the media viewer when one is open (it takes the whole window, as in the native app).
import { Suspense, useEffect, useRef } from 'react';
import { Sidebar } from './components/Sidebar';
import { Toasts } from './components/toast';
import { MenuHost } from './components/Menu';
import { DropImport } from './components/DropImport';
import { PetLayer } from './components/PetLayer';
import { useRoute, type Route } from './lib/router';
import { installAppMenu } from './lib/commands';
import { ViewerHost } from './viewer/Viewer';
import BrowsePage from './pages/browse/BrowsePage';
import './App.css';

import GridPage from './pages/grid/GridPage';
import FoldersPage from './pages/FoldersPage';
import TagsPage from './pages/TagsPage';
import SettingsPage from './pages/settings/SettingsPage';

export default function App() {
  const r = useRoute();
  useEffect(installAppMenu, []);
  // 浏览 keeps its search while another page is shown
  const lastBrowse = useRef<Extract<Route, { page: 'browse' }>>({ page: 'browse' });
  if (r.page === 'browse') lastBrowse.current = r;
  return (
    <div className="app">
      <Sidebar />
      <main className="main">
        {/* 浏览 stays loaded underneath (its position and search survive), as in the native app */}
        <div className="main-page" hidden={r.page !== 'browse'}><BrowsePage route={lastBrowse.current} active={r.page === 'browse'} /></div>
        {r.page !== 'browse' && (
          <div className="main-page">
            <Suspense fallback={null}>
              {r.page === 'grid' && <GridPage key={r.place + (r.folder ?? '')} place={r.place} folder={r.folder} />}
              {r.page === 'folders' && <FoldersPage />}
              {r.page === 'tags' && <TagsPage />}
              {r.page === 'settings' && <SettingsPage sub={r.sub} />}
            </Suspense>
          </div>
        )}
      </main>
      <PetLayer />
      <ViewerHost />
      <Toasts />
      <MenuHost />
      <DropImport />
    </div>
  );
}
