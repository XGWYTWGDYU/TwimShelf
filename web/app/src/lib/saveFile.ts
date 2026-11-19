import { core } from './core';

type SaveResult = { status: 'saved'; savedName: string } | { status: 'cancelled' | 'download' };

export async function saveFile(path: string, name: string): Promise<SaveResult> {
  const url = core.fileUrl(path);
  if (window.twimshelf?.saveFile) {
    try {
      const savedName = await window.twimshelf.saveFile(url, name);
      return savedName ? { status: 'saved', savedName } : { status: 'cancelled' };
    } catch {
      throw new Error('common.notDone');
    }
  }
  const link = document.createElement('a');
  link.href = url;
  link.download = name;
  link.click();
  return { status: 'download' };
}
