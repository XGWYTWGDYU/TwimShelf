import { useEffect, useState } from 'react';
import {
  L, type AiFailure, type DiscoveredPeer, type DiscoveryStatus,
  type ModelDownloadStatus, type ModelInfo, type SyncStatus,
} from '@twimshelf/core';
import {
  ChevronDown, Cloud, Download, Ellipsis, Eye, LayoutGrid, Monitor,
  Network, PlusCircle, RefreshCw, Search, Star, TriangleAlert,
} from 'lucide-react';
import { Button, Dialog, TextField, Toggle } from '../../components/ui';
import { change, FileButton, LoadState, useTask } from '../../components/libraryControls';
import { openMenuBelow } from '../../components/Menu';
import { alertMessage, choose } from '../../components/pickers';
import { core } from '../../lib/core';
import { useAsync, useInterval, useStore } from '../../lib/hooks';
import { libraryVersion } from '../../lib/library';
import {
  activeTagger, autoTag, defaultPrompt, deleteModel, endpoint, externalModels,
  getPrompt, localAIInfo, modelTitle, promptFields, runTagging, saveModel, selectTagger,
  setAuto, setSetting, stopTagging, tagging, testModel, unloadLocalModels, type ExternalModel, type Prompt,
} from './aiTagging';
import { MODEL_SOURCES, ModelProgress } from './ModelHubPage';
import { exportFile, readSecret, removeFile, size, upload } from './serverFiles';
import {
  ActivityRow, Banner, Card, CardRow, IconTile, Pill, PlaceholderEditor,
  PopupSelect, ProgressRing, RowDivider, SectionGroup, SegmentedControl, settings, SettingsScreen,
} from './settingsControls';

export { ModelProgress };

type PromptFieldKey = typeof promptFields[number];

function hostOf(rawUrl: string): string {
  try {
    const u = new URL(rawUrl.includes('://') ? rawUrl : `http://${rawUrl}`);
    return u.host;
  } catch {
    return rawUrl;
  }
}

function isLocalUrl(rawUrl: string): boolean {
  const h = hostOf(rawUrl).toLowerCase();
  return h.startsWith('127.0.0.1') || h.startsWith('localhost') || h.startsWith('192.168.') || h.startsWith('10.') || h.endsWith('.local');
}

