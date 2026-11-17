import { useState } from 'react';
import { L, type DeletedReports, type ImportIssue, type ImportReport } from '@twimshelf/core';
import { FileCheck2, FileWarning } from 'lucide-react';
import { Button, Dialog, Row, Section } from '../../components/ui';
import { change, Confirm, LoadState, useTask } from '../../components/libraryControls';
import { toast } from '../../components/toast';
import { core } from '../../lib/core';
import { useAsync, useStore } from '../../lib/hooks';
import { libraryVersion } from '../../lib/library';
import { deliver, fileName, info, outPath, size } from './serverFiles';
import { SettingsScreen } from './settingsControls';

type RecordRow = [file: string, date: number, source: string, issues: number];
const categories = new Set(['not_media', 'unsupported', 'unreadable', 'duplicate', 'in_bin', 'ignored_location', 'unsafe_path',
  'post_not_imported', 'post_hidden', 'post_merged', 'post_text_truncated']);

export default function ImportRecordsPage() {
  const version = useStore(libraryVersion);
  const records = useAsync(() => core.read<RecordRow[]>(core.b.tl_import_reports()), [version]);
  const [detail, setDetail] = useState<{ file: string; report: ImportReport }>();
  const [deleting, setDeleting] = useState<string[]>();
  const task = useTask();
  const groups = new Map<string, ImportIssue[]>();
  for (const issue of detail?.report.issues ?? []) {
    const group = categories.has(issue.category) ? issue.category : '';
    if (!groups.has(group)) groups.set(group, []);
    groups.get(group)?.push(issue);
  }

  return <SettingsScreen title={L('common.importRecords')} parent="import-backup">
    {!records.data || records.error ? <LoadState error={records.error} reload={records.reload} /> : <>
      <Section footer={L('import.history.footer')}>
        {!records.data.length && <Row title={L('import.history.none')} />}
        {records.data.map(([file, date, source, issues]) => <Row key={file}
          icon={issues ? <FileWarning size={17} /> : <FileCheck2 size={17} />}
          title={L('format.nameDetail', fileName(source), new Date(date).toLocaleString())}
          subtitle={issues ? L('import.issuesCount', issues) : L('mac.importHistory.ok')}
          onClick={() => void task.run(async () => {
            const report = await core.read<ImportReport>(core.b.tl_import_report(file));
            setDetail({ file, report });
          })} />)}
      </Section>
      {!!records.data.length && <Section><Row danger title={L('import.deleteAll')}
        onClick={() => setDeleting(records.data?.map(([file]) => file))} /></Section>}
    </>}
    {detail && !deleting && <Dialog wide title={L('import.details')} onClose={() => setDetail(undefined)} actions={<>
      <Button disabled={task.busy} onClick={() => setDeleting([detail.file])}>{L('import.delete')}</Button>
      {!!detail.report.issues.length && <Button disabled={task.busy} onClick={() => void task.run(async () => {
        const name = L('import.problemsZip');
        const path = outPath(await info(), name);
        await core.read(core.b.tl_import_export_issues(detail.file, path));
        await deliver(path, name);
      })}>{L('import.export')}</Button>}
      <Button kind="primary" onClick={() => setDetail(undefined)}>{L('common.close')}</Button>
    </>}>
      {detail.report.source && <p className="control-wrap">{L('import.source')}{fileName(detail.report.source)}</p>}
      {!groups.size && <Row title={L('mac.importHistory.ok')} />}
      {[...groups].map(([group, issues]) => <Section key={group} title={L('format.nameDetail', L(group ? `import.cat.${group}` : 'sidebar.other'), issues.length)}
        footer={issues.length > 500 ? L('import.first500') : undefined}>
        {issues.slice(0, 500).map((issue, index) => <Row key={index} title={<span className="control-wrap">{issue.path}</span>}
          subtitle={<span className="control-wrap">{L(issue.reason)}{issue.same_as ? L('import.matches') + issue.same_as : ''}</span>} />)}
      </Section>)}
    </Dialog>}
    {deleting && <Confirm title={L('mac.importHistory.deleteTitle')} action={L('common.delete')} danger onClose={() => setDeleting(undefined)}
      onConfirm={async () => {
        const server = await info();
        const result = await change(core.readJson<DeletedReports>('tl_delete_import_reports', { reports: deleting, owned: [server.uploads] }));
        setDetail(undefined);
        toast(L('mac.importHistory.deleted', result.reports) + ' ' + (result.sources
          ? L('import.deleted.sources', result.sources, size(result.bytes)) : L('import.deleted.freed', size(result.bytes))));
      }}>{L('import.deleteAll.message')}</Confirm>}
  </SettingsScreen>;
}
