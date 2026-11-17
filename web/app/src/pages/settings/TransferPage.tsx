import { useState } from 'react';
import { L, type ExportProgress, type ExportReport, type ImportProgress, type ImportReport } from '@twimshelf/core';
import { ArchiveRestore, FileClock, HardDriveDownload, Package } from 'lucide-react';
import { Button, Dialog, Row, Section, TextField } from '../../components/ui';
import { change, FileButton, useTask } from '../../components/libraryControls';
import { core } from '../../lib/core';
import { useAsync, useInterval } from '../../lib/hooks';
import { dateStamp, deliver, info, outPath, size, upload } from './serverFiles';
import { FolderChoice, ProgressRow, SettingsScreen, settings, useNotice } from './settingsControls';

const importers = {
  legacy: { accept: '.zip', run: (path: string, folder: string) => core.b.tl_import_legacy_zip(path, folder), icon: ArchiveRestore },
  loose: { accept: '.zip', run: (path: string, folder: string) => core.b.tl_import_loose_zip(path, folder), icon: Package },
  pack: { accept: '.tlpack', run: (path: string, folder: string) => core.b.tl_import_pack(path, folder), icon: Package },
};
type ImportKind = keyof typeof importers;
const newFolder = '\0new';

export default function TransferPage() {
  const [choice, setChoice] = useState<{ file: File; kind: ImportKind }>();
  const [folder, setFolder] = useState('');
  const [name, setName] = useState('');
  const [phase, setPhase] = useState<'upload' | 'import' | 'backup'>();
  const task = useTask();
  const cancel = useTask();
  const notice = useNotice();
  const incoming = useAsync(() => phase === 'import' ? core.read<ImportProgress | null>(core.b.tl_import_status()) : Promise.resolve(null), [phase]);
  const outgoing = useAsync(() => phase === 'backup' ? core.read<ExportProgress | null>(core.b.tl_export_status()) : Promise.resolve(null), [phase]);
  useInterval(phase === 'import' ? incoming.reload : outgoing.reload, phase && phase !== 'upload' ? 800 : null);

  function start(file: File, kind: ImportKind) {
    setFolder('');
    setName(file.name.replace(/\.[^.]+$/, ''));
    setChoice({ file, kind });
  }

  function importFile() {
    if (!choice) return;
    const destination = folder === newFolder ? name.trim() : folder;
    setChoice(undefined);
    void task.run(async () => {
      try {
        setPhase('upload');
        const path = await upload(choice.file);
        setPhase('import');
        const report = await change(core.read<ImportReport>(importers[choice.kind].run(path, destination)));
        notice.show(L('import.done'), L('import.summary.added', report.posts, report.media).trim()
          + (report.issues.length || report.skipped.length ? L('import.summary.canView') : L('import.summary.allOK'))
          + (report.incomplete ? `\n${L(report.incomplete)}` : ''));
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
        notice.show(L(report.skipped.length ? 'settings.backup.doneIncomplete' : 'settings.backup.done'),
          L('settings.backup.result', report.posts, report.media, report.trashed, size(report.bytes), name)
          + (report.skipped.length ? L('settings.backup.skipped', report.skipped.length) : ''));
      } finally {
        setPhase(undefined);
      }
    });
  }

  return <SettingsScreen title={L('common.importAndBackup')}>
    {phase && <Section>
      <ProgressRow title={L(phase === 'backup' ? 'settings.backup.running' : phase === 'upload' ? 'web.uploading' : 'common.importing')}
        subtitle={phase === 'import' ? incoming.data?.current ?? undefined : undefined}
        value={phase === 'backup' && outgoing.data?.running && outgoing.data.total ? outgoing.data.done / outgoing.data.total
          : phase === 'import' && incoming.data?.running && incoming.data.folders_total ? incoming.data.folders_done / incoming.data.folders_total
            : undefined}
        onCancel={phase === 'upload' || cancel.busy ? undefined : () => void cancel.run(async () => {
          if (phase === 'backup') await core.read(core.b.tl_export_cancel());
          else await core.b.tl_import_cancel();
        })} />
    </Section>}
    <Section title={L('common.import')} footer={L('settings.import.footer')}>
      {(Object.keys(importers) as ImportKind[]).map((kind) => {
        const { icon: Icon, accept } = importers[kind];
        const label = L(`settings.import.${kind}`);
        return <Row key={kind} icon={<Icon size={17} />} title={label}
          trailing={<FileButton label={L('web.chooseFile')} accept={accept} disabled={task.busy} onPick={(file) => start(file, kind)} />} />;
      })}
      <Row icon={<FileClock size={17} />} title={L('common.importRecords')} onClick={() => settings('import-records')} />
    </Section>
    <Section title={L('common.backup')} footer={L('settings.backup.footer')}>
      <Row icon={<HardDriveDownload size={17} />} title={L('settings.backup.button')}
        trailing={<Button disabled={task.busy} onClick={backup}>{L('common.backup')}</Button>} />
    </Section>
    {choice && <Dialog title={L('common.importToFolder')} onClose={() => setChoice(undefined)} actions={<>
      <Button onClick={() => setChoice(undefined)}>{L('common.cancel')}</Button>
      <Button kind="primary" disabled={folder === newFolder && !name.trim()} onClick={importFile}>{L('share.import')}</Button>
    </>}>
      <FolderChoice title={choice.file.name} value={folder} onChange={setFolder}
        extra={[{ value: newFolder, label: L('common.newFolder') }]} />
      {folder === newFolder && <TextField value={name} onChange={setName} placeholder={L('common.newFolder')} />}
    </Dialog>}
    {notice.dialog}
  </SettingsScreen>;
}
