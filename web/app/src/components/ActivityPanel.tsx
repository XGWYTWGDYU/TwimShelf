// What runs in the background (downloads, a model's download, AI tagging, sync, an import, a
// check of the files) floats over every page in a panel at the bottom right, as MacActivityPanel
// does in the native app: one card per kind of work, gone a moment after the work ends, and out of
// the way while the media viewer covers the window.
import { useEffect, useRef, useState } from 'react';
import {
  L,
  type DownloadStatus, type ImportProgress, type LibraryStats,
  type ModelDownloadStatus, type SyncStatus, type VerifyStatus,
} from '@twimshelf/core';
import { core } from '../lib/core';
import { useStore } from '../lib/hooks';
import { libraryChanged, refreshLibrary } from '../lib/library';
import { viewerState } from '../viewer/Viewer';
import { tagging, type TaggingState } from '../pages/settings/aiTagging';
import { size } from '../pages/settings/serverFiles';
import { ActivityRow, type ActivityKind } from '../pages/settings/settingsControls';
import './ActivityPanel.css';

type Activity = {
  kind: ActivityKind;
  title: string;
  detail?: string;
  progress?: number;
  previewPath?: string | null;
  previewIsVideo?: boolean;
};

interface Snap {
  dl: DownloadStatus | null;
  modelDl: ModelDownloadStatus | null;
  sync: SyncStatus | null;
  imp: ImportProgress | null;
  verify: VerifyStatus | null;
  list: Activity[];
}

const isVideoPath = (p?: string | null) => !!p && /\.(mp4|mov|m4v|webm)$/i.test(p);

function outcomeTitle(outcome: string | null | undefined, base: string): { prefix: string; ok: boolean } {
  switch (outcome) {
    case 'failed': return { prefix: L('activity.failed'), ok: false };
    case 'paused': return { prefix: L('activity.paused'), ok: false };
    case 'cancelled':
    case 'stopped': return { prefix: L('activity.stopped'), ok: false };
    case 'partial': return { prefix: L('activity.partial'), ok: false };
    default: return { prefix: L('activity.done'), ok: true };
  }
}

