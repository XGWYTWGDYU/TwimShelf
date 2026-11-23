import { L, store, type MediaRef, type ModelInfo, type TagCount } from '@twimshelf/core';
import { core } from '../../lib/core';
import { libraryChanged, libraryVersion } from '../../lib/library';
import { info as serverInfo, readSecret, serverFetch, updateSecrets } from './serverFiles';
import { parseTags, thinkingOff } from './tagReply';

export interface ExternalModel { id: string; name: string; url: string; model: string }
export interface TaggerChoice { id: string; title: string; kind: 'local' | 'external' }
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

export async function localAIInfo(): Promise<{ supported: boolean; devices: string | null }> {
  try {
    const srv = await serverInfo();
    return srv.local_ai ?? { supported: false, devices: null };
  } catch {
    return { supported: false, devices: null };
  }
}

export async function installedLocalModels(): Promise<ModelInfo[]> {
  try {
    const all = await core.read<ModelInfo[]>(core.b.tl_models_installed());
    return all.filter((m) => m.format === 'gguf');
  } catch {
    return [];
  }
}

export async function allTaggers(): Promise<TaggerChoice[]> {
  const [ext, local, ai] = await Promise.all([
    externalModels().catch(() => [] as ExternalModel[]),
    installedLocalModels(),
    localAIInfo(),
  ]);
  const out: TaggerChoice[] = [];
  if (ai.supported) {
    for (const m of local) {
      if (m.vision) out.push({ id: m.id, title: m.repo || m.id, kind: 'local' });
    }
  }
  for (const m of ext) {
    out.push({ id: m.id, title: modelTitle(m), kind: 'external' });
  }
  return out;
}

