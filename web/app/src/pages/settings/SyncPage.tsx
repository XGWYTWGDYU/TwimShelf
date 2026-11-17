import { useEffect, useRef, useState } from 'react';
import { L, type DiscoveredPeer, type DiscoveryStatus, type SyncStatus } from '@twimshelf/core';
import { Laptop, Radio, RefreshCw } from 'lucide-react';
import { Button, Dialog, Row, Section, TextField } from '../../components/ui';
import { change, Confirm, LoadState, useTask } from '../../components/libraryControls';
import { toast } from '../../components/toast';
import { core } from '../../lib/core';
import { useAsync, useInterval } from '../../lib/hooks';
import { libraryChanged } from '../../lib/library';
import { info, size, updateSecrets } from './serverFiles';
import { ProgressRow, SettingsScreen, settings } from './settingsControls';

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

export default function SyncPage() {
  const task = useTask();
  const state = useAsync(async () => {
    const [status, discovery] = await Promise.all([
      core.read<SyncStatus>(core.b.tl_sync_status()),
      core.read<DiscoveryStatus>(core.b.tl_discovery_status()),
    ]);
    return { status, discovery };
  }, []);
  const [join, setJoin] = useState<DiscoveredPeer>();
  const [code, setCode] = useState('');
  const [leaving, setLeaving] = useState(false);
  const handledJoin = useRef<string | null>(null);
  const status = state.data?.status;
  const discovery = state.data?.discovery;
  const account = status?.account_id;
  const changes = status?.changes;
  const joinKey = status?.join.account_key;
  useInterval(state.reload, 1500);
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
    // Discovery stays active on the server after navigating away.
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
      toast(L('sync.joined.message'));
      state.reload();
    });
  }, [joinKey, task.busy]);

  const peers = discovery?.peers ?? [];
  const joinable = peers.filter((peer) => peer.account && peer.host && peer.port);
  const transfer = status?.receiving;
  const pairing = status?.pairing_code;

  return <SettingsScreen title={L('common.lanSync')} actions={<Button disabled={task.busy || !state.data}
    onClick={() => void task.run(async () => { await core.b.tl_discovery_rediscover(); state.reload(); })}>
    {L('storage.refresh')}
  </Button>}>
    {!state.data || state.error ? <LoadState error={state.error} reload={state.reload} /> : <>
      <Section>
        <Row icon={<Laptop size={17} />} title={L('sync.thisDevice')} subtitle={status?.device_name}
          trailing={L(account ? 'sync.state.on' : 'sync.state.notJoined')} />
        {discovery && !discovery.network_ok && <Row title={L('sync.noLocalNetwork')} subtitle={discovery.error ? L(discovery.error) : undefined} />}
        {transfer ? <ProgressRow title={L('activity.receiving')}
          subtitle={L('activity.received', transfer.received, transfer.total, size(transfer.bytes), size(transfer.total_bytes))}
          value={transfer.total_bytes ? transfer.bytes / transfer.total_bytes : undefined} />
          : !!status?.syncing && <ProgressRow title={L('activity.syncing')} subtitle={L('activity.syncDetail')} />}
      </Section>
      {account ? <>
        <Section title={L('sync.devices')} footer={L('sync.devices.footer')}>
          {!status?.peers.length && <Row title={L('sync.noOthers')} />}
          {status?.peers.map((peer) => <Row key={peer.device} title={peer.name} subtitle={peer.last_error
            ? L(peer.last_error) : peer.last_sync ? L('sync.syncedAgo', new Date(peer.last_sync * 1000).toLocaleString()) : L('sync.offline')}
            trailing={status.in_session.includes(peer.device) ? L('sync.state.on') : undefined} />)}
          <Row icon={<RefreshCw size={17} />} title={L('sync.now')} onClick={() => void task.run(async () => {
            await core.b.tl_discovery_sync_now();
            state.reload();
          })} />
        </Section>
        <Section footer={L('sync.addDevice.footer')}>
          {pairing ? <Row title={<strong className="control-pairing-code">{pairing}</strong>}
            subtitle={status?.pairing_seconds_left == null ? undefined : L('web.sync.expires',
              `${Math.floor(status.pairing_seconds_left / 60)}:${String(status.pairing_seconds_left % 60).padStart(2, '0')}`)}
            trailing={<Button disabled={task.busy} onClick={() => void task.run(async () => {
              await core.b.tl_sync_pair_cancel();
              state.reload();
            })}>{L('common.cancel')}</Button>} />
            : <Row icon={<Radio size={17} />} title={L('sync.showCode')} subtitle={L('sync.showCode.detail')}
              onClick={() => void task.run(async () => { await core.read(core.b.tl_sync_pair_begin()); state.reload(); })} />}
        </Section>
        <Section footer={L('sync.leave.footer')}>
          <Row danger title={L('sync.leaveEllipsis')} onClick={() => setLeaving(true)} />
          <Row danger title={L('sync.leave.deleteAll')} onClick={() => settings('clear-all-data')} />
        </Section>
      </> : <>
        <Section footer={L('sync.first.footer')}>
          <Row title={L('sync.create')} trailing={<Button kind="primary" disabled={task.busy || status?.join.running} onClick={() => void task.run(async () => {
            const key = await core.read<string>(core.b.tl_sync_new_account());
            await change(adopt(key));
            state.reload();
          })}>{L('common.create')}</Button>} />
        </Section>
        <Section title={L('sync.joinExisting')} footer={L('sync.joinExisting.footer')}>
          {!!status?.join.error && <Row title={L('sync.joinFailed')} subtitle={L(status.join.error)} />}
          {status?.join.running ? <ProgressRow title={L('sync.pairing')} />
            : !joinable.length ? <Row title={L('sync.searching')} /> : joinable.map((peer) => <Row key={peer.device}
              title={peer.name} subtitle={peer.host ?? undefined} onClick={() => { setCode(''); setJoin(peer); }} />)}
        </Section>
      </>}
    </>}
    {join && <Dialog title={L('sync.joinOf', join.name)} onClose={() => { if (!task.busy) setJoin(undefined); }} actions={<>
      <Button disabled={task.busy} onClick={() => setJoin(undefined)}>{L('common.cancel')}</Button>
      <Button kind="primary" disabled={task.busy || !code.trim()} onClick={() => void task.run(async () => {
        await core.read(core.b.tl_sync_join(join.host!, join.port!, code.trim().replace(/\s/g, '')));
        setJoin(undefined);
        state.reload();
      })}>{L('sync.join')}</Button>
    </>}><TextField value={code} onChange={setCode} placeholder={L('sync.enterCode')} autoFocus /></Dialog>}
    {leaving && <Confirm title={L('sync.leave.title')} action={L('sync.leave.keep')} danger onClose={() => setLeaving(false)} onConfirm={async () => {
      await updateSecrets({ 'sync.key': null });
      await core.b.tl_sync_reset();
      await core.b.tl_discovery_stop();
      await change(start(''));
      state.reload();
    }}>{L('sync.leave.message')}</Confirm>}
  </SettingsScreen>;
}
