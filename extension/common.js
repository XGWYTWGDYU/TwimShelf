// Shared by the background worker and the popup: the bound devices, the tasks, and how to talk
// to a device (the core's extension API: core/src/extension.rs in the TwimShelf repository).
//
// A device is a TwimShelf app (Windows, Linux, macOS, Flutter or native) or a TwimShelf server
// (Docker). It is reached at one of its addresses ("http://192.168.1.5:27800",
// "https://twimshelf.example.com"), with the token it gave when it was bound.

export const API = 1;
/// Where the desktop apps listen on this computer (the first free one of these), and the server.
export const LOCAL_PORTS = [27800, 27801, 27802, 27803, 27804, 27805, 27806, 27807, 27808, 27809, 2778];
/// A task in one of these states is still followed.
export const ACTIVE = new Set(["sending", "queued", "downloading", "offline"]);
const KEEP_TASKS = 300;

export const t = (key, ...subs) => chrome.i18n.getMessage(key, subs.map(String)) || key;

// ------------------------------------------------------------------------------------------
// storage

export async function load() {
  const s = await chrome.storage.local.get({ devices: [], tasks: {}, defaultDevice: "" });
  return s;
}
export async function saveDevices(devices) { await chrome.storage.local.set({ devices }); }
export async function setDefault(id) { await chrome.storage.local.set({ defaultDevice: id || "" }); }

/// Tasks are keyed by device and post: `${deviceId}|${url}`.
export const taskKey = (deviceId, url) => `${deviceId}|${url}`;

/// Changes tasks under one read-modify-write (the worker and the popup may both write).
let chain = Promise.resolve();
export function updateTasks(change) {
  const run = chain.then(async () => {
    const { tasks } = await chrome.storage.local.get({ tasks: {} });
    change(tasks);
    // the oldest finished ones go first when there are too many
    const keys = Object.keys(tasks);
    if (keys.length > KEEP_TASKS) {
      keys.sort((a, b) => (ACTIVE.has(tasks[a].state) - ACTIVE.has(tasks[b].state)) || tasks[a].updated - tasks[b].updated);
      for (const k of keys.slice(0, keys.length - KEEP_TASKS)) delete tasks[k];
    }
    await chrome.storage.local.set({ tasks });
    return tasks;
  });
  chain = run.catch(() => {});
  return run;
}

// ------------------------------------------------------------------------------------------
// addresses and binding text

/// "192.168.1.5:27800" or a full address → a base URL without a trailing slash.
export function baseOf(address) {
  let a = String(address || "").trim().replace(/\/+$/, "");
  if (!a) return "";
  if (!/^https?:\/\//i.test(a)) a = (/:443$/.test(a) ? "https://" : "http://") + a;
  try {
    const u = new URL(a);
    return `${u.protocol}//${u.host}${u.pathname.replace(/\/+$/, "")}`;
  } catch { return ""; }
}

/// The app's binding text (`TWS1:` + base64url JSON {v, n, i, a, c}) → {name, id, addresses, code},
/// or null.
export function parseBinding(text) {
  const m = String(text || "").trim().match(/TWS1:([A-Za-z0-9_-]+)/);
  if (!m) return null;
  try {
    let b = m[1].replace(/-/g, "+").replace(/_/g, "/");
    while (b.length % 4) b += "=";
    const bytes = Uint8Array.from(atob(b), (c) => c.charCodeAt(0));
    const j = JSON.parse(new TextDecoder().decode(bytes));
    if (!Array.isArray(j.a) || !/^\d{6}$/.test(String(j.c))) return null;
    return { name: String(j.n || ""), id: String(j.i || ""), addresses: j.a.map(baseOf).filter(Boolean), code: String(j.c) };
  } catch { return null; }
}

/// This browser, as the app lists it ("Chrome · macOS").
export function browserName() {
  const d = navigator.userAgentData;
  const brand = d?.brands?.map((b) => b.brand).find((b) => !/not.?a.?brand|chromium/i.test(b)) || "Chromium";
  const platform = d?.platform || (/Mac/.test(navigator.userAgent) ? "macOS" : /Win/.test(navigator.userAgent) ? "Windows" : /Linux/.test(navigator.userAgent) ? "Linux" : "");
  return platform ? `${brand} · ${platform}` : brand;
}

// ------------------------------------------------------------------------------------------
// requests

async function request(base, method, path, { token, body, timeout = 6000 } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;
  const r = await fetch(base + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(timeout), cache: "no-store", credentials: "omit" });
  let json = {};
  try { json = await r.json(); } catch { /* not JSON: an answer of something else */ }
  return { status: r.status, json };
}

