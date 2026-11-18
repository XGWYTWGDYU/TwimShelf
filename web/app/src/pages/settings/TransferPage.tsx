import { useRef, useState } from 'react';
import { L, type ExportProgress, type ExportReport, type ImportProgress, type ImportReport } from '@twimshelf/core';
import {
  Archive, Check, Download, FileClock, HardDriveDownload,
  Package, SquareDashed, TriangleAlert,
} from 'lucide-react';
import { Button, Dialog, TextField } from '../../components/ui';
import { change, useTask } from '../../components/libraryControls';
import { alertMessage, choose } from '../../components/pickers';
import { core } from '../../lib/core';
import { useAsync, useInterval, useStore } from '../../lib/hooks';
import { folders, libraryVersion } from '../../lib/library';
import {
  deleteImportRecordsFlow, formatImportSummary, ImportReportModal, type RecordRow,
} from './ImportRecordsPage';
import { dateStamp, deliver, fileName, info, outPath, size, upload } from './serverFiles';
import {
  ActivityRow, Card, CardRow, IconTile, NavRow, NavTile, Pill,
  PopupSelect, RowDivider, SectionGroup, settings, SettingsScreen,
} from './settingsControls';

const importers = {
  legacy: {
    accept: '.zip',
    titleKey: 'mac.import.legacy',
    detailKey: 'mac.import.legacy.detail',
    color: 'brown' as const,
    icon: Archive,
    run: (path: string, folder: string) => core.b.tl_import_legacy_zip(path, folder),
  },
  loose: {
    accept: '.zip',
    titleKey: 'mac.import.loose',
    detailKey: 'mac.import.loose.detail',
    color: 'indigo' as const,
    icon: SquareDashed,
    run: (path: string, folder: string) => core.b.tl_import_loose_zip(path, folder),
  },
  pack: {
    accept: '.tlpack,.zip',
    titleKey: 'mac.import.pack',
    detailKey: 'mac.import.pack.detail',
    color: 'blue' as const,
    icon: Package,
    run: (path: string, folder: string) => core.b.tl_import_pack(path, folder),
  },
};
type ImportKind = keyof typeof importers;
const newFolder = '\0new';

