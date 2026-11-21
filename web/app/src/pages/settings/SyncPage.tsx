import { useEffect, useRef } from 'react';
import { L, type DiscoveredPeer, type DiscoveryStatus, type PeerInfo, type SyncStatus } from '@twimshelf/core';
import {
  ArrowUpCircle, Check, ClockAlert, Laptop, LogOut, Monitor,
  Plus, RefreshCw, Scan, Smartphone, Tablet, TriangleAlert,
  UserCircle, UserPlus, Users, WifiOff,
} from 'lucide-react';
import { Button, Spinner } from '../../components/ui';
import type { MascotName } from '../../components/Mascot';
import { change, LoadState, useTask } from '../../components/libraryControls';
import { alertMessage, choose, prompt } from '../../components/pickers';
import { core } from '../../lib/core';
import { useAsync, useInterval, useStore } from '../../lib/hooks';
import { libraryChanged, stats } from '../../lib/library';
import { info, size, updateSecrets } from './serverFiles';
import {
  ActivityRow, Banner, Card, CardRow, IconTile, Pill, RowDivider,
  runWipeFlow, SectionGroup, SettingsScreen, StatsStrip,
} from './settingsControls';

async function start(key: string) {
  const server = await info();
  await core.read(core.b.tl_sync_start(key, server.device_name));
  await core.read(core.b.tl_discovery_start(server.sync_service, server.device_name, 'linux'));
}

async function adopt(key: string) {
  await updateSecrets({ 'sync.key': key });
  await core.b.tl_discovery_stop();
  await start(key);
}

function deviceTypeName(kind?: string | null): string | null {
  switch (kind) {
    case 'mac': return 'macOS';
    case 'iphone': return 'iPhone';
    case 'ipad': return 'iPad';
    case 'android-phone':
    case 'android-tablet': return 'Android';
    case 'windows': return 'Windows';
    case 'linux': return 'Linux';
    default: return null;
  }
}

function deviceMascot(kind?: string | null): MascotName | undefined {
  switch (kind) {
    case 'iphone':
    case 'android-phone':
      return 'mobile';
    case 'ipad':
    case 'android-tablet':
      return 'tablet';
    case 'mac':
    case 'windows':
    case 'linux':
      return 'laptop';
    default:
      return undefined;
  }
}

function deviceIcon(kind?: string | null, sz = 18) {
  switch (kind) {
    case 'iphone':
    case 'android-phone':
      return <Smartphone size={sz} strokeWidth={2} />;
    case 'ipad':
    case 'android-tablet':
      return <Tablet size={sz} strokeWidth={2} />;
    case 'windows':
    case 'linux':
      return <Monitor size={sz} strokeWidth={2} />;
    default:
      return <Laptop size={sz} strokeWidth={2} />;
  }
}

function formatAgo(seconds: number): string {
  if (!seconds) return L('time.never');
  const diff = Math.max(0, Math.floor(Date.now() / 1000) - seconds);
  if (diff < 60) return L('time.justNow');
  if (diff < 3600) return L('time.minutesAgo', Math.floor(diff / 60));
  if (diff < 86400) return L('time.hoursAgo', Math.floor(diff / 3600));
  return L('time.daysAgo', Math.floor(diff / 86400));
}

function clockSkewText(p?: PeerInfo): string | null {
  if (!p?.clock_warning || p.clock_skew_ms == null) return null;
  const mins = Math.abs(p.clock_skew_ms) / 60_000;
  const amount = mins >= 120
    ? L('time.hoursValue', Math.round(mins / 60))
    : L('time.minutesValue', Math.round(mins));
  return L('sync.clock.skew', p.clock_skew_ms > 0 ? L('sync.clock.ahead', amount) : L('sync.clock.behind', amount));
}

