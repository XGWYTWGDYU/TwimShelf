import { L, store, type MediaRef, type TagCount } from '@twimshelf/core';
import { core } from '../../lib/core';
import { libraryChanged } from '../../lib/library';
import { readSecret, serverFetch, updateSecrets } from './serverFiles';
import { parseTags, thinkingOff } from './tagReply';

export interface ExternalModel { id: string; name: string; url: string; model: string }
export const promptFields = ['system', 'prompt', 'existing', 'vocabulary', 'context'] as const;
export type Prompt = Record<typeof promptFields[number], string>;
const modelsKey = 'ai.external';
const selectionKey = 'twimshelf.ai.tagger';
const autoKey = 'twimshelf.ai.auto';

export function modelTitle(model: ExternalModel): string {
  return model.name || model.model || model.url;
}

export function endpoint(url: string, path: string): URL {
  try {
    const address = new URL(url.includes('://') ? url : `http://${url}`);
    if (!['https:', 'http:'].includes(address.protocol) || address.username || address.password || address.search || address.hash) {
      throw new Error();
    }
    address.pathname = address.pathname.replace(/\/+$/, '').replace(/\/(models|chat\/completions)$/, '');
    if (!address.pathname.endsWith('/v1')) address.pathname += '/v1';
    address.pathname += '/' + path;
    return address;
  } catch {
    throw new Error('models.external.err.url');
  }
}

const setting = (key: string) => core.read<string | null>(core.b.tl_setting(key));
export const setSetting = (key: string, value: string | null) => core.read(core.b.tl_set_setting(key, value));
export async function externalModels(): Promise<ExternalModel[]> {
  return JSON.parse(await setting(modelsKey) ?? '[]') as ExternalModel[];
}

function credentialKeys(id: string) {
  return { key: `ai.key.${id}`, origin: `ai.keyorigin.${id}` };
}

async function modelCredential(model: ExternalModel): Promise<string | null> {
  const keys = credentialKeys(model.id);
  const origin = await readSecret(keys.origin);
  if (!origin || new URL(origin).origin !== endpoint(model.url, 'models').origin) return null;
  return readSecret(keys.key);
}

export async function saveModel(model: ExternalModel, key: string, clear: boolean) {
  const origin = endpoint(model.url, 'models').origin;
  const models = await externalModels();
  const old = models.find((item) => item.id === model.id);
  const keys = credentialKeys(model.id);
  if (key || clear || (old && endpoint(old.url, 'models').origin !== origin)) {
    await updateSecrets({ [keys.key]: key || null, [keys.origin]: key ? origin : null });
  }
  await setSetting(modelsKey, JSON.stringify([...models.filter((item) => item.id !== model.id), model]));
}

export async function deleteModel(model: ExternalModel) {
  const keys = credentialKeys(model.id);
  await updateSecrets({ [keys.key]: null, [keys.origin]: null });
  await setSetting(modelsKey, JSON.stringify((await externalModels()).filter((item) => item.id !== model.id)));
  await setSetting(`ai.modelPrompt.${model.id}`, null);
}

export function defaultPrompt(): Prompt {
  return Object.fromEntries(promptFields.map((key) => [key, L(`prompt.default.${key}`)])) as Prompt;
}

export async function getPrompt(id: string): Promise<Prompt> {
  const own = await setting(`ai.modelPrompt.${id}`);
  if (own) return { ...defaultPrompt(), ...JSON.parse(own) };
  const assigned = JSON.parse(await setting('ai.modelPrompts') ?? '{}')?.[id];
  if (assigned) {
    const prompts: Array<{ id: string; prompt: Partial<Prompt> }> = JSON.parse(await setting('ai.prompts') ?? '[]');
    const prompt = prompts.find((entry) => entry.id === assigned)?.prompt;
    if (prompt) return { ...defaultPrompt(), ...prompt };
  }
  return { ...defaultPrompt(), ...JSON.parse(await setting('ai.prompt') ?? '{}') };
}

function base64(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(binary);
}

