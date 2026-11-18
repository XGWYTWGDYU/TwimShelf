import { useEffect, useRef, useState, type ReactNode } from 'react';
import { L, type LibraryStats } from '@twimshelf/core';
import {
  CheckCircle2, ChevronRight, ChevronsUpDown, Circle, Download, FolderDown,
  Image, Info, MessageSquare, Package, PlaySquare, RefreshCw, ShieldCheck, Sparkles, Tag,
} from 'lucide-react';
import { Button, Dialog, Page, Progress, Row, TextField, Toggle } from '../../components/ui';
import { change, type Option } from '../../components/libraryControls';
import { openMenuBelow, type MenuEntry } from '../../components/Menu';
import { alertMessage, choose, prompt } from '../../components/pickers';
import { ClawdIcon, mascotEnabled } from '../../components/Mascot';
import { core } from '../../lib/core';
import { useStore } from '../../lib/hooks';
import { folders } from '../../lib/library';
import { go } from '../../lib/router';
import { selectTagger, setAuto, stopTagging } from './aiTagging';
import { info, removeFile } from './serverFiles';
import './settings.css';

export type TileColor = 'blue' | 'accent' | 'purple' | 'teal' | 'green' | 'indigo' | 'orange' | 'brown' | 'yellow' | 'red' | 'pink' | 'gray' | 'secondary';

export function settings(sub?: string) {
  go({ page: 'settings', sub });
}

export function SettingsScreen({ title, subtitle, actions, children, parent, back }: {
  title: string; subtitle?: ReactNode; actions?: ReactNode; children: ReactNode; parent?: string; back?: () => void;
}) {
  return (
    <Page title={title} subtitle={subtitle} actions={actions} back={back ?? (() => settings(parent))}>
      <div className="settings-canvas">{children}</div>
    </Page>
  );
}

export function SectionHeading({ title, note, trailing }: { title: ReactNode; note?: ReactNode; trailing?: ReactNode }) {
  return (
    <div className="section-heading">
      <div className="section-heading-texts">
        <h2 className="section-heading-title">{title}</h2>
        {note && <p className="section-heading-note">{note}</p>}
      </div>
      {trailing && <div className="section-heading-trailing">{trailing}</div>}
    </div>
  );
}

export function SectionGroup({ title, note, trailing, footer, children }: {
  title?: ReactNode; note?: ReactNode; trailing?: ReactNode; footer?: ReactNode; children: ReactNode;
}) {
  return (
    <section className="section-group">
      {title !== undefined && <SectionHeading title={title} note={note} trailing={trailing} />}
      {children}
      {footer && <p className="section-group-footer">{footer}</p>}
    </section>
  );
}

export function Card({ tint, padding, spacing, className, children }: {
  tint?: TileColor; padding?: number; spacing?: number; className?: string; children: ReactNode;
}) {
  return (
    <div
      className={`s-card${tint ? ` tint-${tint}` : ''}${className ? ` ${className}` : ''}`}
      style={{ padding, gap: spacing }}>
      {children}
    </div>
  );
}

export function IconTile({ icon, color = 'blue', size = 30 }: { icon: ReactNode; color?: TileColor; size?: number }) {
  const radius = Math.round(size * 0.29);
  return (
    <span className={`icon-tile tile-${color}`} style={{ width: size, height: size, borderRadius: radius }}>
      {icon}
    </span>
  );
}

export function Pill({ text, color = 'secondary', icon }: { text: ReactNode; color?: TileColor; icon?: ReactNode }) {
  return (
    <span className={`s-pill pill-${color}`}>
      {icon}
      <span>{text}</span>
    </span>
  );
}

export function SlimBar({ value, color = 'blue' }: { value?: number; color?: TileColor }) {
  const clamped = value === undefined ? undefined : Math.min(1, Math.max(0, value));
  return (
    <div className={`slim-bar bar-${color}`} role="progressbar" aria-valuenow={clamped !== undefined ? Math.round(clamped * 100) : undefined}>
      {clamped === undefined
        ? <div className="slim-bar-indeterminate" />
        : <div className="slim-bar-fill" style={{ width: `${Math.max(2, Math.round(clamped * 100))}%` }} />}
    </div>
  );
}