export default function SyncPage() {
  const counts = useStore(stats);
  const task = useTask();
  const state = useAsync(async () => {
    const [status, discovery] = await Promise.all([
      core.read<SyncStatus>(core.b.tl_sync_status()),
      core.read<DiscoveryStatus>(core.b.tl_discovery_status()),
    ]);
    return { status, discovery };
  }, []);
  const handledJoin = useRef<string | null>(null);
  const status = state.data?.status;
  const discovery = state.data?.discovery;
  const account = status?.account_id;
  const changes = status?.changes;
  const joinKey = status?.join.account_key;

  useInterval(state.reload, state.loading ? null : 1200);
  useEffect(() => { if (changes !== undefined) libraryChanged(); }, [changes]);

  useEffect(() => {
    if (discovery?.running !== false || !status) return;
    void task.run(async () => {
      if (!status.port && !status.account_id) await start('');
      else {
        const server = await info();
        await core.read(core.b.tl_discovery_start(server.sync_service, server.device_name, 'linux'));
      }
      state.reload();
    });
  }, [discovery?.running, status?.port]);

  useEffect(() => {
    if (!joinKey) {
      handledJoin.current = null;
      return;
    }
    if (task.busy || handledJoin.current === joinKey) return;
    handledJoin.current = joinKey;
    void task.run(async () => {
      await change(adopt(joinKey));
      state.reload();
      await alertMessage(L('sync.joined'), L('sync.joined.message'));
    });
  }, [joinKey, task.busy]);

  async function joinPeer(peer: DiscoveredPeer) {
    if (!peer.host || !peer.port) return;
    const code = (
      await prompt(L('sync.joinOf', peer.name), {
        message: L('sync.enterCode'),
        placeholder: '000000',
        action: L('sync.join'),
      })
    )?.trim().replace(/\s/g, '');
    if (!code) return;
    await task.run(async () => {
      await core.read(core.b.tl_sync_join(peer.host!, peer.port!, code));
      state.reload();
    });
  }

  async function leaveFlow() {
    const idx = await choose(
      L('sync.leave.title'),
      L('sync.leave.message'),
      [L('sync.leave.keep'), L('sync.leave.deleteAll')],
      { destructive: true },
    );
    if (idx == null) return;
    if (idx === 1) {
      await task.run(() => runWipeFlow());
      return;
    }
    await task.run(async () => {
      await updateSecrets({ 'sync.key': null });
      await core.b.tl_sync_reset();
      await core.b.tl_discovery_stop();
      await change(start(''));
      state.reload();
    });
  }

  const allDiscovered = discovery?.peers ?? [];
  const mine = account
    ? allDiscovered.filter((p) => p.account === account).sort((a, b) => a.name.localeCompare(b.name))
    : [];
  const known = status?.peers ?? [];
  const offline = known.filter((k) => !mine.some((m) => m.device === k.device));
  const reachable = mine.filter((p) => p.host && p.port);

  const joinGroups = [...allDiscovered
    .filter((p) => p.account)
    .reduce((map, p) => {
      const k = p.account!;
      if (!map.has(k)) map.set(k, []);
      map.get(k)!.push(p);
      return map;
    }, new Map<string, DiscoveredPeer[]>())
    .entries()].map(([acct, list]) => ({
    account: acct,
    peers: list.sort((a, b) => a.name.localeCompare(b.name)),
    title: `${L('sync.accountId', acct.slice(0, 8).toUpperCase())} · ${list.map((p) => p.name).join(L('list.separator'))}`,
  }));

  const transfer = status?.receiving;
  const syncing = (status?.syncing ?? 0) > 0;
  const pairing = status?.pairing_code;
  const leftSecs = status?.pairing_seconds_left ?? 0;

  return (
    <SettingsScreen title={L('common.lanSync')}>
      {!state.data || state.error ? (
        <LoadState error={state.error} reload={state.reload} />
      ) : (
        <>
          {discovery && !discovery.network_ok && (
            <Card tint="red" spacing={12}>
              <CardRow
                icon={<WifiOff size={15} strokeWidth={2} />}
                color="red"
                title={L('sync.noLocalNetwork')}
                detail={discovery.error ? L(discovery.error) : L('sync.err.paused')}
              />
            </Card>
          )}

          {(counts?.newer_ops ?? 0) > 0 && (
            <Card tint="orange" spacing={8}>
              <CardRow
                icon={<ArrowUpCircle size={15} strokeWidth={2} />}
                color="orange"
                title={L('sync.updateMac', counts!.newer_ops)}
                detail={L('sync.newerOps').replaceAll('{app}', L('web.appName'))}
              />
            </Card>
          )}

          {(transfer || syncing) && (
            <Card tint="accent" spacing={14}>
              <ActivityRow
                kind="sync"
                title={transfer ? L('activity.receiving') : L('activity.syncing')}
                detail={
                  transfer
                    ? L('activity.filesLeft', Math.max(0, transfer.total - transfer.received))
                      + (transfer.total_bytes > 0
                        ? L('activity.received', transfer.received, transfer.total, size(transfer.bytes), size(transfer.total_bytes))
                        : L('activity.receivedShort', transfer.received, transfer.total, size(transfer.bytes)))
                    : L('activity.syncDetail')
                }
                progress={transfer && transfer.total_bytes ? transfer.bytes / transfer.total_bytes : undefined}
                previewPath={transfer?.last_path}
              />
            </Card>
          )}

          {account ? (
            <>
              <div className="s-hero hero-green">
                <div style={{ display: 'flex', alignItems: 'center', gap: 16, flexWrap: 'wrap' }}>
                  <IconTile icon={<Laptop size={24} strokeWidth={2} />} color="green" size={52} mascot="laptop" />
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 5, flex: 1, minWidth: 0 }}>
                    <div style={{ fontSize: 20, fontWeight: 700, color: 'var(--fg)' }}>
                      {status?.device_name || L('sync.thisMac')}
                    </div>
                    <div className="chips-row" style={{ gap: 6 }}>
                      <Pill
                        text={L('sync.accountId', account.slice(0, 8).toUpperCase())}
                        color="secondary"
                        icon={<UserCircle size={10} strokeWidth={2.5} />}
                      />
                      {syncing ? (
                        <Pill text={L('mac.sync.syncing')} color="blue" icon={<RefreshCw size={10} strokeWidth={2.5} />} />
                      ) : (
                        <Pill text={L('sync.idle')} color="green" icon={<Check size={10} strokeWidth={3} />} />
                      )}
                    </div>
                  </div>
                  <Button
                    kind="primary"
                    disabled={task.busy}
                    onClick={() => void task.run(async () => {
                      await core.b.tl_discovery_sync_now();
                      state.reload();
                    })}>
                    <RefreshCw size={14} strokeWidth={2.2} />
                    <span>{L('sync.now')}</span>
                  </Button>
                </div>

                <StatsStrip stats={counts} />

                <div style={{ fontSize: 11, color: 'var(--fg-2)', lineHeight: 1.45 }}>
                  {L('sync.devices.footer.mac')}
                </div>
              </div>

              <SectionGroup
                title={L('sync.devices')}
                note={
                  mine.length === 0 && known.length === 0
                    ? undefined
                    : L('sync.devices.counts', reachable.length, mine.length, offline.length)
                }>
                {mine.length === 0 && known.length === 0 ? (
                  <Card><span style={{ fontSize: 13, color: 'var(--fg-2)' }}>{L('sync.noOthers.mac')}</span></Card>
                ) : (
                  <div className="sync-devices-grid">
                    {mine.map((p) => {
                      const infoItem = known.find((k) => k.device === p.device);
                      const online = Boolean(p.host && p.port);
                      const failed = Boolean(infoItem?.last_error);
                      const skew = clockSkewText(infoItem);
                      const detailParts = [
                        deviceTypeName(p.kind),
                        !online
                          ? L('sync.found.confirming')
                          : infoItem
                            ? infoItem.last_error
                              ? L('sync.error', L(infoItem.last_error))
                              : infoItem.last_sync > 0
                                ? L('sync.syncedAgo', formatAgo(infoItem.last_sync))
                                : L('sync.justFound')
                            : L('sync.justFound'),
                      ].filter(Boolean);
                      return (
                        <Card key={p.device} spacing={10}>
                          <div style={{ display: 'flex', alignItems: 'flex-start', gap: 12 }}>
                            <IconTile icon={deviceIcon(p.kind, 18)} color={online ? 'green' : 'gray'} size={40} mascot={deviceMascot(p.kind)} />
                            <div className="card-row-texts" style={{ gap: 4 }}>
                              <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--fg)' }}>{p.name}</div>
                              <div style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontSize: 11, fontWeight: 500, color: 'var(--fg-2)' }}>
                                <span className={`status-dot${online ? ' online' : ''}`} />
                                <span>{online ? L('sync.online') : L('sync.found')}</span>
                              </div>
                            </div>
                          </div>
                          <div style={{ fontSize: 11, color: failed ? 'var(--danger)' : 'var(--fg-2)', lineHeight: 1.4 }}>
                            {detailParts.join(' · ')}
                          </div>
                          {skew && <Banner text={skew} icon={<ClockAlert size={14} />} color="orange" />}
                        </Card>
                      );
                    })}

                    {offline.map((k) => {
                      const skew = clockSkewText(k);
                      return (
                        <Card key={k.device} spacing={10} className="offline-device">
                          <div style={{ display: 'flex', alignItems: 'flex-start', gap: 12, opacity: 0.8 }}>
                            <IconTile icon={<Laptop size={18} strokeWidth={2} />} color="gray" size={40} />
                            <div className="card-row-texts" style={{ gap: 4 }}>
                              <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--fg)' }}>{k.name}</div>
                              <div style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontSize: 11, fontWeight: 500, color: 'var(--fg-2)' }}>
                                <span className="status-dot" />
                                <span>{L('sync.offline')}</span>
                              </div>
                            </div>
                          </div>
                          <div style={{ fontSize: 11, color: 'var(--fg-2)', lineHeight: 1.4 }}>
                            {L('sync.lastSynced', formatAgo(k.last_sync))}
                          </div>
                          {skew && <Banner text={skew} icon={<ClockAlert size={14} />} color="orange" />}
                        </Card>
                      );
                    })}
                  </div>
                )}
              </SectionGroup>

              <SectionGroup title={L('sync.addDevice')}>
                {pairing ? (
                  <Card tint="blue" spacing={16}>
                    <div className="pairing-code-box">
                      <div className="pairing-code-digits selectable">{pairing}</div>
                      {status?.pairing_seconds_left != null && (
                        <div style={{ fontSize: 11, fontVariantNumeric: 'tabular-nums', color: 'var(--fg-2)' }}>
                          {L('web.sync.expires', `${Math.floor(leftSecs / 60)}:${String(leftSecs % 60).padStart(2, '0')}`)}
                        </div>
                      )}
                    </div>
                    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10 }}>
                      <span style={{ fontSize: 12.5, color: 'var(--fg-2)' }}>{L('sync.addDevice.mac')}</span>
                      <Button
                        kind="danger"
                        disabled={task.busy}
                        onClick={() => void task.run(async () => {
                          await core.b.tl_sync_pair_cancel();
                          state.reload();
                        })}>
                        {L('common.cancel')}
                      </Button>
                    </div>
                  </Card>
                ) : (
                  <Card spacing={12}>
                    <CardRow
                      icon={<Scan size={15} strokeWidth={2} />}
                      color="blue"
                      title={L('sync.showCode')}
                      detail={L('sync.showCode.detail')}
                      trailing={
                        <Button
                          kind="primary"
                          disabled={task.busy}
                          onClick={() => void task.run(async () => {
                            await core.read(core.b.tl_sync_pair_begin());
                            state.reload();
                          })}>
                          {L('sync.showCodeEllipsis')}
                        </Button>
                      }
                    />
                  </Card>
                )}
              </SectionGroup>

              <Card tint="red" spacing={10}>
                <CardRow
                  icon={<LogOut size={15} strokeWidth={2} />}
                  color="red"
                  title={L('sync.leave')}
                  detail={L('sync.leave.footer.mac')}
                  trailing={
                    <Button kind="danger" disabled={task.busy} onClick={() => void leaveFlow()}>
                      {L('sync.leaveEllipsis')}
                    </Button>
                  }
                />
              </Card>
            </>
          ) : (
            <>
              <Card tint="green" spacing={14}>
                <div style={{ display: 'flex', alignItems: 'flex-start', gap: 14 }}>
                  <IconTile icon={<UserPlus size={20} strokeWidth={2} />} color="green" size={44} />
                  <div className="card-row-texts" style={{ gap: 4 }}>
                    <div style={{ fontSize: 16, fontWeight: 600, color: 'var(--fg)' }}>{L('sync.first')}</div>
                    <div className="card-row-detail" style={{ fontSize: 12.5 }}>{L('sync.first.footer')}</div>
                  </div>
                  <Button
                    kind="primary"
                    disabled={task.busy || status?.join.running}
                    onClick={() => void task.run(async () => {
                      const key = await core.read<string>(core.b.tl_sync_new_account());
                      await change(adopt(key));
                      state.reload();
                    })}>
                    <Plus size={14} strokeWidth={2.4} />
                    <span>{L('sync.create')}</span>
                  </Button>
                </div>
              </Card>

              <SectionGroup title={L('sync.joinExisting')} note={L('sync.joinExisting.footer')}>
                <Card spacing={12}>
                  {status?.join.error && (
                    <Banner
                      text={`${L('sync.joinFailed')}：${L(status.join.error)}`}
                      icon={<TriangleAlert size={15} />}
                      color="red"
                    />
                  )}
                  {status?.join.running && (
                    <div style={{ display: 'inline-flex', alignItems: 'center', gap: 8, color: 'var(--fg-2)', fontSize: 13 }}>
                      <Spinner />
                      <span>{L('sync.pairing')}</span>
                    </div>
                  )}
                  {joinGroups.length === 0 ? (
                    <div style={{ display: 'inline-flex', alignItems: 'center', gap: 10, color: 'var(--fg-2)', fontSize: 13 }}>
                      <Spinner />
                      <span>{L('sync.searching')}</span>
                    </div>
                  ) : (
                    joinGroups.map((g, gi) => (
                      <div key={g.account} style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                        {gi > 0 && <RowDivider />}
                        <div style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontSize: 12.5, fontWeight: 600, color: 'var(--fg-2)' }}>
                          <Users size={14} strokeWidth={2} />
                          <span>{g.title}</span>
                        </div>
                        {g.peers.map((p) => (
                          <CardRow
                            key={p.device}
                            icon={deviceIcon(p.kind, 15)}
                            color="indigo"
                            mascot={deviceMascot(p.kind)}
                            title={p.name}
                            detail={deviceTypeName(p.kind) ?? L('sync.accountDevices')}
                            trailing={
                              <Button
                                disabled={!p.host || !p.port || task.busy || status?.join.running}
                                onClick={() => void joinPeer(p)}>
                                {!p.host ? L('sync.resolving') : L('sync.joinEllipsis')}
                              </Button>
                            }
                          />
                        ))}
                      </div>
                    ))
                  )}
                </Card>
              </SectionGroup>
            </>
          )}
        </>
      )}
    </SettingsScreen>
  );
}
