import { useEffect, useRef, useState } from 'react';
import { L } from '@twimshelf/core';
import { Link2, Puzzle } from 'lucide-react';
import { Button } from '../../components/ui';
import { change, LoadState, useTask } from '../../components/libraryControls';
import { alertMessage, choose } from '../../components/pickers';
import { core } from '../../lib/core';
import { useAsync, useInterval } from '../../lib/hooks';
import { copyText } from './serverFiles';
import {
  Card, CardRow, RowDivider, SectionGroup, SettingsScreen,
} from './settingsControls';

interface Client { id: string; name: string; added: number; seen: number }
interface Pairing { code: string; link: string; expires_in: number }
interface ExtensionState { clients: Client[]; pairing: Pairing | null }

function formatShortDate(seconds: number): string {
  return new Date(seconds * 1000).toLocaleString(undefined, {
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
  });
}

export default function ExtensionPage() {
  const state = useAsync(() => core.read<ExtensionState>(core.b.tl_ext_clients()), []);
  const task = useTask();
  const [copied, setCopied] = useState(false);
  const before = useRef<Set<string> | undefined>(undefined);
  const pairing = state.data?.pairing;

  useInterval(state.reload, pairing ? 1200 : 3000);

  useEffect(() => {
    return () => {
      void core.b.tl_ext_pair_cancel();
    };
  }, []);

  useEffect(() => {
    if (!state.data || pairing || !before.current) return;
    const previous = before.current;
    before.current = undefined;
    const added = state.data.clients.find((client) => !previous.has(client.id));
    if (added) void alertMessage(L('ext.code.done', added.name));
  }, [state.data, pairing]);

  async function removeClient(c: Client) {
    const ok = await choose(
      L('ext.remove.title', c.name),
      L('ext.remove.message'),
      [L('ext.remove.confirm')],
      { destructive: true },
    );
    if (ok == null) return;
    await task.run(async () => {
      await change(core.read(core.b.tl_ext_remove(c.id)));
      state.reload();
    });
  }

  const formattedCode = pairing
    ? pairing.code.length > 3
      ? `${pairing.code.slice(0, 3)} ${pairing.code.slice(3)}`
      : pairing.code
    : '';

  return (
    <SettingsScreen title={L('ext.title')}>
      <div style={{ fontSize: 13, color: 'var(--fg-2)', lineHeight: 1.5, padding: '0 4px' }}>
        {L('ext.intro')}
      </div>

      {pairing ? (
        <Card tint="blue" spacing={12}>
          <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--fg)' }}>{L('ext.code.title')}</div>
          <div className="pairing-code-box">
            <div className="pairing-code-digits selectable" data-testid="extCode">{formattedCode}</div>
          </div>
          <div style={{ fontSize: 13, color: 'var(--fg)', lineHeight: 1.45 }}>{L('ext.code.howto')}</div>
          <div className="ext-link-box selectable">{pairing.link}</div>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10, flexWrap: 'wrap' }}>
            <span style={{ fontSize: 11, color: 'var(--fg-2)' }}>{L('ext.code.expires')}</span>
            <div style={{ display: 'flex', gap: 8 }}>
              <Button
                disabled={task.busy}
                onClick={() => void task.run(async () => {
                  await copyText(pairing.link);
                  setCopied(true);
                })}>
                {copied ? L('ext.code.copied') : L('ext.code.copy')}
              </Button>
              <Button
                disabled={task.busy}
                onClick={() => void task.run(async () => {
                  await core.b.tl_ext_pair_cancel();
                  before.current = undefined;
                  state.reload();
                })}>
                {L('common.cancel')}
              </Button>
            </div>
          </div>
        </Card>
      ) : (
        <Card spacing={12}>
          <CardRow
            icon={<Link2 size={15} strokeWidth={2} />}
            color="blue"
            title={L('ext.bind')}
            trailing={
              <Button
                kind="primary"
                disabled={!state.data || task.busy}
                onClick={() => void task.run(async () => {
                  const endpoint = new URL(core.transport.base || location.origin);
                  // (https is said outright: the extension cannot tell it from a port other than 443)
                  const addresses = [endpoint.protocol === 'https:' ? endpoint.origin : `${endpoint.hostname}:${endpoint.port || '80'}`];
                  await core.read(core.b.tl_ext_pair_begin(JSON.stringify(addresses)));
                  before.current = new Set(state.data?.clients.map(({ id }) => id));
                  setCopied(false);
                  state.reload();
                })}>
                {L('ext.bind').replace('…', '')}
              </Button>
            }
          />
        </Card>
      )}

      {!state.data || state.error ? (
        <LoadState error={state.error} reload={state.reload} />
      ) : (
        <SectionGroup title={L('ext.clients')} note={L('ext.footer.web')}>
          <Card spacing={12}>
            {!state.data.clients.length && (
              <span style={{ fontSize: 13, color: 'var(--fg-2)' }}>{L('ext.state.none')}</span>
            )}
            {state.data.clients.map((client, i) => (
              <div key={client.id} style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                {i > 0 && <RowDivider inset={42} />}
                <CardRow
                  icon={<Puzzle size={15} strokeWidth={2} />}
                  color="indigo"
                  title={client.name}
                  detail={L('ext.client.detail', formatShortDate(client.added), formatShortDate(client.seen))}
                  trailing={
                    <Button disabled={task.busy} onClick={() => void removeClient(client)}>
                      {L('ext.remove.confirm')}
                    </Button>
                  }
                />
              </div>
            ))}
          </Card>
        </SectionGroup>
      )}
    </SettingsScreen>
  );
}
