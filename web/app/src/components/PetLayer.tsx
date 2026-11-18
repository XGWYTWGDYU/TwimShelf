// 使用 Claude Code 吉祥物: the little Clawd over the window, as in the other apps: at home in the
// bottom-right corner, in windows with room for it. Only the crab itself takes a click; everything
// else goes to what is below. The viewer, dialogs and menus cover it, and it takes no clicks then.
import { useEffect, useRef, useState } from 'react';
import { useStore } from '../lib/hooks';
import { mascotEnabled } from './Mascot';
import { PetEngine } from './petEngine';
import './Mascot.css';

const fits = () => window.innerWidth >= 700 && window.innerHeight >= 500;
const covered = () => !!document.querySelector('.viewer, .dialog-scrim, .menu-scrim');

function Pet() {
  const canvas = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const view = canvas.current!;
    const paint = view.getContext('2d')!;
    const engine = new PetEngine();
    let swallowing = false;

    const resize = () => {
      const scale = window.devicePixelRatio || 1;
      view.width = Math.round(window.innerWidth * scale);
      view.height = Math.round(window.innerHeight * scale);
      paint.setTransform(scale, 0, 0, scale, 0, 0);
      engine.setBounds(window.innerWidth, window.innerHeight, 18, 18);
      last = '';
    };

    // thirty pictures a second are plenty for pixel art; nothing is painted when nothing changed
    let last = '', frame = 0, then = performance.now();
    const tick = (now: number) => {
      frame = requestAnimationFrame(tick);
      if (now - then < 30) return;
      engine.tick((now - then) / 1000);
      then = now;
      const rects = engine.draw();
      const picture = rects.join();
      if (picture === last) return;
      last = picture;
      paint.clearRect(0, 0, window.innerWidth, window.innerHeight);
      for (const [x, y, w, h, argb] of rects) {
        const c = argb % 0x1000000;
        paint.fillStyle = `rgba(${c >> 16},${(c >> 8) & 255},${c & 255},${Math.floor(argb / 0x1000000) / 255})`;
        paint.fillRect(x, y, w, h);
      }
    };

    const moved = (e: PointerEvent) => { if (e.pointerType !== 'touch') engine.pointerMoved(e.clientX, e.clientY); };
    const gone = () => engine.pointerGone();
    const left = (e: MouseEvent) => { if (!e.relatedTarget) gone(); };
    const pressed = (e: PointerEvent) => {
      swallowing = e.button === 0 && !covered() && engine.tap(e.clientX, e.clientY);
      if (swallowing) { e.preventDefault(); e.stopPropagation(); }
    };
    // the press that was the crab's does not also reach what is under it
    const swallow = (e: Event) => { if (swallowing) { e.preventDefault(); e.stopPropagation(); } };
    const clicked = (e: Event) => { swallow(e); swallowing = false; };

    resize();
    frame = requestAnimationFrame(tick);
    window.addEventListener('resize', resize);
    window.addEventListener('pointermove', moved, true);
    window.addEventListener('blur', gone);
    document.documentElement.addEventListener('mouseleave', left);
    window.addEventListener('pointerdown', pressed, true);
    window.addEventListener('mousedown', swallow, true);
    window.addEventListener('mouseup', swallow, true);
    window.addEventListener('click', clicked, true);
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener('resize', resize);
      window.removeEventListener('pointermove', moved, true);
      window.removeEventListener('blur', gone);
      document.documentElement.removeEventListener('mouseleave', left);
      window.removeEventListener('pointerdown', pressed, true);
      window.removeEventListener('mousedown', swallow, true);
      window.removeEventListener('mouseup', swallow, true);
      window.removeEventListener('click', clicked, true);
    };
  }, []);
  return <canvas ref={canvas} className="pet-layer" aria-hidden="true" />;
}

export function PetLayer() {
  const enabled = useStore(mascotEnabled);
  const [room, setRoom] = useState(fits);
  useEffect(() => {
    const update = () => setRoom(fits());
    window.addEventListener('resize', update);
    return () => window.removeEventListener('resize', update);
  }, []);
  return enabled && room ? <Pet /> : null;
}
