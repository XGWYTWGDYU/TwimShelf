import { useMemo, useState } from 'react';
import { L, type DeletedReports, type ImportIssue, type ImportReport } from '@twimshelf/core';
import { Check, TriangleAlert } from 'lucide-react';
import { Button, Dialog } from '../../components/ui';
import { change, LoadState, useTask } from '../../components/libraryControls';
import { alertMessage, choose } from '../../components/pickers';
import { core } from '../../lib/core';
import { useAsync, useStore } from '../../lib/hooks';
import { libraryVersion } from '../../lib/library';
import { exportFile, fileName, info, size } from './serverFiles';
import {
  Card, CardRow, Pill, PopupSelect, RowDivider,
  SectionGroup, SettingsScreen,
} from './settingsControls';

export type RecordRow = [file: string, date: number, source: string, issues: number];

const CATEGORY_ORDER = [
  'not_media', 'unsupported', 'unreadable', 'ignored_location', 'unsafe_path',
  'duplicate', 'in_bin', 'post_not_imported', 'post_hidden', 'post_merged', 'post_text_truncated',
] as const;
const KNOWN_CATEGORIES = new Set<string>(CATEGORY_ORDER);

export function categoryTitle(cat: string): string {
  return KNOWN_CATEGORIES.has(cat) ? L(`import.cat.${cat}`) : L('sidebar.other');
}

export function formatImportSummary(r: ImportReport): string {
  let t = L('import.summary.read', r.entries, r.sidecars, r.system_files);
  t += L('import.summary.added', Math.max(0, r.posts - r.merged_posts - r.posts_without_media), r.new_media);
  const byCat = new Map<string, number>();
  for (const issue of r.issues ?? []) {
    const key = KNOWN_CATEGORIES.has(issue.category) ? issue.category : '';
    byCat.set(key, (byCat.get(key) ?? 0) + 1);
  }
  const orderedKeys = [...byCat.keys()].sort((a, b) => {
    const ia = CATEGORY_ORDER.indexOf(a as typeof CATEGORY_ORDER[number]);
    const ib = CATEGORY_ORDER.indexOf(b as typeof CATEGORY_ORDER[number]);
    return (ia < 0 ? 999 : ia) - (ib < 0 ? 999 : ib);
  });
  for (const key of orderedKeys) {
    t += L('import.summary.issue', categoryTitle(key), byCat.get(key)!);
  }
  if (r.folder) t += L('import.summary.folder', r.folder, r.folder_added);
  if (r.to_bin > 0) t += L('import.summary.toBin', r.to_bin);
  if (r.renames_restored + r.folders_restored > 0) {
    t += L('import.summary.restored', r.renames_restored, r.folders_restored);
  }
  t += (r.issues?.length ?? 0) === 0 ? L('import.summary.allOK') : L('import.summary.canView');
  if (r.incomplete) t += `\n${L(r.incomplete)}`;
  return t;
}

export async function deleteImportRecordsFlow(files: string[], what: string): Promise<boolean> {
  if (!files.length) return false;
  const ok = await choose(
    L('mac.importHistory.deleteTitle', what),
    L('mac.importHistory.deleteMessage'),
    [L('common.delete')],
    { destructive: true },
  );
  if (ok == null) return false;
  const server = await info();
  const result = await change(
    core.readJson<DeletedReports>('tl_delete_import_reports', { reports: files, owned: [server.uploads] }),
  );
  await alertMessage(
    L('mac.importHistory.deleted', result.reports),
    result.sources > 0 ? L('mac.importHistory.freed', result.sources, size(result.bytes)) : '',
  );
  return true;
}

type SortKey = 'cat' | 'path' | 'reason' | 'same';