/** Everything running now, read from the core (and the page's own AI tagging). */
async function pollSnapshot(tag: TaggingState): Promise<Snap> {
  const [dl, modelDl, sync, imp, verify] = await Promise.all([
    core.read<DownloadStatus>(core.b.tl_download_status()).catch(() => null),
    core.read<ModelDownloadStatus | null>(core.b.tl_model_status()).catch(() => null),
    core.read<SyncStatus>(core.b.tl_sync_status()).catch(() => null),
    core.read<ImportProgress | null>(core.b.tl_import_status()).catch(() => null),
    core.read<VerifyStatus | null>(core.b.tl_verify_status()).catch(() => null),
  ]);
  const list: Activity[] = [];
  if (dl?.running) {
    const finished = dl.done + dl.skipped + dl.failed;
    const recent = dl.recent.at(-1);
    list.push({
      kind: 'download',
      title: L('activity.downloadingPosts'),
      detail: `${finished} / ${dl.total}${dl.failed > 0 ? L('settings.failedSuffix', dl.failed) : ''}${dl.active.length ? L('activity.activeSuffix', dl.active.length) : ''}`,
      progress: dl.total > 0 ? finished / dl.total : undefined,
      previewPath: recent,
      previewIsVideo: isVideoPath(recent),
    });
  }
  if (modelDl?.running) {
    list.push({
      kind: 'model',
      title: L('activity.downloadingModel', modelDl.repo),
      detail: modelDl.verifying ? L('models.verifying') : modelDl.total_bytes > 0 ? `${size(modelDl.done_bytes)} / ${size(modelDl.total_bytes)}` : L('models.connecting'),
      progress: modelDl.total_bytes > 0 ? modelDl.done_bytes / modelDl.total_bytes : undefined,
    });
  }
  if (tag.running) {
    const total = Math.max(tag.total, tag.done);
    list.push({
      kind: 'tagging',
      title: L('ai.activity.new', tag.modelName || L('models.tagging')),
      detail: total > 0 ? `${tag.done} / ${total}` : L('web.ai.processed', tag.done),
      progress: total > 0 ? tag.done / total : undefined,
      previewPath: tag.currentPath,
      previewIsVideo: tag.currentKind === 'video',
    });
  }
  if ((sync?.syncing ?? 0) > 0) {
    const r = sync?.receiving;
    list.push(r && r.total > 0
      ? {
        kind: 'sync',
        title: L('activity.receiving'),
        detail: L('activity.filesLeft', Math.max(0, r.total - r.received))
          + (r.total_bytes > 0
            ? L('activity.received', r.received, r.total, size(r.bytes), size(r.total_bytes))
            : L('activity.receivedShort', r.received, r.total, size(r.bytes))),
        progress: r.total_bytes > 0 ? r.bytes / r.total_bytes : r.received / r.total,
        previewPath: r.last_path,
        previewIsVideo: isVideoPath(r.last_path),
      }
      : { kind: 'sync', title: L('activity.syncing'), detail: L('activity.syncDetail') });
  }
  if (imp?.running) {
    list.push({
      kind: 'importing',
      title: imp.waiting ? L('activity.importWaiting') : L('activity.importing'),
      detail: L('activity.importProgress', imp.folders_done, imp.folders_total, imp.files_done)
        + (imp.issues > 0 ? L('activity.importIssues', imp.issues) : ''),
      progress: imp.folders_total > 0 ? imp.folders_done / imp.folders_total : undefined,
      previewPath: imp.current,
      previewIsVideo: isVideoPath(imp.current),
    });
  }
  if (verify?.running) {
    list.push({
      kind: 'verify',
      title: L('activity.verifying'),
      detail: `${verify.checked} / ${verify.total} · ${size(verify.bytes)}${verify.bad > 0 ? L('activity.foundBad', verify.bad) : ''}`,
      progress: verify.total > 0 ? verify.checked / verify.total : undefined,
      previewPath: verify.current,
      previewIsVideo: isVideoPath(verify.current),
    });
  }
  return { dl, modelDl, sync, imp, verify, list };
}

function completedCard(kind: ActivityKind, last: Activity, snap: Snap, tag: TaggingState): Activity {
  if (kind === 'download' && snap.dl) {
    const dl = snap.dl;
    const outcome = dl.paused > 0 ? 'paused' : dl.failed > 0 ? (dl.done > 0 ? 'partial' : 'failed') : 'succeeded';
    const { prefix, ok } = outcomeTitle(outcome, last.title);
    return {
      ...last,
      title: `${prefix} · ${last.title}`,
      detail: L('activity.downloadSummary', dl.done, dl.skipped, dl.failed, dl.total),
      progress: ok ? 1 : last.progress,
    };
  }
  if (kind === 'model' && snap.modelDl) {
    const m = snap.modelDl;
    const outcome = m.error ? 'failed' : m.finished ? 'succeeded' : 'stopped';
    const { prefix, ok } = outcomeTitle(outcome, last.title);
    return {
      ...last,
      title: `${prefix} · ${last.title}`,
      detail: m.error ? L(m.error) : last.detail,
      progress: ok ? 1 : last.progress,
    };
  }
  if (kind === 'tagging') {
    const outcome = tag.error ? 'failed' : 'succeeded';
    const { prefix, ok } = outcomeTitle(outcome, last.title);
    return {
      ...last,
      title: `${prefix} · ${last.title}`,
      detail: tag.error ? L(tag.error) : last.detail,
      progress: ok ? 1 : last.progress,
    };
  }
  if (kind === 'importing' && snap.imp) {
    const imp = snap.imp;
    const outcome = imp.issues > 0 ? 'partial' : 'succeeded';
    const { prefix, ok } = outcomeTitle(outcome, last.title);
    return {
      ...last,
      title: `${prefix} · ${last.title}`,
      detail: L('activity.importSummary', imp.folders_done, imp.folders_total, imp.files_done, imp.issues),
      progress: ok ? 1 : last.progress,
    };
  }
  if (kind === 'verify' && snap.verify) {
    const v = snap.verify;
    const outcome = v.bad > 0 ? 'partial' : 'succeeded';
    const { prefix, ok } = outcomeTitle(outcome, last.title);
    return {
      ...last,
      title: `${prefix} · ${last.title}`,
      detail: L('activity.verifySummary', v.checked, v.total, v.bad),
      progress: ok ? 1 : last.progress,
    };
  }
  return { ...last, title: `${L('activity.done')} · ${last.title}`, progress: 1 };
}

