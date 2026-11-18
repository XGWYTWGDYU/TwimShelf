import { useEffect, useRef, useState } from 'react';
import {
  L, type CatalogEntry, type HubDetail, type HubDevice, type HubHidden,
  type HubPage, type HubRepo, type HubVariant, type InterruptedModel,
  type ModelDownloadStatus, type ModelInfo,
} from '@twimshelf/core';
import {
  BadgeCheck, Box, Check, ChevronDown, Eye, EyeOff,
  Search, Tag, ThumbsUp, TriangleAlert,
} from 'lucide-react';
import { Button, Spinner, TextField } from '../../components/ui';
import { change, LoadState, useTask } from '../../components/libraryControls';
import { choose } from '../../components/pickers';
import { core } from '../../lib/core';
import { useAsync, useInterval } from '../../lib/hooks';
import { openExternal, size } from './serverFiles';
import {
  ActivityRow, Banner, Card, CardRow, ChipButton, IconTile,
  Pill, RowDivider, SectionGroup, SettingsScreen, type TileColor,
} from './settingsControls';

const format = 'gguf';

function tierColor(tier: string): TileColor {
  switch (tier) {
    case 'recommended': return 'green';
    case 'usable': return 'orange';
    case 'tooLarge': return 'red';
    default: return 'secondary';
  }
}

function shortName(repo: string): string {
  return repo.split('/').pop() ?? repo;
}

function formatParams(n: number): string {
  return `${(n / 1e9).toFixed(1)}B`;
}

function formatMemory(bytes: number): string {
  return `${Math.round(bytes / 1024 ** 3)} GB`;
}

export function ModelProgress({ status, cancel }: { status?: ModelDownloadStatus | null; cancel: () => void }) {
  if (!status) return null;
  if (status.running) {
    return (
      <Card tint="accent" spacing={12}>
        <ActivityRow
          kind="model"
          title={L('activity.downloadingModel', status.repo)}
          detail={
            status.verifying
              ? L('models.verifying')
              : status.total_bytes
                ? `${size(status.done_bytes)} / ${size(status.total_bytes)}`
                : L('models.connecting')
          }
          progress={status.total_bytes ? status.done_bytes / status.total_bytes : undefined}
        />
        <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
          <Button onClick={cancel}>{L('models.cancelDownload')}</Button>
        </div>
      </Card>
    );
  }
  if (status.error && status.error !== L('models.cancelled')) {
    return (
      <Banner
        text={L('hub.line', L('models.downloadFailed'), L(status.error))}
        icon={<TriangleAlert size={15} />}
        color="red"
      />
    );
  }
  return null;
}

