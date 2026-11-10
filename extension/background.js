// The extension's worker: sends a post to the chosen device and follows the task there until it
// is done (or failed), whichever tab or window it came from. The buttons on X and the popup read
// the tasks from storage.
import { ACTIVE, call, kindOf, load, t, taskKey, updateTasks, unbind } from "./common.js";

const POLL_MS = 2000;
/// A device that cannot be reached is asked again this often (it may be closed, or asleep).
const OFFLINE_MS = 15000;
/// A task nobody could finish in this long stops being followed.
const GIVE_UP_MS = 7 * 24 * 3600 * 1000;

let timer = null;
let pumping = false;

async function badge(tasks) {
  const n = Object.values(tasks).filter((x) => ACTIVE.has(x.state)).length;
  await chrome.action.setBadgeBackgroundColor({ color: "#1d9bf0" });
  await chrome.action.setBadgeText({ text: n ? String(n) : "" });
}

/// Sends `url` to `device` and records the task.
async function send(device, url, tweet) {
  const key = taskKey(device.id, url);
  const now = Date.now();
  await updateTasks((tasks) => {
    tasks[key] = { key, url, tweet: tweet || "", deviceId: device.id, deviceName: device.name, state: "sending", error: "", created: tasks[key]?.created ?? now, updated: now, lastSeen: now };
  });
  const r = await call(device, "POST", "/ext/download", { url });
  const tasks = await updateTasks((tasks) => {
    const x = tasks[key];
    if (!x) return;
    x.updated = Date.now();
    if (r.status === 200) {
      x.url = r.json.url || x.url;
      x.unsent = false;
      x.state = r.json.state === "unknown" ? "queued" : r.json.state;
      x.error = r.json.error || "";
      x.lastSeen = Date.now();
    } else if (r.status === 0) {
      // not reached (the app is closed, the computer asleep): sent when it is back
      x.state = "offline";
      x.unsent = true;
      x.error = t("errorOffline", device.name);
    } else if (r.status === 401) {
      x.state = "failed";
      x.error = t("errorUnbound");
    } else {
      x.state = "failed";
      x.error = r.json.error === "not_a_post" ? t("errorNotAPost") : (r.json.message || r.json.error || `HTTP ${r.status}`);
    }
  });
  if (r.status === 401) await markUnbound(device);
  await badge(tasks);
  schedule(POLL_MS);
  return tasks[key];
}

async function markUnbound(device) {
  const { devices } = await load();
  const d = devices.find((x) => x.id === device.id);
  if (d && !d.unbound) { d.unbound = true; await chrome.storage.local.set({ devices }); }
}

