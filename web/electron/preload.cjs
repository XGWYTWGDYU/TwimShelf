// What the page may know about and ask of the desktop app (nothing more is exposed): the
// platform, the system's own menus (context menus and the menu bar, so they are the real ones),
// the window's chrome while the media viewer covers it, and showing a file in the file manager.
const { contextBridge, ipcRenderer } = require('electron');

const menuListeners = new Set();
ipcRenderer.on('app-menu', (_e, id) => { for (const f of menuListeners) f(id); });

contextBridge.exposeInMainWorld('twimshelf', {
  desktop: true,
  platform: process.platform,
  /** A context menu at the pointer: [{id, label, enabled, checked, danger, children}] or 'separator'.
   *  Resolves to the chosen item's id, or null when the menu was dismissed. */
  popupMenu: (items, x, y) => ipcRenderer.invoke('popup-menu', items, x, y),
  /** The menu bar: [{label, items: [{id, label, accel, role, enabled, checked}]}]. */
  setAppMenu: (menus) => ipcRenderer.send('set-app-menu', menus),
  onAppMenu: (f) => { menuListeners.add(f); return () => menuListeners.delete(f); },
  /** The viewer covers the window: no window buttons (macOS), as in the native app. */
  setViewerMode: (on) => ipcRenderer.send('viewer-mode', !!on),
  toggleFullScreen: () => ipcRenderer.send('toggle-fullscreen'),
  saveFile: (url, name) => ipcRenderer.invoke('save-file', url, name),
  showItemInFolder: (path) => ipcRenderer.send('show-item', String(path)),
  getMascotEnabled: () => ipcRenderer.invoke('get-mascot-enabled'),
  setMascotEnabled: (enabled) => ipcRenderer.invoke('set-mascot-enabled', !!enabled),
});
