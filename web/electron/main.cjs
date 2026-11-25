// The TwimShelf desktop app (Linux; a macOS build exists for testing only): starts the bundled
// TwimShelf server on 127.0.0.1 with a token only this app knows, and shows the React app the
// server serves. The window and the web page are the same code; only the server is local.
const { app, BrowserWindow, Menu, dialog, ipcMain, nativeTheme, screen, session, shell } = require('electron');
const { spawn } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');

const product = (() => {
  try { return require('./product.json'); } catch { return {}; }
})();

// what the app is called and its version: config.yaml, written to product.json by scripts/apply.py;
// icon.png is committed beside this file
const name = product.name || 'TwimShelf';
const icon = path.join(__dirname, 'icon.png');
app.setName(name);
if (product.appId && process.platform === 'linux') app.setDesktopName(`${product.appId}.desktop`);
app.setAboutPanelOptions({
  applicationName: name,
  applicationVersion: product.version || app.getVersion(),
  version: product.buildNumber || '',
  ...(fs.existsSync(icon) ? { iconPath: icon } : {}),
});

if (!app.requestSingleInstanceLock()) app.exit(0);

let server = null;
let win = null;

/** Where the data lives. Linux: where the Flutter app kept it, so an upgrade finds the library. */
function dataPaths() {
  // development and tests: a library given explicitly
  if (process.env.TL_DATA) return { TL_DATA: process.env.TL_DATA };
  if (process.platform === 'linux') {
    const share = process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share');
    // the Flutter app's data: the folder its owner chose (location.json), or its default one
    let flutter = product.desktopId ? path.join(share, product.desktopId) : null;
    try {
      const config = process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config');
      const chosen = JSON.parse(fs.readFileSync(path.join(config, 'twimshelf', 'location.json'), 'utf8')).path;
      if (typeof chosen === 'string' && fs.existsSync(path.join(chosen, 'Library'))) flutter = chosen;
    } catch { /* no folder was chosen */ }
    const data = path.join(share, 'TwimShelf');
    const env = { TL_DATA: data };
    if (flutter && fs.existsSync(path.join(flutter, 'Library'))) {
      env.TL_LIBRARY = path.join(flutter, 'Library');
      if (fs.existsSync(path.join(flutter, 'Models'))) env.TL_MODELS = path.join(flutter, 'Models');
    }
    return env;
  }
  // the macOS test build: a folder of its own, never the native app's library
  return { TL_DATA: path.join(app.getPath('appData'), 'TwimShelf Electron Test') };
}

function freePort(wanted = 0) {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.once('error', reject);
    s.listen(wanted, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)); });
  });
}

/** The same port as last time when it is free: the page's settings (kept per address) and the
 *  browser extension's pairing stay valid from one start to the next. */
async function steadyPort(data) {
  const file = path.join(data, 'desktop-port');
  let last = 0;
  try { last = Number(fs.readFileSync(file, 'utf8')) || 0; } catch { /* the first start */ }
  const port = last >= 1024 && last <= 65535 ? await freePort(last).catch(() => freePort()) : await freePort();
  if (port !== last) fs.writeFileSync(file, String(port));
  return port;
}

function serverBinary() {
  if (process.env.TL_SERVER_BIN) return process.env.TL_SERVER_BIN;
  const name = process.platform === 'win32' ? 'twimshelf-server.exe' : 'twimshelf-server';
  return path.join(process.resourcesPath, 'server', name);
}

function webFolder() {
  return process.env.TL_WEB || path.join(process.resourcesPath, 'web');
}

function applicationPaths() {
  const runtime = process.platform === 'darwin'
    ? [path.resolve(process.execPath, '../../..')]
    : [process.execPath, process.resourcesPath];
  if (!app.isPackaged) return [...runtime, app.getAppPath(), serverBinary(), webFolder()];
  return process.platform === 'linux' && process.env.APPIMAGE ? [process.env.APPIMAGE] : runtime;
}

