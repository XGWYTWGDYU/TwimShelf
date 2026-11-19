// Auto-update for the Linux Electron desktop build (GitHub releases with TL_UPDATE_REPO).
// Strictly Electron-only: never runs or renders in the Docker/Web server UI.
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

export async function checkForUpdate(manual: boolean): Promise<void> {
  const tw = window.twimshelf;
  const repo = updateRepo();
  if (!tw?.desktop || !repo) return;

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
    const dest = await tw.installUpdate(staged);
    toast(dest);
  } catch (e) {
    if (manual) {
      const msg = e instanceof Error ? L(e.message) : L('common.notDone');
      await alertMessage(L('update.check'), L('update.failed', msg));
    }
  }
}
