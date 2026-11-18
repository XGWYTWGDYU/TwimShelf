import { useEffect, useState } from 'react';
import { L, type IntegritySummary, type StorageGroup, type StorageUsage } from '@twimshelf/core';
import { AlertTriangle, Check, CheckCircle2, ChevronDown, FileArchive, RefreshCw, ShieldCheck, Trash2 } from 'lucide-react';
import { Button, Empty, Row, Section, TextField, Toggle } from '../../components/ui';
import { change, LoadState, useTask } from '../../components/libraryControls';
import { alertMessage, choose } from '../../components/pickers';
import { toast } from '../../components/toast';
import { core } from '../../lib/core';
import { useAsync, useInterval, useStore } from '../../lib/hooks';
import { libraryChanged, libraryVersion } from '../../lib/library';
import { dateStamp, deliver, info, outPath, readText, removeFile, size } from './serverFiles';
import { setAuto, selectTagger, stopTagging } from './aiTagging';
import {
  Card, CardRow, Pill, RowDivider, SectionHeading, SettingsScreen, SlimBar, settings,
  type TileColor,
} from './settingsControls';

const STORAGE_ORDER = [
  'app',
  'photos',
  'videos',
  'bin',
  'database',
  'libraryOther',
  'models',
  'thumbnails',
  'cache',
] as const;

const CLEARABLE_KEYS = new Set(['thumbnails', 'cache', 'bin']);

// one colour per group, the native app's (StorageRing.colors: indigo, orange, red, brown, blue,
// teal, purple, green, gray — the system colours, with their dark-mode values in settings.css)
const GROUP_COLORS: Record<string, string> = {
  app: 'var(--storage-indigo)',
  photos: 'var(--storage-orange)',
  videos: 'var(--storage-red)',
  bin: 'var(--storage-brown)',
  database: 'var(--storage-blue)',
  libraryOther: 'var(--storage-teal)',
  models: 'var(--storage-purple)',
  thumbnails: 'var(--storage-green)',
  cache: 'var(--storage-gray)',
};

function groupColor(key: string): string {
  return GROUP_COLORS[key] ?? 'var(--storage-gray)';
}

function polarToCartesian(cx: number, cy: number, r: number, angleRad: number) {
  return {
    x: cx + r * Math.cos(angleRad),
    y: cy + r * Math.sin(angleRad),
  };
}

function describeArc(cx: number, cy: number, r: number, startAngle: number, endAngle: number): string {
  const span = Math.max(0, endAngle - startAngle);
  if (span >= Math.PI * 2 - 0.001) {
    const mid = startAngle + Math.PI;
    const p1 = polarToCartesian(cx, cy, r, startAngle);
    const p2 = polarToCartesian(cx, cy, r, mid);
    const p3 = polarToCartesian(cx, cy, r, endAngle - 0.001);
    return `M ${p1.x} ${p1.y} A ${r} ${r} 0 1 1 ${p2.x} ${p2.y} A ${r} ${r} 0 1 1 ${p3.x} ${p3.y}`;
  }
  const start = polarToCartesian(cx, cy, r, startAngle);
  const end = polarToCartesian(cx, cy, r, endAngle);
  const largeArcFlag = span > Math.PI ? 1 : 0;
  return `M ${start.x} ${start.y} A ${r} ${r} 0 ${largeArcFlag} 1 ${end.x} ${end.y}`;
}