async function startServer() {
  const paths = dataPaths();
  fs.mkdirSync(paths.TL_DATA, { recursive: true });
  const port = await steadyPort(paths.TL_DATA);
  const token = crypto.randomBytes(32).toString('hex');
  const env = {
    ...process.env, ...paths, TL_PORT: String(port), TL_WEB: webFolder(), TL_DESKTOP_TOKEN: token,
    TL_DESKTOP_APP_PATHS: JSON.stringify(applicationPaths()),
    TL_DEVICE_NAME: `TwimShelf · ${os.hostname()}`,
  };
  const log = fs.openSync(path.join(env.TL_DATA, 'desktop-server.log'), 'a');
  // its standard input stays open while this app lives: the server ends when it closes
  server = spawn(serverBinary(), [], { env, stdio: ['pipe', log, log] });
  fs.closeSync(log);
  server.on('exit', (code) => {
    server = null;
    if (!app.isQuitting) { console.error(`server ended (${code})`); app.quit(); }
  });
  const base = `http://127.0.0.1:${port}`;
  for (let i = 0; i < 200; i++) {
    // answered with this start's token: our server, not something else on that port
    try { const r = await fetch(`${base}/api/info`, { headers: { cookie: `tl_desktop=${token}` } }); if (r.ok) return { base, token }; } catch { /* not yet */ }
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error('the server did not start');
}

const startedHidden = process.argv.includes('--autostart');

function boundsFile() { return path.join(dataPaths().TL_DATA, 'window-bounds.json'); }

function loadBounds() {
  try {
    const b = JSON.parse(fs.readFileSync(boundsFile(), 'utf8'));
    if (!b || !Number.isFinite(b.width) || !Number.isFinite(b.height)) return null;
    const width = Math.max(720, Math.round(b.width));
    const height = Math.max(480, Math.round(b.height));
    if (Number.isFinite(b.x) && Number.isFinite(b.y)) {
      const rect = { x: Math.round(b.x), y: Math.round(b.y), width, height };
      const area = screen.getDisplayMatching(rect).workArea;
      const visible = rect.x + rect.width > area.x + 80 && rect.x < area.x + area.width - 80
        && rect.y + rect.height > area.y + 80 && rect.y < area.y + area.height - 80;
      if (visible) return { ...rect, maximized: !!b.maximized };
    }
    return { width, height, maximized: !!b.maximized };
  } catch { return null; }
}

function saveBounds(w) {
  if (!w || w.isDestroyed() || w.isFullScreen()) return;
  try {
    const maximized = w.isMaximized();
    const rect = maximized ? w.getNormalBounds() : w.getBounds();
    fs.writeFileSync(boundsFile(), JSON.stringify({ ...rect, maximized }));
  } catch { /* ignore */ }
}

// Launch at Login: Linux uses an XDG autostart .desktop entry (~/.config/autostart/);
// macOS test builds fall back to Electron's openAtLogin. Never used in Docker/Web.
function autostartFile() {
  const config = process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config');
  const id = product.desktopId || product.appId || 'twimshelf';
  return path.join(config, 'autostart', `${id}.desktop`);
}

function getLoginItem() {
  if (process.platform === 'linux') return fs.existsSync(autostartFile());
  if (process.platform === 'darwin') return app.getLoginItemSettings().openAtLogin;
  return false;
}

function setLoginItem(enabled) {
  if (process.platform === 'linux') {
    const file = autostartFile();
    if (!enabled) {
      fs.rmSync(file, { force: true });
      return false;
    }
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const execPath = (process.env.APPIMAGE || process.execPath).replace(/(["\\`$])/g, '\\$1');
    const id = product.desktopId || product.appId || 'twimshelf';
    const desktop = [
      '[Desktop Entry]',
      'Type=Application',
      `Name=${name}`,
      `Exec="${execPath}" --autostart`,
      `Icon=${id}`,
      'Terminal=false',
      'X-GNOME-Autostart-enabled=true',
      '',
    ].join('\n');
    fs.writeFileSync(file, desktop, 'utf8');
    return true;
  }
  if (process.platform === 'darwin') {
    app.setLoginItemSettings({ openAtLogin: !!enabled, openAsHidden: true });
    return app.getLoginItemSettings().openAtLogin;
  }
  return false;
}

/** The Linux window controls drawn over the toolbar: no plate of their own, symbols in the text colour. */
function overlayColors() {
  return { color: '#00000000', symbolColor: nativeTheme.shouldUseDarkColors ? '#e8e8ec' : '#1d1d1f', height: 52 };
}

async function createWindow() {
  const { base, token } = await startServer();
  await session.defaultSession.cookies.set({ url: base, name: 'tl_desktop', value: token, httpOnly: true, sameSite: 'strict' });
  const mac = process.platform === 'darwin';
  const saved = loadBounds();
  win = new BrowserWindow({
    // as the native window (MacRootViewController: 1180 × 820, the content at least 480 wide)
    width: saved?.width ?? 1180, height: saved?.height ?? 820,
    ...(saved?.x !== undefined && saved?.y !== undefined ? { x: saved.x, y: saved.y } : {}),
    minWidth: 720, minHeight: 480, show: false,
    title: name,
    ...(process.platform !== 'darwin' && fs.existsSync(icon) ? { icon } : {}),
    // No title bar of its own: the page runs up to the window's top edge (浏览's cards scroll
    // under the toolbar). macOS puts its traffic lights in the toolbar; Linux draws the window
    // controls over the toolbar's right end (the page keeps clear of them: Toolbar.css).
    backgroundColor: '#111113',
    titleBarStyle: 'hidden',
    ...(mac ? { trafficLightPosition: { x: 18, y: 18 } } : { autoHideMenuBar: true, titleBarOverlay: overlayColors() }),
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, sandbox: true, spellcheck: false },
  });
  if (!mac) nativeTheme.on('updated', () => { if (!win.isDestroyed()) win.setTitleBarOverlay(overlayColors()); });
  let saveTimer = null;
  const queueSave = () => {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => saveBounds(win), 300);
  };
  win.on('resize', queueSave);
  win.on('move', queueSave);
  win.on('maximize', queueSave);
  win.on('unmaximize', queueSave);
  win.on('close', (e) => {
    clearTimeout(saveTimer);
    saveBounds(win);
    // When Launch at Login is enabled, closing the window keeps the local server running in background
    if (!app.isQuitting && getLoginItem()) {
      e.preventDefault();
      win.hide();
    }
  });
  win.once('ready-to-show', () => {
    if (saved?.maximized) win.maximize();
    if (!startedHidden) win.show();
  });
  // an app, not a page: no pinch zoom of the whole window (and the menu bar has no zoom items)
  win.webContents.on('did-finish-load', () => { win.webContents.setVisualZoomLevelLimits(1, 1); win.webContents.setZoomLevel(0); });
  // links leave the app for the browser; the app stays on its own server
  win.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:/.test(url)) void shell.openExternal(url); return { action: 'deny' }; });
  const stayHere = (e, url) => {
    let origin = '';
    try { origin = new URL(url).origin; } catch { /* not an address */ }
    if (origin !== base) { e.preventDefault(); if (/^https?:/.test(url)) void shell.openExternal(url); }
  };
  win.webContents.on('will-navigate', stayHere);
  win.webContents.on('will-redirect', stayHere);
  await win.loadURL(`${base}/`);
}

