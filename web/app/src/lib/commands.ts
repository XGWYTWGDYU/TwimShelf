// The menu bar's commands (AppDelegate.buildMenu), with the same shortcuts. The desktop app shows
// them as the system's own menu bar; the web page answers the same keys itself. A page that can do a
// command (the grid zooms, 浏览 reshuffles) registers for it while it is shown.
import { L } from '@twimshelf/core';
import type { NativeMenuItem } from './core';
import { createFolder } from './folderActions';
import { folderRoute, go, route } from './router';

export type Command = 'newFolder' | 'zoomIn' | 'zoomOut' | 'select' | 'groupByPost' | 'reshuffle' | 'fullScreen'
  | 'goBrowse' | 'goFolders' | 'goPhotos' | 'goVideos' | 'settings';

export interface MenuState {
  onBrowse: boolean;
  onGrid: boolean;
  selecting: boolean;
  grouped: boolean;
  byAdded: boolean;
  searching: boolean;
}

const menuState: MenuState = {
  onBrowse: true,
  onGrid: false,
  selecting: false,
  grouped: true,
  byAdded: false,
  searching: false,
};

let pushMenu: (() => void) | null = null;

export function setMenuState(patch: Partial<MenuState>): void {
  let changed = false;
  for (const [k, v] of Object.entries(patch) as Array<[keyof MenuState, boolean]>) {
    if (menuState[k] !== v) {
      menuState[k] = v;
      changed = true;
    }
  }
  if (changed) pushMenu?.();
}

const handlers = new Map<Command, Set<() => void>>();

/** Handles `c` until the returned function is called (a page's effect). */
export function onCommand(c: Command, f: () => void): () => void {
  let set = handlers.get(c);
  if (!set) handlers.set(c, (set = new Set()));
  set.add(f);
  return () => { set.delete(f); };
}

export function run(c: Command): void {
  switch (c) {
    case 'newFolder': void createFolder().then((n) => n && go(folderRoute(n))); return;
    case 'goBrowse': go({ page: 'browse' }); return;
    case 'goFolders': go({ page: 'folders' }); return;
    case 'goPhotos': go({ page: 'grid', place: 'photos' }); return;
    case 'goVideos': go({ page: 'grid', place: 'videos' }); return;
    case 'settings':
      if (route.get().page === 'settings') go({ page: 'browse' });
      else go({ page: 'settings' });
      return;
    case 'fullScreen':
      if (window.twimshelf?.toggleFullScreen) window.twimshelf.toggleFullScreen();
      else if (document.fullscreenElement) void document.exitFullscreen(); else void document.documentElement.requestFullscreen().catch(() => {});
      return;
  }
  for (const f of handlers.get(c) ?? []) f();
}

const app = 'TwimShelf';
const item = (
  id: Command,
  label: string,
  accel?: string,
  extra?: { enabled?: boolean; checked?: boolean },
): NativeMenuItem => ({ id, label, accel, ...extra });

/** The desktop app's menu bar, in the user's language, kept in sync with the active page state. */
export function installAppMenu(): () => void {
  const t = window.twimshelf;
  if (!t?.setAppMenu || !t.onAppMenu) return installKeys();
  const mac = t.platform === 'darwin';
  const build = () => {
    t.setAppMenu!([
      ...(mac ? [{ label: app, items: [
        { role: 'about', label: L('menu.about').replace('{app}', app) },
        'separator' as const,
        item('settings', L('menu.manage'), 'CmdOrCtrl+,'),
        'separator' as const,
        { role: 'hide', label: L('menu.hide').replace('{app}', app) },
        { role: 'quit', label: L('menu.quit').replace('{app}', app) },
      ] }] : []),
      { label: L('menu.file'), items: [
        item('newFolder', L('common.newFolderEllipsis'), 'CmdOrCtrl+Shift+N'),
        'separator',
        { role: 'close', label: L('menu.closeWindow') },
        ...(mac ? [] : ['separator' as const, { role: 'quit', label: L('menu.quit').replace('{app}', app) }]),
      ] },
      { label: L('menu.edit'), items: [
        { role: 'undo', label: L('common.undo') },
        { role: 'redo', label: L('menu.redo') },
        'separator',
        { role: 'cut', label: L('menu.cut') },
        { role: 'copy', label: L('menu.copy') },
        { role: 'paste', label: L('menu.paste') },
        { role: 'selectAll', label: L('grid.selectAll') },
        'separator',
        item('select', L('common.select'), undefined, { enabled: menuState.onGrid, checked: menuState.onGrid && menuState.selecting }),
      ] },
      { label: L('menu.view'), items: [
        item('zoomIn', L('grid.zoomIn'), 'CmdOrCtrl+Plus', { enabled: menuState.onGrid }),
        item('zoomOut', L('grid.zoomOut'), 'CmdOrCtrl+-', { enabled: menuState.onGrid }),
        'separator',
        item('groupByPost', L('feed.groupByPost'), undefined, { enabled: menuState.onBrowse, checked: menuState.grouped }),
        item('reshuffle', L('feed.reshuffle'), 'CmdOrCtrl+R', { enabled: menuState.onBrowse && !menuState.byAdded && !menuState.searching }),
        'separator',
        item('fullScreen', L('menu.fullScreen'), mac ? 'Ctrl+Cmd+F' : 'F11'),
      ] },
      { label: L('menu.go'), items: [
        item('goBrowse', L('place.browse'), 'CmdOrCtrl+1'),
        item('goFolders', L('place.folders'), 'CmdOrCtrl+2'),
        item('goPhotos', L('place.photos'), 'CmdOrCtrl+3'),
        item('goVideos', L('place.videos'), 'CmdOrCtrl+4'),
      ] },
      { label: L('menu.window'), role: 'windowMenu', items: [
        { role: 'minimize', label: L('menu.minimize') },
        { role: 'zoom', label: L('grid.zoom') },
      ] },
    ]);
  };
  pushMenu = build;
  build();
  const off = t.onAppMenu((id) => run(id as Command));
  return () => { pushMenu = null; off(); };
}

/** The web page: the same shortcuts, answered by the page. */
function installKeys(): () => void {
  const key = (e: KeyboardEvent) => {
    if (e.key === 'F11' && !e.metaKey && !e.ctrlKey && !e.altKey) {
      e.preventDefault();
      run('fullScreen');
      return;
    }
    if (!(e.metaKey || e.ctrlKey) || e.altKey) return;
    if ((e.target as Element | null)?.closest?.('input, textarea, [contenteditable="true"]') && !/^[1-4]$/.test(e.key)) return;
    const k = e.key.toLowerCase();
    let c: Command | null = null;
    if (k === 'n' && e.shiftKey) c = 'newFolder';
    else if ((k === '=' || k === '+') && !e.shiftKey) c = 'zoomIn';
    else if (k === '+') c = 'zoomIn';
    else if (k === '-') c = 'zoomOut';
    else if (k === 'r' && !e.shiftKey && menuState.onBrowse && !menuState.byAdded && !menuState.searching) c = 'reshuffle';
    else if (k === '1') c = 'goBrowse';
    else if (k === '2') c = 'goFolders';
    else if (k === '3') c = 'goPhotos';
    else if (k === '4') c = 'goVideos';
    else if (k === ',') c = 'settings';
    if (!c) return;
    e.preventDefault();
    run(c);
  };
  window.addEventListener('keydown', key);
  return () => window.removeEventListener('keydown', key);
}