export default function TransferPage() {
  const version = useStore(libraryVersion);
  const overview = useStore(folders);
  const [choice, setChoice] = useState<{ file: File; kind: ImportKind }>();
  const [folder, setFolder] = useState(newFolder);
  const [name, setName] = useState('');
  const [phase, setPhase] = useState<'upload' | 'import' | 'backup'>();
  const [detail, setDetail] = useState<{ file: string; report: ImportReport }>();
  const pendingKind = useRef<ImportKind>('legacy');
  const fileInput = useRef<HTMLInputElement>(null);
  const task = useTask();
  const cancel = useTask();

  const records = useAsync(() => core.read<RecordRow[]>(core.b.tl_import_reports()), [version]);
  const incoming = useAsync(
    () => (phase === 'import' ? core.read<ImportProgress | null>(core.b.tl_import_status()) : Promise.resolve(null)),
    [phase],
  );
  const outgoing = useAsync(
    () => (phase === 'backup' ? core.read<ExportProgress | null>(core.b.tl_export_status()) : Promise.resolve(null)),
    [phase],
  );
  useInterval(
    phase === 'import' ? incoming.reload : outgoing.reload,
    phase && phase !== 'upload' ? 700 : null,
  );

  function pickFile(kind: ImportKind) {
    if (task.busy) return;
    pendingKind.current = kind;
    if (fileInput.current) {
      fileInput.current.accept = importers[kind].accept;
      fileInput.current.click();
    }
  }

  function start(file: File, kind: ImportKind) {
    const suggested = file.name.replace(/\.[^.]+$/, '');
    setName(suggested);
    setFolder(suggested ? newFolder : '');
    setChoice({ file, kind });
  }

  function importFile() {
    if (!choice) return;
    const destination = folder === newFolder ? name.trim() : folder;
    setChoice(undefined);
    void task.run(async () => {
      try {
        if (destination) {
          await core.read(core.b.tl_create_folder(destination)).catch(() => {});
        }
        setPhase('upload');
        const path = await upload(choice.file);
        setPhase('import');
        const report = await change(core.read<ImportReport>(importers[choice.kind].run(path, destination)));
        records.reload();
        const summary = formatImportSummary(report);
        if ((report.issues?.length ?? 0) > 0 && report.report_file) {
          const picked = await choose(
            L('import.done'),
            summary,
            [L('import.viewDetails'), L('common.ok')],
            { cancel: false },
          );
          if (picked === 0) {
            const full = await core.read<ImportReport>(core.b.tl_import_report(report.report_file));
            setDetail({ file: report.report_file, report: full });
          }
        } else {
          await alertMessage(L('import.done'), summary);
        }
      } finally {
        setPhase(undefined);
      }
    });
  }

  function backup() {
    void task.run(async () => {
      setPhase('backup');
      try {
        const name = `${L('settings.backup.fileName', dateStamp()).replaceAll('{app}', L('web.appName'))}.tlpack`;
        const path = outPath(await info(), name);
        const report = await core.read<ExportReport>(core.b.tl_export_backup(path));
        await deliver(path, name);
        let msg = L('mac.backup.result', report.posts, report.media, report.trashed, size(report.bytes));
        if (report.skipped.length) {
          msg += L('settings.backup.skipped', report.skipped.length);
          for (const s of report.skipped.slice(0, 15)) {
            msg += L(
              'export.skip.line',
              s.post_id.startsWith('loose:') ? L('card.loose') : L('common.post', s.post_id),
              s.media_id.slice(0, 10),
              L(s.reason),
            );
          }
          if (report.skipped.length > 15) msg += L('export.skip.more', report.skipped.length - 15);
        }
        await alertMessage(
          L(report.skipped.length ? 'settings.backup.doneIncomplete' : 'settings.backup.done'),
          msg,
        );
      } finally {
        setPhase(undefined);
      }
    });
  }

  const impProg = incoming.data;
  const expProg = outgoing.data;
  const recentRecords = (records.data ?? []).slice(0, 8);

  const folderOptions = [
    { value: '', label: L('mac.noFolder') },
    ...(name.trim() ? [{ value: newFolder, label: L('folderPicker.new', name.trim()) }] : []),
    ...(overview?.folders ?? [])
      .filter((f) => f.name !== name.trim())
      .map((f) => ({ value: f.name, label: L('format.quotedCount', f.name, f.count) })),
  ];

  return (
    <SettingsScreen title={L('common.importAndBackup')}>
      <input
        ref={fileInput}
        type="file"
        hidden
        onChange={(e) => {
          const file = e.target.files?.[0];
          e.target.value = '';
          if (file) start(file, pendingKind.current);
        }}
      />

      {phase && (
        <Card tint="accent" spacing={14}>
          <ActivityRow
            kind="importing"
            title={L(
              phase === 'backup'
                ? 'settings.backup.running'
                : phase === 'upload'
                  ? 'web.uploading'
                  : impProg?.waiting
                    ? 'activity.importWaiting'
                    : 'activity.importing',
            )}
            detail={
              phase === 'backup' && expProg?.total
                ? L('settings.backup.progress', expProg.done, expProg.total, size(expProg.bytes))
                : phase === 'import' && impProg?.folders_total
                  ? L('activity.importProgress', impProg.folders_done, impProg.folders_total, impProg.files_done)
                    + (impProg.issues > 0 ? L('activity.importIssues', impProg.issues) : '')
                  : undefined
            }
            progress={
              phase === 'backup' && expProg?.running && expProg.total
                ? expProg.done / expProg.total
                : phase === 'import' && impProg?.running && impProg.folders_total
                  ? impProg.folders_done / impProg.folders_total
                  : undefined
            }
            previewPath={phase === 'import' ? impProg?.current : undefined}
          />
          {phase !== 'upload' && (
            <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
              <Button
                disabled={cancel.busy}
                onClick={() => void cancel.run(async () => {
                  if (phase === 'backup') await core.read(core.b.tl_export_cancel());
                  else await core.b.tl_import_cancel();
                })}>
                {L('common.cancel')}
              </Button>
            </div>
          )}
        </Card>
      )}

      <SectionGroup title={L('common.import')} note={L('mac.import.footer')}>
        <div className="nav-tiles-grid">
          {(Object.keys(importers) as ImportKind[]).map((kind) => {
            const { titleKey, detailKey, color, icon: Icon } = importers[kind];
            return (
              <NavTile
                key={kind}
                id={`import-${kind}`}
                title={L(titleKey)}
                detail={L(detailKey)}
                icon={<Icon size={19} strokeWidth={2} />}
                color={color}
                onClick={() => pickFile(kind)}
              />
            );
          })}
        </div>
      </SectionGroup>

      <SectionGroup title={L('common.backup')}>
        <Card tint="purple" spacing={14}>
          <div style={{ display: 'flex', alignItems: 'flex-start', gap: 14 }}>
            <IconTile icon={<HardDriveDownload size={20} strokeWidth={2} />} color="purple" size={44} />
            <div className="card-row-texts" style={{ gap: 6 }}>
              <div style={{ fontSize: 15, fontWeight: 600, color: 'var(--fg)' }}>{L('mac.backup.title')}</div>
              <div className="card-row-detail" style={{ fontSize: 12.5 }}>{L('mac.backup.detail')}</div>
            </div>
            <Button kind="primary" disabled={task.busy} onClick={backup}>
              <Download size={14} strokeWidth={2.2} />
              <span>{L('mac.backup.button')}</span>
            </Button>
          </div>
          <div className="card-row-detail">{L('mac.backup.footer')}</div>
        </Card>
      </SectionGroup>

      <SectionGroup
        title={L('common.importRecords')}
        note={L('mac.importHistory.footer')}
        trailing={
          (records.data?.length ?? 0) > 0 ? (
            <Button
              kind="danger"
              disabled={task.busy}
              onClick={() => void task.run(async () => {
                const allFiles = records.data!.map(([f]) => f);
                if (await deleteImportRecordsFlow(allFiles, L('mac.importHistory.all', allFiles.length))) {
                  records.reload();
                }
              })}>
              {L('mac.deleteAll')}
            </Button>
          ) : undefined
        }>
        <Card spacing={12}>
          {!recentRecords.length && (
            <div style={{ fontSize: 13, color: 'var(--fg-2)' }}>{L('import.history.none')}</div>
          )}
          {recentRecords.map(([file, date, source, issues], i) => (
            <div key={file} style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
              {i > 0 && <RowDivider inset={42} />}
              <CardRow
                icon={issues === 0 ? <Check size={15} strokeWidth={2.5} /> : <TriangleAlert size={15} strokeWidth={2.2} />}
                color={issues === 0 ? 'green' : 'orange'}
                title={fileName(source)}
                detail={new Date(date).toLocaleString()}
                trailing={
                  <>
                    <Pill
                      text={issues === 0 ? L('mac.importHistory.ok') : L('mac.importHistory.issues', issues)}
                      color={issues === 0 ? 'green' : 'orange'}
                    />
                    <Button
                      disabled={task.busy}
                      onClick={() => void task.run(async () => {
                        const report = await core.read<ImportReport>(core.b.tl_import_report(file));
                        setDetail({ file, report });
                      })}>
                      {L('mac.viewEllipsis')}
                    </Button>
                    <Button
                      disabled={task.busy}
                      onClick={() => void task.run(async () => {
                        if (await deleteImportRecordsFlow([file], L('mac.importHistory.this'))) {
                          records.reload();
                        }
                      })}>
                      {L('common.delete')}
                    </Button>
                  </>
                }
              />
            </div>
          ))}
          {(records.data?.length ?? 0) > 8 && (
            <>
              <RowDivider inset={42} />
              <NavRow
                icon={<FileClock size={15} strokeWidth={2} />}
                color="gray"
                title={L('common.importRecords')}
                detail={L('common.items', records.data!.length)}
                onClick={() => settings('import-records')}
              />
            </>
          )}
        </Card>
      </SectionGroup>

      {choice && (
        <Dialog
          title={L('common.importToFolder')}
          onClose={() => setChoice(undefined)}
          actions={
            <>
              <Button onClick={() => setChoice(undefined)}>{L('common.cancel')}</Button>
              <Button kind="primary" disabled={folder === newFolder && !name.trim()} onClick={importFile}>
                {L('common.import')}
              </Button>
            </>
          }>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            <div style={{ fontSize: 12, color: 'var(--fg-2)' }}>{L('folderPicker.message.mac')}</div>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10 }}>
              <span style={{ fontSize: 13, fontWeight: 500, color: 'var(--fg)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {choice.file.name}
              </span>
              <PopupSelect
                label={L('common.importToFolder')}
                value={folder}
                options={folderOptions}
                onChange={setFolder}
              />
            </div>
            {folder === newFolder && (
              <TextField
                value={name}
                onChange={setName}
                placeholder={L('common.folderName')}
                autoFocus
                onEnter={() => name.trim() && importFile()}
              />
            )}
          </div>
        </Dialog>
      )}

      {detail && (
        <ImportReportModal
          file={detail.file}
          report={detail.report}
          onClose={() => setDetail(undefined)}
          onDeleted={() => records.reload()}
        />
      )}
    </SettingsScreen>
  );
}