/** Whether a message comes from the app's own page. */
const fromPage = (e) => !!win && e.sender === win.webContents;
ipcMain.handle('save-file', async (e, input, name) => {
  if (!fromPage(e) || e.senderFrame !== e.sender.mainFrame || typeof input !== 'string' || typeof name !== 'string') {
    throw new Error('common.notDone');
  }
  const url = new URL(input, e.sender.getURL());
  if (url.origin !== new URL(e.sender.getURL()).origin || !url.pathname.startsWith('/f/')) {
    throw new Error('common.notDone');
  }
  const safeName = name.replace(/[\\/:*?"<>|\x00-\x1f]/g, '_');
  const fileName = !safeName || safeName === '.' || safeName === '..' ? 'download' : safeName;
  const { canceled, filePath } = await dialog.showSaveDialog(win, {
    defaultPath: path.join(app.getPath('downloads'), fileName),
  });
  if (canceled || !filePath) return null;

  const temporary = path.join(path.dirname(filePath), `.twimshelf-${crypto.randomUUID()}.tmp`);
  try {
    const response = await e.sender.session.fetch(url.href, { credentials: 'include', redirect: 'error' });
    if (!response.ok || !response.body) throw new Error('Download failed');
    await pipeline(Readable.fromWeb(response.body), fs.createWriteStream(temporary, { flags: 'wx' }));
    await fs.promises.rename(temporary, filePath);
    return path.basename(filePath);
  } catch (error) {
    console.error('Could not save the file', error);
    throw new Error('common.notDone');
  } finally {
    await fs.promises.rm(temporary, { force: true }).catch(() => {});
  }
});

/** The system menu items the page may ask for. */
const ROLES = new Set(['about', 'hide', 'hideOthers', 'unhide', 'quit', 'close', 'undo', 'redo', 'cut', 'copy', 'paste', 'selectAll', 'minimize', 'zoom', 'front', 'togglefullscreen', 'windowMenu', 'appMenu', 'editMenu', 'viewMenu', 'fileMenu']);
const role = (r) => (ROLES.has(r) ? r : undefined);

// The system's own menus, built from what the page sends (it has the strings in the user's language).
function menuItems(items, resolve) {
  return items.map((it) => {
    if (it === 'separator') return { type: 'separator' };
    const o = { label: String(it.label ?? ''), enabled: it.enabled !== false };
    if (it.checked !== undefined) { o.type = 'checkbox'; o.checked = !!it.checked; }
    if (it.children) o.submenu = menuItems(it.children, resolve);
    else o.click = () => resolve(it.id);
    return o;
  });
}

// The local server uses a different port on each launch, so its browser storage has a new origin.
function mascotPreferenceFile() { return path.join(dataPaths().TL_DATA, 'mascot.enabled'); }
ipcMain.handle('get-mascot-enabled', (e) => {
  if (win?.webContents !== e.sender) return false;
  try { return fs.readFileSync(mascotPreferenceFile(), 'utf8') === 'true'; } catch { return false; }
});
ipcMain.handle('set-mascot-enabled', (e, enabled) => {
  if (win?.webContents !== e.sender || typeof enabled !== 'boolean') return;
  fs.writeFileSync(mascotPreferenceFile(), String(enabled));
});

ipcMain.handle('popup-menu', (e, items, x, y) => new Promise((resolve) => {
  if (!fromPage(e) || !Array.isArray(items) || !Number.isFinite(x) || !Number.isFinite(y)) { resolve(null); return; }
  let chosen = null;
  try {
    const menu = Menu.buildFromTemplate(menuItems(items, (id) => { chosen = id; }));
    menu.popup({ window: win, x: Math.round(x), y: Math.round(y), callback: () => setTimeout(() => resolve(chosen), 0) });
  } catch { resolve(null); }
}));

ipcMain.on('set-app-menu', (e, menus) => {
  if (!fromPage(e) || !Array.isArray(menus)) return;
  const send = (id) => e.sender.send('app-menu', id);
  try {
  const template = menus.map((m) => ({
    label: m.label,
    role: role(m.role),
    submenu: m.items.map((it) => {
      if (it === 'separator') return { type: 'separator' };
      if (it.role) return { role: role(it.role), label: it.label, accelerator: it.accel };
      const o = { label: it.label, accelerator: it.accel, enabled: it.enabled !== false, click: () => send(it.id) };
      if (it.checked !== undefined) { o.type = 'checkbox'; o.checked = !!it.checked; }
      return o;
    }),
  }));
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
  } catch (error) { console.error(error); }
});

ipcMain.on('viewer-mode', (e, on) => {
  if (!fromPage(e)) return;
  const w = win;
  if (w && process.platform === 'darwin') {
    w.setWindowButtonVisibility(!on);
    // showing them again puts them back at the default place: keep them in the 52 pt toolbar
    if (!on && w.setWindowButtonPosition) w.setWindowButtonPosition({ x: 18, y: 18 });
  }
});
ipcMain.on('toggle-fullscreen', (e) => { if (fromPage(e)) win.setFullScreen(!win.isFullScreen()); });
// only what belongs to the app
ipcMain.on('show-item', (e, p) => {
  if (!fromPage(e) || typeof p !== 'string' || !fs.existsSync(p)) return;
  const real = fs.realpathSync(p);
  const inside = Object.values(dataPaths()).some((d) => fs.existsSync(d) && real.startsWith(fs.realpathSync(d) + path.sep));
  if (inside) shell.showItemInFolder(real);
});

ipcMain.on('desktop-meta', (e) => {
  e.returnValue = {
    updateRepo: product.updateRepo || process.env.TL_UPDATE_REPO || '',
    appVersion: product.version || app.getVersion(),
    arch: process.arch === 'arm64' ? 'arm64' : 'x64',
    // the desktop app's own bundled icon for the About page
    icon: fs.existsSync(icon) ? `data:image/png;base64,${fs.readFileSync(icon).toString('base64')}` : '',
  };
});

ipcMain.handle('get-login-item', (e) => (fromPage(e) ? getLoginItem() : false));
ipcMain.handle('set-login-item', (e, enabled) => (fromPage(e) ? setLoginItem(!!enabled) : false));

function updatePrefsFile() { return path.join(dataPaths().TL_DATA, 'update.json'); }
ipcMain.handle('get-update-prefs', (e) => {
  if (!fromPage(e)) return {};
  try { return JSON.parse(fs.readFileSync(updatePrefsFile(), 'utf8')); } catch { return {}; }
});
ipcMain.handle('set-update-prefs', (e, prefs) => {
  if (!fromPage(e) || !prefs || typeof prefs !== 'object') return;
  try { fs.writeFileSync(updatePrefsFile(), JSON.stringify(prefs)); } catch { /* ignore */ }
});

ipcMain.handle('install-update', async (e, serverFile) => {
  if (!fromPage(e) || typeof serverFile !== 'string' || !fs.existsSync(serverFile)) {
    throw new Error('common.notDone');
  }
  const real = fs.realpathSync(serverFile);
  const inside = Object.values(dataPaths()).some((d) => fs.existsSync(d) && real.startsWith(fs.realpathSync(d) + path.sep));
  if (!inside) throw new Error('common.notDone');
  // An AppImage replaces itself where it is (as mature apps update): the new file next to it,
  // made executable, then renamed over it. The running copy is not disturbed (it keeps the old
  // file open); reopening starts the new one.
  const current = process.platform === 'linux' ? process.env.APPIMAGE : null;
  if (current && real.endsWith('.AppImage') && fs.existsSync(current)) {
    const dir = path.dirname(current);
    const staged = path.join(dir, `.${path.basename(current)}.update-${crypto.randomUUID()}`);
    try {
      await fs.promises.access(dir, fs.constants.W_OK);
      await fs.promises.copyFile(real, staged);
      await fs.promises.chmod(staged, 0o755);
      await fs.promises.rename(staged, current);
      await fs.promises.rm(real, { force: true }).catch(() => {});
      return { replaced: true, path: current };
    } catch {
      await fs.promises.rm(staged, { force: true }).catch(() => {});
      // (a folder it may not write: the new file goes to Downloads instead, below)
    }
  }
  const dest = path.join(app.getPath('downloads'), path.basename(real));
  const tmp = path.join(app.getPath('downloads'), `.twimshelf-update-${crypto.randomUUID()}.tmp`);
  try {
    await fs.promises.copyFile(real, tmp);
    if (process.platform === 'linux') await fs.promises.chmod(tmp, 0o755);
    await fs.promises.rename(tmp, dest);
    await fs.promises.rm(real, { force: true }).catch(() => {});
    shell.showItemInFolder(dest);
    return { replaced: false, path: dest };
  } catch (err) {
    await fs.promises.rm(tmp, { force: true }).catch(() => {});
    throw err;
  }
});

// 立即重新打开 after an update: the (replaced) AppImage starts again
ipcMain.handle('relaunch', (e) => {
  if (!fromPage(e)) return;
  app.relaunch(process.env.APPIMAGE ? { execPath: process.env.APPIMAGE, args: process.argv.slice(1) } : undefined);
  app.isQuitting = true;
  app.quit();
});

app.on('second-instance', () => {
  if (win) {
    if (!win.isVisible()) win.show();
    if (win.isMinimized()) win.restore();
    win.focus();
  }
});
app.on('activate', () => { if (win && !win.isVisible()) win.show(); });
app.on('before-quit', () => { app.isQuitting = true; if (server) server.kill('SIGTERM'); });
app.on('window-all-closed', () => { if (!getLoginItem()) app.quit(); });
app.whenReady().then(() => {
  // run from the sources (not a packaged app): the Dock shows the app's own icon, not Electron's
  if (process.platform === 'darwin' && !app.isPackaged && fs.existsSync(icon)) app.dock.setIcon(icon);
  // the page needs no camera, microphone, location or notifications
  session.defaultSession.setPermissionRequestHandler((_c, permission, grant) => grant(['clipboard-read', 'clipboard-sanitized-write', 'fullscreen'].includes(permission)));
  return createWindow();
}).catch((e) => { console.error(e); app.exit(1); });