/// Asks each device about its tasks still under way.
async function pump() {
  if (pumping) return;
  pumping = true;
  try {
    const { devices, tasks } = await load();
    // (a send the worker was stopped in the middle of is asked about like any other)
    const active = Object.values(tasks).filter((x) => ACTIVE.has(x.state) && (x.state !== "sending" || Date.now() - x.updated > 30000));
    let next = 0;
    for (const device of devices) {
      const mine = active.filter((x) => x.deviceId === device.id);
      if (!mine.length) continue;
      // an offline device is asked less often
      const due = mine.some((x) => x.state !== "offline" || Date.now() - x.updated >= OFFLINE_MS);
      if (!due) { next = next || OFFLINE_MS; continue; }
      // tasks the device never got are sent first
      for (const x of mine.filter((x) => x.unsent)) {
        const sent = await call(device, "POST", "/ext/download", { url: x.url });
        if (sent.status === 200) await updateTasks((all) => { const cur = all[x.key]; if (cur) { cur.unsent = false; cur.url = sent.json.url || cur.url; cur.state = "queued"; cur.error = ""; cur.updated = Date.now(); } });
        else if (sent.status === 0 && Date.now() - x.created > GIVE_UP_MS) await updateTasks((all) => { const cur = all[x.key]; if (cur) { cur.unsent = false; cur.state = "failed"; cur.updated = Date.now(); } });
        else if (sent.status !== 0) await updateTasks((all) => { const cur = all[x.key]; if (cur) { cur.unsent = false; cur.state = "failed"; cur.error = sent.json.message || sent.json.error || `HTTP ${sent.status}`; cur.updated = Date.now(); } });
      }
      const r = await call(device, "POST", "/ext/status", { urls: mine.filter((x) => !x.unsent).map((x) => x.url) });
      await updateTasks((all) => {
        const now = Date.now();
        for (const x of mine) {
          // (sent just now or still unsent: asked about next time)
          if (x.unsent) continue;
          const cur = all[x.key];
          if (!cur || !ACTIVE.has(cur.state)) continue;
          if (r.status === 200) {
            const got = (r.json.tasks || []).find((y) => y.url === cur.url);
            const state = got?.state;
            if (state && state !== "unknown") {
              // paused or cancelled in the app: shown as such, and no longer followed
              cur.state = state;
              cur.error = got.error || "";
              cur.lastSeen = now;
            } else if (now - cur.created > 60000) {
              cur.state = "failed";
              cur.error = t("errorLost");
            }
          } else if (r.status === 401) {
            cur.state = "failed";
            cur.error = t("errorUnbound");
          } else {
            cur.state = "offline";
            if (now - (cur.lastSeen || cur.created) > GIVE_UP_MS) { cur.state = "failed"; cur.error = t("errorOffline", device.name); }
          }
          cur.updated = now;
        }
      });
      if (r.status === 401) await markUnbound(device);
      next = r.status === 200 ? POLL_MS : (next || OFFLINE_MS);
    }
    // tasks of a device that is no longer bound end
    const ids = new Set(devices.map((d) => d.id));
    const orphans = active.filter((x) => !ids.has(x.deviceId));
    if (orphans.length) await updateTasks((all) => { for (const x of orphans) if (all[x.key]) { all[x.key].state = "failed"; all[x.key].error = t("errorUnbound"); } });
    const after = (await load()).tasks;
    await badge(after);
    if (Object.values(after).some((x) => ACTIVE.has(x.state))) schedule(next || POLL_MS);
  } finally {
    pumping = false;
  }
}

function schedule(ms) {
  clearTimeout(timer);
  timer = setTimeout(() => { pump().catch(() => {}); }, ms);
}

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  (async () => {
    const { devices, defaultDevice } = await load();
    const usable = devices.filter((d) => !d.unbound);
    switch (msg.type) {
      case "devices":
        return { devices: usable.map((d) => ({ id: d.id, name: d.name, platform: d.platform, kind: kindOf(d) })), defaultDevice };
      case "download": {
        if (!usable.length) return { needsBinding: true };
        let device = usable.find((d) => d.id === msg.deviceId);
        if (!device && !msg.choose) device = usable.length === 1 ? usable[0] : usable.find((d) => d.id === defaultDevice);
        if (!device) return { needsChoice: true, devices: usable.map((d) => ({ id: d.id, name: d.name, platform: d.platform, kind: kindOf(d) })) };
        return { task: await send(device, msg.url, msg.tweet) };
      }
      case "retry": {
        const { tasks } = await load();
        const x = tasks[msg.key];
        const device = x && usable.find((d) => d.id === x.deviceId);
        if (!device) return { needsBinding: true };
        return { task: await send(device, x.url, x.tweet) };
      }
      case "unbind": {
        const device = devices.find((d) => d.id === msg.id);
        if (device) await unbind(device);
        return { ok: true };
      }
      case "pump":
        await pump();
        return { ok: true };
      case "openSetup":
        await chrome.tabs.create({ url: chrome.runtime.getURL("popup.html?tab=1") });
        return { ok: true };
      default:
        return { error: "unknown" };
    }
  })().then(reply, (e) => reply({ error: String(e) }));
  return true; // answered asynchronously
});

// a worker woken up later (the browser stops idle workers) picks up where it was
chrome.alarms.create("pump", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((a) => { if (a.name === "pump") pump().catch(() => {}); });
chrome.runtime.onStartup.addListener(() => pump().catch(() => {}));
chrome.runtime.onInstalled.addListener(() => pump().catch(() => {}));
pump().catch(() => {});
