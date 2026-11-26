import { useEffect, useState } from 'react';
import {
  KEYWORDS, keywordWord, L,
  type DiscoveryStatus, type DownloadStatus, type ImportProgress,
  type ModelDownloadStatus, type SyncStatus, type VerifyStatus,
} from '@twimshelf/core';
import {
  ArrowDownCircle, ChevronDown, Download, HardDrive, Info, LogOut, Package, Power, Puzzle, Scale,
  RefreshCw, Sparkles, Tags, Trash2, Columns3,
} from 'lucide-react';
import { Button, Page } from '../../components/ui';
import { mascotEnabled, setMascotEnabled } from '../../components/Mascot';
import { clawdLicense } from '../../components/clawdIcons.generated';
import { alertMessage } from '../../components/pickers';
import { Select, useTask } from '../../components/libraryControls';
import { core } from '../../lib/core';
import { useAsync, useInterval, useStore } from '../../lib/hooks';
import { libraryVersion, stats } from '../../lib/library';
import TagsPage from '../TagsPage';
import { cardDensities, cardDensity, setCardDensity } from '../browse/density';
import AIPage from './AIPage';
import {
  activeTagger, allTaggers, enableAutoTagging,
  localAIInfo, tagging,
} from './aiTagging';
import { checkForUpdate, updateRepo } from '../../lib/update';
import DownloadsPage from './DownloadsPage';
import ExtensionPage from './ExtensionPage';
import ImportRecordsPage from './ImportRecordsPage';
import { AboutPage, ProblemsPage, StoragePage, WipePage } from './MaintenancePages';
import ModelHubPage from './ModelHubPage';
import { info as serverInfo, size } from './serverFiles';
import {
  ActivityRow, Card, CardRow, NavRow, NavTile, Pill, RowDivider,
  runWipeFlow, SectionGroup, settings, StatsStrip, ToggleRow,
} from './settingsControls';
import SyncPage from './SyncPage';
import TransferPage from './TransferPage';

const pages = {
  downloads: DownloadsPage,
  'import-backup': TransferPage,
  tags: () => <TagsPage back={() => settings()} />,
  ai: AIPage,
  sync: SyncPage,
  extension: ExtensionPage,
  storage: StoragePage,
  about: AboutPage,
  problems: ProblemsPage,
  'import-records': ImportRecordsPage,
  'model-hub': ModelHubPage,
  'clear-all-data': WipePage,
};

export default function SettingsPage({ sub }: { sub?: string }) {
  useEffect(enableAutoTagging, []);

  if (sub && Object.hasOwn(pages, sub)) {
    const Screen = pages[sub as keyof typeof pages];
    return <Screen key={sub} />;
  }

  return <SettingsOverview />;
}