function StorageRing({ groups }: { groups: StorageGroup[] }) {
  const diameter = 200;
  const stroke = 50;
  const cx = diameter / 2;
  const cy = diameter / 2;
  const r = (diameter - stroke) / 2;
  const nonZero = groups.filter((g) => g.bytes > 0).sort((a, b) => b.bytes - a.bytes);
  const sum = nonZero.reduce((acc, g) => acc + g.bytes, 0);
  const gap = nonZero.length > 1 ? 0.024 : 0;

  let cursor = -Math.PI / 2;
  const slices = nonZero.map((group) => {
    const share = sum > 0 ? group.bytes / sum : 0;
    const rawSpan = share * Math.PI * 2;
    const start = cursor + gap / 2;
    const end = Math.max(start + 0.01, cursor + rawSpan - gap / 2);
    const mid = (start + end) / 2;
    cursor += rawSpan;
    return {
      key: group.key,
      color: groupColor(group.key),
      share,
      start,
      end,
      mid,
      span: end - start,
    };
  });

  return <div className="storage-ring-wrap">
    <svg width={diameter} height={diameter} viewBox={`0 0 ${diameter} ${diameter}`} aria-hidden="true">
      {slices.map((slice) => <path
        key={slice.key}
        d={describeArc(cx, cy, r, slice.start, slice.end)}
        fill="none"
        stroke={slice.color}
        strokeWidth={stroke}
        strokeLinecap="butt"
      />)}
      {slices.filter((slice) => slice.span >= 0.42).map((slice) => {
        const pt = polarToCartesian(cx, cy, r, slice.mid);
        const pct = Math.max(1, Math.round(slice.share * 100));
        return <text
          key={`${slice.key}-label`}
          x={pt.x}
          y={pt.y}
          textAnchor="middle"
          dominantBaseline="central"
          fill="#ffffff"
          fontSize="14"
          fontWeight="600"
        >
          {pct}%
        </text>;
      })}
    </svg>
  </div>;
}

export function StoragePage() {
  const version = useStore(libraryVersion);
  const usage = useAsync(async () => {
    const server = await info();
    const clearable: Record<string, string> = {
      thumbnails: `${server.cache}/posters`,
      cache: `${server.cache}/fonts`,
    };
    const data = await core.readJson<StorageUsage>('tl_storage_usage', [
      ...Object.entries(clearable).map(([key, path]) => ({ key, path })),
      { key: 'libraryOther', path: server.uploads },
      { key: 'libraryOther', path: server.exports },
    ]);
    return { data, clearable };
  }, [version]);

  const [selected, setSelected] = useState<Set<string>>(() => new Set(['thumbnails', 'cache']));
  const [expanded, setExpanded] = useState<Set<string>>(() => new Set());
  const [clearing, setClearing] = useState(false);

  const data = usage.data?.data;

  useEffect(() => {
    if (!data) return;
    setSelected((prev) => {
      const next = new Set<string>();
      for (const key of prev) {
        const g = data.groups.find((item) => item.key === key);
        if (g && g.bytes > 0 && CLEARABLE_KEYS.has(key)) next.add(key);
      }
      if (next.size === 0) {
        for (const key of ['thumbnails', 'cache']) {
          const g = data.groups.find((item) => item.key === key);
          if (g && g.bytes > 0) next.add(key);
        }
      }
      return next;
    });
  }, [data]);

  // the parts that take space, largest first (StorageUsageView.parts)
  const orderedGroups: StorageGroup[] = data
    ? STORAGE_ORDER.map((key) => data.groups.find((g) => g.key === key) ?? { key, bytes: 0, files: 0 }).filter((g) => g.bytes > 0).sort((a, b) => b.bytes - a.bytes)
    : [];

  const selectedBytes = orderedGroups
    .filter((g) => selected.has(g.key) && CLEARABLE_KEYS.has(g.key))
    .reduce((sum, g) => sum + g.bytes, 0);

  const toggleExpanded = (key: string) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  };

  const toggleSelected = (key: string) => {
    if (!CLEARABLE_KEYS.has(key)) return;
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  };

  const confirmAndClear = async () => {
    if (!usage.data || selectedBytes <= 0 || clearing) return;
    const pick = await choose(
      L('storage.clear.title'),
      L('storage.clear.message', size(selectedBytes)) + (selected.has('bin') ? '\n' + L('storage.clear.binWarning') : ''),
      [L('storage.clear.confirm')],
      { destructive: true },
    );
    if (pick !== 0) return;
    setClearing(true);
    try {
      const freed = selectedBytes;
      for (const key of selected) {
        if (key === 'bin') {
          await change(core.read(core.b.tl_trash_empty()));
        } else if (usage.data.clearable[key]) {
          await removeFile(usage.data.clearable[key]);
        }
      }
      await usage.reload();
      await alertMessage(L('storage.clear.done', size(freed)));
    } catch (err) {
      toast(err instanceof Error ? err.message : String(err));
    } finally {
      setClearing(false);
    }
  };

  const total = Math.max(1, data?.total ?? 1);
  const percent = (b: number) => { const p = (b / total) * 100; return p > 0 && p < 1 ? '<1%' : `${Math.round(p)}%`; };
  return <SettingsScreen title={L('storage.title')}>
    {!data || usage.error ? <LoadState error={usage.error} reload={usage.reload} /> : <div className="storage-layout">
      <StorageRing groups={orderedGroups} />
      <div className="storage-card">
        {orderedGroups.map((group) => {
          const isOpen = expanded.has(group.key);
          const canClear = CLEARABLE_KEYS.has(group.key) && group.bytes > 0;
          const isChecked = canClear && selected.has(group.key);
          const color = groupColor(group.key);
          return <div key={group.key} className="storage-group">
            <div className="storage-row">
              <div className="storage-lead">
                {CLEARABLE_KEYS.has(group.key) ? <button type="button" className={`storage-check${isChecked ? ' checked' : ''}`} disabled={!canClear}
                  style={isChecked ? { background: color, borderColor: color } : undefined} aria-pressed={isChecked}
                  onClick={() => toggleSelected(group.key)}>{isChecked && <Check size={12} strokeWidth={3.2} />}</button>
                  : <span className="storage-dot" style={{ background: color }} />}
              </div>
              <button type="button" className="storage-row-main" aria-expanded={isOpen} onClick={() => toggleExpanded(group.key)}>
                <span className="storage-row-title">{L(`storage.group.${group.key}`)}</span>
                <span className="storage-row-percent">{percent(group.bytes)}</span>
                <span className="storage-row-size">{size(group.bytes)}</span>
                <ChevronDown size={13} strokeWidth={2.6} className={`storage-chevron${isOpen ? ' open' : ''}`} />
              </button>
              {group.key === 'models' && <Button kind="plain" onClick={() => settings('ai')}>{L('storage.manage')}</Button>}
            </div>
            <div className={`storage-detail${isOpen ? ' open' : ''}`}><div>
              <div className="storage-detail-text">
                {L(`storage.group.${group.key}.detail`)}
                {group.files > 0 && group.key !== 'app' ? ` · ${L('storage.files', group.files)}` : ''}
              </div>
            </div></div>
          </div>;
        })}
        <button type="button" className="storage-clear-btn" disabled={selectedBytes <= 0 || clearing} onClick={() => void confirmAndClear()}>
          <span className="storage-clear-label">{L('storage.clear.selected')}</span>
          {selectedBytes > 0 && <span className="storage-clear-size">{size(selectedBytes)}</span>}
        </button>
      </div>
      <Button onClick={usage.reload} disabled={usage.loading || clearing}>{L('storage.refresh')}</Button>
    </div>}
  </SettingsScreen>;
}

