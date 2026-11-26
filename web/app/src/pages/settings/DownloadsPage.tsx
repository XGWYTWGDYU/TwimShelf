import { useEffect, useRef, useState } from 'react';
import { L, type CookieCheck, type DownloadRequest, type DownloadStatus } from '@twimshelf/core';
import {
  Check, ChevronDown, Download, FileText, Folder, Globe, Inbox, KeyRound,
  Lock, LockOpen, Plus, TriangleAlert, WandSparkles,
} from 'lucide-react';
import { Button, TextField } from '../../components/ui';
import { change, errorText, LoadState, useTask } from '../../components/libraryControls';
import { alertMessage, choose, prompt } from '../../components/pickers';
import { toast } from '../../components/toast';
import { core } from '../../lib/core';
import { useAsync, useInterval, useStore } from '../../lib/hooks';
import { folders, libraryChanged } from '../../lib/library';
import { removeFile, upload, writeText } from './serverFiles';
import {
  defaultDownloadOptions, downloadLinks, downloadOptionFile, downloadRoutes, parseLinks,
  readDownloadOptionFile, type DownloadOptions,
} from './downloadLinks';
import {
  ActivityRow, Card, ChipButton, CustomSlider, IconTile, OptionCard,
  Pill, PlaceholderEditor, RowDivider, SectionGroup, SettingsScreen,
} from './settingsControls';

type Options = DownloadOptions;
const defaults = defaultDownloadOptions;
let optionWrites: Promise<void> = Promise.resolve();
const routes = downloadRoutes;
const optionFile = downloadOptionFile;
const readOptions = readDownloadOptionFile;

