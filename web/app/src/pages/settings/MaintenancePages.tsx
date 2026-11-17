import { useEffect, useState } from 'react';
import { L, type IntegritySummary, type StorageUsage } from '@twimshelf/core';
import { Database, HardDrive, Images, ShieldCheck, Trash2 } from 'lucide-react';
import { Button, Empty, Row, Section, TextField, Toggle } from '../../components/ui';
import { change, Confirm, LoadState, useTask } from '../../components/libraryControls';
import { toast } from '../../components/toast';
import { core } from '../../lib/core';
import { useAsync, useInterval, useStore } from '../../lib/hooks';
import { libraryChanged, libraryVersion } from '../../lib/library';
import { go } from '../../lib/router';
import { dateStamp, deliver, info, outPath, readText, removeFile, size } from './serverFiles';
import { setAuto, selectTagger, stopTagging } from './aiTagging';
import { ProgressRow, SettingsScreen, settings, useNotice } from './settingsControls';

export function StoragePage() {
  const version = useStore(libraryVersion);
  const usage = useAsync(async () => {
    const server = await info();
    const clearable = { thumbnails: `${server.cache}/posters`, cache: `${server.cache}/fonts` };
    const data = await core.readJson<StorageUsage>('tl_storage_usage', [
      ...Object.entries(clearable).map(([key, path]) => ({ key, path })),
      { key: 'libraryOther', path: server.uploads },
      { key: 'libraryOther', path: server.exports },
    ]);
    return { data, clearable };
  }, [version]);
  const [clear, setClear] = useState<'thumbnails' | 'cache'>();
  const data = usage.data?.data;

  return <SettingsScreen title={L('storage.title')} actions={<Button onClick={usage.reload}>{L('storage.refresh')}</Button>}>
    {!data || usage.error ? <LoadState error={usage.error} reload={usage.reload} /> : <>
      <Section>
        <Row icon={<HardDrive size={18} />} title={L('storage.title')} trailing={size(data.total)} />
        <div className="control-padded">
          <div className="control-usage" aria-hidden="true">
            {data.groups.filter((group) => group.bytes).map((group) => <span key={group.key} style={{ flexGrow: group.bytes }} />)}
          </div>
        </div>
      </Section>
      {[
        { title: 'storage.section.aiAndApp', keys: ['models', 'app'] },
        { title: 'storage.section.library', keys: ['database', 'photos', 'videos', 'libraryOther'] },
        { title: 'storage.section.free', keys: ['bin', 'thumbnails', 'cache'] },
      ].map(({ title, keys }) => <Section key={title} title={L(title)}>
        {data.groups.filter((group) => keys.includes(group.key)).map((group) => <Row key={group.key}
          icon={group.key === 'bin' ? <Trash2 size={17} /> : group.key === 'thumbnails' ? <Images size={17} /> : <Database size={17} />}
          title={L(`storage.group.${group.key}`)}
          subtitle={L(`storage.group.${group.key}.detail`) + ' ' + L('storage.files', group.files)}
          trailing={<>{size(group.bytes)}
            {group.key === 'models' && <Button onClick={() => settings('ai')}>{L('storage.manage')}</Button>}
            {group.key === 'bin' && <Button onClick={() => go({ page: 'bin' })}>{L('storage.manage')}</Button>}
            {group.bytes > 0 && (group.key === 'thumbnails' || group.key === 'cache') && <Button onClick={() => {
              if (group.key === 'thumbnails' || group.key === 'cache') setClear(group.key);
            }}>{L('storage.clear.confirm')}</Button>}
          </>} />)}
      </Section>)}
    </>}
    {clear && usage.data && <Confirm title={L('storage.clear.title')} action={L('storage.clear.confirm')} danger onClose={() => setClear(undefined)}
      onConfirm={async () => {
        await removeFile(usage.data!.clearable[clear]);
        usage.reload();
        toast(L('storage.clear.done', size(data?.groups.find((group) => group.key === clear)?.bytes ?? 0)));
      }}>{L(`storage.group.${clear}.detail`)}</Confirm>}
  </SettingsScreen>;
}

function integrityText(summary: IntegritySummary): string {
  const last = summary.last;
  if (!last) return L('verify.never', summary.unchecked) + (summary.bad ? L('verify.knownBad', summary.bad) : '');
  if (last.running) return L('verify.checking', last.checked, last.total);
  if (!last.completed_at || ['interrupted', 'failed', 'cancelled'].includes(last.outcome)) {
    return L('verify.stopped', L(last.outcome === 'failed' ? 'verify.failed' : 'verify.interrupted'), last.checked, last.total);
  }
  if (summary.bad) return L('verify.foundBad', summary.bad, summary.unchecked);
  if (summary.unchecked) return L('verify.newSince', summary.unchecked);
  return last.outcome === 'succeeded' ? L('verify.lastOK').trim() : L('verify.lastBad', last.bad);
}

