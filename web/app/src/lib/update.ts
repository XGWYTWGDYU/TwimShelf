// 检查更新 (GitHub releases, in GitHub builds only). The Linux Electron build downloads and
// installs; the server's web page only tells of a newer release — a Docker image is updated on
// the server (`checkServerUpdate`).
import { L } from '@twimshelf/core';
import { alertMessage, choose } from '../components/pickers';
import { toast } from '../components/toast';
import { info as serverInfo } from '../pages/settings/serverFiles';
import { core } from './core';

export interface UpdateInfo {
  version: string;
  page_url: string;
  notes: string;
  asset_name?: string | null;
  asset_url?: string | null;
  asset_size: number;
  asset_digest?: string | null;
}

const ONE_DAY_MS = 24 * 60 * 60 * 1000;

export function updateRepo(): string {
  return window.twimshelf?.desktop ? (window.twimshelf.updateRepo ?? '') : '';
}

const SERVER_PREFS = 'web.update';

/** The server's web page: a newer release of the image, told once a day (never installed). */
async function checkServerUpdate(manual: boolean): Promise<void> {
  const srv = await serverInfo();
  const repo = srv.update_repo;
  if (!repo || !repo.includes('/')) return;
  let prefs: { lastCheck?: number; skipped?: string } = {};
  try { prefs = JSON.parse(localStorage.getItem(SERVER_PREFS) ?? '{}'); } catch { /* none kept */ }
  const save = (p: typeof prefs) => { try { localStorage.setItem(SERVER_PREFS, JSON.stringify(p)); } catch { /* not kept */ } };
  if (!manual && prefs.lastCheck && Date.now() - prefs.lastCheck < ONE_DAY_MS) return;
  try {
    const query = { repo, current: srv.version, suffixes: [], flutter: false };
    const update = await core.read<UpdateInfo | null>(core.b.tl_update_check(JSON.stringify(query)));
    save({ ...prefs, lastCheck: Date.now() });
    if (!update) {
      if (manual) await alertMessage(L('update.check'), L('update.current', srv.version));
      return;
    }
    if (!manual && prefs.skipped === update.version) return;
    const image = `ghcr.io/${repo.toLowerCase().split('/')[0]}/twimshelf:latest`;
    const msg = [L('update.available.message', srv.version), L('update.docker', image), update.notes.trim()].filter(Boolean).join('\n\n');
    const choice = await choose(L('update.available.title', update.version), msg, [L('update.skip'), L('update.later'), L('update.openPage')], { cancel: false });
    if (choice === 0) save({ ...prefs, lastCheck: Date.now(), skipped: update.version });
    if (choice === 2 && /^https:\/\/github\.com\//.test(update.page_url)) window.open(update.page_url, '_blank', 'noopener,noreferrer');
  } catch (e) {
    if (manual) {
      const msg = e instanceof Error ? L(e.message) : L('common.notDone');
      await alertMessage(L('update.check'), L('update.failed', msg));
    }
  }
}

export async function checkForUpdate(manual: boolean): Promise<void> {
  const tw = window.twimshelf;
  if (!tw?.desktop) return checkServerUpdate(manual);
  const repo = updateRepo();
  if (!repo) return;

  const current = tw.appVersion || (await serverInfo()).version;
  const prefs = (await tw.getUpdatePrefs?.()) ?? {};
  if (!manual && prefs.lastCheck && Date.now() - prefs.lastCheck < ONE_DAY_MS) return;

  try {
    const query = {
      repo,
      current,
      suffixes: tw.platform === 'darwin' ? ['.dmg'] : ['.AppImage'],
      flutter: false,
      arch: tw.arch || 'x64',
    };
    const update = await core.read<UpdateInfo | null>(core.b.tl_update_check(JSON.stringify(query)));
    await tw.setUpdatePrefs?.({ ...prefs, lastCheck: Date.now() });

    if (!update) {
      if (manual) await alertMessage(L('update.check'), L('update.current', current));
      return;
    }
    if (!manual && prefs.skipped === update.version) return;

    const msg = [L('update.available.message', current), update.notes.trim()].filter(Boolean).join('\n\n');
    const actionLabel = update.asset_url ? L('update.install') : L('update.openPage');
    const choice = await choose(
      L('update.available.title', update.version),
      msg,
      [L('update.skip'), L('update.later'), actionLabel],
      { cancel: false },
    );

    if (choice === 0) {
      await tw.setUpdatePrefs?.({ ...prefs, lastCheck: Date.now(), skipped: update.version });
      return;
    }
    if (choice !== 2) return;

    if (!update.asset_url || !tw.installUpdate) {
      window.open(update.page_url, '_blank', 'noopener,noreferrer');
      return;
    }

    toast(L('update.downloading'));
    const srv = await serverInfo();
    const staged = await core.read<string>(core.b.tl_update_download(JSON.stringify(update), srv.exports));
    const result = await tw.installUpdate(staged);
    if (result.replaced) {
      // in place: reopen now, or the next start is the new version
      const again = await choose(L('update.ready.title'), L('update.ready.message', update.version), [L('update.later'), L('update.relaunch')], { cancel: false });
      if (again === 1) await tw.relaunch?.();
    } else {
      toast(result.path);
    }
  } catch (e) {
    if (manual) {
      const msg = e instanceof Error ? L(e.message) : L('common.notDone');
      await alertMessage(L('update.check'), L('update.failed', msg));
    }
  }
}

export interface ExtensionManagedStatus {
  installed: boolean;
  version: string | null;
  dir: string;
}

export interface ExtensionUpdateCheck {
  installed: boolean;
  current: string | null;
  latest: string;
  has_update: boolean;
  page_url: string;
  dir: string;
}

let pendingExtAutoCheck = false;
const extCheckListeners = new Set<() => void>();

export function requestExtensionAutoCheck(): void {
  pendingExtAutoCheck = true;
  for (const fn of extCheckListeners) fn();
}

export function consumeExtensionAutoCheck(): boolean {
  const v = pendingExtAutoCheck;
  pendingExtAutoCheck = false;
  return v;
}

export function onExtensionAutoCheck(fn: () => void): () => void {
  extCheckListeners.add(fn);
  return () => extCheckListeners.delete(fn);
}

/** Downloads or updates the app-hosted extension in-place (desktop apps only; never touches Web/Docker). */
export async function installManagedExtension(updating: boolean): Promise<ExtensionManagedStatus | null> {
  const tw = window.twimshelf;
  if (!tw?.desktop) return null;
  try {
    toast(updating ? L('ext.managed.updating') : L('ext.managed.downloading'));
    const st = await core.read<ExtensionManagedStatus>(core.b.tl_ext_managed_install(updateRepo()));
    const prefs = (await tw.getUpdatePrefs?.()) ?? {};
    await tw.setUpdatePrefs?.({ ...prefs, extLastCheck: Date.now(), extSkipped: undefined });
    if (updating) {
      await alertMessage(L('ext.managed.updated.title', st.version ?? ''), L('ext.managed.updated.message'));
    } else {
      await alertMessage(L('ext.managed.downloaded.title'), L('ext.managed.downloaded.message', st.dir));
    }
    return st;
  } catch (e) {
    const msg = e instanceof Error ? L(e.message) : L('common.notDone');
    await alertMessage(L('ext.managed.title'), L('ext.managed.downloadFailed', msg));
    return null;
  }
}

/** Daily automatic update check for the app-hosted extension (desktop apps only, and only when the
 *  app already manages a copy in its data directory; external installs are never checked or touched). */
export async function checkExtensionUpdate(manual: boolean): Promise<ExtensionUpdateCheck | null> {
  const tw = window.twimshelf;
  if (!tw?.desktop) return null;
  try {
    const status = await core.read<ExtensionManagedStatus>(core.b.tl_ext_managed_status());
    if (!status.installed) return null;
    const prefs = (await tw.getUpdatePrefs?.()) ?? {};
    if (!manual && prefs.extLastCheck && Date.now() - prefs.extLastCheck < ONE_DAY_MS) return null;

    const info = await core.read<ExtensionUpdateCheck>(core.b.tl_ext_managed_check(updateRepo()));
    await tw.setUpdatePrefs?.({ ...prefs, extLastCheck: Date.now() });
    if (!info.installed) return info;
    if (!info.has_update) {
      if (manual) await alertMessage(L('ext.managed.title'), L('ext.managed.upToDate', info.current ?? info.latest));
      return info;
    }
    if (!manual && prefs.extSkipped === info.latest) return info;

    const buttons = manual
      ? [L('update.later'), L('ext.managed.updateNow')]
      : [L('update.skip'), L('update.later'), L('ext.managed.updateNow')];
    const choice = await choose(
      L('ext.managed.prompt.title', info.latest),
      L('ext.managed.prompt.message', info.current ?? ''),
      buttons,
      { cancel: false },
    );
    if (!manual && choice === 0) {
      await tw.setUpdatePrefs?.({ ...prefs, extLastCheck: Date.now(), extSkipped: info.latest });
      return info;
    }
    const updateIdx = manual ? 1 : 2;
    if (choice === updateIdx) await installManagedExtension(true);
    return info;
  } catch (e) {
    if (manual) {
      const msg = e instanceof Error ? L(e.message) : L('common.notDone');
      await alertMessage(L('ext.managed.title'), L('ext.managed.checkFailed', msg));
    }
    return null;
  }
}
