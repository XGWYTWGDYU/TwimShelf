import { useEffect, useState } from 'react';
import { L, type CookieCheck, type DownloadRequest, type DownloadRoute, type DownloadStatus } from '@twimshelf/core';
import { KeyRound } from 'lucide-react';
import { Button, Row, Section } from '../../components/ui';
import { FileButton, LoadState, NameDialog, Select, change, useTask } from '../../components/libraryControls';
import { toast } from '../../components/toast';
import { core } from '../../lib/core';
import { useAsync, useInterval } from '../../lib/hooks';
import { libraryChanged } from '../../lib/library';
import { info, readText, removeFile, updateSecrets, upload, writeText } from './serverFiles';
import { FieldRow, FolderChoice, ProgressRow, SettingsScreen, TextArea, useNotice } from './settingsControls';

type Options = { route: DownloadRoute; concurrency: number; intervalMs: number; folder: string | null };
const defaults: Options = { route: 'auto', concurrency: 3, intervalMs: 500, folder: null };
const routes = ['auto', 'fx', 'cookie'] as const;
const newFolder = '\0new';

async function optionFile(): Promise<string> {
  return `${(await info()).library}/downloads.queue.json`;
}

async function readOptions(path: string): Promise<Record<string, unknown>> {
  return JSON.parse(await readText(path) ?? '{}') as Record<string, unknown>;
}

export default function DownloadsPage() {
  const options = useAsync(async () => {
    const saved = await readOptions(await optionFile());
    return {
      route: routes.find((route) => route === saved.route) ?? defaults.route,
      concurrency: Number(saved.concurrency) || defaults.concurrency,
      intervalMs: saved.intervalMs == null ? defaults.intervalMs : Number(saved.intervalMs),
      folder: typeof saved.folder === 'string' ? saved.folder : null,
    };
  }, []);
  const [links, setLinks] = useState('');
  const [batch, setBatch] = useState<{ name: string; urls: string[] }>();
  const [newName, setNewName] = useState(false);
  const task = useTask();
  const status = useAsync(() => core.read<DownloadStatus>(core.b.tl_download_status()), []);
  useInterval(status.reload, 1400);
  const current = status.data;
  const done = current?.done ?? 0;
  useEffect(() => { if (done) libraryChanged(); }, [done, current?.generation]);

  async function save(next: Partial<Options>) {
    const path = await optionFile();
    const saved = await readOptions(path);
    await writeText(path, JSON.stringify({ ...defaults, ...saved, ...next }));
    options.reload();
  }

  const update = (next: Partial<Options>) => void task.run(() => save(next));
  function download(urls: string[], bookmarks: boolean, resume = false) {
    if (!options.data) return;
    if (!resume && !urls.length) { toast(L('settings.links.empty')); return; }
    const config = options.data;
    void task.run(async () => {
      const request: DownloadRequest = {
        urls, route: config.route, concurrency: config.concurrency, interval_ms: config.intervalMs,
        folder: config.folder, revive: !bookmarks && !resume, mark_recent: bookmarks && !resume,
      };
      await change(core.read(resume ? core.b.tl_download_resume(JSON.stringify(request)) : core.b.tl_download_start(JSON.stringify(request))));
      if (!resume) {
        if (bookmarks) setBatch(undefined);
        else setLinks('');
      }
      status.reload();
    });
  }

  const phase = !current ? 'download.notYet' : current.running ? 'settings.downloading'
    : current.paused ? 'download.paused' : current.outcome === 'cancelled' ? 'download.cancelled'
      : current.failed ? 'download.partial' : current.total ? 'download.done' : 'download.notYet';

  return <SettingsScreen title={L('common.downloadPosts')}>
    <Section title={L('settings.downloadStatus')} footer={current?.paused ? L('settings.paused.footer') : undefined}>
      {status.error ? <LoadState error={status.error} reload={status.reload} />
        : current?.running ? <ProgressRow title={L(phase)} subtitle={L('activity.downloadSummary', current.done, current.skipped, current.failed, current.total)}
          value={current.total ? (current.done + current.skipped + current.failed) / current.total : undefined} />
          : <Row title={L(phase)} subtitle={current?.total ? L('activity.downloadSummary', current.done, current.skipped, current.failed, current.total) : undefined} />}
      {(current?.running || !!current?.paused) && <Row title={L('settings.downloadStatus')} trailing={<div className="control-actions">
        {current.running ? <Button disabled={task.busy} onClick={() => void task.run(async () => {
          await change(core.read(core.b.tl_download_stop(true)));
          status.reload();
        })}>{L('settings.pause')}</Button> : <Button disabled={task.busy || !options.data} onClick={() => download([], false, true)}>{L('settings.resume')}</Button>}
        <Button disabled={task.busy} onClick={() => void task.run(async () => {
          await change(core.read(core.b.tl_download_stop(false)));
          status.reload();
        })}>{L('settings.cancelDownload')}</Button>
      </div>} />}
      {!!current?.errors.length && <details className="control-padded"><summary>{L('settings.viewFailed')}</summary>
        {current.errors.map(([url, reason], i) => <Row key={i} title={url} subtitle={L(reason)} />)}
      </details>}
    </Section>
    {!options.data || options.error ? <LoadState error={options.error} reload={options.reload} /> : <>
      <Section title={L('settings.section.method')} footer={L('settings.method.footer')}>
        <Row title={L('settings.section.method')} trailing={<Select label={L('settings.section.method')} value={options.data.route}
          disabled={task.busy} options={routes.map((value) => ({ value, label: L(value === 'auto' ? 'common.auto' : `settings.method.${value}`) }))}
          onChange={(route) => update({ route: route as DownloadRoute })} />} />
        <FolderChoice title={L('settings.intoFolder')} disabled={task.busy} value={options.data.folder ?? ''}
          extra={[{ value: newFolder, label: L('common.newFolderEllipsis') }]}
          onChange={(folder) => folder === newFolder ? setNewName(true) : update({ folder: folder || null })} />
      </Section>
      <Section title={L('common.download')} footer={L('settings.links.footer')}>
        <div className="control-padded control-stack">
          <TextArea label={L('common.downloadPosts')} placeholder={L('settings.links.placeholder')} value={links} onChange={setLinks} disabled={task.busy} />
          <div className="control-actions"><Button kind="primary" disabled={task.busy || !links.trim()}
            onClick={() => download(links.trim().split(/\s+/), false)}>{L('common.download')}</Button></div>
        </div>
      </Section>
      <Section title={L('settings.batch')}>
        <Row title={batch ? L('settings.batch.loaded', batch.name) : L('settings.batch.pick')}
          subtitle={batch ? L('format.labelValue', L('settings.batch.posts'), batch.urls.length) : undefined}
          trailing={<FileButton label={L('web.chooseFile')} accept=".json,application/json" disabled={task.busy} onPick={(file) => void task.run(async () => {
            const path = await upload(file);
            try {
              const urls = await core.read<string[]>(core.b.tl_parse_bookmarks(path));
              setBatch({ name: file.name, urls });
            } finally {
              await removeFile(path).catch(() => {});
            }
          })} />} />
        <Row title={L('settings.batch.concurrency')} trailing={<Select label={L('settings.batch.concurrency')} value={String(options.data.concurrency)}
          disabled={task.busy} options={Array.from({ length: 16 }, (_, index) => ({ value: String(index + 1), label: String(index + 1) }))}
          onChange={(value) => update({ concurrency: Number(value) })} />} />
        <Row title={L('settings.batch.interval')} trailing={<Select label={L('settings.batch.interval')} value={String(options.data.intervalMs)}
          disabled={task.busy} options={[...new Set([0, 250, 500, 1000, 2000, 5000, options.data.intervalMs])].sort((a, b) => a - b)
            .map((value) => ({ value: String(value), label: L('settings.batch.seconds', (value / 1000).toFixed(2)) }))}
          onChange={(value) => update({ intervalMs: Number(value) })} />} />
        {batch && <Row title={L('settings.batch.start')} trailing={<Button kind="primary" disabled={task.busy || !batch.urls.length}
          onClick={() => download(batch.urls, true)}>{L('common.download')}</Button>} />}
      </Section>
    </>}
    <CookieSettings />
    {newName && <NameDialog title={L('common.newFolder')} action={L('common.create')} onClose={() => setNewName(false)}
      onSave={async (folder) => {
        const name = await change(core.read<string>(core.b.tl_create_folder(folder)));
        await save({ folder: name });
      }} />}
  </SettingsScreen>;
}

