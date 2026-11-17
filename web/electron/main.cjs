// The TwimShelf desktop app (Linux; a macOS build exists for testing only): starts the bundled
// TwimShelf server on 127.0.0.1 with a token only this app knows, and shows the React app the
// server serves. The window and the web page are the same code; only the server is local.
const { app, BrowserWindow, session, shell } = require('electron');
const { spawn } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');

const product = (() => {
  try { return require('./product.json'); } catch { return {}; }
})();

if (!app.requestSingleInstanceLock()) app.exit(0);

let server = null;
let win = null;

/** Where the data lives. Linux: where the Flutter app kept it, so an upgrade finds the library. */
function dataPaths() {
  // development and tests: a library given explicitly
  if (process.env.TL_DATA) return { TL_DATA: process.env.TL_DATA };
  if (process.platform === 'linux') {
    const share = process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share');
    const flutter = product.desktopId ? path.join(share, product.desktopId) : null;
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

function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.once('error', reject);
    s.listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)); });
  });
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
  const port = await freePort();
  const token = crypto.randomBytes(32).toString('hex');
  const env = {
    ...process.env, ...dataPaths(), TL_PORT: String(port), TL_WEB: webFolder(), TL_DESKTOP_TOKEN: token,
    TL_DEVICE_NAME: `TwimShelf · ${os.hostname()}`,
  };
  fs.mkdirSync(env.TL_DATA, { recursive: true });
  const log = fs.openSync(path.join(env.TL_DATA, 'desktop-server.log'), 'a');
  // its standard input stays open while this app lives: the server ends when it closes
  server = spawn(serverBinary(), [], { env, stdio: ['pipe', log, log] });
  server.on('exit', (code) => {
    server = null;
    if (!app.isQuitting) { console.error(`server ended (${code})`); app.quit(); }
  });
  const base = `http://127.0.0.1:${port}`;
  for (let i = 0; i < 200; i++) {
    try { const r = await fetch(`${base}/api/info`); if (r.status === 401 || r.ok) return { base, token }; } catch { /* not yet */ }
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error('the server did not start');
}

async function createWindow() {
  const { base, token } = await startServer();
  await session.defaultSession.cookies.set({ url: base, name: 'tl_desktop', value: token, httpOnly: true, sameSite: 'strict' });
  win = new BrowserWindow({
    width: 1280, height: 820, minWidth: 720, minHeight: 480, show: false,
    title: 'TwimShelf',
    backgroundColor: '#1e1e1e',
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    autoHideMenuBar: true,
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, sandbox: true },
  });
  win.once('ready-to-show', () => win.show());
  // links leave the app for the browser; the app stays on its own server
  win.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:/.test(url)) void shell.openExternal(url); return { action: 'deny' }; });
  win.webContents.on('will-navigate', (e, url) => { if (!url.startsWith(base)) { e.preventDefault(); if (/^https?:/.test(url)) void shell.openExternal(url); } });
  await win.loadURL(`${base}/`);
}

app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });
app.on('before-quit', () => { app.isQuitting = true; if (server) server.kill('SIGTERM'); });
app.on('window-all-closed', () => app.quit());
app.whenReady().then(createWindow).catch((e) => { console.error(e); app.exit(1); });