/** A card stays at least two seconds (ActivityCenter.minimumShown), and a moment after its work
 *  ends it shows its final outcome. */
const MINIMUM_SHOWN_MS = 2000;
const DONE_FOR_MS = 1600;

export function ActivityPanel() {
  const tag = useStore(tagging);
  const viewer = useStore(viewerState);
  const [list, setList] = useState<Activity[]>([]);
  const memory = useRef(new Map<ActivityKind, { since: number; last: Activity; doneCard?: Activity; until?: number }>());
  const lastDlRecent = useRef<string | undefined>(undefined);
  const tagNow = useRef(tag);
  tagNow.current = tag;

  // Resume interrupted downloads 3s after startup (matching ActivityCenter.resumeInterruptedDownloads)
  useEffect(() => {
    const t = window.setTimeout(async () => {
      try {
        const s = await core.read<LibraryStats>(core.b.tl_stats());
        if (s.pending_jobs > 0) {
          const dl = await core.read<DownloadStatus>(core.b.tl_download_status()).catch(() => null);
          if (!dl?.running) await core.read(core.b.tl_download_resume('{}')).catch(() => null);
        }
      } catch { /* ignore */ }
    }, 3000);
    return () => window.clearTimeout(t);
  }, []);

  useEffect(() => {
    let live = true;
    let timer = 0;
    const tick = async () => {
      // a hidden window asks for nothing (it is read again as soon as it is shown)
      if (!document.hidden) {
        const now = Date.now();
        const snap = await pollSnapshot(tagNow.current);
        if (!live) return;
        const recent = snap.dl?.recent.at(-1);
        if (recent && recent !== lastDlRecent.current) {
          lastDlRecent.current = recent;
          void refreshLibrary();
        }
        const kept = memory.current;
        const out = [...snap.list];
        const seen = new Set(snap.list.map((a) => a.kind));
        for (const a of snap.list) {
          const m = kept.get(a.kind);
          kept.set(a.kind, { since: m && m.until === undefined ? m.since : now, last: a });
        }
        for (const [kind, m] of kept) {
          if (seen.has(kind)) continue;
          if (m.until === undefined) {
            m.until = Math.max(m.since + MINIMUM_SHOWN_MS, now + DONE_FOR_MS);
            m.doneCard = completedCard(kind, m.last, snap, tagNow.current);
            if (kind === 'download' || kind === 'importing' || kind === 'verify' || kind === 'model' || kind === 'sync') {
              libraryChanged();
            }
          }
          if (now < m.until) out.push(m.doneCard ?? m.last);
          else kept.delete(kind);
        }
        setList(out);
      }
      if (live) timer = window.setTimeout(tick, 500);
    };
    void tick();
    return () => { live = false; window.clearTimeout(timer); };
  }, []);

  const show = list.length > 0 && !viewer;
  // the last cards stay while the panel fades out
  const [shown, setShown] = useState<Activity[]>([]);
  useEffect(() => { if (list.length > 0) setShown(list); }, [list]);

  return (
    <div className={`activity-panel${show ? ' is-shown' : ''}`} aria-live="polite" aria-hidden={!show}>
      {(list.length > 0 ? list : shown).map((a) => (
        <ActivityRow
          key={a.kind}
          kind={a.kind}
          title={a.title}
          detail={a.detail}
          progress={a.progress}
          previewPath={a.previewPath}
          previewIsVideo={a.previewIsVideo}
        />
      ))}
    </div>
  );
}
