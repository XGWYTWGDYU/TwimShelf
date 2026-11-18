import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import { loadMascotPreference } from './components/Mascot';
import { loadLanguage } from './lib/core';
import { refreshLibrary } from './lib/library';
import './theme.css';

const html = document.documentElement;
const mac = window.twimshelf?.platform === 'darwin' || (!window.twimshelf && /Mac/.test(navigator.platform));
if (mac) html.classList.add('platform-mac');
// the macOS desktop window has its buttons over the sidebar's top
if (window.twimshelf?.platform === 'darwin') html.classList.add('mac-titlebar');
// the Linux desktop window has its buttons over the toolbar, on the side the desktop puts them
if (window.twimshelf?.platform === 'linux') html.classList.add('linux-titlebar');
if (window.twimshelf) html.classList.add('desktop');

// An app, not a page. No browser menu (Back, Reload, Inspect…) on a right click outside text
// fields: places that have a menu of their own open it. No page zoom from a pinch or ⌘± (the
// grid and the viewer use the pinch themselves).
window.addEventListener('contextmenu', (e) => {
  const t = e.target as Element | null;
  if (t?.closest?.('input, textarea, [contenteditable="true"], .selectable')) return;
  e.preventDefault();
});
window.addEventListener('wheel', (e) => { if (e.ctrlKey) e.preventDefault(); }, { passive: false });
for (const t of ['gesturestart', 'gesturechange', 'gestureend']) window.addEventListener(t, (e) => e.preventDefault());
window.addEventListener('keydown', (e) => {
  if ((e.metaKey || e.ctrlKey) && ['=', '+', '-', '0'].includes(e.key) && !e.defaultPrevented) e.preventDefault();
});
// files dropped outside the import area do not navigate away
window.addEventListener('dragover', (e) => e.preventDefault());
window.addEventListener('drop', (e) => e.preventDefault());

Promise.allSettled([loadLanguage(), loadMascotPreference()])
  .finally(() => {
    refreshLibrary();
    createRoot(document.getElementById('root')!).render(<StrictMode><App /></StrictMode>);
  });