export async function unloadLocalModels(): Promise<void> {
  try {
    await serverFetch(`${core.transport.base}/api/ai/unload`, { method: 'POST' });
  } catch { /* ignore */ }
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

async function completion(model: ExternalModel, key: string | null, prompt: Prompt, question: string, imageDataUrl: string, signal?: AbortSignal) {
  const name = model.model || (await proxy<{ data?: Array<{ id: string }> }>(endpoint(model.url, 'models'), key, undefined, signal)).data?.[0]?.id;
  if (!name) throw new Error('models.external.err.noModel');
  type Reply = { choices?: Array<{ message?: { content?: string | Array<{ type?: string; text?: string }> } }> };
  const url = endpoint(model.url, 'chat/completions');
  const ask = (extra: Record<string, unknown>) => proxy<Reply>(url, key, {
    ...extra, model: name, max_tokens: 300, stream: false, temperature: 0.1,
    messages: [
      { role: 'system', content: prompt.system },
      { role: 'user', content: [{ type: 'text', text: question }, { type: 'image_url', image_url: { url: imageDataUrl } }] },
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

async function localDescribe(modelId: string, prompt: Prompt, question: string, imageB64: string, signal?: AbortSignal): Promise<string[]> {
  const response = await serverFetch(`${core.transport.base}/api/ai/describe`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ model_id: modelId, image_b64: imageB64, system: prompt.system, question, max_tokens: 160 }),
    signal,
  });
  if (!response.ok) throw new Error('common.notDone');
  const reply = await response.json() as { ok?: string; error?: string };
  if (reply.error !== undefined) throw new Error(reply.error);
  return parseTags(reply.ok ?? '');
}

export async function testModel(model: ExternalModel, key: string, clear: boolean) {
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = 64;
  const context = canvas.getContext('2d');
  if (context) {
    context.fillStyle = '#888';
    context.fillRect(0, 0, 64, 64);
  }
  const prompt = await getPrompt(model.id);
  return completion(model, key || (clear ? null : await modelCredential(model)), prompt, prompt.prompt, canvas.toDataURL('image/jpeg', 0.8));
}

export const activeTagger = store(localStorage.getItem(selectionKey) ?? '');
export const autoTag = store(localStorage.getItem(autoKey) === 'true');

export interface TaggingState {
  running: boolean;
  mode: 'new' | 'retag' | 'item';
  modelName: string;
  done: number;
  total: number;
  currentPath: string | null;
  currentKind: string;
  error: string;
}

export const tagging = store<TaggingState>({
  running: false,
  mode: 'new',
  modelName: '',
  done: 0,
  total: 0,
  currentPath: null,
  currentKind: '',
  error: '',
});

export function selectTagger(id: string) {
  localStorage.setItem(selectionKey, id);
  activeTagger.set(id);
}

export function setAuto(enabled: boolean) {
  localStorage.setItem(autoKey, String(enabled));
  autoTag.set(enabled);
}

/** Extracts a video frame in the page at 33% of duration and fits it for vision models
 *  (long side <= 896, short side >= 112, black-padded to <= 4:1, JPEG q=0.8). */
async function videoFrameB64(path: string, signal: AbortSignal): Promise<string> {
  if (signal.aborted) throw new DOMException('Aborted', 'AbortError');
  const url = core.fileUrl(path);
  return new Promise<string>((resolve, reject) => {
    const v = document.createElement('video');
    v.muted = true;
    v.playsInline = true;
    v.preload = 'auto';
    let settled = false;
    const cleanup = () => {
      v.pause();
      v.removeAttribute('src');
      v.load();
      signal.removeEventListener('abort', onAbort);
      window.clearTimeout(timer);
    };
    const fail = (err: Error) => { if (settled) return; settled = true; cleanup(); reject(err); };
    const onAbort = () => fail(new DOMException('Aborted', 'AbortError'));
    signal.addEventListener('abort', onAbort);
    const timer = window.setTimeout(() => fail(new Error('ai.err.unreadable')), 15_000);
    v.onerror = () => fail(new Error('ai.err.unreadable'));
    v.onloadeddata = () => {
      const target = Number.isFinite(v.duration) && v.duration > 0 ? Math.min(v.duration * 0.33, Math.max(0, v.duration - 0.1)) : 0;
      if (target > 0.05) {
        try { v.currentTime = target; return; } catch { /* fall through */ }
      }
      capture();
    };
    v.onseeked = () => capture();
    const capture = () => {
      if (settled) return;
      const vw = v.videoWidth;
      const vh = v.videoHeight;
      if (!vw || !vh) { fail(new Error('ai.err.unreadable')); return; }
      const limit = 896;
      let w = vw;
      let h = vh;
      const fit = Math.min(1, limit / Math.max(w, h));
      w *= fit; h *= fit;
      const shortSide = Math.min(w, h);
      const longSide = Math.max(w, h);
      const maxGrow = longSide > 0 ? Math.max(1, limit / longSide) : 1;
      const grow = Math.min(Math.max(112 / shortSide, 1), maxGrow);
      const sw = Math.max(1, Math.round(w * grow));
      const sh = Math.max(1, Math.round(h * grow));
      const cw = Math.max(sw, Math.ceil(sh / 4));
      const ch = Math.max(sh, Math.ceil(sw / 4));
      const canvas = document.createElement('canvas');
      canvas.width = cw;
      canvas.height = ch;
      const ctx = canvas.getContext('2d');
      if (!ctx) { fail(new Error('ai.err.unreadable')); return; }
      ctx.fillStyle = '#000';
      ctx.fillRect(0, 0, cw, ch);
      ctx.drawImage(v, Math.floor((cw - sw) / 2), Math.floor((ch - sh) / 2), sw, sh);
      const dataUrl = canvas.toDataURL('image/jpeg', 0.8);
      const idx = dataUrl.indexOf(',');
      if (idx < 0) { fail(new Error('ai.err.unreadable')); return; }
      settled = true;
      cleanup();
      resolve(dataUrl.slice(idx + 1));
    };
    v.src = url;
  });
}

async function imageFor(item: MediaRef, signal: AbortSignal): Promise<{ dataUrl: string; b64: string }> {
  if (item.kind === 'video') {
    const b64 = await videoFrameB64(item.path, signal);
    return { b64, dataUrl: 'data:image/jpeg;base64,' + b64 };
  }
  const base = core.transport.base;
  const query = new URLSearchParams({ path: item.path, side: '896', whole: '1' });
  const response = await serverFetch(`${base}/api/scaled?${query}`, { signal });
  if (!response.ok) throw new Error('ai.err.unreadable');
  const b64 = base64(new Uint8Array(await response.arrayBuffer()));
  return { b64, dataUrl: 'data:image/jpeg;base64,' + b64 };
}

let abort: AbortController | undefined;
let finished: Promise<void> = Promise.resolve();
let interval: number | undefined;
let unsubLib: (() => void) | undefined;
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
  unsubLib = libraryVersion.subscribe(tick);
  tick();
}

interface ResolvedRunner {
  id: string;
  name: string;
  ask: (prompt: Prompt, question: string, img: { dataUrl: string; b64: string }, signal: AbortSignal) => Promise<string[]>;
}

async function resolveRunner(modelId: string): Promise<ResolvedRunner | null> {
  const [ext, local, ai] = await Promise.all([
    externalModels().catch(() => [] as ExternalModel[]),
    installedLocalModels(),
    localAIInfo(),
  ]);
  const extModel = ext.find((m) => m.id === modelId);
  if (extModel) {
    const key = await modelCredential(extModel);
    return {
      id: extModel.id,
      name: modelTitle(extModel),
      ask: (prompt, question, img, signal) => completion(extModel, key, prompt, question, img.dataUrl, signal),
    };
  }
  const localModel = ai.supported ? local.find((m) => m.id === modelId && m.vision) : undefined;
  if (localModel) {
    return {
      id: localModel.id,
      name: localModel.repo || localModel.id,
      ask: (prompt, question, img, signal) => localDescribe(localModel.id, prompt, question, img.b64, signal),
    };
  }
  return null;
}

export async function retagMedia(items: MediaRef[], modelId: string, replaceOld: boolean): Promise<void> {
  if (!items.length || !modelId) return;
  if (abort) { abort.abort(); await finished; }
  await runTagging({ modelId, replace: replaceOld, explicitItems: items });
}

export async function runTagging(opts: {
  retag?: boolean;
  replace?: boolean;
  automatic?: boolean;
  modelId?: string;
  explicitItems?: MediaRef[];
} = {}): Promise<void> {
  const { retag = false, replace = false, automatic = false, explicitItems } = opts;
  // asked for by hand while the automatic run is going: that run ends first
  if (abort && !automatic) { abort.abort(); await finished; }
  const selected = opts.modelId || activeTagger.get();
  if (abort || !selected) return;
  let ended = () => {};
  finished = new Promise<void>((resolve) => { ended = resolve; });
  const controller = abort = new AbortController();
  const { signal } = controller;
  let heartbeat: number | undefined;
  let done = 0;
  const mode: TaggingState['mode'] = explicitItems ? 'item' : retag ? 'retag' : 'new';
  try {
    const runner = await resolveRunner(selected);
    if (!runner) return;
    if (!await lease()) {
      if (!automatic) tagging.set({ running: false, mode, modelName: runner.name, done: 0, total: 0, currentPath: null, currentKind: '', error: 'web.ai.otherTab' });
      return;
    }
    heartbeat = window.setInterval(() => { void lease().then((held) => { if (!held) controller.abort(); }).catch(() => controller.abort()); }, 15_000);
    const [prompt, epoch, counts] = await Promise.all([
      getPrompt(runner.id),
      core.read<number>(core.b.tl_epoch()),
      core.read<[number, number]>(core.b.tl_ai_counts()).catch(() => [0, 0] as [number, number]),
    ]);
    const total = explicitItems ? explicitItems.length : retag ? counts[1] : Math.max(0, counts[1] - counts[0]);
    const since = Math.floor(Date.now() / 1000);
    const separator = L('list.separator');
    let words: string[] = [];
    const loadVocab = async () => {
      const vocabulary = await core.read<TagCount[]>(core.b.tl_all_tags());
      words = [...vocabulary].sort((a, b) => b.count - a.count).slice(0, 150).map(({ label }) => label);
    };
    await loadVocab();
    let after = '';
    let processed = 0;
    let consecutiveFail = 0;
    tagging.set({ running: true, mode, modelName: runner.name, done: 0, total, currentPath: null, currentKind: '', error: '' });

    const processBatch = async (batch: MediaRef[]) => {
      for (const item of batch) {
        if (signal.aborted || (!opts.modelId && activeTagger.get() !== selected) || await core.read<number>(core.b.tl_epoch()) !== epoch) return false;
        after = item.media_id;
        tagging.set({ running: true, mode, modelName: runner.name, done, total: Math.max(total, done), currentPath: item.path, currentKind: item.kind, error: '' });
        const trackAttempt = !retag && !explicitItems;
        const attempt = (step: string, reason = '') => trackAttempt
          ? core.readJson('tl_ai_attempt', { step, reason, model: runner.id, media_id: item.media_id, now: Math.floor(Date.now() / 1000) })
          : Promise.resolve();
        await attempt('begin');
        try {
          if (processed > 0 && processed % 10 === 0) await loadVocab();
          processed++;
          const [img, tags] = await Promise.all([
            imageFor(item, signal),
            core.read<Array<[string, number]>>(core.b.tl_media_tags(item.media_id)),
          ]);
          const rawPost = item.text?.replace(/https?:\/\/\S+|@[A-Za-z0-9_]{1,15}/g, '').trim() ?? '';
          const post = rawPost.length > 300 ? `${rawPost.slice(0, 300)}…` : rawPost;
          const question = [
            prompt.prompt,
            tags.length && prompt.existing.replaceAll('{existing}', tags.map(([tag]) => tag).join(separator)),
            words.length && prompt.vocabulary.replaceAll('{tags}', words.join(separator)),
            post && prompt.context.replaceAll('{text}', post),
          ].filter(Boolean).join('\n\n');
          const labels = await runner.ask(prompt, question, img, signal);
          if (!labels.length) throw new Error('ai.err.noTags');
          if (signal.aborted || (!opts.modelId && activeTagger.get() !== selected)) { await attempt('undo'); return false; }
          await core.readJson('tl_ai_apply', { epoch, media_id: item.media_id, model: runner.id, labels, replace_old: replace });
          consecutiveFail = 0;
          done++;
          tagging.set({ running: true, mode, modelName: runner.name, done, total: Math.max(total, done), currentPath: item.path, currentKind: item.kind, error: '' });
        } catch (error) {
          const reason = error instanceof Error ? error.message : 'common.notDone';
          if (await core.read<number>(core.b.tl_epoch()) !== epoch) return false;
          if (signal.aborted || !['ai.err.noTags', 'ai.err.badReply', 'ai.err.unreadable'].includes(reason)) {
            await attempt('undo');
            if (signal.aborted) return false;
            throw error;
          }
          await attempt('failed', reason);
          if (reason !== 'ai.err.unreadable') {
            consecutiveFail++;
            if (consecutiveFail >= 3) throw error;
          }
        }
      }
      return true;
    };

    if (explicitItems) {
      await processBatch(explicitItems);
    } else {
      while (!signal.aborted && (opts.modelId || activeTagger.get() === selected)) {
        const batch = await core.read<MediaRef[]>(retag ? core.b.tl_media_page(after, 32) : core.b.tl_ai_pending_for(runner.id, since, 32));
        if (!batch.length) break;
        const ok = await processBatch(batch);
        if (!ok) break;
        libraryChanged();
      }
    }
  } catch (error) {
    retryAfter = Date.now() + 60_000;
    tagging.set({ ...tagging.get(), running: false, done, error: error instanceof Error ? error.message : 'common.notDone' });
  } finally {
    if (heartbeat !== undefined) window.clearInterval(heartbeat);
    abort = undefined;
    tagging.set({ ...tagging.get(), running: false, currentPath: null });
    if (done) {
      libraryChanged();
    }
    ended();
  }
}

export function disposeAutoTagging() {
  if (interval !== undefined) { window.clearInterval(interval); interval = undefined; }
  unsubLib?.();
  unsubLib = undefined;
}
