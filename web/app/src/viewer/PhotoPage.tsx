// One photo of the viewer (MacViewerPage): the picture fills the viewer, scaled to fit (small
// pictures too); pinch the trackpad to zoom (1–6×, about the pointer), double-click to zoom to
// 2.5× at the pointer or back, and while zoomed two fingers pan. The card's picture shows at once
// and the full picture over it when it is ready; a sharper one is read when zoomed in.
import { forwardRef, useCallback, useEffect, useImperativeHandle, useLayoutEffect, useRef, useState } from 'react';
import type { FeedItem } from '@twimshelf/core';
import { core } from '../lib/core';
import { cachedThumb, thumb } from '../lib/thumbs';

let cacheDir: Promise<string> | null = null;
function cache(): Promise<string> {
  cacheDir ??= fetch(`${core.transport.base}/api/info`, { credentials: 'same-origin' }).then((r) => r.json()).then((i: { cache: string }) => i.cache);
  cacheDir.catch(() => { cacheDir = null; });
  return cacheDir;
}

/** A photo's URL the browser can show: the original, or a JPEG of a HEIC (browsers cannot). */
export async function displayUrl(item: FeedItem): Promise<string> {
  if (/\.(heic|heif)$/i.test(item.path)) return core.fileUrl(await core.read<string>(core.b.tl_display_image(item.path, 4096, await cache())));
  return core.fileUrl(item.path);
}

/** The best picture of `item` already loaded (a card's), for the first frame. */
export function previewOf(item: FeedItem): string | undefined {
  return cachedThumb(item, 1024, 'whole') ?? cachedThumb(item, 512, 'whole') ?? cachedThumb(item, 256, 'whole');
}

export interface PhotoHandle {
  zoomed(): boolean;
  /** Pinch (a ctrl-wheel event from the trackpad) or pan (a wheel event while zoomed). */
  wheel(e: WheelEvent): boolean;
  toggleZoom(x: number, y: number): void;
  reset(): void;
  image(): HTMLImageElement | null;
}

interface View { s: number; x: number; y: number }

export const PhotoPage = forwardRef<PhotoHandle, { item: FeedItem; width: number; height: number; squarePreview?: string }>(function PhotoPage({ item, width, height, squarePreview }, ref) {
  const [preview] = useState(() => previewOf(item));
  const [full, setFull] = useState<string | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [natural, setNatural] = useState<{ w: number; h: number } | null>(item.size && item.size[0] > 0 && item.size[1] > 0 ? { w: item.size[0], h: item.size[1] } : null);
  const [view, setView] = useState<View>({ s: 1, x: 0, y: 0 });
  const [animating, setAnimating] = useState(false);
  const img = useRef<HTMLImageElement>(null);
  const viewRef = useRef(view);
  viewRef.current = view;

  useEffect(() => {
    let live = true;
    if (!preview && item.kind !== 'photo') thumb(item, 1024, 0, 'whole').then(() => {}, () => {});
    displayUrl(item).then((u) => live && setFull(u), () => {});
    return () => { live = false; };
  }, [item, preview]);

  // the fitted size at 1× (as large as the viewer allows, small pictures scaled up too)
  const nw = natural?.w ?? width, nh = natural?.h ?? height;
  const fit = Math.min(width / nw, height / nh);
  const bw = nw * fit, bh = nh * fit;

  /** Keeps the picture over the viewer: centred when smaller, its edges at the viewer's when larger. */
  const clamp = useCallback((v: View): View => {
    const w = bw * v.s, h = bh * v.s;
    const mx = Math.max(0, (w - width) / 2), my = Math.max(0, (h - height) / 2);
    return { s: v.s, x: Math.min(mx, Math.max(-mx, v.x)), y: Math.min(my, Math.max(-my, v.y)) };
  }, [bw, bh, width, height]);

  /** Zooms to `s` keeping the point (px, py) of the viewer still. */
  const zoomAt = useCallback((s: number, px: number, py: number, v = viewRef.current): View => {
    const ns = Math.min(6, Math.max(1, s));
    const cx = px - width / 2, cy = py - height / 2;
    const k = ns / v.s;
    return clamp({ s: ns, x: cx - (cx - v.x) * k, y: cy - (cy - v.y) * k });
  }, [clamp, width, height]);

  useLayoutEffect(() => { setView((v) => clamp(v)); }, [clamp]);

  // zoomed in: the sharper picture (the original is already the sharpest the server has)
  useImperativeHandle(ref, () => ({
    zoomed: () => viewRef.current.s > 1.001,
    wheel(e: WheelEvent) {
      const r = (e.currentTarget as Element | null)?.getBoundingClientRect?.() ?? { left: 0, top: 0 };
      if (e.ctrlKey) {
        setAnimating(false);
        setView(zoomAt(viewRef.current.s * Math.exp(-e.deltaY * 0.01), e.clientX - r.left, e.clientY - r.top));
        return true;
      }
      if (viewRef.current.s <= 1.001) return false;
      setAnimating(false);
      setView((v) => clamp({ s: v.s, x: v.x - e.deltaX, y: v.y - e.deltaY }));
      return true;
    },
    toggleZoom(px: number, py: number) {
      setAnimating(true);
      setView(viewRef.current.s > 1.01 ? { s: 1, x: 0, y: 0 } : zoomAt(2.5, px, py));
    },
    reset() { setAnimating(false); setView({ s: 1, x: 0, y: 0 }); },
    image: () => img.current,
  }), [zoomAt, clamp]);

  const style = {
    width: bw, height: bh,
    transform: `translate(${view.x}px, ${view.y}px) scale(${view.s})`,
    transition: animating ? 'transform 0.25s cubic-bezier(0.25, 0.9, 0.3, 1)' : 'none',
  };
  return (
    <div className="photo-page">
      <div className="photo-frame" style={style} onTransitionEnd={() => setAnimating(false)}>
        {(preview || squarePreview) && !loaded && <img className={`photo-img${preview ? '' : ' square-preview'}`} src={preview ?? squarePreview} alt="" draggable={false}
          onLoad={(e) => {
            const t = e.currentTarget;
            if (preview && !natural) setNatural({ w: t.naturalWidth, h: t.naturalHeight });
          }} />}
        {full && <img ref={img} className={`photo-img${loaded ? '' : ' loading'}`} src={full} alt="" draggable={false}
          onLoad={(e) => { setLoaded(true); const t = e.currentTarget; if (!natural || Math.abs(natural.w / natural.h - t.naturalWidth / t.naturalHeight) > 0.01) setNatural({ w: t.naturalWidth, h: t.naturalHeight }); }} />}
      </div>
    </div>
  );
});