export function ProgressRing({ value, size = 104, lineWidth = 11, color = 'purple', children }: {
  value: number; size?: number; lineWidth?: number; color?: 'purple' | 'blue' | 'green'; children?: ReactNode;
}) {
  const r = (size - lineWidth) / 2;
  const c = 2 * Math.PI * r;
  const clamped = Math.min(1, Math.max(0, value));
  const stroke = color === 'purple' ? 'var(--ai)' : color === 'green' ? 'var(--approved)' : 'var(--accent)';
  const track = color === 'purple' ? 'var(--ai-soft)' : color === 'green' ? 'var(--approved-soft)' : 'var(--accent-soft)';
  return (
    <div className="progress-ring-wrap" style={{ width: size, height: size }}>
      <svg className="progress-ring-svg" width={size} height={size} viewBox={`0 0 ${size} ${size}`}>
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={track} strokeWidth={lineWidth} />
        <circle
          cx={size / 2}
          cy={size / 2}
          r={r}
          fill="none"
          stroke={stroke}
          strokeWidth={lineWidth}
          strokeLinecap="round"
          strokeDasharray={c}
          strokeDashoffset={c * (1 - clamped)}
          style={{ transition: 'stroke-dashoffset 0.35s ease-out' }}
        />
      </svg>
      {children && <div className="progress-ring-center">{children}</div>}
    </div>
  );
}

export function CardRow({ icon, color = 'blue', title, detail, trailing, danger }: {
  icon?: ReactNode; color?: TileColor; title: ReactNode; detail?: ReactNode; trailing?: ReactNode; danger?: boolean;
}) {
  return (
    <div className={`card-row${danger ? ' danger' : ''}`}>
      {icon && <IconTile icon={icon} color={danger ? 'red' : color} size={30} />}
      <div className="card-row-texts">
        <div className="card-row-title">{title}</div>
        {detail !== undefined && detail !== null && detail !== '' && <div className="card-row-detail">{detail}</div>}
      </div>
      {trailing !== undefined && <div className="card-row-trailing">{trailing}</div>}
    </div>
  );
}

export function NavRow({ icon, color = 'blue', title, detail, id, onClick }: {
  icon?: ReactNode; color?: TileColor; title: ReactNode; detail?: ReactNode; id?: string; onClick: () => void;
}) {
  return (
    <button type="button" className="nav-row-btn" data-testid={id} onClick={onClick}>
      <CardRow icon={icon} color={color} title={title} detail={detail} trailing={<ChevronRight size={14} strokeWidth={2.2} />} />
    </button>
  );
}

export function ToggleRow({ icon, color = 'blue', title, detail, checked, onChange, disabled }: {
  icon?: ReactNode; color?: TileColor; title: string; detail?: ReactNode; checked: boolean; onChange: (v: boolean) => void; disabled?: boolean;
}) {
  return (
    <div style={{ opacity: disabled ? 0.55 : 1 }}>
      <CardRow
        icon={icon}
        color={color}
        title={title}
        detail={detail}
        trailing={<Toggle label={title} checked={checked} onChange={onChange} disabled={disabled} />}
      />
    </div>
  );
}

export function RowDivider({ inset = 0 }: { inset?: number }) {
  return <hr className="row-divider" style={inset ? { marginLeft: inset } : undefined} />;
}

export function NavTile({ title, detail, icon, color = 'blue', progress, badge, badgeColor = 'secondary', id, onClick }: {
  title: string; detail?: string | null; icon: ReactNode; color?: TileColor; progress?: number;
  badge?: string | null; badgeColor?: TileColor; id?: string; onClick: () => void;
}) {
  return (
    <button type="button" className="nav-tile" data-testid={id} onClick={onClick}>
      <div className="nav-tile-top">
        <IconTile icon={icon} color={color} size={40} />
        <div className="nav-tile-top-right">
          {badge && <Pill text={badge} color={badgeColor} />}
          <ChevronRight size={14} strokeWidth={2.2} />
        </div>
      </div>
      <div className="nav-tile-body">
        <div className="nav-tile-title">{title}</div>
        <div className="nav-tile-detail">{detail || '\u00a0'}</div>
      </div>
      {progress !== undefined && (
        <div className="nav-tile-bar">
          <SlimBar value={progress} color={color} />
        </div>
      )}
    </button>
  );
}

