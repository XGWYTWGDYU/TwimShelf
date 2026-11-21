// Export Search Results dialog (matching native SearchExportView in Apple/Shared/SearchQuery.swift).
import { useState } from 'react';
import { L, type ExportReport } from '@twimshelf/core';
import { Button, Dialog, Toggle } from '../../components/ui';
import { alertMessage } from '../../components/pickers';
import { toast } from '../../components/toast';
import { core } from '../../lib/core';
import { exportFile, size } from '../settings/serverFiles';

export function SearchExportDialog({
  mediaIds,
  queryLabel,
  onClose,
}: {
  mediaIds: string[];
  queryLabel: string;
  onClose: () => void;
}) {
  const [mediaOnly, setMediaOnly] = useState(false);
  const [includeTags, setIncludeTags] = useState(true);
  const [includeFolders, setIncludeFolders] = useState(true);
  const [busy, setBusy] = useState(false);

  const count = mediaIds.length;

  const run = async () => {
    if (!count || busy) return;
    setBusy(true);
    try {
      const clean = queryLabel.trim().replace(/[\\/:*?"<>|]/g, '_').slice(0, 40);
      const base = (clean
        ? L('export.search.fileName', clean)
        : L('export.search.fileNameAll')).replace('{app}', 'TwimShelf');
      const ext = mediaOnly ? '.zip' : '.tlpack';
      const { report, status } = await exportFile<ExportReport>(
        `${base}${ext}`,
        (out) => core.readJson<ExportReport>('tl_export_media', {
          media_ids: mediaIds,
          options: {
            tags: !mediaOnly && includeTags,
            folders: !mediaOnly && includeFolders,
            media_only: mediaOnly,
          },
          out,
        }),
      );
      if (status === 'cancelled') return;
      const summary = mediaOnly
        ? L('export.summaryMedia', report.media, size(report.bytes))
        : L('export.summary', report.posts, report.media, size(report.bytes));
      if (report.skipped.length > 0) {
        const lines = report.skipped.slice(0, 10)
          .map((s) => L('export.skip.line', s.post_id, s.media_id.slice(0, 8), L(s.reason)))
          .join('');
        const more = report.skipped.length > 10 ? L('export.skip.more', report.skipped.length - 10) : '';
        await alertMessage(
          L('export.doneIncomplete'),
          `${summary}\n\n${L('export.skipped', report.skipped.length)}${lines}${more}`,
        );
      } else {
        toast(`${L('export.done')} · ${summary}`);
      }
      onClose();
    } catch (e) {
      const msg = e instanceof Error ? L(e.message) : L('common.notDone');
      await alertMessage(L('export.failed'), msg);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Dialog
      modal
      title={L('export.search.title')}
      onClose={busy ? () => {} : onClose}
      actions={
        <>
          <Button disabled={busy} onClick={onClose}>{L('common.cancel')}</Button>
          <Button kind="primary" disabled={busy || count === 0} onClick={() => void run()}>
            {busy ? L('export.runningShort') : L('export.go')}
          </Button>
        </>
      }
    >
      <p className="dialog-message">
        {count === 0
          ? L('export.search.none')
          : mediaOnly
            ? L('export.search.countMedia', count)
            : L('export.search.countWithPosts', count)}
      </p>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 12, marginTop: 10 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
          <div>
            <div style={{ fontSize: 13.5, fontWeight: 500 }}>{L('export.option.mediaOnly')}</div>
            <div style={{ fontSize: 12, color: 'var(--fg-2)' }}>{L('export.option.mediaOnly.detail')}</div>
          </div>
          <Toggle label={L('export.option.mediaOnly')} checked={mediaOnly} disabled={busy} onChange={setMediaOnly} />
        </div>

        {!mediaOnly && (
          <>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
              <div>
                <div style={{ fontSize: 13.5, fontWeight: 500 }}>{L('export.option.tags')}</div>
                <div style={{ fontSize: 12, color: 'var(--fg-2)' }}>{L('export.option.tags.detail')}</div>
              </div>
              <Toggle label={L('export.option.tags')} checked={includeTags} disabled={busy} onChange={setIncludeTags} />
            </div>

            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
              <div>
                <div style={{ fontSize: 13.5, fontWeight: 500 }}>{L('export.option.folders')}</div>
                <div style={{ fontSize: 12, color: 'var(--fg-2)' }}>{L('export.option.folders.detail')}</div>
              </div>
              <Toggle label={L('export.option.folders')} checked={includeFolders} disabled={busy} onChange={setIncludeFolders} />
            </div>
          </>
        )}
      </div>
    </Dialog>
  );
}
