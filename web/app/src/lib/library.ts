// What the sidebar and pages share about the library: counts and folders, refreshed after changes.
import { store, type FolderOverview, type LibraryStats } from '@twimshelf/core';
import { core } from './core';

export const stats = store<LibraryStats | null>(null);
export const folders = store<FolderOverview | null>(null);
/** Bumped after anything that changes the feed (tags, folders, bin, imports): pages reload. */
export const libraryVersion = store(0);

export async function refreshLibrary(): Promise<void> {
  const [s, f] = await Promise.allSettled([
    core.read<LibraryStats>(core.b.tl_stats()),
    core.read<FolderOverview>(core.b.tl_folder_overview()),
  ]);
  if (s.status === 'fulfilled') stats.set(s.value);
  if (f.status === 'fulfilled') folders.set(f.value);
}

/** After a change to the library: counts, folders and every open list are read again. */
export function libraryChanged(): void {
  libraryVersion.set((v) => v + 1);
  void refreshLibrary();
}