function SettingsOverview() {
  const counts = useStore(stats);
  const density = useStore(cardDensity);
  const version = useStore(libraryVersion);
  const selectedTagger = useStore(activeTagger);
  const tagActivity = useStore(tagging);
  const mascot = useStore(mascotEnabled);
  const task = useTask();
  const [loginItem, setLoginItem] = useState(false);
  const [checkingUpdate, setCheckingUpdate] = useState(false);
  // the server's page: 检查更新 is offered when the server is a GitHub build (it only tells)
  const serverRepo = useAsync(async () => (window.twimshelf?.desktop ? null : (await serverInfo()).update_repo ?? null), []);

  useEffect(() => {
    window.twimshelf?.getLoginItem?.().then(setLoginItem, () => {});
  }, []);

  const live = useAsync(async () => {
    const [dl, aiCounts, taggers, localAI, sync, discovery, ext, modelDl, verify, imp] = await Promise.all([
      core.read<DownloadStatus>(core.b.tl_download_status()).catch(() => null),
      core.read<[number, number]>(core.b.tl_ai_counts()).catch(() => [0, 0] as [number, number]),
      allTaggers().catch(() => []),
      localAIInfo(),
      core.read<SyncStatus>(core.b.tl_sync_status()).catch(() => null),
      core.read<DiscoveryStatus>(core.b.tl_discovery_status()).catch(() => null),
      core.read<{ clients: { id: string }[] }>(core.b.tl_ext_clients()).catch(() => null),
      core.read<ModelDownloadStatus | null>(core.b.tl_model_status()).catch(() => null),
      core.read<VerifyStatus | null>(core.b.tl_verify_status()).catch(() => null),
      core.read<ImportProgress | null>(core.b.tl_import_status()).catch(() => null),
    ]);
    return { dl, aiCounts, taggers, localAI, sync, discovery, ext, modelDl, verify, imp };
  }, [version]);

  useInterval(live.reload, live.loading ? null : 2000);

  const d = live.data;
  const dl = d?.dl;
  const [aiDone = 0, aiTotal = 0] = d?.aiCounts ?? [0, 0];
  const activeModel = d?.taggers.find((m) => m.id === selectedTagger);
  const sync = d?.sync;
  const hasAccount = !!sync?.account_id;
  const onlinePeers = hasAccount
    ? (d?.discovery?.peers ?? []).filter((p) => p.account === sync?.account_id && p.host && p.port).length
    : 0;
  const syncing = (sync?.syncing ?? 0) > 0;
  const extCount = d?.ext?.clients.length ?? 0;

  const dlFinish = (dl?.done ?? 0) + (dl?.skipped ?? 0) + (dl?.failed ?? 0);
  const dlDetail = dl?.running
    ? `${L('activity.downloadingPosts')} · ${dlFinish} / ${dl.total}`
    : dl?.paused
      ? L('mac.download.paused', dl.paused)
      : undefined;
  const dlProgress = dl?.running && dl.total > 0 ? dlFinish / dl.total : undefined;

  const aiDetail = (activeModel ? activeModel.title : L('mac.models.none'))
    + (aiTotal > 0 ? L('mac.models.analysed', aiDone, aiTotal) : '');

  const syncDetail = hasAccount
    ? (onlinePeers > 0 ? L('mac.sync.online', onlinePeers) : L('mac.sync.noneOnline'))
    : L('mac.sync.noAccount');

  const syncPillText = !hasAccount
    ? L('sync.state.notJoined')
    : syncing
      ? L('mac.sync.syncing')
      : onlinePeers > 0
        ? L('mac.sync.online', onlinePeers)
        : L('sync.state.on');

  const receiving = sync?.receiving;
  const otherActivities: {
    key: string;
    kind: 'download' | 'model' | 'tagging' | 'verify' | 'importing';
    title: string;
    detail?: string;
    progress?: number;
    previewPath?: string | null;
    previewIsVideo?: boolean;
  }[] = [];

  if (dl?.running) {
    const recent = dl.recent.at(-1);
    otherActivities.push({
      key: 'download',
      kind: 'download',
      title: L('activity.downloadingPosts'),
      detail: `${dlFinish} / ${dl.total}${dl.failed > 0 ? L('settings.failedSuffix', dl.failed) : ''}${dl.active.length ? L('activity.activeSuffix', dl.active.length) : ''}`,
      progress: dl.total > 0 ? dlFinish / dl.total : undefined,
      previewPath: recent,
      previewIsVideo: recent ? /\.(mp4|mov|m4v|webm)$/i.test(recent) : false,
    });
  }
  if (d?.modelDl?.running) {
    const m = d.modelDl;
    otherActivities.push({
      key: 'model',
      kind: 'model',
      title: L('activity.downloadingModel', m.repo),
      detail: m.verifying ? L('models.verifying') : m.total_bytes > 0 ? `${size(m.done_bytes)} / ${size(m.total_bytes)}` : L('models.connecting'),
      progress: m.total_bytes > 0 ? m.done_bytes / m.total_bytes : undefined,
    });
  }
  if (tagActivity.running) {
    otherActivities.push({
      key: 'tagging',
      kind: 'tagging',
      title: L('ai.activity.new', tagActivity.modelName || activeModel?.title || L('models.tagging')),
      detail: tagActivity.total > 0 ? `${tagActivity.done} / ${Math.max(tagActivity.total, tagActivity.done)}` : L('web.ai.processed', tagActivity.done),
      progress: tagActivity.total > 0 ? tagActivity.done / Math.max(tagActivity.total, tagActivity.done) : (aiTotal > 0 ? aiDone / aiTotal : undefined),
      previewPath: tagActivity.currentPath,
      previewIsVideo: tagActivity.currentKind === 'video',
    });
  }
  if (d?.imp?.running) {
    const imp = d.imp;
    otherActivities.push({
      key: 'importing',
      kind: 'importing',
      title: imp.waiting ? L('activity.importWaiting') : L('activity.importing'),
      detail: L('activity.importProgress', imp.folders_done, imp.folders_total, imp.files_done)
        + (imp.issues > 0 ? L('activity.importIssues', imp.issues) : ''),
      progress: imp.folders_total > 0 ? imp.folders_done / imp.folders_total : undefined,
      previewPath: imp.current,
    });
  }
  if (d?.verify?.running) {
    const v = d.verify;
    otherActivities.push({
      key: 'verify',
      kind: 'verify',
      title: L('activity.verifying'),
      detail: `${v.checked} / ${v.total} · ${size(v.bytes)}${v.bad > 0 ? L('activity.foundBad', v.bad) : ''}`,
      progress: v.total > 0 ? v.checked / v.total : undefined,
      previewPath: v.current,
    });
  }

  return (
    <Page title={L('place.settings')}>
      <div className="settings-canvas">
        {syncing && (
          <Card tint="accent" spacing={16}>
            <ActivityRow
              kind="sync"
              title={receiving && receiving.total > 0 ? L('activity.receiving') : L('activity.syncing')}
              detail={
                receiving && receiving.total > 0
                  ? L('activity.filesLeft', Math.max(0, receiving.total - receiving.received))
                    + (receiving.total_bytes > 0
                      ? L('activity.received', receiving.received, receiving.total, size(receiving.bytes), size(receiving.total_bytes))
                      : L('activity.receivedShort', receiving.received, receiving.total, size(receiving.bytes)))
                  : L('activity.syncDetail')
              }
              progress={receiving && receiving.total_bytes > 0 ? receiving.bytes / receiving.total_bytes : undefined}
              previewPath={receiving?.last_path}
            />
          </Card>
        )}

        <div className="s-hero">
          <div className="s-hero-top">
            <h2 className="s-hero-title">{L('common.library')}</h2>
            <Pill
              text={syncPillText}
              color={syncing ? 'blue' : 'secondary'}
              icon={<RefreshCw size={10} strokeWidth={2.5} />}
            />
          </div>
          <StatsStrip stats={counts} />
        </div>

        {otherActivities.length > 0 && (
          <Card tint="accent" spacing={16}>
            {otherActivities.map((act) => (
              <ActivityRow
                key={act.key}
                kind={act.kind}
                title={act.title}
                detail={act.detail}
                progress={act.progress}
                previewPath={act.previewPath}
                previewIsVideo={act.previewIsVideo}
              />
            ))}
          </Card>
        )}

        <SectionGroup title={L('mac.manage')}>
          <div className="nav-tiles-grid">
            <NavTile
              id="nav-download"
              title={L('common.downloadPosts')}
              detail={dlDetail}
              icon={<Download size={19} strokeWidth={2} />}
              color="blue"
              mascot={dl?.running ? 'bag' : undefined}
              progress={dlProgress}
              onClick={() => settings('downloads')}
            />
            <NavTile
              id="nav-transfer"
              title={L('common.importAndBackup')}
              icon={<Package size={19} strokeWidth={2} />}
              color="brown"
              onClick={() => settings('import-backup')}
            />
            <NavTile
              id="nav-tags"
              title={L('common.tags')}
              icon={<Tags size={19} strokeWidth={2} />}
              color="indigo"
              onClick={() => settings('tags')}
            />
            <NavTile
              id="nav-models"
              title={L('common.aiModels')}
              detail={aiDetail}
              icon={<Sparkles size={19} strokeWidth={2} />}
              color="purple"
              mascot={tagActivity.running ? 'camera' : undefined}
              onClick={() => settings('ai')}
            />
            <NavTile
              id="nav-sync"
              title={L('mac.sync')}
              detail={syncDetail}
              icon={<RefreshCw size={19} strokeWidth={2} />}
              color="green"
              badge={syncing ? L('mac.sync.syncing') : undefined}
              badgeColor="blue"
              onClick={() => settings('sync')}
            />
            <NavTile
              id="nav-extension"
              title={L('ext.title')}
              detail={extCount === 0 ? L('ext.state.none') : L('ext.state.count', String(extCount))}
              icon={<Puzzle size={19} strokeWidth={2} />}
              color="indigo"
              onClick={() => settings('extension')}
            />
          </div>
        </SectionGroup>

        <SectionGroup title={L('mac.prefs')}>
          <Card spacing={14}>
            <div className="card-group-label">{L('common.search')}</div>
            <div style={{ padding: 12, borderRadius: 12, background: 'var(--bg-subtle)' }}>
              <div className="chips-row" style={{ gap: 6 }}>
                {KEYWORDS.map((kw) => (
                  <Pill key={kw.id} text={keywordWord(kw)} color="blue" />
                ))}
              </div>
            </div>
          </Card>
        </SectionGroup>

        <SectionGroup title={L('mascot.title')}>
          <Card spacing={14}>
            <ToggleRow
              mascot="settings"
              alwaysMascot
              color="orange"
              title={L('mascot.toggle')}
              detail={L('mascot.footer')}
              checked={mascot}
              onChange={setMascotEnabled}
            />
            <RowDivider inset={42} />
            <CardRow
              icon={<Scale size={15} />}
              color="gray"
              title={L('mascot.licenses')}
              trailing={(
                <Button onClick={() => void alertMessage(L('mascot.licenses'), clawdLicense)}>
                  {L('common.view')}
                </Button>
              )}
            />
          </Card>
        </SectionGroup>

        {(!!updateRepo() || !!serverRepo.data) && (
          <Card spacing={12}>
            <CardRow
              icon={<ArrowDownCircle size={15} strokeWidth={2} />}
              color="blue"
              title={L('update.check')}
              trailing={
                <Button
                  disabled={checkingUpdate}
                  onClick={() => {
                    setCheckingUpdate(true);
                    void checkForUpdate(true).finally(() => setCheckingUpdate(false));
                  }}>
                  {checkingUpdate ? L('update.checking') : L('update.check')}
                </Button>
              }
            />
          </Card>
        )}

        <Card spacing={14}>
          <CardRow
            icon={<Columns3 size={15} />}
            color="teal"
            title={L('cards.section')}
            trailing={(
              <span className="browse-card-density">
                <Select
                  label={L('cards.section')}
                  value={density}
                  options={cardDensities.map((value) => ({ value, label: L(`cards.${value}`) }))}
                  onChange={(value) => {
                    const selected = cardDensities.find((option) => option === value);
                    if (selected) setCardDensity(selected);
                  }}
                />
                <ChevronDown className="browse-card-density-arrow" size={14} strokeWidth={1.8} aria-hidden="true" />
              </span>
            )}
          />
        </Card>

        <Card spacing={12}>
          {window.twimshelf?.desktop && window.twimshelf.getLoginItem && (
            <>
              <ToggleRow
                icon={<Power size={15} strokeWidth={2} />}
                color="green"
                title={L('settings.launchAtLogin')}
                checked={loginItem}
                onChange={(v) => {
                  void window.twimshelf?.setLoginItem?.(v).then(setLoginItem, () => {});
                }}
              />
              <RowDivider inset={42} />
            </>
          )}
          <NavRow
            id="nav-storage"
            icon={<HardDrive size={15} strokeWidth={2} />}
            color="gray"
            title={L('storage.title')}
            onClick={() => settings('storage')}
          />
          <RowDivider inset={42} />
          <NavRow
            id="settingsAbout"
            icon={<Info size={15} strokeWidth={2} />}
            color="gray"
            title={L('settings.about')}
            onClick={() => settings('about')}
          />
        </Card>

        {!window.twimshelf && (
          <SectionGroup footer={L('settings.signOut.footer')}>
            <Card spacing={12}>
              <NavRow
                icon={<LogOut size={15} strokeWidth={2} />}
                color="gray"
                title={L('settings.signOut')}
                onClick={() => { location.href = '/logout'; }}
              />
            </Card>
          </SectionGroup>
        )}

        <Card tint="red" spacing={12}>
          <CardRow
            icon={<Trash2 size={15} strokeWidth={2} />}
            color="red"
            title={L('mac.wipe.title')}
            trailing={
              <Button kind="danger" disabled={task.busy} onClick={() => void task.run(() => runWipeFlow())}>
                {L('mac.eraseEllipsis')}
              </Button>
            }
          />
        </Card>
      </div>
    </Page>
  );
}