export default function AIPage() {
  const version = useStore(libraryVersion);
  const selected = useStore(activeTagger);
  const automatic = useStore(autoTag);
  const activity = useStore(tagging);
  const localAI = useAsync(localAIInfo, []);
  const models = useAsync(externalModels, [version]);
  const counts = useAsync(() => core.read<[number, number]>(core.b.tl_ai_counts()), [version, activity.done, activity.running]);
  const failures = useAsync(() => core.read<AiFailure[]>(core.b.tl_ai_failures()), [version, activity.running]);
  const status = useAsync(() => core.read<ModelDownloadStatus | null>(core.b.tl_model_status()), []);
  const source = useAsync(() => core.read<string>(core.b.tl_model_source()), []);
  const installed = useAsync(
    () => core.read<ModelInfo[]>(core.b.tl_models_installed()),
    [version, status.data?.repo, status.data?.finished],
  );
  const syncState = useAsync(async () => {
    const [s, d] = await Promise.all([
      core.read<SyncStatus>(core.b.tl_sync_status()).catch(() => null),
      core.read<DiscoveryStatus>(core.b.tl_discovery_status()).catch(() => null),
    ]);
    return { s, d };
  }, [version]);

  const [expanded, setExpanded] = useState<Set<string>>(() => new Set());
  const [externalTests, setExternalTests] = useState<Record<string, string>>({});
  const [edit, setEdit] = useState<{ model: ExternalModel; isNew: boolean }>();
  const [remoteState, setRemoteState] = useState<'idle' | 'loading' | 'done' | 'error'>('idle');
  const [remoteModels, setRemoteModels] = useState<{ peer: DiscoveredPeer; info: ModelInfo }[]>([]);
  const [remoteError, setRemoteError] = useState<string>();
  const task = useTask();

  useInterval(status.reload, status.loading ? null : 1600);

  const localSupported = !!localAI.data?.supported;
  const localList = (installed.data ?? []).filter((m) => m.format === 'gguf');
  const localTaggers = localSupported ? localList.filter((m) => m.vision) : [];
  const modelList = models.data ?? [];
  const taggerOptions = [
    ...localTaggers.map((m) => ({ id: m.id, title: m.repo || m.id })),
    ...modelList.map((m) => ({ id: m.id, title: modelTitle(m) })),
  ];
  const activeChoice = taggerOptions.find((candidate) => candidate.id === selected);
  const [done = 0, total = 0] = counts.data ?? [0, 0];
  const ratio = total > 0 ? done / total : 0;

  const toggleExpand = (id: string) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  async function retagAllFlow(forcedModelId?: string) {
    if (!taggerOptions.length) return;
    let targetId = forcedModelId ?? activeChoice?.id ?? taggerOptions[0].id;
    if (!forcedModelId && taggerOptions.length > 1) {
      const idx = await choose(
        L('models.retagAll'),
        L('models.retagAll.message'),
        taggerOptions.map((m) => m.title),
      );
      if (idx == null) return;
      targetId = taggerOptions[idx].id;
    }
    const modeIdx = await choose(
      L('models.retag.oldTitle'),
      L('models.retag.oldMessage'),
      [L('models.retag.keep'), L('models.retag.replace')],
    );
    if (modeIdx == null) return;
    void runTagging({ retag: true, replace: modeIdx === 1, modelId: targetId });
  }

  async function runInlineTest(e: ExternalModel) {
    const title = modelTitle(e);
    setExternalTests((prev) => ({ ...prev, [e.id]: L('mac.models.testing', title) }));
    try {
      const tags = await testModel(e, '', false);
      const text = L('mac.models.testOK') + (tags.length === 0 ? L('models.external.noTags') : tags.join(L('list.separator')));
      setExternalTests((prev) => ({ ...prev, [e.id]: text }));
    } catch (err) {
      const msg = L((err as Error)?.message ?? 'common.notDone');
      setExternalTests((prev) => ({ ...prev, [e.id]: L('mac.models.testFailed') + msg }));
    }
  }

  async function confirmDeleteExternal(e: ExternalModel) {
    const ok = await choose(
      L('mac.models.external.delete.title', modelTitle(e)),
      L('mac.models.external.delete.message'),
      [L('common.delete')],
      { destructive: true },
    );
    if (ok == null) return;
    await task.run(async () => {
      await change(deleteModel(e));
      if (e.id === selected) selectTagger('');
    });
  }

  async function confirmDeleteLocal(m: ModelInfo) {
    const title = m.repo || m.id;
    const ok = await choose(
      L('models.delete.title', title),
      L('models.delete.message'),
      [L('common.delete')],
      { destructive: true },
    );
    if (ok == null) return;
    await task.run(async () => {
      if (m.id === selected) { stopTagging(); selectTagger(''); }
      await unloadLocalModels();
      await change(core.read(core.b.tl_model_delete(m.id)));
    });
  }

  async function queryRemoteModels() {
    const acct = syncState.data?.s?.account_id;
    const peers = (syncState.data?.d?.peers ?? []).filter((p) => p.account === acct && p.host && p.port);
    if (!peers.length) {
      setRemoteModels([]);
      setRemoteState('done');
      return;
    }
    setRemoteState('loading');
    setRemoteError(undefined);
    const have = new Set((installed.data ?? []).map((m) => m.id));
    const found: { peer: DiscoveredPeer; info: ModelInfo }[] = [];
    const errs: string[] = [];
    let anyOk = false;
    for (const p of peers) {
      try {
        const list = await core.read<ModelInfo[]>(core.b.tl_sync_peer_models(p.host!, p.port!));
        anyOk = true;
        for (const infoItem of list) {
          if (!have.has(infoItem.id) && !found.some((f) => f.info.id === infoItem.id)) {
            found.push({ peer: p, info: infoItem });
          }
        }
      } catch (e) {
        errs.push(L('format.labelValue', p.name, L((e as Error)?.message ?? 'common.notDone')));
      }
    }
    setRemoteModels(found);
    if (anyOk) {
      setRemoteState('done');
    } else {
      setRemoteError(errs.join(L('list.semicolon')));
      setRemoteState('error');
    }
  }

  const failList = failures.data ?? [];
  const failReasons = [...failList.reduce((map, f) => {
    map.set(f.reason, (map.get(f.reason) ?? 0) + 1);
    return map;
  }, new Map<string, number>()).entries()].sort((a, b) => b[1] - a[1]);

  const dl = status.data;
  const anyRunning = activity.running || !!dl?.running;

  return (
    <SettingsScreen title={L('common.aiModels')}>
      {anyRunning && (
        <Card tint="accent" spacing={14}>
          {activity.running && (
            <ActivityRow
              kind="tagging"
              title={L('ai.activity.new', activity.modelName || activeChoice?.title || L('models.tagging'))}
              detail={activity.total > 0 ? `${activity.done} / ${Math.max(activity.total, activity.done)}` : L('web.ai.processed', activity.done)}
              progress={activity.total > 0 ? activity.done / Math.max(activity.total, activity.done) : (total > 0 ? done / total : undefined)}
              previewPath={activity.currentPath}
              previewIsVideo={activity.currentKind === 'video'}
            />
          )}
          {dl?.running && (
            <ActivityRow
              kind="model"
              title={L('activity.downloadingModel', dl.repo)}
              detail={
                dl.verifying
                  ? L('models.verifying')
                  : dl.total_bytes
                    ? `${size(dl.done_bytes)} / ${size(dl.total_bytes)}`
                    : L('models.connecting')
              }
              progress={dl.total_bytes ? dl.done_bytes / dl.total_bytes : undefined}
            />
          )}
          <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
            {activity.running && (
              <Button onClick={() => stopTagging()}>{L('models.stopTagging')}</Button>
            )}
            {dl?.running && (
              <Button disabled={task.busy} onClick={() => void task.run(async () => {
                await core.b.tl_model_cancel();
                status.reload();
              })}>{L('models.cancelDownload')}</Button>
            )}
          </div>
        </Card>
      )}

      <div className="s-hero hero-purple">
        <div style={{ display: 'flex', alignItems: 'center', gap: 22, flexWrap: 'wrap' }}>
          <ProgressRing value={ratio} size={104} lineWidth={11} color="purple">
            <span style={{ fontSize: 24, fontWeight: 700, fontVariantNumeric: 'tabular-nums', color: 'var(--fg)' }}>
              {Math.round(ratio * 100)}%
            </span>
            <span style={{ fontSize: 10, color: 'var(--fg-2)' }}>{L('models.analysed')}</span>
          </ProgressRing>

          <div style={{ display: 'flex', flexDirection: 'column', gap: 10, minWidth: 0, flex: 1 }}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
              <div style={{ fontSize: 20, fontWeight: 700, color: 'var(--fg)' }}>{L('mac.models.tagging')}</div>
              <div style={{ fontSize: 13, fontVariantNumeric: 'tabular-nums', color: 'var(--fg-2)' }}>
                {L('mac.models.analysedCount', done, total)}
              </div>
            </div>

            <div style={{ display: 'inline-flex', alignItems: 'center', gap: 10 }}>
              <Toggle
                label={L('models.autoTag')}
                checked={automatic}
                disabled={!activeChoice}
                onChange={(v) => {
                  setAuto(v);
                  if (v) void runTagging();
                  else stopTagging();
                }}
              />
              <span style={{ fontSize: 13.5, fontWeight: 500, color: 'var(--fg)' }}>{L('models.autoTag')}</span>
            </div>
          </div>
        </div>

        <div className="ai-default-grid">
          <div className="ai-default-card">
            <IconTile icon={<Eye size={15} strokeWidth={2} />} color="purple" size={30} />
            <div className="ai-default-meta">
              <span className="ai-default-label">{L('mac.models.tagger')}</span>
              {!taggerOptions.length ? (
                <span style={{ fontSize: 13, fontWeight: 500, color: 'var(--fg-2)' }}>{L('common.notInstalled')}</span>
              ) : (
                <PopupSelect
                  label={L('mac.models.tagger')}
                  value={activeChoice?.id ?? ''}
                  disabled={activity.running}
                  options={[
                    ...(activeChoice ? [] : [{ value: '', label: L('mac.notChosen') }]),
                    ...taggerOptions.map((entry) => ({ value: entry.id, label: entry.title })),
                  ]}
                  onChange={(id) => {
                    selectTagger(id);
                    if (id && automatic) void runTagging();
                  }}
                />
              )}
            </div>
          </div>

        </div>

        {activity.error && (
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <Banner text={L(activity.error)} icon={<TriangleAlert size={15} />} color="red" />
            <Button onClick={() => void runTagging()}>{L('models.retry')}</Button>
          </div>
        )}

        {failList.length > 0 && (
          <div style={{ display: 'flex', alignItems: 'flex-start', gap: 10 }}>
            <Banner
              text={
                L('mac.models.failures', failList.length)
                + failReasons.slice(0, 2).map(([r, n]) => L('mac.models.failures.group', n, L(r))).join(L('list.semicolon'))
                + L('mac.models.failures.tail')
              }
              icon={<TriangleAlert size={15} />}
              color="orange"
            />
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6, flex: 'none' }}>
              <Button
                onClick={() => {
                  const lines = failList.slice(0, 30).map((f) => L('models.failure.line', f.media_id.slice(0, 12), f.attempts, L(f.reason)));
                  if (failList.length > 30) lines.push(L('models.failures.more', failList.length - 30));
                  void alertMessage(L('models.failures.title'), lines.join('\n') + L('models.failures.footer'));
                }}>
                {L('mac.detailsEllipsis')}
              </Button>
              <Button
                disabled={task.busy || activity.running}
                onClick={() => void task.run(async () => {
                  await change(core.read(core.b.tl_ai_failures_clear()));
                  failures.reload();
                  void runTagging();
                })}>
                {L('models.retry')}
              </Button>
            </div>
          </div>
        )}

        {taggerOptions.length > 0 && (
          <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
            {!activity.running && activeChoice && (
              <Button kind="primary" onClick={() => void runTagging()}>{L('web.ai.tagNow')}</Button>
            )}
            <Button disabled={activity.running} onClick={() => void retagAllFlow()}>
              <RefreshCw size={13} strokeWidth={2.2} />
              <span>{L('models.retagAllEllipsis')}</span>
            </Button>
          </div>
        )}
      </div>

      <SectionGroup
        title={L('models.installed', installed.data?.length ?? 0)}
        note={localSupported && localAI.data?.devices ? localAI.data.devices : L('web.ai.local')}>
        {!installed.data || installed.error ? (
          <LoadState error={installed.error} reload={installed.reload} />
        ) : !installed.data.length ? (
          <Card><span style={{ fontSize: 13, color: 'var(--fg-2)' }}>{L('mac.models.none')}</span></Card>
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            {installed.data.map((item) => {
              const open = expanded.has(item.id);
              // (only a vision model runs here: search by meaning is the Apple apps' alone)
              const isDefault = item.vision && item.id === selected;
              const runnable = localSupported && item.format === 'gguf' && item.vision;
              return (
                <Card key={item.id} spacing={12}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                    <IconTile
                      icon={item.vision ? <Eye size={17} strokeWidth={2} /> : <Search size={17} strokeWidth={2} />}
                      color={item.vision ? 'purple' : 'teal'}
                      size={36}
                    />
                    <div className="card-row-texts" style={{ gap: 4 }}>
                      <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--fg)' }}>{item.repo || item.id}</div>
                      <div className="chips-row" style={{ gap: 5 }}>
                        <Pill
                          text={item.vision ? L('mac.models.role.tagger') : L('models.semanticSearch')}
                          color={item.vision ? 'purple' : 'teal'}
                        />
                        <Pill text={size(item.bytes)} color="secondary" />
                        {isDefault && runnable && <Pill text={L('prompt.default')} color="blue" />}
                      </div>
                    </div>

                    {runnable && !isDefault && (
                      <Button
                        disabled={activity.running}
                        onClick={() => {
                          selectTagger(item.id);
                          if (automatic) void runTagging();
                        }}>
                        {L('mac.models.setDefault')}
                      </Button>
                    )}

                    <button
                      type="button"
                      className="icon-btn"
                      aria-label={L('grid.more')}
                      onClick={(ev) => openMenuBelow(ev.currentTarget, [
                        ...(window.twimshelf?.showItemInFolder ? [{
                          label: L('mac.showInFinder'),
                          run: () => window.twimshelf?.showItemInFolder?.(item.path),
                        }] : []),
                        {
                          label: L('mac.models.exportZip'),
                          disabled: task.busy,
                          run: () => void task.run(async () => {
                            const name = `${item.id.replaceAll('/', '-')}.zip`;
                            await exportFile(name, (path) => core.read(core.b.tl_model_export_zip(item.id, path)));
                          }),
                        },
                        'separator',
                        {
                          label: L('mac.deleteEllipsis'),
                          danger: true,
                          run: () => void confirmDeleteLocal(item),
                        },
                      ])}>
                      <Ellipsis size={16} strokeWidth={2} />
                    </button>

                    {item.vision && (
                      <button
                        type="button"
                        className="icon-btn"
                        aria-label={L('models.expand')}
                        onClick={() => toggleExpand(item.id)}>
                        <ChevronDown
                          size={15}
                          strokeWidth={2.2}
                          style={{ transform: open ? 'rotate(180deg)' : undefined, transition: 'transform 0.18s' }}
                        />
                      </button>
                    )}
                  </div>

                  {item.vision && open && (
                    <>
                      <RowDivider />
                      <InlinePromptEditor modelId={item.id} onRetag={() => void retagAllFlow(runnable ? item.id : undefined)} />
                    </>
                  )}
                </Card>
              );
            })}
          </div>
        )}
      </SectionGroup>

      <SectionGroup title={L('models.external')} note={L('web.ai.browser')}>
        {!models.data || models.error ? (
          <LoadState error={models.error} reload={models.reload} />
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            {models.data.map((e) => {
              const isDef = e.id === selected;
              const open = expanded.has(e.id);
              const local = isLocalUrl(e.url);
              const host = hostOf(e.url);
              const testRes = externalTests[e.id];
              return (
                <Card key={e.id} spacing={12}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                    <IconTile
                      icon={local ? <Monitor size={17} strokeWidth={2} /> : <Cloud size={17} strokeWidth={2} />}
                      color="blue"
                      size={36}
                    />
                    <div className="card-row-texts" style={{ gap: 4 }}>
                      <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--fg)' }}>{modelTitle(e)}</div>
                      <div className="chips-row" style={{ gap: 5 }}>
                        <Pill text={local ? L('models.external.local') : L('models.external.cloud')} color="blue" />
                        {host && <Pill text={host} color="secondary" />}
                        {e.model && <span style={{ fontSize: 11, color: 'var(--fg-2)' }}>{e.model}</span>}
                      </div>
                    </div>

                    {isDef ? (
                      <Pill text={L('prompt.default')} color="yellow" icon={<Star size={10} strokeWidth={2.5} />} />
                    ) : (
                      <Button
                        disabled={activity.running}
                        onClick={() => {
                          selectTagger(e.id);
                          if (automatic) void runTagging();
                        }}>
                        {L('mac.models.setDefault')}
                      </Button>
                    )}

                    <button
                      type="button"
                      className="icon-btn"
                      aria-label={L('grid.more')}
                      onClick={(ev) => openMenuBelow(ev.currentTarget, [
                        { label: L('mac.models.test'), run: () => void runInlineTest(e) },
                        { label: L('mac.editEllipsis'), disabled: activity.running, run: () => setEdit({ model: e, isNew: false }) },
                        'separator',
                        { label: L('mac.deleteEllipsis'), danger: true, disabled: activity.running, run: () => void confirmDeleteExternal(e) },
                      ])}>
                      <Ellipsis size={16} strokeWidth={2} />
                    </button>

                    <button
                      type="button"
                      className="icon-btn"
                      aria-label={L('models.expand')}
                      onClick={() => toggleExpand(e.id)}>
                      <ChevronDown
                        size={15}
                        strokeWidth={2.2}
                        style={{ transform: open ? 'rotate(180deg)' : undefined, transition: 'transform 0.18s' }}
                      />
                    </button>
                  </div>

                  {testRes && (
                    <div className="selectable" style={{ fontSize: 11, color: 'var(--fg-2)', whiteSpace: 'pre-wrap' }}>
                      {testRes}
                    </div>
                  )}

                  {open && (
                    <>
                      <RowDivider />
                      <InlinePromptEditor modelId={e.id} onRetag={() => void retagAllFlow(e.id)} />
                    </>
                  )}
                </Card>
              );
            })}

            <button
              type="button"
              className="dashed-add-btn"
              onClick={() => setEdit({
                model: { id: `ext:${crypto.getRandomValues(new Uint32Array(4)).join('-')}`, name: '', url: '', model: '' },
                isNew: true,
              })}>
              <PlusCircle size={18} strokeWidth={2} />
              <span>{models.data.length > 0 ? L('mac.models.addAnother') : L('models.addExternal')}</span>
            </button>
          </div>
        )}
      </SectionGroup>

      <SectionGroup title={L('models.available')}>
        <Card spacing={0}>
          <CardRow
            icon={<LayoutGrid size={15} strokeWidth={2} />}
            color="blue"
            title={L('hub.title')}
            detail={L('hub.entry.detail')}
            trailing={<Button onClick={() => settings('model-hub')}>{L('hub.open')}</Button>}
          />
          <RowDivider />
          <CardRow
            icon={<Download size={15} strokeWidth={2} />}
            color="green"
            title={L('models.source')}
            detail={L('models.source.footer')}
            trailing={
              <SegmentedControl
                value={source.data ?? 'huggingface'}
                onChange={(v) => void core.read(core.b.tl_set_model_source(v)).then(source.reload, source.reload)}
                options={MODEL_SOURCES}
              />
            }
          />
        </Card>
      </SectionGroup>

      {syncState.data?.s?.account_id && (
        <SectionGroup
          title={L('models.peers.title')}
          note={L('models.appleOnly')}
          trailing={
            <Button disabled={remoteState === 'loading'} onClick={() => void queryRemoteModels()}>
              {L('mac.models.query')}
            </Button>
          }>
          <Card spacing={10}>
            {remoteState === 'loading' ? (
              <span style={{ fontSize: 13, color: 'var(--fg-2)' }}>{L('models.peers.querying')}</span>
            ) : remoteModels.length === 0 ? (
              <span style={{ fontSize: 13, color: 'var(--fg-2)' }}>
                {remoteError
                  ?? (remoteState === 'done'
                    ? L('models.peers.nothing')
                    : L('mac.models.peers.tap'))}
              </span>
            ) : (
              remoteModels.map((r, i) => (
                <div key={r.info.id} style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                  {i > 0 && <RowDivider inset={42} />}
                  <CardRow
                    icon={<Monitor size={15} strokeWidth={2} />}
                    color="indigo"
                    title={r.info.repo || r.info.id}
                    detail={`${r.peer.name} · ${size(r.info.bytes)}`}
                    trailing={
                      <Button
                        disabled={task.busy}
                        onClick={() => void task.run(async () => {
                          await core.read(
                            core.b.tl_sync_pull_model(
                              r.peer.host!,
                              r.peer.port!,
                              r.info.id,
                              L('sync.model.from', r.info.repo || r.info.id, r.peer.name),
                              r.info.bytes,
                            ),
                          );
                          setRemoteModels((prev) => prev.filter((x) => x.info.id !== r.info.id));
                          status.reload();
                        })}>
                        {L('models.pull')}
                      </Button>
                    }
                  />
                </div>
              ))
            )}
          </Card>
        </SectionGroup>
      )}

      <Card spacing={0}>
        <CardRow
          icon={<Download size={15} strokeWidth={2} />}
          color="green"
          title={L('mac.models.import')}
          detail={L('models.appleOnly')}
          trailing={
            <FileButton
              label={L('mac.importEllipsis')}
              accept=".zip"
              disabled={task.busy}
              onPick={(file) => void task.run(async () => {
                const path = await upload(file);
                try {
                  const imported = await change(core.read<ModelInfo>(core.b.tl_model_import(path)));
                  await alertMessage(L('models.imported'), imported.repo || imported.id);
                } finally {
                  await removeFile(path).catch(() => {});
                }
              })}
            />
          }
        />
      </Card>

      {edit && (
        <ExternalModelEditor
          initial={edit.model}
          isNew={edit.isNew}
          onClose={() => setEdit(undefined)}
        />
      )}
    </SettingsScreen>
  );
}