async function proxy<T>(url: URL, key: string | null, body?: unknown, signal?: AbortSignal): Promise<T> {
  const headers = [['content-type', 'application/json']];
  if (key) headers.push(['authorization', `Bearer ${key}`]);
  let response: Response;
  try {
    response = await serverFetch(`${core.transport.base}/api/proxy`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ url: url.href, method: body ? 'POST' : 'GET', headers,
        body: body ? base64(new TextEncoder().encode(JSON.stringify(body))) : undefined }),
      signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(120_000)]) : AbortSignal.timeout(120_000),
    });
  } catch {
    throw new Error('common.notDone');
  }
  if (!response.ok) throw new Error('common.notDone');
  const reply = await response.json() as { status: number; body: string };
  if (reply.status < 200 || reply.status >= 300) throw Object.assign(new Error(L('models.external.err.status', reply.status)), { status: reply.status });
  if (reply.body.length > 3_000_000) throw new Error('models.external.err.empty');
  try {
    return JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(reply.body), (c) => c.charCodeAt(0)))) as T;
  } catch {
    throw new Error('models.external.err.empty');
  }
}

/** Servers that refused the switch for reasoning: asked plainly from then on. */
const refusedThinkingOff = new Set<string>();

async function completion(model: ExternalModel, key: string | null, prompt: Prompt, question: string, image: string, signal?: AbortSignal) {
  const name = model.model || (await proxy<{ data?: Array<{ id: string }> }>(endpoint(model.url, 'models'), key, undefined, signal)).data?.[0]?.id;
  if (!name) throw new Error('models.external.err.noModel');
  type Reply = { choices?: Array<{ message?: { content?: string | Array<{ type?: string; text?: string }> } }> };
  const url = endpoint(model.url, 'chat/completions');
  const ask = (extra: Record<string, unknown>) => proxy<Reply>(url, key, {
    ...extra, model: name, max_tokens: 300, stream: false, temperature: 0.1,
    messages: [
      { role: 'system', content: prompt.system },
      { role: 'user', content: [{ type: 'text', text: question }, { type: 'image_url', image_url: { url: image } }] },
    ],
  }, signal);
  const off = refusedThinkingOff.has(model.url) ? {} : thinkingOff(url.hostname);
  let result: Reply;
  try {
    result = await ask(off);
  } catch (error) {
    const status = (error as { status?: number }).status;
    if (!Object.keys(off).length || (status !== 400 && status !== 422)) throw error;
    refusedThinkingOff.add(model.url);
    result = await ask({});
  }
  const content = result.choices?.[0]?.message?.content ?? '';
  // (never the parts that hold the model's reasoning)
  return parseTags(typeof content === 'string' ? content : content.filter((p) => !/think|reason/i.test(p.type ?? '')).map((p) => p.text ?? '').join(''));
}

export async function testModel(model: ExternalModel, key: string, clear: boolean) {
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = 32;
  const context = canvas.getContext('2d');
  if (context) {
    context.fillStyle = '#888';
    context.fillRect(0, 0, 32, 32);
  }
  const prompt = await getPrompt(model.id);
  return completion(model, key || (clear ? null : await modelCredential(model)), prompt, prompt.prompt, canvas.toDataURL('image/jpeg'));
}

export const activeTagger = store(localStorage.getItem(selectionKey) ?? '');
export const autoTag = store(localStorage.getItem(autoKey) === 'true');
export const tagging = store({ running: false, done: 0, error: '' });
export function selectTagger(id: string) {
  localStorage.setItem(selectionKey, id);
  activeTagger.set(id);
}

export function setAuto(enabled: boolean) {
  localStorage.setItem(autoKey, String(enabled));
  autoTag.set(enabled);
}

let abort: AbortController | undefined;
let finished: Promise<void> = Promise.resolve();
let interval: number | undefined;
let retryAfter = 0;
const leaseId = crypto.getRandomValues(new Uint32Array(4)).join('-');

async function lease(): Promise<boolean> {
  const response = await serverFetch(`${core.transport.base}/api/lease`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ id: leaseId }),
  });
  return response.ok && ((await response.json()) as { holder: boolean }).holder;
}

export function stopTagging() {
  abort?.abort();
}

export function enableAutoTagging() {
  if (interval !== undefined) return;
  const tick = () => {
    if (autoTag.get() && activeTagger.get() && Date.now() >= retryAfter) void runTagging({ automatic: true });
  };
  interval = window.setInterval(tick, 15_000);
  tick();
}

