import { L, store, type CatalogEntry, type MediaRef, type ModelInfo, type TagCount } from '@twimshelf/core';
import { core } from '../../lib/core';
import { libraryChanged, libraryVersion } from '../../lib/library';
import { info as serverInfo, readSecret, serverFetch, updateSecrets } from './serverFiles';

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

/** The model a picture is tagged with, as the core takes it (core/src/ai/mod.rs). */
type ModelRef =
  | { kind: 'local'; id: string }
  | { kind: 'external'; id: string; url: string; model: string; key: string | null };

/** Why the core could not tag a picture (its `ai.kind`), as the message the page shows. */
const aiMessages: Record<string, string> = {
  badUrl: 'models.external.err.url',
  http: 'models.external.err.status',
  noModel: 'models.external.err.noModel',
  empty: 'models.external.err.empty',
  invalidResponse: 'models.external.err.empty',
  unreadable: 'ai.err.unreadable',
  badTags: 'ai.err.badReply',
  noTags: 'ai.err.noTags',
  noGpu: 'ai.err.noGpu',
};

/** The tags for one picture, from the core (on the server): it prepares the picture, asks the
 *  model and reads the tags out of the reply. `image`: a path in the library, or `frameB64`, a frame
 *  the page took from a video; neither: a plain grey picture (to try a model). */
async function coreTag(model: ModelRef, opts: {
  image?: string; frameB64?: string; existing?: string[]; vocabulary?: string[]; postText?: string; signal?: AbortSignal;
} = {}): Promise<string[]> {
  const job = `web-${crypto.getRandomValues(new Uint32Array(2)).join('-')}`;
  const request = {
    job, model, image: opts.image ?? '', existing: opts.existing ?? [], vocabulary: opts.vocabulary ?? [], post_text: opts.postText ?? null,
  };
  const stop = () => { void core.b.tl_ai_cancel(job).catch(() => {}); };
  opts.signal?.addEventListener('abort', stop);
  let reply: { ok?: { tags: string[] }; error?: string; ai?: { kind: string; status?: number; detail?: string } };
  try {
    const response = await serverFetch(`${core.transport.base}/api/ai/tag`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ request, frame_b64: opts.frameB64 }),
      signal: opts.signal,
    });
    if (!response.ok) throw new Error('common.notDone');
    reply = await response.json();
  } finally {
    opts.signal?.removeEventListener('abort', stop);
  }
  if (reply.ok) return reply.ok.tags;
  if (reply.ai?.kind === 'cancelled') throw new DOMException('Aborted', 'AbortError');
  const key = reply.ai ? aiMessages[reply.ai.kind] ?? 'common.notDone' : reply.error ?? 'common.notDone';
  const status = reply.ai?.status;
  throw Object.assign(new Error(key === 'models.external.err.status' ? L(key, status ?? 0) : key), { status });
}

export async function testModel(model: ExternalModel, key: string, clear: boolean) {
  return coreTag({ kind: 'external', id: model.id, url: model.url, model: model.model, key: key || (clear ? null : await modelCredential(model)) });
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

/** A tagger when there is none or the chosen one has gone: of the on-device models installed, the
 *  one that asks least of the machine, as the other apps choose (the person can choose another). */
export async function adoptInstalled(): Promise<void> {
  const current = activeTagger.get();
  const choices = await allTaggers();
  if (current && choices.some((c) => c.id === current)) return;
  const local = choices.filter((c) => c.kind === 'local');
  if (!local.length) {
    if (current) selectTagger('');
    return;
  }
  const catalog = await core.read<CatalogEntry[]>(core.b.tl_model_catalog('gguf')).catch(() => [] as CatalogEntry[]);
  const asks = (id: string) => catalog.find((c) => c.folder === id)?.recommend_gb ?? 1 << 30;
  local.sort((a, b) => asks(a.id) - asks(b.id));
  selectTagger(local[0].id);
}

/** Tags what waits when tagging is on, after choosing a tagger if a model came in (downloaded,
 *  imported, pulled) and none was chosen. Also called by the pages that see a download end. */
export function checkAutoTagging() {
  // a run going on already (its own refreshes come here every second)
  if (abort) return;
  void adoptInstalled().catch(() => {}).finally(() => {
    if (autoTag.get() && activeTagger.get() && Date.now() >= retryAfter) void runTagging({ automatic: true });
  });
}

export function enableAutoTagging() {
  if (interval !== undefined) return;
  interval = window.setInterval(checkAutoTagging, 15_000);
  unsubLib = libraryVersion.subscribe(checkAutoTagging);
  checkAutoTagging();
}

interface ResolvedRunner {
  id: string;
  name: string;
  model: ModelRef;
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
      model: { kind: 'external', id: extModel.id, url: extModel.url, model: extModel.model, key },
    };
  }
  const localModel = ai.supported ? local.find((m) => m.id === modelId && m.vision) : undefined;
  if (localModel) {
    return { id: localModel.id, name: localModel.repo || localModel.id, model: { kind: 'local', id: localModel.id } };
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
    const [epoch, counts] = await Promise.all([
      core.read<number>(core.b.tl_epoch()),
      core.read<[number, number]>(core.b.tl_ai_counts()).catch(() => [0, 0] as [number, number]),
    ]);
    const total = explicitItems ? explicitItems.length : retag ? counts[1] : Math.max(0, counts[1] - counts[0]);
    const since = Math.floor(Date.now() / 1000);
    let words: string[] = [];
    const loadVocab = async () => {
      const vocabulary = await core.read<TagCount[]>(core.b.tl_all_tags());
      words = [...vocabulary].sort((a, b) => b.count - a.count).slice(0, 150).map(({ label }) => label);
    };
    await loadVocab();
    let after = '';
    let processed = 0;
    let consecutiveFail = 0;
    // the grid shows the tags as they come: after each picture, at most once a second (a model on
    // the server's GPU takes seconds a picture)
    let shownAt = Date.now();
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
          const [frameB64, tags] = await Promise.all([
            item.kind === 'video' ? videoFrameB64(item.path, signal) : Promise.resolve(undefined),
            core.read<Array<[string, number]>>(core.b.tl_media_tags(item.media_id)),
          ]);
          const labels = await coreTag(runner.model, {
            image: item.kind === 'video' ? undefined : item.path, frameB64,
            existing: tags.map(([tag]) => tag), vocabulary: words, postText: item.text ?? undefined, signal,
          });
          if (!labels.length) throw new Error('ai.err.noTags');
          if (signal.aborted || (!opts.modelId && activeTagger.get() !== selected)) { await attempt('undo'); return false; }
          await core.readJson('tl_ai_apply', { epoch, media_id: item.media_id, model: runner.id, labels, replace_old: replace });
          consecutiveFail = 0;
          done++;
          tagging.set({ running: true, mode, modelName: runner.name, done, total: Math.max(total, done), currentPath: item.path, currentKind: item.kind, error: '' });
          if (Date.now() - shownAt >= 1000) { shownAt = Date.now(); libraryChanged(); }
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