export function OptionCard({ title, detail, icon, color = 'blue', selected, onClick }: {
  title: string; detail: string; icon: ReactNode; color?: TileColor; selected: boolean; onClick: () => void;
}) {
  return (
    <button type="button" className={`option-card${selected ? ' selected' : ''}`} aria-pressed={selected} onClick={onClick}>
      <div className="option-card-top">
        <IconTile icon={icon} color={selected ? color : 'gray'} size={32} />
        <span className="option-card-check">
          {selected ? <CheckCircle2 size={18} /> : <Circle size={18} />}
        </span>
      </div>
      <div className="card-row-texts">
        <div className="option-card-title">{title}</div>
        <div className="option-card-detail">{detail}</div>
      </div>
    </button>
  );
}

export function ChipButton({ title, icon, selected = false, dashed = false, onClick }: {
  title: string; icon?: ReactNode; selected?: boolean; dashed?: boolean; onClick: () => void;
}) {
  return (
    <button
      type="button"
      className={`chip-btn${selected ? ' selected' : ''}${dashed ? ' dashed' : ''}`}
      aria-pressed={selected}
      onClick={onClick}>
      {icon}
      <span>{title}</span>
    </button>
  );
}

export function Banner({ text, icon, color = 'orange' }: { text: ReactNode; icon?: ReactNode; color?: 'orange' | 'red' | 'blue' }) {
  return (
    <div className={`s-banner banner-${color}`}>
      <span className="s-banner-icon">{icon ?? <Info size={15} />}</span>
      <span className="s-banner-text selectable">{text}</span>
    </div>
  );
}

export function BigStat({ value, name, icon, color }: { value?: number | null; name: string; icon: ReactNode; color: string }) {
  return (
    <div className="big-stat" aria-label={`${name}: ${value ?? 0}`}>
      <div className="big-stat-value">{(value ?? 0).toLocaleString()}</div>
      <div className="big-stat-label">
        <span style={{ color, display: 'inline-grid', placeItems: 'center' }}>{icon}</span>
        <span>{name}</span>
      </div>
    </div>
  );
}

export function StatsStrip({ stats }: { stats?: LibraryStats | null }) {
  return (
    <div className="stats-strip">
      <BigStat value={stats?.posts} name={L('common.posts')} icon={<MessageSquare size={12} />} color="var(--accent)" />
      <BigStat value={stats?.photos} name={L('search.kw.photo.word')} icon={<Image size={12} />} color="var(--orange)" />
      <BigStat value={stats?.videos} name={L('place.videos')} icon={<PlaySquare size={12} />} color="var(--danger)" />
      <BigStat value={stats?.tags} name={L('common.tags')} icon={<Tag size={12} />} color="var(--ai)" />
    </div>
  );
}

export type ActivityKind = 'download' | 'model' | 'tagging' | 'sync' | 'verify' | 'importing';

export function ActivityRow({ kind, title, detail, progress, previewPath, previewIsVideo }: {
  kind: ActivityKind; title: string; detail?: string; progress?: number; previewPath?: string | null; previewIsVideo?: boolean;
}) {
  const mascot = useStore(mascotEnabled);
  const [thumbUrl, setThumbUrl] = useState<string>();
  useEffect(() => {
    setThumbUrl(undefined);
    if (!previewPath) return;
    const q = new URLSearchParams({ path: previewPath, side: '140' });
    if (!previewIsVideo) {
      setThumbUrl(`${core.transport.base}/api/scaled?${q}`);
      return;
    }
    let live = true;
    fetch(`${core.transport.base}/api/poster?${q}`, { credentials: 'same-origin' })
      .then((r) => (r.ok ? r.json() : null))
      .then((d: { path?: string } | null) => { if (live && d?.path) setThumbUrl(core.fileUrl(d.path)); })
      .catch(() => {});
    return () => { live = false; };
  }, [previewPath, previewIsVideo]);

  const icon = {
    download: mascot ? <ClawdIcon name="bag" size={34} /> : <Download size={20} />,
    model: <Package size={20} />,
    tagging: mascot ? <ClawdIcon name="camera" size={34} /> : <Sparkles size={20} />,
    sync: <RefreshCw size={20} />,
    verify: <ShieldCheck size={20} />,
    importing: <FolderDown size={20} />,
  }[kind];

  return (
    <div className="activity-row">
      <div className="activity-thumb">
        {thumbUrl ? <img src={thumbUrl} alt="" onError={() => setThumbUrl(undefined)} /> : icon}
      </div>
      <div className="activity-body">
        <div className="activity-title">{title}</div>
        {detail && <div className="activity-detail">{detail}</div>}
        <SlimBar value={progress} />
      </div>
    </div>
  );
}