/// A request to a bound device: its last good address first, then the others. The address that
/// answered becomes the device's current one. `{status: 0}` when none answered.
export async function call(device, method, path, body) {
  const order = [device.current, ...device.addresses.filter((a) => a !== device.current)].filter(Boolean);
  for (const base of order) {
    try {
      const r = await request(base, method, path, { token: device.token, body });
      if (r.json?.app === undefined && r.status === 404 && path === "/ext/hello") continue; // something else lives there
      if (base !== device.current) {
        device.current = base;
        const { devices } = await load();
        const d = devices.find((x) => x.id === device.id);
        if (d) { d.current = base; await saveDevices(devices); }
      }
      return r;
    } catch { /* unreachable there: the next address */ }
  }
  return { status: 0, json: { error: "offline" } };
}

/// Is there a TwimShelf at `base`? Its hello, or null.
export async function hello(base, token) {
  try {
    const r = await request(base, "GET", "/ext/hello", { token, timeout: 1500 });
    return r.status === 200 && r.json?.app === "TwimShelf" ? r.json : null;
  } catch { return null; }
}

/// TwimShelf apps and servers on this computer that are not bound yet.
export async function discoverLocal(devices) {
  const found = await Promise.all(LOCAL_PORTS.map(async (port) => {
    const base = `http://127.0.0.1:${port}`;
    const h = await hello(base);
    return h ? { ...h, base } : null;
  }));
  const bound = new Set(devices.map((d) => d.id));
  return found.filter((f) => f && !bound.has(f.id));
}

/// Binds this browser to the device at one of `addresses` with `code`. The new device, or an
/// error code ("wrong_code", "expired", "no_code", "offline", "too_old", …).
export async function bind(addresses, code, fallbackName = "") {
  let last = "offline";
  for (const base of addresses.map(baseOf).filter(Boolean)) {
    let r;
    try { r = await request(base, "POST", "/ext/pair", { body: { code: String(code).replace(/\s+/g, ""), name: browserName() } }); }
    catch { continue; }
    if (r.status === 200 && r.json.token) {
      if ((r.json.api ?? 1) > API) return { error: "too_new" };
      const device = {
        id: r.json.id, name: r.json.name || fallbackName || base, platform: r.json.platform || "", flavor: r.json.flavor || "",
        token: r.json.token, addresses: [...new Set([base, ...addresses.map(baseOf).filter(Boolean)])], current: base, added: Date.now(),
      };
      const { devices } = await load();
      const rest = devices.filter((d) => d.id !== device.id);
      await saveDevices([...rest, device]);
      return { device };
    }
    // the device answered: its answer is final (a code is used up after a few wrong tries)
    if (r.status === 404) { last = "too_old"; continue; }
    return { error: r.json.error || `http_${r.status}` };
  }
  return { error: last };
}

/// One entry for whatever the user has: a six-digit code (tried on every TwimShelf found on this
/// computer: only the one showing that code takes it, the others have none and say so), or the
/// app's binding text (which carries the addresses). An address is only needed for a device
/// reached some other way.
export async function bindAny(input, address = "") {
  const text = String(input || "").trim();
  const parsed = parseBinding(text);
  if (parsed) return bind(parsed.addresses, parsed.code, parsed.name);
  const code = text.replace(/\s+/g, "");
  if (!/^\d{6}$/.test(code)) return { error: text ? "bad_text" : "nothing" };
  if (address.trim()) return bind([address], code);
  const { devices } = await load();
  const found = await discoverLocal(devices);
  if (!found.length) return { error: "no_local" };
  // the most telling answer wins: a wrong code (it was this device) over "no code shown here"
  const rank = { wrong_code: 3, expired: 2, no_code: 1 };
  let best = "no_code";
  for (const f of found) {
    const r = await bind([f.base], code, f.name);
    if (r.device) return r;
    if ((rank[r.error] || 0) > (rank[best] || 0)) best = r.error;
  }
  return { error: best === "no_code" ? "no_code_here" : best };
}

/// How a device is named under its name: "Mac app", "Flutter · Windows", "Server".
export function kindOf(d) {
  const os = { macos: "macOS", windows: "Windows", linux: "Linux" }[d.platform] || "";
  if (d.platform === "server" || d.flavor === "server") return t("kindServer");
  if (d.flavor === "native") return t("kindNative", os);
  if (d.flavor === "flutter") return t("kindFlutter", os);
  return os;
}

export async function unbind(device) {
  await call(device, "POST", "/ext/unbind", {}).catch(() => {});
  const { devices, defaultDevice } = await load();
  await saveDevices(devices.filter((d) => d.id !== device.id));
  if (defaultDevice === device.id) await setDefault("");
  await updateTasks((tasks) => { for (const k of Object.keys(tasks)) if (tasks[k].deviceId === device.id && ACTIVE.has(tasks[k].state)) { tasks[k].state = "failed"; tasks[k].error = t("errorUnbound"); } });
}

/// "@user · 1234…" for a post's link.
export function shortPost(url) {
  const m = String(url).match(/x\.com\/([^/]+)\/status\/(\d+)/);
  return m ? `@${m[1]} · ${m[2].slice(-6)}` : url;
}