export default function DownloadsPage() {
  const folderList = useStore(folders);
  const options = useAsync(async () => {
    const saved = await readOptions(await optionFile());
    return {
      route: routes.find((route) => route === saved.route) ?? defaults.route,
      concurrency: Number(saved.concurrency) || defaults.concurrency,
      intervalMs: saved.intervalMs == null ? defaults.intervalMs : Number(saved.intervalMs),
      folder: typeof saved.folder === 'string' && saved.folder ? saved.folder : null,
    };
  }, []);
  const [localConcurrency, setLocalConcurrency] = useState<number>();
  const [localInterval, setLocalInterval] = useState<number>();
  const links = useStore(downloadLinks);
  const setLinks = (text: string) => downloadLinks.set(text);
  const [batch, setBatch] = useState<{ name: string; urls: string[] }>();
  const [dropTargeted, setDropTargeted] = useState(false);
  const fileInput = useRef<HTMLInputElement>(null);
  const saveTimer = useRef<number | undefined>(undefined);
  const task = useTask();
  const status = useAsync(() => core.read<DownloadStatus>(core.b.tl_download_status()), []);
  useInterval(status.reload, status.loading ? null : 1200);
  const current = status.data;
  const done = current?.done ?? 0;
  useEffect(() => { if (done) libraryChanged(); }, [done, current?.generation]);

  async function save(next: Partial<Options>) {
    const write = optionWrites.then(async () => {
      const path = await optionFile();
      const saved = await readOptions(path);
      await writeText(path, JSON.stringify({ ...defaults, ...saved, ...next }));
    });
    optionWrites = write.catch(() => {});
    await write;
    options.reload();
  }

  const update = (next: Partial<Options>) => void task.run(() => save(next));

  // several quick changes (concurrency, then interval) are saved together
  const unsaved = useRef<Partial<Options>>({});
  const scheduleSave = (next: Partial<Options>) => {
    unsaved.current = { ...unsaved.current, ...next };
    if (saveTimer.current !== undefined) window.clearTimeout(saveTimer.current);
    saveTimer.current = window.setTimeout(() => {
      const all = unsaved.current;
      unsaved.current = {};
      void save(all).catch((error) => toast(errorText(error)));
    }, 250);
  };

  function download(urls: string[], bookmarks: boolean, resume = false) {
    if (!options.data) return;
    if (!resume && !urls.length) { toast(L('settings.links.empty')); return; }
    const config = options.data;
    const concurrency = localConcurrency ?? config.concurrency;
    const intervalMs = localInterval ?? config.intervalMs;
    void task.run(async () => {
      const request: DownloadRequest = {
        urls,
        route: config.route,
        concurrency,
        interval_ms: intervalMs,
        folder: config.folder,
        revive: !bookmarks && !resume,
        mark_recent: bookmarks && !resume,
      };
      await change(core.read(resume ? core.b.tl_download_resume(JSON.stringify(request)) : core.b.tl_download_start(JSON.stringify(request))));
      if (!resume) {
        if (bookmarks) setBatch(undefined);
        else setLinks('');
      }
      status.reload();
    });
  }

  function loadBatchFile(file: File) {
    void task.run(async () => {
      const path = await upload(file);
      try {
        const urls = await core.read<string[]>(core.b.tl_parse_bookmarks(path));
        setBatch({ name: file.name, urls });
      } catch (e) {
        await alertMessage(L('settings.json.unreadable'), L(String((e as Error)?.message ?? 'common.notDone')));
      } finally {
        await removeFile(path).catch(() => {});
      }
    });
  }

  async function createNewFolder() {
    const n = (await prompt(L('common.newFolder'), { placeholder: L('common.folderName'), action: L('common.create') }))?.trim();
    if (!n) return;
    await task.run(async () => {
      const created = await change(core.read<string>(core.b.tl_create_folder(n)).catch(() => n));
      await save({ folder: created });
    });
  }

  const config = options.error ? undefined : options.data;
  const canConfigure = !!config && !task.busy;
  const parsed = parseLinks(links);
  const concurrency = localConcurrency ?? config?.concurrency ?? defaults.concurrency;
  const intervalMs = localInterval ?? config?.intervalMs ?? defaults.intervalMs;

  const phaseKey = !current
    ? 'download.notYet'
    : current.running
      ? 'settings.downloading'
      : current.paused
        ? 'download.paused'
        : current.outcome === 'cancelled'
          ? 'download.cancelled'
          : current.failed
            ? 'download.partial'
            : current.total
              ? 'download.done'
              : 'download.notYet';

  const finishedCount = (current?.done ?? 0) + (current?.skipped ?? 0) + (current?.failed ?? 0);
  const recentPath = current?.recent.at(-1);

  return (
    <SettingsScreen title={L('common.downloadPosts')}>
      {current?.running && (
        <Card tint="accent" spacing={14}>
          <ActivityRow
            kind="download"
            title={L('activity.downloadingPosts')}
            detail={`${finishedCount} / ${current.total}${current.failed > 0 ? L('settings.failedSuffix', current.failed) : ''}${current.active.length ? L('activity.activeSuffix', current.active.length) : ''}`}
            progress={current.total > 0 ? finishedCount / current.total : undefined}
            previewPath={recentPath}
            previewIsVideo={recentPath ? /\.(mp4|mov|m4v|webm)$/i.test(recentPath) : false}
          />
          <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
            <Button disabled={task.busy} onClick={() => void task.run(async () => {
              await change(core.read(core.b.tl_download_stop(true)));
              status.reload();
            })}>{L('mac.pause')}</Button>
            <Button kind="danger" disabled={task.busy} onClick={() => void task.run(async () => {
              await change(core.read(core.b.tl_download_stop(false)));
              status.reload();
            })}>{L('settings.cancelDownload')}</Button>
          </div>
        </Card>
      )}

      {current && !current.running && current.total > 0 && (
        <div style={{ fontSize: 12, color: 'var(--fg-2)', padding: '0 4px' }}>
          {L(phaseKey)}{L('mac.download.progress', current.done, current.failed)}
        </div>
      )}

      {current && !current.running && current.paused > 0 && (
        <Card spacing={12}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10, flexWrap: 'wrap' }}>
            <span style={{ fontSize: 13.5, fontWeight: 500 }}>{L('mac.download.paused', current.paused)}</span>
            <div style={{ display: 'flex', gap: 8 }}>
              <Button kind="primary" disabled={!canConfigure} onClick={() => download([], false, true)}>{L('settings.resume')}</Button>
              <Button kind="danger" disabled={task.busy} onClick={() => void task.run(async () => {
                await change(core.read(core.b.tl_download_stop(false)));
                status.reload();
              })}>{L('settings.cancelJobs')}</Button>
            </div>
          </div>
          <div style={{ fontSize: 11, color: 'var(--fg-2)' }}>{L('settings.paused.footer')}</div>
        </Card>
      )}

      {!!options.error && <LoadState error={options.error} reload={options.reload} />}
      {!!status.error && <LoadState error={status.error} reload={status.reload} />}
      <SectionGroup title={L('settings.method')} note={L('mac.method.footer')}>
        <div className="option-cards-grid">
          <OptionCard
            title={L('common.auto')}
            detail={L('mac.method.auto')}
            icon={<WandSparkles size={16} strokeWidth={2} />}
            color="blue"
            disabled={!canConfigure}
            selected={config?.route === 'auto'}
            onClick={() => update({ route: 'auto' })}
          />
          <OptionCard
            title={L('settings.method.fx')}
            detail={L('mac.method.fx')}
            icon={<Globe size={16} strokeWidth={2} />}
            color="teal"
            disabled={!canConfigure}
            selected={config?.route === 'fx'}
            onClick={() => update({ route: 'fx' })}
          />
          <OptionCard
            title={L('settings.method.cookie')}
            detail={L('mac.method.cookie')}
            icon={<KeyRound size={16} strokeWidth={2} />}
            color="orange"
            disabled={!canConfigure}
            selected={config?.route === 'cookie'}
            onClick={() => update({ route: 'cookie' })}
          />
        </div>

        <Card spacing={10}>
          <div style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontSize: 13, fontWeight: 500 }}>
            <Folder size={15} strokeWidth={2} />
            <span>{L('mac.saveToFolder')}</span>
          </div>
          <div className="chips-row">
            <ChipButton
              title={L('mac.noFolder')}
              disabled={!canConfigure}
              selected={config?.folder === null}
              onClick={() => update({ folder: null })}
            />
            {(folderList?.folders ?? []).map((f) => (
              <ChipButton
                key={f.name}
                title={f.name}
                icon={<Folder size={11} strokeWidth={2.2} />}
                disabled={!canConfigure}
                selected={config?.folder === f.name}
                onClick={() => update({ folder: f.name })}
              />
            ))}
            {config?.folder && !(folderList?.folders ?? []).some((f) => f.name === config.folder) && (
              <ChipButton
                title={config.folder}
                icon={<Folder size={11} strokeWidth={2.2} />}
                selected
                disabled
                onClick={() => {}}
              />
            )}
            <ChipButton
              title={L('common.newFolderEllipsis')}
              icon={<Plus size={11} strokeWidth={2.4} />}
              dashed
              disabled={!canConfigure}
              onClick={() => void createNewFolder()}
            />
          </div>
        </Card>
      </SectionGroup>

      <SectionGroup title={L('common.downloadPosts')} note={L('mac.links.footer')}>
        <Card spacing={12}>
          <PlaceholderEditor
            value={links}
            onChange={setLinks}
            placeholder={L('mac.links.placeholder')}
            label={L('mac.links.label')}
            minHeight={120}
            disabled={task.busy}
          />
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
            {parsed.good > 0 && (
              <Pill text={L('mac.links.good', parsed.good)} color="green" icon={<Check size={10} strokeWidth={3} />} />
            )}
            {parsed.bad > 0 && (
              <Pill text={L('mac.links.bad', parsed.bad)} color="orange" icon={<TriangleAlert size={10} strokeWidth={2.5} />} />
            )}
            <div style={{ flex: 1 }} />
            <Button
              kind="primary"
              disabled={!canConfigure || (parsed.good === 0 && parsed.bad === 0)}
              onClick={() => {
                if (parsed.bad > 0) {
                  void alertMessage(L('settings.links.unrecognized'), parsed.badUrls.slice(0, 3).join('\n'));
                  return;
                }
                download(parsed.goodUrls, false);
              }}>
              <Download size={14} strokeWidth={2.2} />
              <span>{L('common.download')}</span>
            </Button>
          </div>
        </Card>
      </SectionGroup>

      <SectionGroup title={L('settings.batch')}>
        <Card spacing={16}>
          <input
            ref={fileInput}
            type="file"
            accept=".json,application/json"
            hidden
            onChange={(e) => {
              const file = e.target.files?.[0];
              e.target.value = '';
              if (file) loadBatchFile(file);
            }}
          />
          <button
            type="button"
            className={`batch-dropzone${dropTargeted ? ' targeted' : ''}`}
            disabled={task.busy}
            onClick={() => fileInput.current?.click()}
            onDragEnter={(e) => { e.preventDefault(); e.stopPropagation(); setDropTargeted(true); }}
            onDragOver={(e) => { e.preventDefault(); e.stopPropagation(); setDropTargeted(true); }}
            onDragLeave={(e) => { e.preventDefault(); e.stopPropagation(); setDropTargeted(false); }}
            onDrop={(e) => {
              e.preventDefault();
              e.stopPropagation();
              setDropTargeted(false);
              const file = e.dataTransfer?.files?.[0];
              if (file) loadBatchFile(file);
            }}>
            <IconTile
              icon={batch ? <FileText size={20} strokeWidth={2} /> : <Inbox size={20} strokeWidth={2} />}
              color={batch ? 'green' : 'indigo'}
              size={42}
            />
            <div className="card-row-texts">
              <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--fg)' }}>
                {batch ? batch.name : L('mac.batch.drop')}
              </div>
              <div className="card-row-detail">
                {batch ? L('mac.batch.loaded', batch.urls.length) : L('mac.batch.drop.detail')}
              </div>
            </div>
            {batch && (
              <Pill text={L('mac.batch.count', batch.urls.length)} color="green" icon={<Check size={10} strokeWidth={3} />} />
            )}
          </button>

          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            <div className="slider-row">
              <div className="slider-row-meta">
                <div className="slider-row-title">{L('mac.batch.concurrency')}</div>
                <div className="slider-row-note">{L('mac.batch.concurrency.detail')}</div>
              </div>
              <CustomSlider
                label={L('mac.batch.concurrency')}
                value={concurrency}
                min={1}
                max={16}
                step={1}
                disabled={!canConfigure}
                onChange={(v) => {
                  setLocalConcurrency(v);
                  scheduleSave({ concurrency: v });
                }}
              />
              <div className="slider-row-value">{config ? concurrency : '–'}</div>
            </div>

            <div className="slider-row">
              <div className="slider-row-meta">
                <div className="slider-row-title">{L('settings.batch.interval')}</div>
                <div className="slider-row-note">{L('mac.batch.interval.detail')}</div>
              </div>
              <CustomSlider
                label={L('settings.batch.interval')}
                value={intervalMs}
                min={0}
                max={10000}
                step={250}
                disabled={!canConfigure}
                onChange={(v) => {
                  setLocalInterval(v);
                  scheduleSave({ intervalMs: v });
                }}
              />
              <div className="slider-row-value">
                {config ? L('settings.batch.seconds', (intervalMs / 1000).toFixed(2)) : '–'}
              </div>
            </div>
          </div>

          <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
            <Button
              kind="primary"
              disabled={!canConfigure || !batch?.urls.length}
              onClick={() => batch && download(batch.urls, true)}>
              <Download size={14} strokeWidth={2.2} />
              <span>{L('settings.batch.start')}</span>
            </Button>
          </div>
        </Card>
      </SectionGroup>

      <CookieSettings />

      {!!current?.errors.length && (
        <SectionGroup title={L('mac.failures', current.errors.length)}>
          <Card tint="orange" spacing={10}>
            {current.errors.slice(-8).reverse().map(([url, reason], i) => (
              <div key={i} style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
                <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--fg)', overflowWrap: 'anywhere' }}>{url}</div>
                <div className="selectable" style={{ fontSize: 11, color: 'var(--fg-2)', overflowWrap: 'anywhere' }}>{L(reason)}</div>
              </div>
            ))}
          </Card>
        </SectionGroup>
      )}
    </SettingsScreen>
  );
}