export function AboutPage() {
  const server = useAsync(info, []);
  const [extras, setExtras] = useState(false);
  const [taps, setTaps] = useState(0);
  const task = useTask();
  const notice = useNotice();
  const integrity = useAsync(() => extras ? core.read<IntegritySummary>(core.b.tl_integrity_summary()) : Promise.resolve(null), [extras]);
  const status = integrity.data?.last;
  useInterval(integrity.reload, extras && status?.running ? 1000 : null);
  const stopped = !!status?.finished;
  useEffect(() => { if (stopped) libraryChanged(); }, [stopped]);

  return <SettingsScreen title={L('settings.about')}>
    <Empty title={L('web.appName')} icon={<button type="button" className="control-about-icon" aria-label={L('web.appName')} onClick={() => {
      if (taps === 9) {
        setTaps(0);
        setExtras(!extras);
      } else setTaps(taps + 1);
    }}><img src={new URL('../../../../../icon.png', import.meta.url).href} alt="" width="80" height="80" /></button>}>
      <span>{L('about.tagline')}</span>
      {server.data && <span>{L('about.version', server.data.version)}</span>}
      {!!server.error && <Button onClick={server.reload}>{L('models.retry')}</Button>}
    </Empty>
    {extras && <Section title={L('settings.section.maintenance')} footer={L('settings.maintenance.footer')}>
      {status?.running
        ? <ProgressRow title={L('settings.integrity')} subtitle={L('verify.checking', status.checked, status.total)}
          value={status.total ? status.checked / status.total : undefined}
          onCancel={() => void task.run(async () => { await core.b.tl_verify_cancel(); integrity.reload(); })} />
        : <Row icon={<ShieldCheck size={17} />} title={L('settings.integrity')}
          subtitle={integrity.data ? integrityText(integrity.data) : integrity.error ? L('settings.checkUnreadable') : undefined}
          trailing={<Button disabled={task.busy || integrity.loading} onClick={() => void task.run(async () => {
            await core.read(core.b.tl_verify_start());
            integrity.reload();
          })}>{L('settings.check')}</Button>} />}
      <Row title={L('about.logs')} onClick={() => void task.run(async () => {
        const { library } = await info();
        const log = await readText(`${library}/logs/diagnostics.log`);
        notice.show(L('about.logs'), <div className="control-wrap">{log || L('about.logs.empty')}</div>);
      })} />
      <Row title={L('settings.exportDiagnostics')} onClick={() => void task.run(async () => {
        const name = L('settings.diagnostics.fileName', dateStamp()).replaceAll('{app}', L('web.appName'));
        const path = outPath(await info(), name);
        await core.read(core.b.tl_export_diagnostics(path, JSON.stringify({
          platform: window.twimshelf?.platform ?? 'web', exported_at: new Date().toISOString(),
        })));
        await deliver(path, name);
      })} />
    </Section>}
    {notice.dialog}
  </SettingsScreen>;
}

export function WipePage() {
  const [text, setText] = useState('');
  const [models, setModels] = useState(false);
  const task = useTask();
  const word = L('settings.wipe.word');

  const erase = () => {
    if (text.trim() !== word) return;
    void task.run(async () => {
      const server = await info();
      setAuto(false);
      selectTagger('');
      stopTagging();
      await removeFile(`${server.data}/app/secrets.json`);
      await core.b.tl_set_cookies('', '');
      await core.b.tl_discovery_stop();
      await core.b.tl_ext_pair_cancel();
      await change(core.read(core.b.tl_wipe(models)));
      const cleanup = await Promise.allSettled([
        removeFile(`${server.data}/app/secrets.key`),
        removeFile(`${server.library}/downloads.queue.json`),
        removeFile(server.uploads),
        removeFile(server.exports),
        removeFile(server.cache),
      ]);
      if (cleanup.some((result) => result.status === 'rejected')) throw new Error('web.wipe.cleanup');
      toast(L('settings.wipe.doneMessage'));
      settings();
    });
  };

  return <SettingsScreen title={L('settings.wipe.button')}>
    <Section footer={L('settings.wipe.footer')}>
      <div className="control-padded control-stack">
        <div className="control-wrap">{L('settings.wipe.message')}{models && L('settings.wipe.modelsToo')}</div>
        <label className="control-field-label">{L('settings.wipe.typeToConfirm', word)}
          <TextField value={text} onChange={setText} onEnter={erase} />
        </label>
      </div>
      <Row title={L('settings.wipe.withModels')} trailing={<Toggle checked={models} onChange={setModels}
        label={L('settings.wipe.withModels')} disabled={task.busy} />} />
      <Row title={L('settings.wipe.title')} danger trailing={<Button kind="danger" disabled={task.busy || text.trim() !== word} onClick={erase}>
        {L(task.busy ? 'settings.wipe.erasing' : 'settings.wipe.confirm')}
      </Button>} />
    </Section>
  </SettingsScreen>;
}