export function PlaceholderEditor({ value, onChange, placeholder, minHeight = 120, disabled, label }: {
  value: string; onChange: (v: string) => void; placeholder?: string; minHeight?: number; disabled?: boolean; label?: string;
}) {
  return (
    <textarea
      className="placeholder-editor"
      style={{ minHeight }}
      aria-label={label ?? placeholder}
      value={value}
      placeholder={placeholder}
      disabled={disabled}
      onChange={(e) => onChange(e.target.value)}
    />
  );
}

/** A macOS-style popup menu button (NSPopUpButton) backed by components/Menu.tsx openMenuBelow. */
export function PopupSelect({ label, value, options, onChange, disabled }: {
  label: string; value: string; options: (Option | 'separator')[]; onChange: (value: string) => void; disabled?: boolean;
}) {
  const current = options.find((o): o is Option => o !== 'separator' && o.value === value);
  return (
    <button
      type="button"
      className="popup-select"
      aria-label={label}
      disabled={disabled}
      onClick={(e) => {
        const items: MenuEntry[] = options.map((o) =>
          o === 'separator'
            ? 'separator'
            : { label: o.label, checked: o.value === value, run: () => onChange(o.value) },
        );
        openMenuBelow(e.currentTarget, items);
      }}>
      <span className="popup-select-label">{current?.label ?? value}</span>
      <span className="popup-select-chevrons"><ChevronsUpDown size={12} strokeWidth={2.4} /></span>
    </button>
  );
}

/** A macOS-style segmented control (NSSegmentedControl). */
export function SegmentedControl<T extends string>({ options, value, onChange }: {
  options: { value: T; label: string }[]; value: T; onChange: (v: T) => void;
}) {
  return (
    <div className="seg-control" role="tablist">
      {options.map((o) => (
        <button
          key={o.value}
          type="button"
          role="tab"
          aria-selected={o.value === value}
          className={`seg-btn${o.value === value ? ' on' : ''}`}
          onClick={() => onChange(o.value)}>
          {o.label}
        </button>
      ))}
    </div>
  );
}

/** Custom macOS-style slider (no browser <input type="range">). */
export function CustomSlider({ value, min, max, step = 1, onChange, disabled, label }: {
  value: number; min: number; max: number; step?: number; onChange: (v: number) => void; disabled?: boolean; label?: string;
}) {
  const trackRef = useRef<HTMLDivElement>(null);
  const clamped = Math.min(max, Math.max(min, value));
  const pct = max > min ? ((clamped - min) / (max - min)) * 100 : 0;

  const updateFromClientX = (clientX: number) => {
    const rect = trackRef.current?.getBoundingClientRect();
    if (!rect || !rect.width) return;
    const ratio = Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
    const raw = min + ratio * (max - min);
    const stepped = Math.round((raw - min) / step) * step + min;
    const next = Math.min(max, Math.max(min, stepped));
    if (next !== value) onChange(next);
  };

  return (
    <div
      className={`custom-slider${disabled ? ' disabled' : ''}`}
      role="slider"
      tabIndex={disabled ? -1 : 0}
      aria-label={label}
      aria-valuemin={min}
      aria-valuemax={max}
      aria-valuenow={clamped}
      onPointerDown={(e) => {
        if (disabled) return;
        e.currentTarget.setPointerCapture(e.pointerId);
        updateFromClientX(e.clientX);
      }}
      onPointerMove={(e) => {
        if (disabled || !e.currentTarget.hasPointerCapture(e.pointerId)) return;
        updateFromClientX(e.clientX);
      }}
      onKeyDown={(e) => {
        if (disabled) return;
        if (e.key === 'ArrowRight' || e.key === 'ArrowUp') {
          e.preventDefault();
          onChange(Math.min(max, clamped + step));
        } else if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') {
          e.preventDefault();
          onChange(Math.max(min, clamped - step));
        }
      }}>
      <div className="custom-slider-track" ref={trackRef}>
        <div className="custom-slider-fill" style={{ width: `${pct}%` }} />
        <div className="custom-slider-thumb" style={{ left: `${pct}%` }} />
      </div>
    </div>
  );
}

