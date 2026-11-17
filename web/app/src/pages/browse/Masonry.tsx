// A virtual masonry grid: cards of different heights in columns, each card into the shortest
// column. Only the cards near the visible area exist in the DOM, so 5000 posts scroll as smoothly
// as 50. Heights start as estimates and are corrected as cards are measured.
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import './Masonry.css';

export interface MasonryProps<T> {
  items: T[];
  keyOf: (item: T) => string;
  /** A first guess of a card's height at `width`, before it has been measured. */
  estimate: (item: T, width: number) => number;
  render: (item: T, width: number, index: number) => ReactNode;
  minColumn?: number;
  gap?: number;
  /** Something above the grid that scrolls with it (the search bar, a header). */
  header?: ReactNode;
  /** Gets the scroller, for keyboard scrolling and restoring a position. */
  scrollerRef?: (el: HTMLDivElement | null) => void;
  onScroll?: (top: number) => void;
}

interface Placed { key: string; index: number; x: number; y: number; h: number }

export function Masonry<T>({ items, keyOf, estimate, render, minColumn = 250, gap = 14, header, scrollerRef, onScroll }: MasonryProps<T>) {
  const scroller = useRef<HTMLDivElement>(null);
  const headerBox = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(0);
  const [view, setView] = useState({ top: 0, height: 800 });
  const [headerH, setHeaderH] = useState(0);
  const measured = useRef(new Map<string, number>());
  const [version, setVersion] = useState(0);
  const pending = useRef(false);

  useLayoutEffect(() => {
    const el = scroller.current!;
    // measured now as well: a ResizeObserver reports only with the next frame (none in a hidden tab)
    setWidth(el.clientWidth);
    setView((v) => ({ ...v, height: el.clientHeight || v.height }));
    const ro = new ResizeObserver(() => {
      setWidth(el.clientWidth);
      setView((v) => ({ ...v, height: el.clientHeight }));
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  useLayoutEffect(() => {
    const el = headerBox.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setHeaderH(el.offsetHeight));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const padding = 20;
  const inner = Math.max(0, width - padding * 2);
  const columns = Math.max(1, Math.floor((inner + gap) / (minColumn + gap)));
  const colW = columns > 0 ? (inner - gap * (columns - 1)) / columns : inner;
  // a measured height belongs to a width: a new width measures again
  const widthKey = Math.round(colW);

  const layout = useMemo(() => {
    const tops = new Array(columns).fill(0);
    const placed: Placed[] = new Array(items.length);
    for (let i = 0; i < items.length; i++) {
      const key = keyOf(items[i]);
      const h = measured.current.get(`${key}@${widthKey}`) ?? estimate(items[i], colW);
      let c = 0;
      for (let j = 1; j < columns; j++) if (tops[j] < tops[c] - 0.5) c = j;
      placed[i] = { key, index: i, x: padding + c * (colW + gap), y: tops[c], h };
      tops[c] += h + gap;
    }
    return { placed, height: Math.max(0, ...tops) };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [items, columns, colW, widthKey, version]);

  const report = useCallback((key: string, h: number) => {
    const k = `${key}@${widthKey}`;
    if (Math.abs((measured.current.get(k) ?? -1) - h) < 1) return;
    measured.current.set(k, h);
    if (!pending.current) {
      pending.current = true;
      requestAnimationFrame(() => { pending.current = false; setVersion((v) => v + 1); });
    }
  }, [widthKey]);

  const scroll = useCallback(() => {
    const el = scroller.current!;
    setView({ top: el.scrollTop, height: el.clientHeight });
    onScroll?.(el.scrollTop);
  }, [onScroll]);

  useEffect(() => { scrollerRef?.(scroller.current); return () => scrollerRef?.(null); }, [scrollerRef]);

  // the cards near the view: a screen above, two below (where the scroll usually goes)
  const from = view.top - headerH - view.height;
  const to = view.top - headerH + view.height * 2;
  const visible = layout.placed.filter((p) => p.y + p.h >= from && p.y <= to);

  return (
    <div className="masonry-scroller" ref={scroller} onScroll={scroll}>
      <div ref={headerBox}>{header}</div>
      <div className="masonry" style={{ height: layout.height + padding }}>
        {width > 0 && visible.map((p) => (
          <Cell key={p.key} id={p.key} x={p.x} y={p.y} w={colW} report={report}>
            {render(items[p.index], colW, p.index)}
          </Cell>
        ))}
      </div>
    </div>
  );
}

function Cell({ id, x, y, w, report, children }: { id: string; x: number; y: number; w: number; report: (k: string, h: number) => void; children: ReactNode }) {
  const box = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const el = box.current!;
    report(id, el.offsetHeight);
    const ro = new ResizeObserver(() => report(id, el.offsetHeight));
    ro.observe(el);
    return () => ro.disconnect();
  }, [id, report]);
  return <div ref={box} className="masonry-cell" style={{ transform: `translate(${x}px, ${y}px)`, width: w }}>{children}</div>;
}