function integrityText(summary: IntegritySummary): string {
  const last = summary.last;
  if (!last) return L('verify.never', summary.unchecked) + (summary.bad ? L('verify.knownBad', summary.bad) : '');
  if (last.running) return L('verify.checking', last.checked, last.total);
  if (!last.completed_at || ['interrupted', 'failed', 'cancelled'].includes(last.outcome)) {
    return L('verify.stopped', L(last.outcome === 'failed' ? 'verify.failed' : 'verify.interrupted'), last.checked, last.total);
  }
  if (summary.bad) return L('verify.foundBad', summary.bad, summary.unchecked);
  if (summary.unchecked) return L('verify.newSince', summary.unchecked);
  return last.outcome === 'succeeded' ? L('verify.lastOK').trim() : L('verify.lastBad', last.bad);
}

function integrityTone(summary?: IntegritySummary | null): TileColor {
  if (!summary) return 'secondary';
  if (summary.last?.running) return 'accent';
  if (summary.bad > 0) return 'orange';
  if (summary.last?.outcome === 'succeeded' && summary.unchecked === 0) return 'green';
  return 'secondary';
}

export function AboutPage() {
  const server = useAsync(info, []);
  const [extras, setExtras] = useState(() => localStorage.getItem('about.extras') === 'true');
  const [, setTaps] = useState(0);
  const task = useTask();
  const integrity = useAsync(() => extras ? core.read<IntegritySummary>(core.b.tl_integrity_summary()) : Promise.resolve(null), [extras]);
  const status = integrity.data?.last;
  useInterval(integrity.reload, extras && status?.running ? 1000 : null);
  const stopped = !!status?.finished;
  useEffect(() => { if (stopped) libraryChanged(); }, [stopped]);

  const handleIconTap = () => {
    setTaps((prev) => {
      if (prev + 1 >= 10) {
        const next = !extras;
        setExtras(next);
        localStorage.setItem('about.extras', String(next));
        return 0;
      }
      return prev + 1;
    });
  };

  const tone = integrityTone(integrity.data);

  return <SettingsScreen title={L('settings.about')}>
    <div className="about-hero">
      <button
        type="button"
        className="about-icon-btn"
        aria-label={L('web.appName')}
        onClick={handleIconTap}
      >
        <img src={new URL('../../../../../icon.png', import.meta.url).href} alt="" width="128" height="128" />
      </button>
      <div className="about-title">{L('web.appName')}</div>
      <div className="about-tagline">{L('about.tagline')}</div>
      {server.data && <Pill text={L('about.version', server.data.version)} color="secondary" />}
    </div>

    {extras && <div className="section-group">
      <SectionHeading title={L('settings.section.maintenance')} />
      <Card>
        <CardRow
          icon={<ShieldCheck size={17} />}
          color={tone === 'secondary' ? 'green' : tone}
          title={L('mac.integrity')}
          detail={integrity.data ? integrityText(integrity.data) : integrity.error ? L('settings.checkUnreadable') : undefined}
          trailing={status?.running
            ? <Button onClick={() => void task.run(async () => {
              await core.b.tl_verify_cancel();
              integrity.reload();
            })}>{L('settings.stopCheck')}</Button>
            : <Button disabled={task.busy || integrity.loading} onClick={() => void task.run(async () => {
              await core.read(core.b.tl_verify_start());
              integrity.reload();
            })}>{L('settings.check')}</Button>}
        />
        {status?.running && <div style={{ paddingTop: 4 }}>
          <SlimBar value={status.total ? status.checked / status.total : 0} color="accent" />
        </div>}
        <RowDivider />

        <CardRow
          icon={<AlertTriangle size={17} />}
          color="orange"
          title={L('common.problemLog')}
          detail={L('mac.problems.footer')}
          trailing={<Button onClick={() => settings('problems')}>{L('common.view')}</Button>}
        />
        <RowDivider />

        <CardRow
          icon={<FileArchive size={17} />}
          color="accent"
          title={L('mac.diagnostics')}
          detail={L('settings.maintenance.footer')}
          trailing={<Button disabled={task.busy} onClick={() => void task.run(async () => {
            const name = L('settings.diagnostics.fileName', dateStamp()).replaceAll('{app}', L('web.appName'));
            const path = outPath(await info(), name);
            await core.read(core.b.tl_export_diagnostics(path, JSON.stringify({
              platform: window.twimshelf?.platform ?? 'web',
              exported_at: new Date().toISOString(),
            })));
            await deliver(path, name);
            await alertMessage(L('diag.exported'), L('diag.exported.detail', name));
          })}>{L('mac.exportEllipsis')}</Button>}
        />
      </Card>
    </div>}
  </SettingsScreen>;
}

