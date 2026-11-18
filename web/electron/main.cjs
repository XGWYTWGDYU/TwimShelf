// The TwimShelf desktop app (Linux; a macOS build exists for testing only): starts the bundled
// TwimShelf server on 127.0.0.1 with a token only this app knows, and shows the React app the
// server serves. The window and the web page are the same code; only the server is local.
const { app, BrowserWindow, Menu, ipcMain, nativeTheme, session, shell } = require('electron');
const { spawn } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');

const product = (() => {
  try { return require('./product.json'); } catch { return {}; }
})();

// what the app is called, its version and icon: config.yaml, written to product.json and icon.png by
// scripts/apply.py (every build does that first)
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

async function startServer() {
  const paths = dataPaths();
  fs.mkdirSync(paths.TL_DATA, { recursive: true });
  const port = await steadyPort(paths.TL_DATA);
  const token = crypto.randomBytes(32).toString('hex');
  const env = {
    ...process.env, ...paths, TL_PORT: String(port), TL_WEB: webFolder(), TL_DESKTOP_TOKEN: token,
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

// Linux: no separate title bar. The window's buttons float over the page's 52 pt toolbar, on the
// page's colour (black over the viewer), and the toolbar keeps clear of them (theme.css).
let viewerOpen = false;
function windowControls() {
  const dark = nativeTheme.shouldUseDarkColors;
  if (viewerOpen) return { color: '#000000', symbolColor: '#ffffff', height: 52 };
  return { color: dark ? '#111113' : '#fbfbfc', symbolColor: dark ? '#f4f4f5' : '#141416', height: 52 };
}
nativeTheme.on('updated', () => { if (process.platform === 'linux') win?.setTitleBarOverlay(windowControls()); });

async function createWindow() {
  const { base, token } = await startServer();
  await session.defaultSession.cookies.set({ url: base, name: 'tl_desktop', value: token, httpOnly: true, sameSite: 'strict' });
  const mac = process.platform === 'darwin';
  win = new BrowserWindow({
    // as the native window (MacRootViewController: 1180 × 820, the content at least 480 wide)
    width: 1180, height: 820, minWidth: 720, minHeight: 480, show: false,
    title: name,
    ...(process.platform !== 'darwin' && fs.existsSync(icon) ? { icon } : {}),
    // the page looks exactly as on the web; only the window buttons move into its 52 pt toolbar
    backgroundColor: '#111113',
    ...(mac ? { titleBarStyle: 'hidden', trafficLightPosition: { x: 18, y: 18 } } : { titleBarStyle: 'hidden', titleBarOverlay: windowControls(), autoHideMenuBar: true }),
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, sandbox: true, spellcheck: false },
  });
  win.once('ready-to-show', () => win.show());
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
  } else if (w && process.platform === 'linux') {
    viewerOpen = !!on;
    w.setTitleBarOverlay(windowControls());
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

app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });
app.on('before-quit', () => { app.isQuitting = true; if (server) server.kill('SIGTERM'); });
app.on('window-all-closed', () => app.quit());
app.whenReady().then(() => {
  // run from the sources (not a packaged app): the Dock shows the app's own icon, not Electron's
  if (process.platform === 'darwin' && !app.isPackaged && fs.existsSync(icon)) app.dock.setIcon(icon);
  // the page needs no camera, microphone, location or notifications
  session.defaultSession.setPermissionRequestHandler((_c, permission, grant) => grant(['clipboard-read', 'clipboard-sanitized-write', 'fullscreen'].includes(permission)));
  return createWindow();
}).catch((e) => { console.error(e); app.exit(1); });