interface CookieAccount {
  id: string;
  label: string;
  auth_token: string;
  ct0: string;
  screen_name?: string | null;
  created_at: number;
}

function cookieDisplayName(a: CookieAccount): string {
  if (a.label.trim()) return a.label.trim();
  if (a.screen_name) return `@${a.screen_name}`;
  return L('cookie.unnamed');
}

function CookieSettings() {
  const accounts = useAsync(() => core.read<CookieAccount[]>(core.b.tl_cookies_list()), []);
  const [expanded, setExpanded] = useState<Set<string>>(() => new Set());
  const [adding, setAdding] = useState(false);

  const list = accounts.data ?? [];
  const loading = !accounts.data && !accounts.error;

  function toggleExpand(id: string) {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  async function removeAccount(acc: CookieAccount) {
    const ok = await choose(
      L('cookie.delete.title', cookieDisplayName(acc)),
      L('cookie.delete.message'),
      [L('common.delete')],
      { destructive: true },
    );
    if (ok == null) return;
    await core.read(core.b.tl_cookie_delete(acc.id));
    setExpanded((prev) => {
      const next = new Set(prev);
      next.delete(acc.id);
      return next;
    });
    accounts.reload();
  }

  return (
    <SectionGroup
      title={L('mac.cookie')}
      note={L('cookie.multi.footer')}
      trailing={
        <Pill
          text={loading ? L('mac.preparing') : list.length ? L('cookie.count', String(list.length)) : L('mac.notSet')}
          color={list.length ? 'green' : 'secondary'}
          icon={list.length ? <Lock size={10} strokeWidth={2.5} /> : <LockOpen size={10} strokeWidth={2.5} />}
        />
      }>
      {accounts.error ? (
        <LoadState error={accounts.error} reload={accounts.reload} />
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          {!list.length && !adding && (
            <Card><span style={{ fontSize: 13, color: 'var(--fg-2)' }}>{L('cookie.noneAdded')}</span></Card>
          )}
          {list.map((acc) => {
            const open = expanded.has(acc.id);
            const masked = acc.auth_token.length > 4 ? `••••${acc.auth_token.slice(-4)}` : '••••';
            return (
              <Card key={acc.id} spacing={12}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                  <IconTile icon={<KeyRound size={17} strokeWidth={2} />} color="orange" size={36} />
                  <div className="card-row-texts" style={{ gap: 4 }}>
                    <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--fg)' }}>{cookieDisplayName(acc)}</div>
                    <div className="chips-row" style={{ gap: 5 }}>
                      {acc.screen_name && <Pill text={`@${acc.screen_name}`} color="blue" />}
                      <Pill text={masked} color="secondary" />
                    </div>
                  </div>
                  <button
                    type="button"
                    className="icon-btn"
                    aria-label={L('models.expand')}
                    onClick={() => toggleExpand(acc.id)}>
                    <ChevronDown
                      size={15}
                      strokeWidth={2.2}
                      style={{ transform: open ? 'rotate(180deg)' : undefined, transition: 'transform 0.18s' }}
                    />
                  </button>
                </div>
                {open && (
                  <>
                    <RowDivider />
                    <CookieAccountEditor
                      account={acc}
                      onSaved={() => accounts.reload()}
                      onDelete={() => void removeAccount(acc)}
                    />
                  </>
                )}
              </Card>
            );
          })}
          {adding ? (
            <Card spacing={12}>
              <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--fg)' }}>{L('cookie.add')}</div>
              <CookieAccountEditor
                onSaved={(saved) => {
                  setAdding(false);
                  setExpanded((prev) => new Set(prev).add(saved.id));
                  accounts.reload();
                }}
                onCancel={() => setAdding(false)}
              />
            </Card>
          ) : (
            <Card spacing={0}>
              <button
                type="button"
                style={{
                  display: 'flex', alignItems: 'center', gap: 12, width: '100%',
                  background: 'none', border: 'none', padding: 0, cursor: 'pointer', color: 'var(--fg)', textAlign: 'left',
                }}
                onClick={() => setAdding(true)}>
                <IconTile icon={<Plus size={16} strokeWidth={2.4} />} color="blue" size={32} />
                <span style={{ fontSize: 13.5, fontWeight: 600 }}>{L('cookie.add')}</span>
              </button>
            </Card>
          )}
        </div>
      )}
    </SectionGroup>
  );
}