const PROMPT_META: Record<PromptFieldKey, { title: string; note: string }> = {
  system: { title: 'prompt.system', note: 'mac.prompt.system.detail' },
  prompt: { title: 'prompt.question', note: 'mac.prompt.question.detail' },
  existing: { title: 'prompt.existing', note: 'mac.prompt.existing.detail' },
  vocabulary: { title: 'prompt.libraryTags', note: 'mac.prompt.tags.detail' },
  context: { title: 'prompt.postText', note: 'mac.prompt.text.detail' },
};

function InlinePromptEditor({ modelId, onRetag }: { modelId: string; onRetag: () => void }) {
  const [field, setField] = useState<PromptFieldKey>('system');
  const [saved, setSaved] = useState<Prompt>();
  const [texts, setTexts] = useState<Prompt>(() => defaultPrompt());
  const task = useTask();

  useEffect(() => {
    let live = true;
    getPrompt(modelId).then((p) => {
      if (live) {
        setSaved(p);
        setTexts(p);
      }
    }, () => {});
    return () => { live = false; };
  }, [modelId]);

  const save = () => void task.run(async () => {
    const unchanged = saved && promptFields.every((k) => texts[k] === saved[k]);
    if (unchanged) return;
    await change(setSetting(`ai.modelPrompt.${modelId}`, JSON.stringify(texts)));
    setSaved(texts);
    const idx = await choose(
      L('prompt.saved'),
      L('prompt.saved.retag'),
      [L('prompt.saved.later'), L('prompt.saved.now')],
    );
    if (idx === 1) onRetag();
  });

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
      <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--fg)' }}>{L('models.promptSection')}</div>
      <SegmentedControl<PromptFieldKey>
        value={field}
        onChange={setField}
        options={promptFields.map((k) => ({ value: k, label: L(PROMPT_META[k].title) }))}
      />
      <PlaceholderEditor
        value={texts[field]}
        onChange={(v) => setTexts({ ...texts, [field]: v })}
        placeholder={L(PROMPT_META[field].title)}
        minHeight={130}
        disabled={task.busy}
      />
      <div style={{ fontSize: 11, color: 'var(--fg-2)' }}>{L(PROMPT_META[field].note)}</div>
      <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
        <Button disabled={task.busy} onClick={() => setTexts(defaultPrompt())}>{L('mac.prompt.reset')}</Button>
        <Button kind="primary" disabled={task.busy} onClick={save}>{L('mac.prompt.save')}</Button>
      </div>
    </div>
  );
}