interface ProblemEntry {
  id: string;
  ts: string;
  area: string;
  message: string;
  detail?: string;
}

function parseProblemLines(raw: string, startIdx: number): ProblemEntry[] {
  const out: ProblemEntry[] = [];
  const lines = raw.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    if (line.startsWith('{') && line.endsWith('}')) {
      try {
        const obj = JSON.parse(line) as Record<string, unknown>;
        const level = String(obj.level ?? obj.severity ?? 'error').toLowerCase();
        if (level === 'info' || level === 'debug') continue;
        out.push({
          id: `${startIdx}-${i}`,
          ts: String(obj.ts ?? obj.timestamp ?? obj.time ?? ''),
          area: String(obj.area ?? obj.category ?? obj.scope ?? 'app'),
          message: String(obj.message ?? obj.error ?? line),
          detail: typeof obj.detail === 'string' ? obj.detail : undefined,
        });
        continue;
      } catch {
        // fall through to text parser
      }
    }
    const bracket = line.match(/^\[([^\]]+)\]\s*(?:\[([^\]]+)\]\s*)?(.*)$/);
    if (bracket) {
      out.push({
        id: `${startIdx}-${i}`,
        ts: bracket[1] ?? '',
        area: bracket[2] ?? 'log',
        message: bracket[3] || line,
      });
    } else if (/error|warn|fail|问题|错误|失败/i.test(line)) {
      out.push({
        id: `${startIdx}-${i}`,
        ts: '',
        area: 'log',
        message: line,
      });
    }
  }
  return out;
}