function CookieAccountEditor({
  account,
  onSaved,
  onDelete,
  onCancel,
}: {
  account?: CookieAccount;
  onSaved: (saved: CookieAccount) => void;
  onDelete?: () => void;
  onCancel?: () => void;
}) {
  const [label, setLabel] = useState(account?.label ?? '');
  const [authToken, setAuthToken] = useState(account?.auth_token ?? '');
  const [ct0, setCt0] = useState(account?.ct0 ?? '');
  const [screenName, setScreenName] = useState<string | null>(account?.screen_name ?? null);
  const task = useTask();

  async function save() {
    const a = authToken.trim();
    const c = ct0.trim();
    if (!a || !c) {
      await alertMessage(L('cookie.fillBoth'));
      return;
    }
    await task.run(async () => {
      const saved = await core.read<CookieAccount>(
        core.b.tl_cookie_save(JSON.stringify({
          id: account?.id ?? null,
          label: label.trim(),
          auth_token: a,
          ct0: c,
          screen_name: screenName,
        })),
      );
      toast(L('settings.cookie.saved'));
      onSaved(saved);
    });
  }

  async function check() {
    const a = authToken.trim();
    const c = ct0.trim();
    if (!a || !c) {
      await alertMessage(L('cookie.fillBoth'));
      return;
    }
    await task.run(async () => {
      const result = await core.read<CookieCheck>(core.b.tl_check_cookies(a, c));
      if (!result.error && result.screen_name) {
        setScreenName(result.screen_name);
        if (account) {
          const saved = await core.read<CookieAccount>(
            core.b.tl_cookie_save(JSON.stringify({
              id: account.id,
              label: label.trim(),
              auth_token: a,
              ct0: c,
              screen_name: result.screen_name,
            })),
          );
          onSaved(saved);
        }
      }
      await alertMessage(
        result.error ? L('cookie.invalid') : L('cookie.signedIn', result.screen_name ?? ''),
        result.error ? L(result.error) : (result.name ?? ''),
      );
    });
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
      <div className="secret-field-row">
        <span className="secret-field-name">{L('cookie.label')}</span>
        <TextField value={label} onChange={setLabel} />
      </div>
      <div className="secret-field-row">
        <span className="secret-field-name">auth_token</span>
        <TextField value={authToken} onChange={setAuthToken} />
      </div>
      <div className="secret-field-row">
        <span className="secret-field-name">ct0</span>
        <TextField value={ct0} onChange={setCt0} />
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
        {onDelete && (
          <Button kind="danger" disabled={task.busy} onClick={onDelete}>{L('common.delete')}</Button>
        )}
        {onCancel && (
          <Button disabled={task.busy} onClick={onCancel}>{L('common.cancel')}</Button>
        )}
        <div style={{ flex: 1 }} />
        <Button disabled={task.busy} onClick={() => void check()}>{L('settings.cookie.check')}</Button>
        <Button kind="primary" disabled={task.busy} onClick={() => void save()}>{L('common.save')}</Button>
      </div>
    </div>
  );
}