function ExternalModelEditor({ initial, isNew, onClose }: {
  initial: ExternalModel; isNew: boolean; onClose: () => void;
}) {
  const [model, setModel] = useState(initial);
  const [key, setKey] = useState('');
  const [hasKey, setHasKey] = useState(false);
  const [clear, setClear] = useState(false);
  const [error, setError] = useState<string>();
  const task = useTask();

  useEffect(() => {
    if (isNew) return;
    let live = true;
    readSecret(`ai.key.${initial.id}`)
      .then((k) => { if (live) setHasKey(!!k); })
      .catch(() => {});
    return () => { live = false; };
  }, [initial.id, isNew]);

  const validate = (): ExternalModel | null => {
    const normalized: ExternalModel = {
      ...model,
      name: model.name.trim(),
      url: model.url.trim(),
      model: model.model.trim(),
    };
    if (!normalized.url) {
      setError(L('models.external.needURL'));
      return null;
    }
    try {
      endpoint(normalized.url, 'models');
    } catch {
      setError(L('models.external.needURL'));
      return null;
    }
    if ((key.trim() || (hasKey && !clear)) && !normalized.model) {
      setError(L('models.external.needModel'));
      return null;
    }
    setError(undefined);
    return normalized;
  };

  return (
    <Dialog
      title={isNew ? L('models.addExternal') : L('mac.models.edit', modelTitle(initial))}
      onClose={() => { if (!task.busy) onClose(); }}
      actions={
        <>
          <Button disabled={task.busy} onClick={onClose}>{L('common.cancel')}</Button>
          <Button
            disabled={task.busy}
            onClick={() => {
              const norm = validate();
              if (!norm) return;
              void task.run(async () => {
                const labels = await testModel(norm, key.trim(), clear);
                await alertMessage(
                  L('models.external.success'),
                  labels.length ? labels.join(L('list.separator')) : L('models.external.noTags'),
                );
              });
            }}>
            {L('models.external.test')}
          </Button>
          <Button
            kind="primary"
            disabled={task.busy}
            onClick={() => {
              const norm = validate();
              if (!norm) return;
              void task.run(async () => {
                await change(saveModel(norm, key.trim(), clear));
                if (!activeTagger.get()) selectTagger(norm.id);
                onClose();
              });
            }}>
            {L('common.save')}
          </Button>
        </>
      }>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <IconTile icon={<Network size={19} strokeWidth={2} />} color="blue" size={40} />
          <div className="card-row-texts">
            <div className="card-row-detail" style={{ fontSize: 12.5 }}>{L('mac.models.external.hint')}</div>
          </div>
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <TextField
            value={model.name}
            onChange={(name) => setModel({ ...model, name })}
            placeholder={L('models.external.name')}
          />
          <TextField
            value={model.url}
            onChange={(url) => setModel({ ...model, url })}
            placeholder={L('mac.models.external.urlPlaceholder')}
          />
          <TextField
            type="password"
            value={key}
            onChange={setKey}
            placeholder={hasKey && !clear ? `${L('models.external.key')} ••••••` : L('models.external.key')}
          />
          <TextField
            value={model.model}
            onChange={(m) => setModel({ ...model, model: m })}
            placeholder={L('models.external.model')}
          />
          {!isNew && hasKey && (
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '4px 2px' }}>
              <span style={{ fontSize: 12.5, color: 'var(--fg-2)' }}>{L('web.ai.clearKey')}</span>
              <Toggle label={L('web.ai.clearKey')} checked={clear} onChange={setClear} />
            </div>
          )}
        </div>

        {error && <Banner text={error} icon={<TriangleAlert size={15} />} color="red" />}
      </div>
    </Dialog>
  );
}