export default function ModelHubPage() {
  const [draft, setDraft] = useState('');
  const [query, setQuery] = useState('');
  const [onlyFit, setOnlyFit] = useState(true);
  const [uncensored, setUncensored] = useState(false);
  const [items, setItems] = useState<HubRepo[]>([]);
  const [hidden, setHidden] = useState<HubHidden[]>([]);
  const [next, setNext] = useState<string | null>(null);
  const [device, setDevice] = useState<HubDevice | null>(null);
  const [loading, setLoading] = useState(false);
  const [searched, setSearched] = useState(false);
  const [searchError, setSearchError] = useState<string>();
  const [showHidden, setShowHidden] = useState(false);
  const [openRepo, setOpenRepo] = useState<string>();
  const generation = useRef(0);
  const task = useTask();

  const catalog = useAsync(async () => {
    const [entries, dev, interrupted] = await Promise.all([
      core.read<CatalogEntry[]>(core.b.tl_model_catalog(format)),
      core.read<HubDevice | null>(core.b.tl_hub_device()),
      core.read<InterruptedModel[]>(core.b.tl_models_interrupted()).catch(() => [] as InterruptedModel[]),
    ]);
    return { entries, dev, interrupted };
  }, []);

  const status = useAsync(() => core.read<ModelDownloadStatus | null>(core.b.tl_model_status()), []);
  const installed = useAsync(
    () => core.read<ModelInfo[]>(core.b.tl_models_installed()),
    [status.data?.finished, status.data?.repo],
  );
  useInterval(status.reload, 1500);

  async function runSearch(q: string, unc: boolean, nextToken: string | null) {
    const runId = nextToken === null ? ++generation.current : generation.current;
    if (nextToken === null) {
      setItems([]);
      setHidden([]);
      setNext(null);
    }
    setLoading(true);
    setSearchError(undefined);
    try {
      const page = await core.readJson<HubPage>('tl_hub_search', {
        format,
        query: q,
        uncensored: unc,
        ...(nextToken ? { next: nextToken } : {}),
      });
      if (runId !== generation.current) return;
      setItems((prev) => {
        const seen = new Set(prev.map((r) => r.repo));
        return [...prev, ...page.items.filter((r) => !seen.has(r.repo))];
      });
      setHidden((prev) => [...prev, ...page.hidden]);
      setNext(page.next ?? null);
      setDevice(page.device);
    } catch (e) {
      if (runId !== generation.current) return;
      setSearchError(L((e as Error)?.message ?? 'common.notDone'));
    } finally {
      if (runId === generation.current) {
        setLoading(false);
        setSearched(true);
      }
    }
  }

  useEffect(() => {
    void runSearch('', false, null);
    return () => { generation.current++; };
  }, []);

  const dev = device ?? catalog.data?.dev;
  const busy = task.busy || !!status.data?.running;
  const browsing = query.trim() === '' && !uncensored;
  const shown = onlyFit ? items.filter((r) => r.tier !== 'tooLarge') : items;
  const overMemory = onlyFit ? items.length - shown.length : 0;

  async function offerCurated(entry: CatalogEntry) {
    const ok = await choose(
      L('models.download.title', L(entry.name_key)),
      L('mac.models.download.message', size(entry.bytes)),
      [L('common.download')],
    );
    if (ok == null) return;
    await task.run(async () => {
      const { repo, folder, bytes, weights, projector } = entry;
      await change(core.readJson('tl_hub_install', { format, repo, folder, bytes, weights, projector }));
      status.reload();
    });
  }

  if (openRepo) {
    return (
      <ModelHubRepoScreen
        repo={openRepo}
        status={status.data}
        installed={installed.data ?? []}
        busy={busy}
        reloadStatus={status.reload}
        onBack={() => setOpenRepo(undefined)}
      />
    );
  }

  const unknown = L('hub.unknown');
  const deviceLine = L(
    'hub.device',
    dev?.memory_bytes != null ? formatMemory(dev.memory_bytes) : unknown,
    dev?.free_bytes != null ? size(dev.free_bytes) : unknown,
  );

  return (
    <SettingsScreen title={L('hub.title')} parent="ai">
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <TextField
            value={draft}
            onChange={setDraft}
            placeholder={L('hub.search.placeholder')}
            onEnter={() => {
              const q = draft.trim();
              setQuery(q);
              void runSearch(q, uncensored, null);
            }}
          />
          <Button
            kind="primary"
            disabled={loading}
            onClick={() => {
              const q = draft.trim();
              setQuery(q);
              void runSearch(q, uncensored, null);
            }}>
            {L('hub.search')}
          </Button>
        </div>

        <div className="chips-row">
          <ChipButton
            title={L('hub.filter.fit')}
            icon={<BadgeCheck size={12} strokeWidth={2.2} />}
            selected={onlyFit}
            onClick={() => setOnlyFit(!onlyFit)}
          />
          <ChipButton
            title={L('hub.filter.uncensored')}
            icon={<Tag size={12} strokeWidth={2.2} />}
            selected={uncensored}
            onClick={() => {
              const nextUnc = !uncensored;
              setUncensored(nextUnc);
              void runSearch(query, nextUnc, null);
            }}
          />
        </div>

        <div style={{ fontSize: 11, color: 'var(--fg-2)', whiteSpace: 'pre-wrap', lineHeight: 1.45 }}>
          {`${deviceLine}\n${L('hub.device.footer')}`}
        </div>
      </div>

      <ModelProgress
        status={status.data}
        cancel={() => void task.run(async () => {
          await core.b.tl_model_cancel();
          status.reload();
        })}
      />

      {browsing && (
        !catalog.data || catalog.error ? (
          <LoadState error={catalog.error} reload={catalog.reload} />
        ) : (
          <SectionGroup title={L('hub.curated')} note={L('hub.curated.footer')}>
            <Card spacing={12}>
              {!catalog.data.entries.length && (
                <span style={{ fontSize: 13, color: 'var(--fg-2)' }}>{L('hub.empty')}</span>
              )}
              {catalog.data.entries.map((entry, i) => {
                const have = installed.data?.some(
                  (m) => m.id === entry.folder || m.path.endsWith('/' + entry.folder),
                );
                const part = catalog.data?.interrupted.find((p) => p.repo === entry.repo)?.bytes;
                const isDownloadingThis = status.data?.running && status.data.repo === entry.repo;
                return (
                  <div key={entry.folder} style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                    {i > 0 && <RowDivider inset={42} />}
                    <CardRow
                      icon={entry.role === 'tagger' ? <Eye size={15} strokeWidth={2} /> : <Search size={15} strokeWidth={2} />}
                      color={entry.role === 'tagger' ? 'purple' : 'teal'}
                      title={L(entry.name_key)}
                      detail={
                        part != null
                          ? L('mac.models.partial', size(part), size(entry.bytes))
                          : `${L(entry.note_key)} · ${size(entry.bytes)}`
                      }
                      trailing={
                        have ? (
                          <Pill text={L('hub.installed')} color="green" icon={<Check size={10} strokeWidth={3} />} />
                        ) : (
                          <>
                            <Pill
                              text={L(`hub.tier.${entry.tier || 'unknown'}`)}
                              color={tierColor(entry.tier)}
                            />
                            <Button disabled={busy} onClick={() => void offerCurated(entry)}>
                              {isDownloadingThis
                                ? L('models.downloading')
                                : part != null
                                  ? L('settings.resume')
                                  : L('common.download')}
                            </Button>
                          </>
                        )
                      }
                    />
                  </div>
                );
              })}
            </Card>
          </SectionGroup>
        )
      )}

      <SectionGroup title={browsing ? L('hub.popular') : L('hub.results')} note={L('hub.results.footer')}>
        {searchError && (
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <Banner text={searchError} icon={<TriangleAlert size={15} />} color="orange" />
            <Button onClick={() => void runSearch(query, uncensored, null)}>{L('models.retry')}</Button>
          </div>
        )}

        {searched && !loading && shown.length === 0 && !searchError && (
          <Card><span style={{ fontSize: 13, color: 'var(--fg-2)' }}>{L('hub.empty')}</span></Card>
        )}

        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {shown.map((r) => (
            <Card key={r.repo} spacing={8}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                <IconTile
                  icon={<Box size={16} strokeWidth={2} />}
                  color={tierColor(r.tier) === 'secondary' ? 'gray' : tierColor(r.tier)}
                  size={34}
                />
                <div className="card-row-texts" style={{ gap: 4 }}>
                  <div style={{ fontSize: 13.5, fontWeight: 600, color: 'var(--fg)' }}>{shortName(r.repo)}</div>
                  <div style={{ fontSize: 11, color: 'var(--fg-2)' }}>{r.repo.split('/')[0]}</div>
                  <div className="chips-row" style={{ gap: 5 }}>
                    <Pill text={L(`hub.tier.${r.tier}`)} color={tierColor(r.tier)} />
                    {r.estimated_bytes != null && <Pill text={L('hub.estimate', size(r.estimated_bytes))} />}
                    {r.params != null && <Pill text={formatParams(r.params)} />}
                    {r.architecture && <Pill text={r.architecture} />}
                    {r.claims_uncensored && <Pill text={L('hub.claim')} color="purple" />}
                  </div>
                </div>
                <Button onClick={() => setOpenRepo(r.repo)}>{L('hub.view')}</Button>
              </div>
            </Card>
          ))}
        </div>

        {loading && (
          <div style={{ display: 'inline-flex', alignItems: 'center', gap: 8, padding: '4px 4px', color: 'var(--fg-2)', fontSize: 12.5 }}>
            <Spinner />
            <span>{L('hub.loading')}</span>
          </div>
        )}

        {(overMemory > 0 || (next && !loading)) && (
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 4px' }}>
            {overMemory > 0 ? (
              <Button kind="plain" onClick={() => setOnlyFit(false)}>
                {L('hub.overMemory', overMemory)}
              </Button>
            ) : <span />}
            {next && !loading && (
              <Button onClick={() => void runSearch(query, uncensored, next)}>{L('hub.more')}</Button>
            )}
          </div>
        )}
      </SectionGroup>

      {hidden.length > 0 && (
        <Card spacing={8}>
          <button
            type="button"
            className="nav-row-btn"
            onClick={() => setShowHidden(!showHidden)}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', width: '100%', color: 'var(--fg-2)', fontSize: 12.5 }}>
              <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8 }}>
                <EyeOff size={14} strokeWidth={2} />
                <span>{L('hub.hidden', hidden.length)}</span>
              </span>
              <ChevronDown
                size={14}
                strokeWidth={2.2}
                style={{ transform: showHidden ? 'rotate(180deg)' : undefined, transition: 'transform 0.18s' }}
              />
            </div>
          </button>
          {showHidden && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8, paddingTop: 4 }}>
              {hidden.map((h) => (
                <div key={h.repo} style={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
                  <div className="selectable" style={{ fontSize: 11.5, fontWeight: 500, color: 'var(--fg)' }}>{h.repo}</div>
                  <div style={{ fontSize: 11, color: 'var(--fg-2)' }}>{L(h.reason)}</div>
                </div>
              ))}
            </div>
          )}
        </Card>
      )}
    </SettingsScreen>
  );
}

