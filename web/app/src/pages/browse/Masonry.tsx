// The 浏览 grid (MacFeedMasonryLayout / FeedMasonry): cards as tall as their content in columns of
// equal width, each card into the shortest column; 20 at the sides, 16 between columns, 18 between
// cards, the footer under the tallest column. Density sets how wide the cards should be. Virtual: only the cards near the visible area exist, so 5000 posts scroll as 50. Heights
// start as estimates and are corrected as cards are measured.
import { forwardRef, useCallback, useImperativeHandle, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { cardColumns, type CardDensity } from './density';
import './Masonry.css';

export interface MasonryProps<T> {
  items: T[];
  active: boolean;
  density: CardDensity;
  keyOf: (item: T) => string;
  estimate: (item: T, width: number) => number;
  render: (item: T, width: number, index: number) => ReactNode;
  /** Room above the first row (the toolbar the cards scroll under, and 12 more). */
  top: number;
  footer?: ReactNode;
  /** Every scroll, with how far down the list is. */
  onScrollTop?: (top: number) => void;
}

export interface MasonryHandle {
  focus(): void;
  scrollToTop(): void;
  scrollToIndex(i: number): void;
}

interface Placed { key: string; index: number; x: number; y: number; h: number }

const SIDE = 20, COL_GAP = 16, ROW_GAP = 18, FOOTER = 56;

function MasonryInner<T>({ items, active, density, keyOf, estimate, render, top, footer, onScrollTop }: MasonryProps<T>, ref: React.Ref<MasonryHandle>) {
  const scroller = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(0);
  const [view, setView] = useState({ top: 0, height: 800 });
  const measured = useRef(new Map<string, number>());
  const [version, setVersion] = useState(0);
  const pending = useRef(false);

  // while the window is being resized the cards go straight to their places (no glide)
  const [resizing, setResizing] = useState(false);
  const resizeTimer = useRef(0);
  useLayoutEffect(() => {
    if (!active) return;
    const el = scroller.current!;
    let lastW = el.clientWidth;
    const measure = () => {
      const { clientWidth, clientHeight, scrollTop } = el;
      if (!clientWidth || !clientHeight) return;
      if (clientWidth !== lastW) {
        lastW = clientWidth;
        setResizing(true);
        window.clearTimeout(resizeTimer.current);
        resizeTimer.current = window.setTimeout(() => setResizing(false), 250);
      }
      setWidth(clientWidth);
      setView({ top: scrollTop, height: clientHeight });
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, [active]);

  const columns = cardColumns(width - SIDE * 2, density);
  const colW = Math.max(1, Math.floor((width - SIDE * 2 - (columns - 1) * COL_GAP) / columns));
  const widthKey = colW;

  const layout = useMemo(() => {
    const bottoms = new Array(columns).fill(top);
    const placed: Placed[] = new Array(items.length);
    for (let i = 0; i < items.length; i++) {
      const key = keyOf(items[i]);
      const h = measured.current.get(`${key}@${widthKey}`) ?? estimate(items[i], colW);
      let c = 0;
      for (let j = 1; j < columns; j++) if (bottoms[j] < bottoms[c] - 0.5) c = j;
      placed[i] = { key, index: i, x: SIDE + c * (colW + COL_GAP), y: bottoms[c], h };
      bottoms[c] += h + ROW_GAP;
    }
    return { placed, height: Math.max(top, ...bottoms) - ROW_GAP };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [items, columns, colW, widthKey, version, top]);

  const report = useCallback((key: string, h: number) => {
    const k = `${key}@${widthKey}`;
    if (Math.abs((measured.current.get(k) ?? -1) - h) < 1) return;
    measured.current.set(k, h);
    if (!pending.current) {
      pending.current = true;
      requestAnimationFrame(() => { pending.current = false; setVersion((v) => v + 1); });
    }
  }, [widthKey]);

  useImperativeHandle(ref, () => ({
    focus() { scroller.current?.focus({ preventScroll: true }); },
    scrollToTop() { scroller.current?.scrollTo({ top: 0 }); },
    scrollToIndex(i: number) {
      const p = layout.placed[i], el = scroller.current;
      if (p && el) el.scrollTo({ top: Math.max(0, p.y + p.h / 2 - el.clientHeight / 2) });
    },
  }), [layout]);

  const from = view.top - view.height;
  const to = view.top + view.height * 2;
  const visible = layout.placed.filter((p) => p.y + p.h >= from && p.y <= to);

  return (
    <div className="masonry-scroller" ref={scroller} tabIndex={-1} onScroll={(e) => { setView({ top: e.currentTarget.scrollTop, height: e.currentTarget.clientHeight }); onScrollTop?.(e.currentTarget.scrollTop); }}>
      <div className={`masonry${resizing ? ' resizing' : ''}`} style={{ height: layout.height + FOOTER }}>
        {width > 0 && visible.map((p) => (
          <Cell key={p.key} id={p.key} x={p.x} y={p.y} w={colW} report={report}>
            {render(items[p.index], colW, p.index)}
          </Cell>
        ))}
        {footer && <div className="masonry-footer" style={{ top: layout.height }}>{footer}</div>}
      </div>
    </div>
  );
}

export const Masonry = forwardRef(MasonryInner) as <T>(p: MasonryProps<T> & { ref?: React.Ref<MasonryHandle> }) => ReturnType<typeof MasonryInner>;

/** The height a card is heading for: a part of it that animates its height says where to
 *  (`data-target-h`), so the cards under it move once, in step, rather than chasing every frame. */
function heightOf(el: HTMLElement): number {
  const t = el.querySelector<HTMLElement>('[data-target-h]');
  return el.offsetHeight + (t ? Number(t.dataset.targetH) - t.offsetHeight : 0);
}

function Cell({ id, x, y, w, report, children }: { id: string; x: number; y: number; w: number; report: (k: string, h: number) => void; children: ReactNode }) {
  const box = useRef<HTMLDivElement>(null);
  // a cell that just appeared is put in place without a glide
  const [placed, setPlaced] = useState(false);
  useLayoutEffect(() => {
    const el = box.current!;
    report(id, heightOf(el));
    const ro = new ResizeObserver(() => report(id, heightOf(el)));
    ro.observe(el);
    const mo = new MutationObserver(() => report(id, heightOf(el)));
    mo.observe(el, { attributes: true, subtree: true, attributeFilter: ['data-target-h'] });
    const raf = requestAnimationFrame(() => setPlaced(true));
    return () => { ro.disconnect(); mo.disconnect(); cancelAnimationFrame(raf); };
  }, [id, report]);
  return <div ref={box} className={`masonry-cell${placed ? ' placed' : ''}`} style={{ transform: `translate(${x}px, ${y}px)`, width: w }}>{children}</div>;
}