function CookieSettings() {
  const [token, setToken] = useState('');
  const [csrf, setCsrf] = useState('');
  const task = useTask();
  const notice = useNotice();
  const auth = token.trim();
  const ct0 = csrf.trim();
  const valid = Boolean(auth) === Boolean(ct0);
  return <>
    <Section title={L('settings.cookie.header')} footer={L('web.cookie.footer')}>
      <FieldRow label={L('web.cookie.auth')} type="password" value={token} onChange={setToken} />
      <FieldRow label={L('web.cookie.csrf')} type="password" value={csrf} onChange={setCsrf} />
      <Row icon={<KeyRound size={17} />} title={L('settings.cookie.save')} trailing={<div className="control-actions">
        <Button disabled={task.busy || !auth || !ct0} onClick={() => void task.run(async () => {
          const result = await core.read<CookieCheck>(core.b.tl_check_cookies(auth, ct0));
          notice.show(result.error ? L('cookie.invalid') : `@${result.screen_name ?? ''}`, result.error ? L(result.error) : result.name);
        })}>{L('settings.cookie.check')}</Button>
        <Button kind="primary" disabled={task.busy || !valid} onClick={() => void task.run(async () => {
          await updateSecrets({ auth_token: auth, ct0 });
          await core.b.tl_set_cookies(auth, ct0);
          setToken('');
          setCsrf('');
          toast(L(auth ? 'settings.cookie.saved' : 'settings.cookie.cleared'));
        })}>{L('common.save')}</Button>
      </div>} />
    </Section>
    {notice.dialog}
  </>;
}