/** Native 2-step wipe flow (MacWipeFlow.start): choose whether to keep AI models, then type 清除 to confirm. */
export async function runWipeFlow(): Promise<boolean> {
  const choice = await choose(
    L('settings.wipe.title'),
    L('mac.wipe.message'),
    [L('settings.wipe.keepModels'), L('settings.wipe.withModels')],
    { destructive: true },
  );
  if (choice == null) return false;
  const includeModels = choice === 1;
  const word = L('settings.wipe.word');
  const typed = await prompt(
    L('common.confirmAgain'),
    { message: `${L('mac.wipe.typeToConfirm', word)}${includeModels ? L('settings.wipe.modelsToo') : ''}`, placeholder: word, action: L('settings.wipe.confirm') },
  );
  if (typed?.trim() !== word) return false;

  const server = await info();
  setAuto(false);
  selectTagger('');
  stopTagging();
  await removeFile(`${server.data}/app/secrets.json`).catch(() => {});
  await core.b.tl_set_cookies('', '');
  await core.b.tl_discovery_stop();
  await core.b.tl_ext_pair_cancel();
  await change(core.read(core.b.tl_wipe(includeModels)));
  await Promise.allSettled([
    removeFile(`${server.data}/app/secrets.key`),
    removeFile(`${server.library}/downloads.queue.json`),
    removeFile(server.uploads),
    removeFile(server.exports),
    removeFile(server.cache),
  ]);
  await alertMessage(L('settings.wipe.done'), L('settings.wipe.doneMessage'));
  settings();
  return true;
}

export function FolderChoice({ title, value, onChange, disabled, extra = [], empty = L('common.notIntoFolder') }: {
  title: string; value: string; onChange: (name: string) => void; disabled?: boolean; extra?: Option[]; empty?: string;
}) {
  const overview = useStore(folders);
  const options: Option[] = [
    { value: '', label: empty },
    ...(overview?.folders ?? []).map(({ name }) => ({ value: name, label: name })),
    ...extra,
  ];
  if (!options.some((option) => option.value === value)) options.splice(1, 0, { value, label: value });
  return <Row title={title} trailing={<PopupSelect label={title} value={value} options={options} onChange={onChange} disabled={disabled} />} />;
}

export function FieldRow({ label, value, onChange, type, subtitle, placeholder }: {
  label: string; value: string; onChange: (value: string) => void; type?: string; subtitle?: string; placeholder?: string;
}) {
  return <Row title={label} subtitle={subtitle} trailing={<TextField value={value} onChange={onChange} type={type} placeholder={placeholder ?? label} />} />;
}

export function TextArea({ label, value, onChange, placeholder, disabled }: {
  label: string; value: string; onChange: (value: string) => void; placeholder?: string; disabled?: boolean;
}) {
  return <label className="control-field-label">{label}<textarea className="field control-textarea" value={value}
    placeholder={placeholder} disabled={disabled} onChange={(event) => onChange(event.target.value)} /></label>;
}

export function ProgressRow({ title, subtitle, value, onCancel }: {
  title: string; subtitle?: string; value?: number; onCancel?: () => void;
}) {
  return <>
    <Row title={title} subtitle={subtitle} trailing={onCancel && <Button onClick={onCancel}>{L('common.cancel')}</Button>} />
    <div className="control-padded"><Progress value={value} /></div>
  </>;
}

export function ResultDialog({ title, children, close }: { title: string; children: ReactNode; close: () => void }) {
  return <Dialog title={title} onClose={close}
    actions={<Button kind="primary" onClick={close}>{L('common.ok')}</Button>}>{children}</Dialog>;
}

export function useNotice() {
  const [notice, setNotice] = useState<{ title: string; text: ReactNode }>();
  return {
    show: (title: string, text: ReactNode) => setNotice({ title, text }),
    dialog: notice && <ResultDialog title={notice.title} close={() => setNotice(undefined)}>{notice.text}</ResultDialog>,
  };
}