export function ImportReportModal({ file, report, onClose, onDeleted }: {
  file: string; report: ImportReport; onClose: () => void; onDeleted: () => void;
}) {
  const task = useTask();
  const [catFilter, setCatFilter] = useState('');
  const [sort, setSort] = useState<{ key: SortKey; asc: boolean }>({ key: 'cat', asc: true });

  const grouped = useMemo(() => {
    const map = new Map<string, ImportIssue[]>();
    for (const issue of report.issues ?? []) {
      const k = KNOWN_CATEGORIES.has(issue.category) ? issue.category : 'other';
      if (!map.has(k)) map.set(k, []);
      map.get(k)!.push(issue);
    }
    return [...map.entries()];
  }, [report.issues]);

  const rows = useMemo(() => {
    const base = !catFilter
      ? (report.issues ?? [])
      : grouped.find(([k]) => k === catFilter)?.[1] ?? [];
    const val = (i: ImportIssue): string => {
      switch (sort.key) {
        case 'cat': return categoryTitle(i.category);
        case 'path': return i.path;
        case 'reason': return L(i.reason);
        case 'same': return i.same_as ?? '';
      }
    };
    return [...base].sort((a, b) => {
      const cmp = val(a).localeCompare(val(b));
      return sort.asc ? cmp : -cmp;
    });
  }, [report.issues, grouped, catFilter, sort]);

  const filterOptions = [
    { value: '', label: L('import.allIssues', report.issues?.length ?? 0) },
    ...grouped.map(([k, list]) => ({
      value: k,
      label: L('format.nameDetail', categoryTitle(k), list.length),
    })),
  ];

  const toggleSort = (key: SortKey) => {
    setSort((prev) => (prev.key === key ? { key, asc: !prev.asc } : { key, asc: true }));
  };

  return (
    <Dialog
      wide
      title={L('import.details')}
      onClose={onClose}
      actions={
        <>
          <Button
            kind="danger"
            disabled={task.busy}
            onClick={() => void task.run(async () => {
              if (await deleteImportRecordsFlow([file], L('mac.importHistory.this'))) {
                onDeleted();
                onClose();
              }
            })}>
            {L('common.delete')}
          </Button>
          <Button kind="primary" onClick={onClose}>{L('common.close')}</Button>
        </>
      }>
      <div className="selectable" style={{ fontSize: 12, color: 'var(--fg)', whiteSpace: 'pre-wrap', lineHeight: 1.45 }}>
        {(report.source ? L('import.sourceLine', fileName(report.source)) : '') + formatImportSummary(report)}
      </div>

      <div className="report-toolbar">
        <PopupSelect
          label={L('import.col.category')}
          value={catFilter}
          options={filterOptions}
          onChange={setCatFilter}
        />
        {!!report.issues?.length && (
          <Button
            disabled={task.busy}
            onClick={() => void task.run(async () => {
              const name = L('import.problemsZip');
              const { report: count, status } = await exportFile(name, (path) => core.read<number>(core.b.tl_import_export_issues(file, path)));
              if (status === 'saved') await alertMessage(L('mac.models.exported'), L('import.exported.message', count));
            })}>
            {L('import.export')}
          </Button>
        )}
      </div>

      <div className="report-table-wrap">
        <table className="report-table">
          <thead>
            <tr>
              <th style={{ width: 140 }} onClick={() => toggleSort('cat')}>{L('import.col.category')}</th>
              <th style={{ width: 280 }} onClick={() => toggleSort('path')}>{L('import.col.path')}</th>
              <th style={{ width: 220 }} onClick={() => toggleSort('reason')}>{L('import.col.reason')}</th>
              <th style={{ width: 150 }} onClick={() => toggleSort('same')}>{L('import.col.match')}</th>
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 ? (
              <tr>
                <td colSpan={4} style={{ textAlign: 'center', color: 'var(--fg-2)', padding: 24 }}>
                  {L('mac.importHistory.ok')}
                </td>
              </tr>
            ) : (
              rows.slice(0, 500).map((issue, idx) => (
                <tr key={idx}>
                  <td className="selectable">{categoryTitle(issue.category)}</td>
                  <td className="selectable">{issue.path}</td>
                  <td className="selectable">{L(issue.reason)}</td>
                  <td className="selectable">{issue.same_as ?? ''}</td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
      {rows.length > 500 && (
        <p style={{ fontSize: 11, color: 'var(--fg-2)', margin: '8px 0 0' }}>{L('import.first500')}</p>
      )}
    </Dialog>
  );
}

export default function ImportRecordsPage() {
  const version = useStore(libraryVersion);
  const records = useAsync(() => core.read<RecordRow[]>(core.b.tl_import_reports()), [version]);
  const [detail, setDetail] = useState<{ file: string; report: ImportReport }>();
  const task = useTask();

  return (
    <SettingsScreen title={L('common.importRecords')} parent="import-backup">
      {!records.data || records.error ? (
        <LoadState error={records.error} reload={records.reload} />
      ) : (
        <SectionGroup
          title={L('common.importRecords')}
          note={L('mac.importHistory.footer')}
          trailing={
            records.data.length > 0 ? (
              <Button
                kind="danger"
                disabled={task.busy}
                onClick={() => void task.run(async () => {
                  const files = records.data!.map(([f]) => f);
                  if (await deleteImportRecordsFlow(files, L('mac.importHistory.all', files.length))) {
                    records.reload();
                  }
                })}>
                {L('mac.deleteAll')}
              </Button>
            ) : undefined
          }>
          <Card spacing={12}>
            {!records.data.length && (
              <div style={{ fontSize: 13, color: 'var(--fg-2)' }}>{L('import.history.none')}</div>
            )}
            {records.data.map(([file, date, source, issues], i) => (
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
          </Card>
        </SectionGroup>
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