export function ProblemsPage() {
  const task = useTask();
  const problems = useAsync(async () => {
    const { library } = await info();
    const files = [
      `${library}/logs/app.1.log`,
      `${library}/logs/app.log`,
      `${library}/logs/diagnostics.log`,
    ];
    const entries: ProblemEntry[] = [];
    for (let i = 0; i < files.length; i++) {
      const text = await readText(files[i]);
      if (text) entries.push(...parseProblemLines(text, i));
    }
    return entries.reverse().slice(0, 200);
  }, []);

  const clearLogs = () => void task.run(async () => {
    const { library } = await info();
    await Promise.allSettled([
      removeFile(`${library}/logs/app.1.log`),
      removeFile(`${library}/logs/app.log`),
      removeFile(`${library}/logs/diagnostics.log`),
    ]);
    await problems.reload();
  });

  const list = problems.data ?? [];

  return <SettingsScreen
    title={L('common.problemLog')}
    subtitle={L('mac.problems.footer')}
    parent="about"
    actions={<>
      <Button onClick={problems.reload} disabled={problems.loading}>
        <RefreshCw size={14} /> {L('storage.refresh')}
      </Button>
      {list.length > 0 && <Button kind="danger" disabled={task.busy} onClick={clearLogs}>
        <Trash2 size={14} /> {L('common.clear')}
      </Button>}
    </>}
  >
    {problems.error ? <LoadState error={problems.error} reload={problems.reload} /> : list.length === 0 ? <Card>
      <Empty
        icon={<CheckCircle2 size={32} />}
        title={L('mac.problems.none')}
      >
        <span>{L('mac.problems.footer')}</span>
      </Empty>
    </Card> : <Card>
      {list.map((entry, idx) => <div key={entry.id}>
        {idx > 0 && <RowDivider />}
        <div className="problem-row">
          <div className="problem-row-head">
            <Pill text={entry.area} color="orange" />
            {entry.ts && <span className="problem-row-time">{entry.ts}</span>}
          </div>
          <div className="problem-row-msg">{entry.message}</div>
          {entry.detail && <div className="problem-row-detail">{entry.detail}</div>}
        </div>
      </div>)}
    </Card>}
  </SettingsScreen>;
}

export function WipePage() {
  const [text, setText] = useState('');
  const [models, setModels] = useState(false);
  const task = useTask();
  const word = L('settings.wipe.word');

  const erase = () => {
    if (text.trim() !== word) return;
    void task.run(async () => {
      const server = await info();
      setAuto(false);
      selectTagger('');
      stopTagging();
      await removeFile(`${server.data}/app/secrets.json`);
      await core.b.tl_set_cookies('', '');
      await core.b.tl_discovery_stop();
      await core.b.tl_ext_pair_cancel();
      await change(core.read(core.b.tl_wipe(models)));
      const cleanup = await Promise.allSettled([
        removeFile(`${server.data}/app/secrets.key`),
        removeFile(`${server.library}/downloads.queue.json`),
        removeFile(server.uploads),
        removeFile(server.exports),
        removeFile(server.cache),
      ]);
      if (cleanup.some((result) => result.status === 'rejected')) throw new Error('web.wipe.cleanup');
      toast(L('settings.wipe.doneMessage'));
      settings();
    });
  };

  return <SettingsScreen title={L('settings.wipe.button')}>
    <Section footer={L('settings.wipe.footer')}>
      <div className="control-padded control-stack">
        <div className="control-wrap">{L('settings.wipe.message')}{models && L('settings.wipe.modelsToo')}</div>
        <label className="control-field-label">{L('settings.wipe.typeToConfirm', word)}
          <TextField value={text} onChange={setText} onEnter={erase} />
        </label>
      </div>
      <Row title={L('settings.wipe.withModels')} trailing={<Toggle checked={models} onChange={setModels}
        label={L('settings.wipe.withModels')} disabled={task.busy} />} />
      <Row title={L('settings.wipe.title')} danger trailing={<Button kind="danger" disabled={task.busy || text.trim() !== word} onClick={erase}>
        {L(task.busy ? 'settings.wipe.erasing' : 'settings.wipe.confirm')}
      </Button>} />
    </Section>
  </SettingsScreen>;
}
