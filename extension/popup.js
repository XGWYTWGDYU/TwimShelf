// The popup (also opened as a tab when a button on X needs a device first): binding, the bound
// devices, and the recent downloads.
import { ACTIVE, bindAny, discoverLocal, hello, kindOf, load, setDefault, shortPost, t, updateTasks } from "./common.js";

const $ = (id) => document.getElementById(id);
function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined) e.textContent = text; return e; }

const SVG = {
  macos: '<path d="M4 5.5A1.5 1.5 0 0 1 5.5 4h13A1.5 1.5 0 0 1 20 5.5V15H4zM2 17h20v1a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2z" fill="currentColor"/>',
  windows: '<path d="M3 5.5l7.5-1v7H3zm8.5-1.2L21 3v8.5h-9.5zM3 12.5h7.5v7L3 18.5zm8.5 0H21V21l-9.5-1.3z" fill="currentColor"/>',
  linux: '<path d="M4 5h16a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1zm2.3 4.2 2.6 1.8-2.6 1.8.9 1.2 4.3-3-4.3-3zM12 13v1.5h5V13z" fill="currentColor"/><path d="M8 19h8v1.5H8z" fill="currentColor"/>',
  server: '<path d="M4 4h16a1 1 0 0 1 1 1v5H3V5a1 1 0 0 1 1-1zm-1 8h18v5a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1zm3-5.5v1.5h2V6.5zm0 8v1.5h2v-1.5z" fill="currentColor"/>',
  unlink: '<path d="M9.5 6.5 11 5a4.2 4.2 0 0 1 6 6l-1.5 1.5M14.5 17.5 13 19a4.2 4.2 0 0 1-6-6l1.5-1.5M4 4l16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
  check: '<path d="m5 12.5 4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>',
  cross: '<path d="M7 7l10 10M17 7 7 17" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"/>',
  pause: '<path d="M8 6v12M16 6v12" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"/>',
  cloud: '<path d="M7 18a4.5 4.5 0 0 1-.6-9 6 6 0 0 1 11.4 1.6A3.8 3.8 0 0 1 17.5 18z" fill="none" stroke="currentColor" stroke-width="2"/>',
  retry: '<path d="M19 12a7 7 0 1 1-2.1-5M19 4v4.5h-4.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>',
};
const svg = (name) => `<svg viewBox="0 0 24 24" aria-hidden="true">${SVG[name] || SVG.macos}</svg>`;

if (new URLSearchParams(location.search).has("tab")) document.body.classList.add("tab");
for (const e of document.querySelectorAll("[data-i18n]")) e.innerHTML = t(e.dataset.i18n).replace(/\*\*(.+?)\*\*/g, "<b>$1</b>");
for (const e of document.querySelectorAll("[data-i18n-placeholder]")) e.placeholder = t(e.dataset.i18nPlaceholder);
document.documentElement.lang = chrome.i18n.getUILanguage();

const ERRORS = {
  bad_text: "errorBadText", nothing: "errorNothing", wrong_code: "errorWrongCode", expired: "errorExpired",
  no_code: "errorNoCode", no_code_here: "errorNoCodeHere", no_local: "errorNoLocal", offline: "errorUnreachable",
  too_old: "errorTooOld", too_new: "errorTooNew", origin: "errorUnreachable",
};
let adding = false;

function status(text, kind = "") {
  const p = $("bindStatus");
  p.className = `status ${kind}`;
  p.textContent = text;
}

// ------------------------------------------------------------------------------------------
// binding

async function renderLocal() {
  const { devices } = await load();
  const found = await discoverLocal(devices);
  const chips = $("local");
  chips.replaceChildren(...found.map((f) => {
    const c = el("span", "chip");
    c.innerHTML = svg(f.platform);
    c.append(`${f.name || "TwimShelf"} · ${kindOf(f)}`);
    return c;
  }));
  $("localBox").hidden = found.length === 0;
}

$("bindForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const button = $("bind");
  button.disabled = true;
  status(t("binding"), "busy");
  const r = await bindAny($("entry").value, $("addressBox").open ? $("address").value : "");
  button.disabled = false;
  if (r.device) {
    status(t("bound", r.device.name), "ok");
    $("entry").value = "";
    adding = false;
    await render();
  } else {
    status(t(ERRORS[r.error] || "errorBind", r.error), "err");
    $("entry").focus();
    renderLocal();
  }
});
// pasting the binding text binds at once
$("entry").addEventListener("paste", () => setTimeout(() => { if (/TWS1:/.test($("entry").value)) $("bindForm").requestSubmit(); }, 0));
$("addToggle").addEventListener("click", () => { adding = true; render(); $("entry").focus(); });
$("cancelAdd").addEventListener("click", () => { adding = false; status(""); render(); });

// ------------------------------------------------------------------------------------------
// devices

