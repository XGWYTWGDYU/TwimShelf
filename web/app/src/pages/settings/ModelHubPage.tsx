import { useState } from 'react';
import { L, type CatalogEntry, type HubDetail, type HubDevice, type HubPage, type HubVariant, type ModelDownloadStatus, type ModelInfo } from '@twimshelf/core';
import { Cpu, Download } from 'lucide-react';
import { Button, Dialog, Empty, Row, Section, TextField, Toggle } from '../../components/ui';
import { change, Confirm, LoadState, useTask } from '../../components/libraryControls';
import { core } from '../../lib/core';
import { useAsync, useInterval } from '../../lib/hooks';
import { openExternal, size } from './serverFiles';
import { ProgressRow, SettingsScreen } from './settingsControls';

const format = 'gguf';
type Install = Pick<CatalogEntry, 'repo' | 'folder' | 'weights' | 'projector' | 'bytes'> & { revision?: string; label: string };

export function ModelProgress({ status, cancel }: { status?: ModelDownloadStatus | null; cancel: () => void }) {
  if (!status) return null;
  if (status.running) return <Section><ProgressRow title={L('activity.downloadingModel', status.repo)}
    subtitle={status.verifying ? L('models.verifying') : status.total_bytes
      ? `${size(status.done_bytes)} / ${size(status.total_bytes)}` : L('models.connecting')}
    value={status.total_bytes ? status.done_bytes / status.total_bytes : undefined} onCancel={cancel} /></Section>;
  if (status.error) return <Section><Row title={L('models.downloadFailed')} subtitle={L(status.error)} /></Section>;
  if (status.finished) return <Section><Row title={L('hub.installed')} subtitle={status.repo} /></Section>;
  return null;
}

