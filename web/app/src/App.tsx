// The window: sidebar on the left, the current page on the right.
import { lazy, Suspense } from 'react';
import { Sidebar } from './components/Sidebar';
import { Toasts } from './components/toast';
import { Spinner } from './components/ui';
import { useRoute } from './lib/router';
import BrowsePage from './pages/browse/BrowsePage';
import './App.css';

const FoldersPage = lazy(() => import('./pages/FoldersPage'));
const TagsPage = lazy(() => import('./pages/TagsPage'));
const BinPage = lazy(() => import('./pages/BinPage'));
const SettingsPage = lazy(() => import('./pages/settings/SettingsPage'));

export default function App() {
  const r = useRoute();
  return (
    <div className="app">
      <Sidebar />
      <main className="main">
        <Suspense fallback={<div className="center"><Spinner /></div>}>
          {r.page === 'browse' && <BrowsePage route={r} />}
          {r.page === 'folders' && <FoldersPage />}
          {r.page === 'tags' && <TagsPage />}
          {r.page === 'bin' && <BinPage />}
          {r.page === 'settings' && <SettingsPage sub={r.sub} />}
        </Suspense>
      </main>
      <Toasts />
    </div>
  );
}
