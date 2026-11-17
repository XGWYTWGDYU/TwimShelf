import { useEffect, useRef, useState } from 'react';
import { L } from '@twimshelf/core';
import { Link2, Puzzle } from 'lucide-react';
import { Button, Row, Section } from '../../components/ui';
import { change, Confirm, LoadState, useTask } from '../../components/libraryControls';
import { toast } from '../../components/toast';
import { core } from '../../lib/core';
import { useAsync, useInterval } from '../../lib/hooks';
import { copyText } from './serverFiles';
import { SettingsScreen } from './settingsControls';

interface Client { id: string; name: string; added: number; seen: number }
interface Pairing { code: string; link: string; expires_in: number }
interface ExtensionState { clients: Client[]; pairing: Pairing | null }

export default function ExtensionPage() {
  const state = useAsync(() => core.read<ExtensionState>(core.b.tl_ext_clients()), []);
  const task = useTask();
  const [removing, setRemoving] = useState<Client>();
  const before = useRef<Set<string> | undefined>(undefined);
  const pairing = state.data?.pairing;
  useInterval(state.reload, pairing ? 1200 : 3000);

  useEffect(() => {
    if (!state.data || pairing || !before.current) return;
    const previous = before.current;
    before.current = undefined;
    const added = state.data.clients.find((client) => !previous.has(client.id));
    if (added) toast(L('ext.code.done', added.name));
  }, [state.data, pairing]);

  return <SettingsScreen title={L('ext.title')}>
    <Section footer={L('ext.intro')}>
      {pairing ? <>
        <Row title={L('ext.code.title')} trailing={<strong className="control-pairing-code">{pairing.code}</strong>} />
        <div className="control-stack control-padded">
          <p>{L('ext.code.howto')}</p>
          <code className="control-wrap">{pairing.link}</code>
          <small>{L('ext.code.expires')}</small>
          <div className="control-actions">
            <Button disabled={task.busy} onClick={() => void task.run(async () => {
              await copyText(pairing.link);
              toast(L('ext.code.copied'));
            })}>{L('ext.code.copy')}</Button>
            <Button disabled={task.busy} onClick={() => void task.run(async () => {
              await core.b.tl_ext_pair_cancel();
              before.current = undefined;
              state.reload();
            })}>{L('common.cancel')}</Button>
          </div>
        </div>
      </> : <Row icon={<Link2 size={17} />} title={L('ext.bind')} trailing={<Button kind="primary" disabled={!state.data || task.busy}
        onClick={() => void task.run(async () => {
          const endpoint = new URL(core.transport.base || location.origin);
          const addresses = [`${endpoint.hostname}:${endpoint.port || (endpoint.protocol === 'https:' ? '443' : '80')}`];
          await core.read(core.b.tl_ext_pair_begin(JSON.stringify(addresses)));
          before.current = new Set(state.data?.clients.map(({ id }) => id));
          state.reload();
        })}>{L('ext.bind')}</Button>} />}
    </Section>
    {!state.data || state.error ? <LoadState error={state.error} reload={state.reload} /> :
      <Section title={L('ext.clients')} footer={L('ext.footer.web')}>
        {!state.data.clients.length && <Row title={L('ext.state.none')} />}
        {state.data.clients.map((client) => <Row key={client.id} icon={<Puzzle size={17} />} title={client.name}
          subtitle={L('ext.client.detail', new Date(client.added * 1000).toLocaleString(), new Date(client.seen * 1000).toLocaleString())}
          trailing={<Button onClick={() => setRemoving(client)}>{L('ext.remove.confirm')}</Button>} />)}
      </Section>}
    {removing && <Confirm title={L('ext.remove.title', removing.name)} action={L('ext.remove.confirm')} danger
      onClose={() => setRemoving(undefined)} onConfirm={async () => {
        await change(core.read(core.b.tl_ext_remove(removing.id)));
        state.reload();
      }}>{L('ext.remove.message')}</Confirm>}
  </SettingsScreen>;
}
