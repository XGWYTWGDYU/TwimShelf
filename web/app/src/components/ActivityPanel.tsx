// What runs in the background (downloads, a model's download, AI tagging, sync, an import, a
// check of the files) floats over every page in a panel at the bottom right, as MacActivityPanel
// does in the native app: one card per kind of work, gone a moment after the work ends, and out of
// the way while the media viewer covers the window.
import { useEffect, useRef, useState } from 'react';
import {
  L,
  type DownloadStatus, type ImportProgress, type ModelDownloadStatus, type SyncStatus, type VerifyStatus,
} from '@twimshelf/core';
import { core } from '../lib/core';
import { useStore } from '../lib/hooks';
import { viewerState } from '../viewer/Viewer';
import { activeTagger, externalModels, modelTitle, tagging } from '../pages/settings/aiTagging';
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

const isVideoPath = (p?: string | null) => !!p && /\.(mp4|mov|m4v|webm)$/i.test(p);

/** Everything running now, read from the core (and the page's own AI tagging). */
async function running(tag: { running: boolean; done: number }, taggerId: string): Promise<Activity[]> {
  const [dl, modelDl, sync, imp, verify, counts, models] = await Promise.all([
    core.read<DownloadStatus>(core.b.tl_download_status()).catch(() => null),
    core.read<ModelDownloadStatus | null>(core.b.tl_model_status()).catch(() => null),
    core.read<SyncStatus>(core.b.tl_sync_status()).catch(() => null),
    core.read<ImportProgress | null>(core.b.tl_import_status()).catch(() => null),
    core.read<VerifyStatus | null>(core.b.tl_verify_status()).catch(() => null),
    tag.running ? core.read<[number, number]>(core.b.tl_ai_counts()).catch(() => null) : Promise.resolve(null),
    tag.running ? externalModels().catch(() => []) : Promise.resolve([]),
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
    const model = models.find((m) => m.id === taggerId);
    const [done, total] = counts ?? [0, 0];
    list.push({
      kind: 'tagging',
      title: L('ai.activity.new', model ? modelTitle(model) : L('models.tagging')),
      detail: L('web.ai.processed', tag.done),
      progress: total > 0 ? done / total : undefined,
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
  return list;
}

/** A card stays at least two seconds (ActivityCenter.minimumShown), and a moment after its work
 *  ends it shows that it is done. */
const MINIMUM_SHOWN_MS = 2000;
const DONE_FOR_MS = 1200;

export function ActivityPanel() {
  const tag = useStore(tagging);
  const taggerId = useStore(activeTagger);
  const viewer = useStore(viewerState);
  const [list, setList] = useState<Activity[]>([]);
  const memory = useRef(new Map<ActivityKind, { since: number; last: Activity; until?: number }>());
  const tagNow = useRef(tag);
  tagNow.current = tag;
  const taggerNow = useRef(taggerId);
  taggerNow.current = taggerId;

  useEffect(() => {
    let live = true;
    let timer = 0;
    const tick = async () => {
      // a hidden window asks for nothing (it is read again as soon as it is shown)
      if (!document.hidden) {
        const now = Date.now();
        const current = await running(tagNow.current, taggerNow.current);
        if (!live) return;
        const kept = memory.current;
        const out = [...current];
        const seen = new Set(current.map((a) => a.kind));
        for (const a of current) {
          const m = kept.get(a.kind);
          kept.set(a.kind, { since: m && m.until === undefined ? m.since : now, last: a });
        }
        for (const [kind, m] of kept) {
          if (seen.has(kind)) continue;
          m.until ??= Math.max(m.since + MINIMUM_SHOWN_MS, now + DONE_FOR_MS);
          if (now < m.until) out.push({ ...m.last, title: `${L('activity.done')} · ${m.last.title}`, progress: 1 });
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