function ModelHubRepoScreen({ repo, status, installed, busy, reloadStatus, onBack }: {
  repo: string;
  status?: ModelDownloadStatus | null;
  installed: ModelInfo[];
  busy: boolean;
  reloadStatus: () => void;
  onBack: () => void;
}) {
  const detail = useAsync(() => core.read<HubDetail>(core.b.tl_hub_repo(format, repo)), [repo]);
  const task = useTask();
  const d = detail.data;

  async function offerVariant(v: HubVariant, infoDetail: HubDetail) {
    const ok = await choose(
      L('models.download.title', shortName(repo)),
      L('hub.download.message', v.label, size(v.bytes)),
      [L('common.download')],
    );
    if (ok == null) return;
    await task.run(async () => {
      await change(
        core.readJson('tl_hub_install', {
          format,
          repo: infoDetail.repo.repo,
          revision: infoDetail.revision,
          folder: v.folder,
          bytes: v.bytes,
          weights: v.weights,
          projector: v.projector,
        }),
      );
      reloadStatus();
    });
  }

  return (
    <SettingsScreen title={shortName(repo)} back={onBack}>
      <Card spacing={10}>
        <CardRow
          icon={<Box size={15} strokeWidth={2} />}
          color="indigo"
          title={<span className="selectable">{repo}</span>}
          detail={L('hub.unverified.footer')}
          trailing={
            <Button onClick={() => openExternal(`https://huggingface.co/${repo.split('/').map(encodeURIComponent).join('/')}`)}>
              {L('hub.detail.openPage')}
            </Button>
          }
        />
        {d && (
          <div className="chips-row" style={{ gap: 5 }}>
            {d.repo.architecture && <Pill text={d.repo.architecture} />}
            {d.repo.params != null && <Pill text={formatParams(d.repo.params)} />}
            <Pill text={L('hub.line', L('hub.detail.license'), d.repo.license ?? L('hub.unknown'))} />
            <Pill text={L('hub.line', L('hub.detail.downloads'), d.repo.downloads.toLocaleString())} />
            {d.repo.claims_uncensored && <Pill text={L('hub.claim')} color="purple" />}
          </div>
        )}
      </Card>

      {status?.repo === repo && (
        <ModelProgress
          status={status}
          cancel={() => void task.run(async () => {
            await core.b.tl_model_cancel();
            reloadStatus();
          })}
        />
      )}

      {detail.error ? (
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <Banner text={L((detail.error as Error)?.message ?? 'common.notDone')} color="orange" />
          <Button onClick={detail.reload}>{L('models.retry')}</Button>
        </div>
      ) : !d ? (
        <div style={{ display: 'inline-flex', alignItems: 'center', gap: 8, color: 'var(--fg-2)', fontSize: 12.5 }}>
          <Spinner />
          <span>{L('hub.loading')}</span>
        </div>
      ) : (
        <>
          {d.problem && (
            <Banner
              text={L('hub.line', L('hub.detail.cannotInstall'), L(d.problem))}
              icon={<TriangleAlert size={15} />}
              color="red"
            />
          )}

          {d.variants.length > 0 && (
            <SectionGroup title={L('hub.detail.versions')} note={L('hub.detail.versions.footer')}>
              <Card spacing={12}>
                {d.variants.map((v, i) => {
                  const have = installed.some((m) => m.id === v.folder || m.path.endsWith('/' + v.folder));
                  return (
                    <div key={v.folder} style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                      {i > 0 && <RowDivider />}
                      <CardRow
                        title={v.label}
                        detail={size(v.bytes)}
                        trailing={
                          have ? (
                            <Pill text={L('hub.installed')} color="green" icon={<Check size={10} strokeWidth={3} />} />
                          ) : (
                            <>
                              {v.suggested && (
                                <Pill
                                  text={L('hub.variant.suggestedShort')}
                                  color="blue"
                                  icon={<ThumbsUp size={10} strokeWidth={2.5} />}
                                />
                              )}
                              <Pill text={L(`hub.tier.${v.tier}`)} color={tierColor(v.tier)} />
                              {v.enough_space ? (
                                <Button disabled={busy} onClick={() => void offerVariant(v, d)}>
                                  {L('common.download')}
                                </Button>
                              ) : (
                                <Pill text={L('hub.variant.noSpace', size(v.bytes))} color="red" />
                              )}
                            </>
                          )
                        }
                      />
                    </div>
                  );
                })}
              </Card>
            </SectionGroup>
          )}

          {d.skipped.length > 0 && (
            <SectionGroup title={L('hub.detail.skipped')}>
              <Card spacing={8}>
                {d.skipped.map((s) => (
                  <div key={s.name} style={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
                    <div className="selectable" style={{ fontSize: 11.5, fontWeight: 500, color: 'var(--fg)' }}>{s.name}</div>
                    <div style={{ fontSize: 11, color: 'var(--fg-2)' }}>{L(s.reason)}</div>
                  </div>
                ))}
              </Card>
            </SectionGroup>
          )}
        </>
      )}
    </SettingsScreen>
  );
}
