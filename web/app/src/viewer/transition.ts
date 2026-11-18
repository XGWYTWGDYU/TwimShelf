export type ViewerSource = (mediaId: string) => DOMRectReadOnly | undefined;

export function fitMedia(bounds: DOMRectReadOnly, width: number, height: number): DOMRectReadOnly {
  if (width <= 0 || height <= 0) return bounds;
  const scale = Math.min(bounds.width / width, bounds.height / height);
  const w = width * scale, h = height * scale;
  return new DOMRectReadOnly(bounds.x + (bounds.width - w) / 2, bounds.y + (bounds.height - h) / 2, w, h);
}

export function intersect(a: DOMRectReadOnly, b: DOMRectReadOnly): DOMRectReadOnly {
  const x = Math.max(a.left, b.left), y = Math.max(a.top, b.top);
  return new DOMRectReadOnly(x, y, Math.max(0, Math.min(a.right, b.right) - x), Math.max(0, Math.min(a.bottom, b.bottom) - y));
}

/** Match the macOS viewer's uniform scale, centre crop and 320 ms timing. */
export function animateViewer(surface: HTMLElement, media: DOMRectReadOnly, source: DOMRectReadOnly | undefined,
  opening: boolean, interrupted?: Keyframe): Animation[] {
  if (!source || !source.width || !source.height || !media.width || !media.height || matchMedia('(prefers-reduced-motion: reduce)').matches) {
    const frames = opening ? [{ opacity: 0 }, { opacity: 1 }]
      : [{ ...interrupted, opacity: interrupted?.opacity ?? 1 }, { ...interrupted, opacity: 0 }];
    return [surface.animate(frames, { duration: 160, easing: 'ease-out', fill: 'both' })];
  }

  const bounds = surface.getBoundingClientRect();
  const scale = Math.max(source.width / media.width, source.height / media.height);
  const w = source.width / scale, h = source.height / scale;
  const mx = media.x - bounds.x + media.width / 2, my = media.y - bounds.y + media.height / 2;
  const x = source.x - bounds.x + source.width / 2 - mx * scale;
  const y = source.y - bounds.y + source.height / 2 - my * scale;
  const zoom = {
    transform: `translate(${x}px, ${y}px) scale(${scale})`,
    clipPath: `inset(${my - h / 2}px ${bounds.width - mx - w / 2}px ${bounds.height - my - h / 2}px ${mx - w / 2}px)`,
  };
  const full = { transform: 'translate(0px, 0px) scale(1)', clipPath: 'inset(0px 0px 0px 0px)' };
  const frames = opening ? [zoom, full] : [interrupted ?? full, zoom];
  const geometry = surface.animate(frames.map(({ transform, clipPath }) => ({ transform, clipPath })),
    { duration: 320, easing: 'ease-in-out', fill: 'both' });
  const opacity = opening
    ? [{ opacity: 0 }, { opacity: 1, offset: 0.45 }, { opacity: 1 }]
    : [{ opacity: interrupted?.opacity ?? 1 }, { opacity: interrupted?.opacity ?? 1, offset: 0.55 }, { opacity: 0 }];
  const fade = surface.animate(opacity, { duration: 320, easing: 'ease-in-out', fill: 'both' });
  return [geometry, fade];
}