function deviceRow(d, usableCount) {
  const li = el("li");
  const tile = el("span", "tile");
  tile.innerHTML = svg(d.platform);
  const dot = el("span", "dot");
  tile.append(dot);
  const info = el("div", "grow");
  const sub = el("div", "sub", `${kindOf(d)} · ${d.unbound ? t("deviceUnbound") : t("checking")}`);
  info.append(el("div", "name", d.name), sub);
  const remove = el("button", "icon-btn");
  remove.type = "button";
  remove.innerHTML = svg("unlink");
  remove.title = t("unbindTitle", d.name);
  remove.setAttribute("aria-label", t("unbindTitle", d.name));
  remove.addEventListener("click", () => {
    // asked in place: a second, explicit tap
    const confirm = el("div", "confirm");
    const no = el("button", "text", t("cancel"));
    const yes = el("button", "text danger", t("unbind"));
    no.type = yes.type = "button";
    no.addEventListener("click", () => confirm.replaceWith(remove));
    yes.addEventListener("click", async () => { yes.disabled = true; await chrome.runtime.sendMessage({ type: "unbind", id: d.id }); render(); });
    confirm.append(no, yes);
    remove.replaceWith(confirm);
    yes.focus();
  });
  li.append(tile, info, remove);
  if (d.unbound) dot.classList.add("bad");
  else (async () => {
    for (const base of [d.current, ...d.addresses.filter((a) => a !== d.current)]) {
      const h = await hello(base, d.token);
      if (h) {
        dot.classList.add(h.bound ? "on" : "bad");
        sub.textContent = `${kindOf({ ...d, ...h })} · ${h.bound ? t("deviceOnline") : t("deviceUnbound")}`;
        return;
      }
    }
    dot.classList.add("off");
    sub.textContent = `${kindOf(d)} · ${t("deviceOffline")}`;
  })();
  return li;
}

// ------------------------------------------------------------------------------------------
// tasks

const STATE = {
  sending: ["active", "", "stateSending"], queued: ["active queued", "", "stateQueued"], downloading: ["active", "", "stateDownloading"],
  done: ["done", "check", "stateDone"], failed: ["failed", "cross", "stateFailed"], offline: ["wait", "cloud", "stateOffline"],
  paused: ["wait", "pause", "statePaused"], cancelled: ["wait", "pause", "stateCancelled"],
};

function taskRow(x) {
  const li = el("li");
  const [cls, icon, label] = STATE[x.state] || STATE.queued;
  const mark = el("span", `state ${cls}`);
  mark.innerHTML = icon ? svg(icon) : '<span class="spin" aria-hidden="true"></span>';
  mark.title = t(label);
  const info = el("div", "grow");
  const link = el("a", "name", shortPost(x.url));
  link.href = x.url; link.target = "_blank"; link.rel = "noreferrer";
  info.append(link, el("div", "sub", `${t(label)} · ${x.deviceName}`));
  if (x.error && (x.state === "failed" || x.state === "offline")) info.append(el("div", "err-line", x.error));
  li.append(mark, info);
  if (x.state === "failed" || x.state === "cancelled") {
    const again = el("button", "icon-btn");
    again.type = "button";
    again.innerHTML = svg("retry");
    again.title = t("retry");
    again.setAttribute("aria-label", t("retry"));
    again.addEventListener("click", async () => { again.disabled = true; await chrome.runtime.sendMessage({ type: "retry", key: x.key }); });
    li.append(again);
  }
  return li;
}

// ------------------------------------------------------------------------------------------

async function render() {
  const { devices, tasks, defaultDevice } = await load();
  const usable = devices.filter((d) => !d.unbound);
  const list = Object.values(tasks).sort((a, b) => b.updated - a.updated).slice(0, 30);
  const active = list.filter((x) => ACTIVE.has(x.state)).length;

  // binding by itself when there is nothing yet
  const connecting = devices.length === 0 || adding;
  $("connect").hidden = !connecting;
  $("connectTitle").textContent = devices.length === 0 ? t("connectTitle") : t("addDevice");
  $("cancelAdd").hidden = devices.length === 0;
  if (connecting) renderLocal();

  $("devicesCard").hidden = devices.length === 0;
  $("addToggle").hidden = adding;
  $("devices").replaceChildren(...devices.map((d) => deviceRow(d, usable.length)));
  $("defaultRow").hidden = usable.length < 2;
  const select = $("defaultDevice");
  select.replaceChildren(new Option(t("askEveryTime"), ""), ...usable.map((d) => new Option(d.name, d.id)));
  select.value = usable.some((d) => d.id === defaultDevice) ? defaultDevice : "";

  $("tasksCard").hidden = devices.length === 0 && list.length === 0;
  $("tasks").replaceChildren(...list.map(taskRow));
  if (!list.length) $("tasks").replaceChildren(el("p", "empty", t("noTasks")));
  $("clear").hidden = !list.some((x) => !ACTIVE.has(x.state));
  $("hintX").hidden = devices.length === 0 || list.length > 0;

  const connected = usable.length === 1 ? t("oneDevice") : t("nDevices", usable.length);
  $("summary").textContent = devices.length === 0 ? t("summaryNone") : active ? `${connected} · ${t("nDownloading", active)}` : connected;
}

$("defaultDevice").addEventListener("change", (e) => setDefault(e.target.value));
$("clear").addEventListener("click", () => updateTasks((tasks) => { for (const k of Object.keys(tasks)) if (!ACTIVE.has(tasks[k].state)) delete tasks[k]; }));
// what the worker changes shows here as it happens (the binding form is left as typed)
chrome.storage.onChanged.addListener((c, area) => { if (area === "local" && (c.tasks || c.devices || c.defaultDevice)) render(); });
chrome.runtime.sendMessage({ type: "pump" }).catch(() => {});
render().then(() => { if (!$("connect").hidden) $("entry").focus(); });
