import { useCallback, useEffect, useRef, useState } from 'react';
import { L } from '@twimshelf/core';
import { Download, Link2, Puzzle } from 'lucide-react';
import { Button } from '../../components/ui';
import { change, LoadState, useTask } from '../../components/libraryControls';
import { alertMessage, choose } from '../../components/pickers';
import { core, desktop } from '../../lib/core';
import { useAsync, useInterval } from '../../lib/hooks';
import {
  checkExtensionUpdate,
  consumeExtensionAutoCheck,
  installManagedExtension,
  onExtensionAutoCheck,
  type ExtensionManagedStatus,
  type ExtensionUpdateCheck,
} from '../../lib/update';
import { copyText } from './serverFiles';
import {
  Card, CardRow, RowDivider, SectionGroup, SettingsScreen,
} from './settingsControls';

interface Client { id: string; name: string; added: number; seen: number }
interface Pairing { code: string; link: string; expires_in: number }
interface ExtensionState { clients: Client[]; pairing: Pairing | null; port?: number | null }

function formatShortDate(seconds: number): string {
  return new Date(seconds * 1000).toLocaleString(undefined, {
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
  });
}

export default function ExtensionPage() {
  const state = useAsync(() => core.read<ExtensionState>(core.b.tl_ext_clients()), []);
  const managed = useAsync(
    () => (desktop ? core.read<ExtensionManagedStatus>(core.b.tl_ext_managed_status()) : Promise.resolve(null)),
    [],
  );
  const task = useTask();
  const [copied, setCopied] = useState(false);
  const [pathCopied, setPathCopied] = useState(false);
  const [updateCheck, setUpdateCheck] = useState<ExtensionUpdateCheck | null>(null);
  const [extBusy, setExtBusy] = useState<string | null>(null);
  const before = useRef<Set<string> | undefined>(undefined);
  const pairing = state.data?.pairing;

  useInterval(state.reload, state.loading ? null : pairing ? 1200 : 3000);

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

  const runCheckUpdate = useCallback(async () => {
    if (!desktop || extBusy) return;
    setExtBusy(L('ext.managed.checking'));
    try {
      const info = await checkExtensionUpdate(true);
      if (info) setUpdateCheck(info);
      managed.reload();
    } finally {
      setExtBusy(null);
    }
  }, [extBusy, managed]);

  const runInstall = useCallback(async (updating: boolean) => {
    if (!desktop || extBusy) return;
    setExtBusy(updating ? L('ext.managed.updating') : L('ext.managed.downloading'));
    try {
      const st = await installManagedExtension(updating);
      if (st) {
        setUpdateCheck(null);
        setPathCopied(false);
        managed.reload();
      }
    } finally {
      setExtBusy(null);
    }
  }, [extBusy, managed]);

  useEffect(() => {
    if (!desktop) return;
    const trigger = () => {
      if (!consumeExtensionAutoCheck()) return;
      if (managed.data?.installed) void runCheckUpdate();
    };
    if (managed.data?.installed) trigger();
    return onExtensionAutoCheck(trigger);
  }, [managed.data?.installed, runCheckUpdate]);

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
  const managedInstalled = desktop && managed.data?.installed === true;
  const clientsFooter = desktop && state.data?.port
    ? L('ext.footer.desktop', String(state.data.port))
    : L('ext.footer.web');

  return (
    <SettingsScreen title={L('ext.title')}>
      {desktop && (
        <SectionGroup title={L('ext.managed.title')}>
          <Card spacing={12}>
            {managedInstalled && managed.data ? (
              <>
                <CardRow
                  icon={<Download size={15} strokeWidth={2} />}
                  color="blue"
                  title={L('ext.managed.version', managed.data.version ?? '')}
                  detail={updateCheck?.has_update ? L('ext.managed.updateReady', updateCheck.latest) : undefined}
                  trailing={
                    extBusy ? (
                      <span style={{ fontSize: 12, color: 'var(--fg-2)' }}>{extBusy}</span>
                    ) : updateCheck?.has_update ? (
                      <Button kind="primary" onClick={() => void runInstall(true)}>
                        {L('ext.managed.update', updateCheck.latest)}
                      </Button>
                    ) : (
                      <Button onClick={() => void runCheckUpdate()}>
                        {L('ext.managed.checkUpdate')}
                      </Button>
                    )
                  }
                />
                <div className="ext-link-box selectable">{managed.data.dir}</div>
                <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                  <Button onClick={() => void window.twimshelf?.openPath?.(managed.data!.dir)}>
                    {L('ext.managed.openFolder')}
                  </Button>
                  <Button
                    onClick={() => void copyText(managed.data!.dir).then(() => setPathCopied(true))}>
                    {pathCopied ? L('ext.managed.pathCopied') : L('ext.managed.copyPath')}
                  </Button>
                </div>
                <div style={{ fontSize: 12, color: 'var(--fg-2)', lineHeight: 1.55, whiteSpace: 'pre-line' }}>
                  {L('ext.managed.installGuide')}
                </div>
              </>
            ) : (
              <CardRow
                icon={<Download size={15} strokeWidth={2} />}
                color="blue"
                title={L('ext.managed.download')}
                detail={L('ext.managed.notInstalled')}
                trailing={
                  <Button kind="primary" disabled={!!extBusy} onClick={() => void runInstall(false)}>
                    {extBusy || L('ext.managed.download')}
                  </Button>
                }
              />
            )}
          </Card>
        </SectionGroup>
      )}

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
        <SectionGroup title={L('ext.clients')} note={clientsFooter}>
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
                    <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                      {managedInstalled && (
                        updateCheck?.has_update ? (
                          <Button kind="primary" disabled={!!extBusy || task.busy} onClick={() => void runInstall(true)}>
                            {L('ext.managed.update', updateCheck.latest)}
                          </Button>
                        ) : (
                          <Button disabled={!!extBusy || task.busy} onClick={() => void runCheckUpdate()}>
                            {L('ext.managed.checkUpdate')}
                          </Button>
                        )
                      )}
                      <Button disabled={task.busy} onClick={() => void removeClient(client)}>
                        {L('ext.remove.confirm')}
                      </Button>
                    </div>
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
