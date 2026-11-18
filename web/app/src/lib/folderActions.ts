// Creating, renaming and deleting folders, from the sidebar, the overview, the grid's More menu and
// the menu bar (MacFolderActions): the same alerts and the same rules (a name that is taken merges
// the two, asked first).
import { L } from '@twimshelf/core';
import { alertMessage, choose, prompt } from '../components/pickers';
import { core } from './core';
import { folders, libraryChanged } from './library';

const message = (e: unknown) => L(String((e as Error)?.message ?? e));

/** A new folder; resolves to its name. */
export async function createFolder(): Promise<string | null> {
  const name = (await prompt(L('common.newFolder'), { placeholder: L('common.name') }))?.trim();
  if (!name) return null;
  try {
    await core.read(core.b.tl_create_folder(name));
    libraryChanged();
    return name;
  } catch (e) {
    await alertMessage(L('common.couldNotCreate'), message(e));
    return null;
  }
}

/** Renames a folder; resolves to the new name. */
export async function renameFolder(name: string): Promise<string | null> {
  const to = (await prompt(L('folder.rename.title'), { placeholder: L('common.name'), initial: name }))?.trim();
  if (!to || to === name) return null;
  if (folders.get()?.folders.some((f) => f.name === to)) {
    const ok = await choose(L('folder.merge.title', to), L('folder.merge.message', to, name, name), [L('folder.merge')]);
    if (ok == null) return null;
  }
  try {
    await core.readJson('tl_rename_folder', { old: name, new: to });
    libraryChanged();
    return to;
  } catch (e) {
    await alertMessage(L('common.couldNotRename'), message(e));
    return null;
  }
}

export async function deleteFolder(name: string): Promise<boolean> {
  const ok = await choose(L('folder.delete.title', name), L('folder.delete.message'), [L('folder.delete.confirm')], { destructive: true });
  if (ok == null) return false;
  try { await core.read(core.b.tl_delete_folder(name)); } catch { /* gone already */ }
  libraryChanged();
  return true;
}