export default function ModelHubPage() {
  const [draft, setDraft] = useState('');
  const [search, setSearch] = useState<{ query: string; uncensored: boolean }>();
  const [fit, setFit] = useState(false);
  const [uncensored, setUncensored] = useState(false);
  const [more, setMore] = useState<HubPage[]>([]);
  const [detail, setDetail] = useState<HubDetail>();
  const [install, setInstall] = useState<Install>();
  const task = useTask();
  const catalog = useAsync(async () => {
    const [entries, device] = await Promise.all([
      core.read<CatalogEntry[]>(core.b.tl_model_catalog(format)),
      core.read<HubDevice | null>(core.b.tl_hub_device()),
    ]);
    return { entries, device };
  }, []);
  const results = useAsync(() => search ? core.readJson<HubPage>('tl_hub_search', { format, ...search }) : Promise.resolve(null), [search]);
  const status = useAsync(() => core.read<ModelDownloadStatus | null>(core.b.tl_model_status()), []);
  const installed = useAsync(() => core.read<ModelInfo[]>(core.b.tl_models_installed()), [status.data?.finished, status.data?.repo]);
  useInterval(status.reload, 1500);

  const device = results.data?.device ?? catalog.data?.device;
  const busy = task.busy || !!status.data?.running;
  const pages = results.data ? [results.data, ...more] : [];
  const next = pages.at(-1)?.next;
  const items = [...new Map(pages.flatMap((page) => page.items).map((item) => [item.repo, item])).values()]
    .filter((item) => !fit || ['recommended', 'usable'].includes(item.tier));
  const open = (repo: string) => void task.run(async () => setDetail(await core.read<HubDetail>(core.b.tl_hub_repo(format, repo))));
  const submit = (query: string, lowRestriction: boolean) => {
    setMore([]);
    setSearch({ query, uncensored: lowRestriction });
  };
  const variantInstall = (variant: HubVariant, item: HubDetail) => setInstall({
    ...variant, repo: item.repo.repo, revision: item.revision,
  });

  return <SettingsScreen title={L('hub.title')} parent="ai">
    <ModelProgress status={status.data} cancel={() => void task.run(async () => { await core.b.tl_model_cancel(); status.reload(); })} />
    {device && <Section title={L('hub.device.title')} footer={L('hub.device.footer')}>
      <Row icon={<Cpu size={17} />} title={L('hub.device',
        device.memory_bytes == null ? L('hub.unknown') : size(device.memory_bytes),
        device.free_bytes == null ? L('hub.unknown') : size(device.free_bytes))} />
    </Section>}
    <Section>
      <Row title={L('hub.search')} trailing={<div className="control-actions">
        <TextField value={draft} onChange={setDraft} placeholder={L('hub.search.placeholder')} onEnter={() => submit(draft.trim(), uncensored)} />
        <Button disabled={task.busy} kind="primary" onClick={() => submit(draft.trim(), uncensored)}>{L('hub.search')}</Button>
      </div>} />
      <Row title={L('hub.filter.fit')} trailing={<Toggle label={L('hub.filter.fit')} checked={fit} onChange={setFit} />} />
      <Row title={L('hub.filter.uncensored')} trailing={<Toggle label={L('hub.filter.uncensored')} checked={uncensored}
        onChange={(value) => { setUncensored(value); if (search) submit(search.query, value); }} />} />
    </Section>
    {search && <Section title={L('hub.results')} footer={L('hub.results.footer')}>
      {results.error ? <LoadState error={results.error} reload={results.reload} /> : results.loading || !results.data
        ? <Row title={L('hub.loading')} /> : <>
          {!items.length && <Row title={L('hub.empty')} />}
          {items.map((item) => <Row key={item.repo} title={item.repo} subtitle={[
            L(`hub.tier.${item.tier}`), item.estimated_bytes != null && L('hub.estimate', size(item.estimated_bytes)),
            item.claims_uncensored && L('hub.claim'),
          ].filter(Boolean).join(' · ')} onClick={() => open(item.repo)} />)}
          {next && <Row title={L('hub.more')} trailing={<Button disabled={task.busy} onClick={() => void task.run(async () => {
            const page = await core.readJson<HubPage>('tl_hub_search', { format, ...search, next });
            setMore((current) => [...current, page]);
          })}>{L('hub.more')}</Button>} />}
        </>}
    </Section>}
    {!catalog.data || catalog.error ? <LoadState error={catalog.error} reload={catalog.reload} />
      : <Section title={L('hub.curated')} footer={L('hub.curated.footer')}>
        {!catalog.data.entries.length && <Row title={L('hub.empty')} />}
        {catalog.data.entries.filter((entry) => !fit || entry.tier !== 'tooLarge').map((entry) => {
          const have = installed.data?.some((model) => model.id === entry.folder || model.path.endsWith('/' + entry.folder));
          return <Row key={entry.folder} icon={<Download size={17} />} title={L(entry.name_key)}
            subtitle={[L(entry.note_key), L(`hub.tier.${entry.tier}`), size(entry.bytes)].join(' · ')}
            trailing={have ? L('hub.installed') : <Button disabled={busy} onClick={() => setInstall({ ...entry, label: L(entry.name_key) })}>
              {L('common.download')}
            </Button>} />;
        })}
      </Section>}
    {detail && !install && <Dialog wide title={detail.repo.repo} onClose={() => setDetail(undefined)} actions={<>
      <Button onClick={() => openExternal(`https://huggingface.co/${detail.repo.repo.split('/').map(encodeURIComponent).join('/')}`)}>{L('hub.detail.openPage')}</Button>
      <Button onClick={() => setDetail(undefined)}>{L('common.close')}</Button>
    </>}>
      <Section footer={L('hub.unverified.footer')}>
        {detail.repo.architecture && <Row title={L('hub.detail.architecture')} trailing={detail.repo.architecture} />}
        {detail.repo.license && <Row title={L('hub.detail.license')} trailing={detail.repo.license} />}
        <Row title={L('hub.detail.downloads')} trailing={detail.repo.downloads.toLocaleString()} />
      </Section>
      <Section title={L('hub.detail.versions')} footer={L('hub.detail.versions.footer')}>
        {detail.problem && <Empty title={L('hub.detail.cannotInstall')}>{L(detail.problem)}</Empty>}
        {detail.variants.map((variant) => <Row key={variant.folder} title={variant.suggested ? L('hub.variant.suggested', variant.label) : variant.label}
          subtitle={variant.enough_space ? L(`hub.tier.${variant.tier}`) : L('hub.variant.noSpace', size(variant.bytes))}
          trailing={<>{size(variant.bytes)}<Button disabled={busy || !variant.enough_space} onClick={() => variantInstall(variant, detail)}>
            {L('common.download')}
          </Button></>} />)}
      </Section>
      {!!detail.skipped.length && <Section title={L('hub.detail.skipped')}>
        {detail.skipped.map(({ name, reason }) => <Row key={name} title={name} subtitle={L(reason)} />)}
      </Section>}
    </Dialog>}
    {install && <Confirm title={L('common.download')} action={L('common.download')} onClose={() => setInstall(undefined)} onConfirm={async () => {
      const { repo, folder, bytes, weights, projector, revision } = install;
      await change(core.readJson('tl_hub_install', { format, repo, folder, bytes, weights, projector, revision }));
      setDetail(undefined);
      status.reload();
    }}>{L('hub.download.message', install.label, size(install.bytes))}</Confirm>}
  </SettingsScreen>;
}