async function imageFor(item: MediaRef, signal: AbortSignal): Promise<string> {
  const base = core.transport.base;
  const query = new URLSearchParams({ path: item.path, side: '768', whole: '1' });
  const response = await serverFetch(`${base}/api/${item.kind === 'video' ? 'poster' : 'scaled'}?${query}`, { signal });
  if (!response.ok) throw new Error('ai.err.unreadable');
  const picture = item.kind === 'video'
    ? await serverFetch(core.fileUrl(((await response.json()) as { path: string }).path), { signal })
    : response;
  if (!picture.ok) throw new Error('ai.err.unreadable');
  return 'data:image/jpeg;base64,' + base64(new Uint8Array(await picture.arrayBuffer()));
}

export async function runTagging({ retag = false, replace = false, automatic = false } = {}): Promise<void> {
  // asked for by hand while the automatic run is going: that run ends first
  if (abort && !automatic) { abort.abort(); await finished; }
  const selected = activeTagger.get();
  if (abort || !selected) return;
  let ended = () => {};
  finished = new Promise<void>((resolve) => { ended = resolve; });
  const controller = abort = new AbortController();
  const { signal } = controller;
  let heartbeat: number | undefined;
  let done = 0;
  try {
    const model = (await externalModels()).find((entry) => entry.id === selected);
    if (!model) return;
    if (!await lease()) {
      if (!automatic) tagging.set({ running: false, done: 0, error: 'web.ai.otherTab' });
      return;
    }
    heartbeat = window.setInterval(() => { void lease().then((held) => { if (!held) controller.abort(); }).catch(() => controller.abort()); }, 15_000);
    const [key, prompt, epoch, vocabulary] = await Promise.all([
      modelCredential(model), getPrompt(model.id), core.read<number>(core.b.tl_epoch()),
      core.read<TagCount[]>(core.b.tl_all_tags()),
    ]);
    const since = Math.floor(Date.now() / 1000);
    const words = [...vocabulary].sort((a, b) => b.count - a.count).slice(0, 150).map(({ label }) => label);
    const separator = L('list.separator');
    let after = '';
    tagging.set({ running: true, done: 0, error: '' });
    while (!signal.aborted && activeTagger.get() === selected) {
      const batch = await core.read<MediaRef[]>(retag ? core.b.tl_media_page(after, 32) : core.b.tl_ai_pending_for(model.id, since, 32));
      if (!batch.length) break;
      for (const item of batch) {
        if (signal.aborted || activeTagger.get() !== selected || await core.read<number>(core.b.tl_epoch()) !== epoch) return;
        after = item.media_id;
        const attempt = (step: string, reason = '') => core.readJson('tl_ai_attempt', {
          step, reason, model: model.id, media_id: item.media_id, now: Math.floor(Date.now() / 1000),
        });
        await attempt('begin');
        try {
          const [image, tags] = await Promise.all([
            imageFor(item, signal), core.read<Array<[string, number]>>(core.b.tl_media_tags(item.media_id)),
          ]);
          const post = item.text?.replace(/https?:\/\/\S+|@[A-Za-z0-9_]{1,15}/g, '').trim().slice(0, 300);
          const question = [prompt.prompt, tags.length && prompt.existing.replaceAll('{existing}', tags.map(([tag]) => tag).join(separator)),
            words.length && prompt.vocabulary.replaceAll('{tags}', words.join(separator)), post && prompt.context.replaceAll('{text}', post)]
            .filter(Boolean).join('\n\n');
          const labels = await completion(model, key, prompt, question, image, signal);
          if (!labels.length) throw new Error('ai.err.noTags');
          if (signal.aborted || activeTagger.get() !== selected) { await attempt('undo'); return; }
          await core.readJson('tl_ai_apply', { epoch, media_id: item.media_id, model: model.id, labels, replace_old: replace });
          tagging.set({ running: true, done: ++done, error: '' });
        } catch (error) {
          const reason = error instanceof Error ? error.message : 'common.notDone';
          if (await core.read<number>(core.b.tl_epoch()) !== epoch) return;
          if (signal.aborted || !['ai.err.noTags', 'ai.err.badReply', 'ai.err.unreadable'].includes(reason)) {
            await attempt('undo');
            if (signal.aborted) return;
            throw error;
          }
          await attempt('failed', reason);
        }
      }
      libraryChanged();
    }
  } catch (error) {
    retryAfter = Date.now() + 60_000;
    tagging.set({ running: false, done, error: error instanceof Error ? error.message : 'common.notDone' });
  } finally {
    if (heartbeat !== undefined) window.clearInterval(heartbeat);
    abort = undefined;
    tagging.set({ ...tagging.get(), running: false });
    if (done) libraryChanged();
    ended();
  }
}
