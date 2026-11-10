// A download button in every post's action bar on X. A click sends the post to the bound device
// (with several, a menu asks which one, unless a default is set); the button then shows how the
// task is doing until it is done. Right-click always asks for the device.
(() => {
  const t = (key, ...subs) => chrome.i18n.getMessage(key, subs.map(String)) || key;
  const MARK = "tlDone";
  /// The latest task of each post (by its canonical link), from storage.
  let byUrl = new Map();

  const ICONS = {
    idle: '<path d="M12 3.5a1 1 0 0 1 1 1v9.09l3.3-3.3a1 1 0 1 1 1.4 1.42l-5 5a1 1 0 0 1-1.4 0l-5-5a1 1 0 1 1 1.4-1.42l3.3 3.3V4.5a1 1 0 0 1 1-1zM4.5 17a1 1 0 0 1 1 1v1h13v-1a1 1 0 1 1 2 0v2a1 1 0 0 1-1 1h-15a1 1 0 0 1-1-1v-2a1 1 0 0 1 1-1z"/>',
    done: '<path d="M9.2 16.6 4.9 12.3a1 1 0 1 0-1.4 1.4l5 5a1 1 0 0 0 1.4 0l11-11a1 1 0 1 0-1.4-1.4z"/>',
    failed: '<path d="M12 2.5a9.5 9.5 0 1 1 0 19 9.5 9.5 0 0 1 0-19zm0 2a7.5 7.5 0 1 0 0 15 7.5 7.5 0 0 0 0-15zM12 7a1 1 0 0 1 1 1v4.5a1 1 0 1 1-2 0V8a1 1 0 0 1 1-1zm0 8a1.25 1.25 0 1 1 0 2.5 1.25 1.25 0 0 1 0-2.5z"/>',
    offline: '<path d="M3.3 2.3a1 1 0 0 1 1.4 0l17 17a1 1 0 0 1-1.4 1.4l-2.1-2.1H7a5 5 0 0 1-1.4-9.8L3.3 3.7a1 1 0 0 1 0-1.4zM7.3 9.3A3 3 0 0 0 7 16.6h9.2zM12 4.5a7 7 0 0 1 6.9 5.8A4.5 4.5 0 0 1 21 18.2l-1.5-1.5a2.5 2.5 0 0 0-1.6-4.3h-.9l-.1-.9A5 5 0 0 0 9.8 7.6L8.4 6.2A7 7 0 0 1 12 4.5z"/>',
    paused: '<path d="M8 5a1 1 0 0 1 1 1v12a1 1 0 1 1-2 0V6a1 1 0 0 1 1-1zm8 0a1 1 0 0 1 1 1v12a1 1 0 1 1-2 0V6a1 1 0 0 1 1-1z"/>',
  };
  const svg = (name) => `<svg viewBox="0 0 24 24" aria-hidden="true">${ICONS[name]}</svg>`;
  const spinner = '<span class="tl-spin" aria-hidden="true"></span>';

  const LABEL = {
    idle: () => t("buttonIdle"), sending: () => t("stateSending"), queued: () => t("stateQueued"), downloading: () => t("stateDownloading"),
    done: () => t("stateDone"), failed: () => t("stateFailed"), offline: () => t("stateOffline"), paused: () => t("statePaused"), cancelled: () => t("stateCancelled"),
  };

  /// `https://x.com/<user>/status/<id>` of the post an article shows, or null (an ad, a deleted
  /// post). Its own time link first (a quoted post's comes later); X's signed-out pages have no
  /// time in the link, the post's own link comes first there.
  function postUrl(article) {
    const links = [...article.querySelectorAll('a[href*="/status/"]')];
    for (const a of [...links.filter((a) => a.querySelector("time")), ...links]) {
      const m = (a.getAttribute("href") || "").match(/^(?:https:\/\/(?:x|twitter)\.com)?\/([A-Za-z0-9_]+)\/status\/(\d+)/);
      if (m) return `https://x.com/${m[1]}/status/${m[2]}`;
    }
    return null;
  }

  function paint(button) {
    const task = byUrl.get(button.dataset.url);
    const state = task?.state || "idle";
    button.dataset.state = state;
    const icon = state === "sending" || state === "queued" || state === "downloading" ? spinner
      : state === "done" ? svg("done") : state === "failed" ? svg("failed") : state === "offline" ? svg("offline")
      : state === "paused" || state === "cancelled" ? svg("paused") : svg("idle");
    button.querySelector(".tl-icon").innerHTML = icon;
    let label = (LABEL[state] || LABEL.idle)();
    if (task && state !== "idle") label += ` — ${task.deviceName}`;
    if (task?.error) label += `\n${task.error}`;
    button.title = label;
    button.setAttribute("aria-label", label.split("\n")[0]);
  }

  function addButton(article) {
    if (article.dataset[MARK]) return;
    // the action bar (reply, repost, like, …): the post's last group of buttons
    const bar = [...article.querySelectorAll('[role="group"]')].filter((g) => g.closest("article") === article).pop();
    if (!bar || bar.children.length < 3) return;
    const url = postUrl(article);
    if (!url) return;
    article.dataset[MARK] = "1";
    const wrap = document.createElement("div");
    wrap.className = "tl-wrap";
    const button = document.createElement("button");
    button.type = "button";
    button.className = "tl-button";
    button.dataset.url = url;
    button.innerHTML = '<span class="tl-icon"></span>';
    button.addEventListener("click", (e) => { e.preventDefault(); e.stopPropagation(); activate(button, false); });
    button.addEventListener("contextmenu", (e) => { e.preventDefault(); e.stopPropagation(); activate(button, true); });
    wrap.appendChild(button);
    // before the share button (the last one), as X's own buttons sit
    const items = [...bar.children];
    const last = items[items.length - 1];
    if (last) bar.insertBefore(wrap, last); else bar.appendChild(wrap);
    paint(button);
  }

  function scan(root = document) {
    // signed in, posts are article[data-testid="tweet"]; signed out, plain articles
    for (const a of root.querySelectorAll("article")) addButton(a);
  }

  async function ask(msg) {
    try { return await chrome.runtime.sendMessage(msg); }
    catch { return { error: "reload" }; }
  }

  async function activate(button, choose) {
    const task = byUrl.get(button.dataset.url);
    // under way already: nothing to do (a click on a finished one sends it again)
    if (task && ["sending", "queued", "downloading"].includes(task.state) && !choose) return;
    const r = await ask({ type: "download", url: button.dataset.url, choose });
    if (r?.needsBinding) return bubble(button, t("needsBinding"), [{ label: t("openSetup"), run: () => ask({ type: "openSetup" }) }]);
    if (r?.needsChoice) return menu(button, r.devices);
    if (r?.error === "reload") return bubble(button, t("extensionReloaded"));
  }

  function closePopups() { document.querySelectorAll(".tl-pop").forEach((p) => p.remove()); }

  /// X's own theme (light, dim, lights out) decides, not the system's.
  function dark() {
    const m = getComputedStyle(document.body).backgroundColor.match(/\d+/g);
    return m ? (0.299 * m[0] + 0.587 * m[1] + 0.114 * m[2]) < 128 : matchMedia("(prefers-color-scheme: dark)").matches;
  }

  function place(pop, button) {
    pop.classList.toggle("tl-dark", dark());
    document.body.appendChild(pop);
    const b = button.getBoundingClientRect();
    const w = pop.offsetWidth, h = pop.offsetHeight;
    let left = Math.min(Math.max(8, b.left + b.width / 2 - w / 2), innerWidth - w - 8);
    let top = b.bottom + 6;
    if (top + h > innerHeight - 8) top = b.top - h - 6;
    pop.style.left = `${left}px`;
    pop.style.top = `${Math.max(8, top)}px`;
    setTimeout(() => document.addEventListener("pointerdown", function away(e) {
      if (!pop.contains(e.target)) { pop.remove(); document.removeEventListener("pointerdown", away, true); }
    }, true));
    addEventListener("scroll", () => pop.remove(), { once: true, passive: true });
  }

  function menu(button, devices) {
    closePopups();
    const pop = document.createElement("div");
    pop.className = "tl-pop tl-menu";
    pop.setAttribute("role", "menu");
    const title = document.createElement("div");
    title.className = "tl-pop-title";
    title.textContent = t("chooseDevice");
    pop.appendChild(title);
    for (const d of devices) {
      const item = document.createElement("button");
      item.type = "button";
      item.className = "tl-item";
      item.setAttribute("role", "menuitem");
      const name = document.createElement("span");
      name.textContent = d.name;
      const kind = document.createElement("span");
      kind.className = "tl-kind";
      kind.textContent = d.kind || "";
      item.append(name, kind);
      item.addEventListener("click", async (e) => {
        e.stopPropagation();
        pop.remove();
        await ask({ type: "download", url: button.dataset.url, deviceId: d.id });
      });
      pop.appendChild(item);
    }
    place(pop, button);
    pop.querySelector(".tl-item")?.focus();
  }

  function bubble(button, text, actions = []) {
    closePopups();
    const pop = document.createElement("div");
    pop.className = "tl-pop tl-bubble";
    const p = document.createElement("div");
    p.textContent = text;
    pop.appendChild(p);
    for (const a of actions) {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "tl-action";
      b.textContent = a.label;
      b.addEventListener("click", (e) => { e.stopPropagation(); pop.remove(); a.run(); });
      pop.appendChild(b);
    }
    place(pop, button);
    setTimeout(() => pop.remove(), 6000);
  }

  function refreshTasks(tasks) {
    const latest = new Map();
    for (const x of Object.values(tasks || {})) {
      const cur = latest.get(x.url);
      if (!cur || x.updated > cur.updated) latest.set(x.url, x);
    }
    byUrl = latest;
    document.querySelectorAll(".tl-button").forEach(paint);
  }

  chrome.storage.local.get({ tasks: {} }).then(({ tasks }) => refreshTasks(tasks));
  chrome.storage.onChanged.addListener((changes, area) => { if (area === "local" && changes.tasks) refreshTasks(changes.tasks.newValue); });

  // X builds its pages as one goes: new posts are found as they appear
  let queued = false;
  new MutationObserver(() => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => { queued = false; scan(); });
  }).observe(document.body, { childList: true, subtree: true });
  scan();
})();
