import { L, RemoteError } from '@twimshelf/core';
import { core } from '../../lib/core';

export interface ServerInfo {
  data: string;
  library: string;
  cache: string;
  uploads: string;
  exports: string;
  version: string;
  device_name: string;
  sync_service: string;
}

export async function serverFetch(url: string, init?: RequestInit): Promise<Response> {
  const headers = new Headers(init?.headers);
  if (window.twimshelf) headers.set('authorization', `Bearer ${window.twimshelf.token}`);
  const response = await fetch(url, { ...init, headers });
  if (response.status === 401 && !window.twimshelf) location.href = '/login';
  return response;
}

async function checked(response: Response): Promise<Response> {
  if (!response.ok) throw new RemoteError(response.status, 'common.notDone');
  return response;
}

export async function info(): Promise<ServerInfo> {
  return (await checked(await serverFetch(`${core.transport.base}/api/info`))).json();
}

export async function readText(path: string): Promise<string | null> {
  const response = await serverFetch(core.fileUrl(path), { cache: 'no-store' });
  return response.status === 404 ? null : (await checked(response)).text();
}

export async function writeText(path: string, body: string): Promise<void> {
  await checked(await serverFetch(core.fileUrl(path), { method: 'PUT', body }));
}

export async function removeFile(path: string): Promise<void> {
  await checked(await serverFetch(core.fileUrl(path), { method: 'DELETE' }));
}

export async function upload(file: File): Promise<string> {
  const query = new URLSearchParams({ name: file.name });
  const response = await checked(await serverFetch(`${core.transport.base}/api/upload?${query}`, { method: 'POST', body: file }));
  return ((await response.json()) as { path: string }).path;
}

export async function deliver(path: string, name: string): Promise<void> {
  const url = core.fileUrl(path);
  // Electron's renderer may have a different origin from its authenticated file server.
  const href = window.twimshelf ? URL.createObjectURL(await (await checked(await serverFetch(url))).blob()) : url;
  const link = document.createElement('a');
  link.href = href;
  link.download = name;
  link.click();
  if (window.twimshelf) setTimeout(() => URL.revokeObjectURL(href), 60_000);
}

export function outPath(server: ServerInfo, name: string): string {
  return `${server.exports}/${crypto.getRandomValues(new Uint32Array(2)).join('-')}-${name.replaceAll('/', '_').replaceAll('\\', '_')}`;
}

export function fileName(path: string): string {
  return path.split(/[\\/]/).pop() ?? path;
}

export function size(bytes: number): string {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let unit = 0;
  while (bytes >= 1000 && unit < units.length - 1) {
    bytes /= 1000;
    unit++;
  }
  return `${bytes.toLocaleString(undefined, { maximumFractionDigits: unit ? 1 : 0 })} ${units[unit]}`;
}

export function dateStamp(): string {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')} ${String(now.getHours()).padStart(2, '0')}.${String(now.getMinutes()).padStart(2, '0')}`;
}

export function openExternal(url: string): void {
  if (!/^https?:\/\//i.test(url)) return;
  if (window.twimshelf) window.twimshelf.openExternal(url);
  else window.open(url, '_blank', 'noopener,noreferrer');
}

let secretWrites: Promise<unknown> = Promise.resolve();

/** Same sealed server files used by Flutter and by the server at startup. */
export function updateSecrets(values: Record<string, string | null>): Promise<void> {
  const write = secretWrites.then(async () => {
    const server = await info();
    const keyPath = `${server.data}/app/secrets.key`;
    const file = `${server.data}/app/secrets.json`;
    const raw = await readText(file);
    const records = raw ? JSON.parse(raw) as Record<string, string> : {};
    let key = (await readText(keyPath))?.trim();
    for (const [name, value] of Object.entries(values)) {
      if (!value) {
        delete records[name];
        continue;
      }
      if (!key) {
        key = await core.read<string>(core.b.tl_secret_key());
        await writeText(keyPath, key);
      }
      records[name] = await core.read<string>(core.b.tl_secret_seal(key, value));
    }
    if (raw || Object.keys(records).length) await writeText(file, JSON.stringify(records));
  });
  secretWrites = write.catch(() => {});
  return write.catch(() => { throw new Error('settings.cookie.notSaved'); });
}

export async function readSecret(name: string): Promise<string | null> {
  await secretWrites;
  try {
    const server = await info();
    const raw = await readText(`${server.data}/app/secrets.json`);
    const sealed = raw ? (JSON.parse(raw) as Record<string, string>)[name] : undefined;
    const key = sealed && (await readText(`${server.data}/app/secrets.key`))?.trim();
    return key && sealed ? await core.read<string>(core.b.tl_secret_open(key, sealed)) : null;
  } catch {
    throw new Error(L('settings.cookie.notSaved'));
  }
}

export async function copyText(text: string): Promise<void> {
  if (navigator.clipboard) {
    await navigator.clipboard.writeText(text);
    return;
  }
  const focused = document.activeElement;
  const field = document.createElement('textarea');
  field.value = text;
  field.readOnly = true;
  field.style.position = 'fixed';
  field.style.opacity = '0';
  document.body.append(field);
  try {
    field.select();
    if (!document.execCommand('copy')) throw new Error('common.notDone');
  } finally {
    field.remove();
    if (focused instanceof HTMLElement) focused.focus();
  }
}
