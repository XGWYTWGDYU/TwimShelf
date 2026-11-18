// The video player of the viewer (MacPlayerView.swift): the video with its own controls right on
// it, no bar behind them and nothing of the browser's player — play · progress · time · speed ·
// share · close, white with a soft shadow, gone after 2.5 s of playing without the mouse moving
// (the pointer too). Double-click plays or pauses; press and hold plays at 2.5×; Space, ↑ ↓
// (volume) and F come from the viewer. Loops at the end.
import { forwardRef, useCallback, useEffect, useImperativeHandle, useRef, useState } from 'react';
import { Pause, Play, Share, X } from 'lucide-react';
import { L, type FeedItem } from '@twimshelf/core';
import { core } from '../lib/core';
import { openMenuBelow } from '../components/Menu';
import { handBack, position } from '../lib/videoPositions';

export interface PlayerHandle {
  togglePlay(): void;
  seek(by: number): void;
  volume(by: number): void;
}

const SPEEDS = [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3];
const speedText = (r: number) => `${r}×`;
let savedVolume = 1;
try { const v = Number(localStorage.getItem('player.volume')); if (v >= 0 && v <= 1 && localStorage.getItem('player.volume') != null) savedVolume = v; } catch { /* none */ }

export function fmt(s: number): string {
  if (!isFinite(s) || s < 0) return '0:00';
  const i = Math.floor(s);
  const mm = String(Math.floor(i / 60) % 60).padStart(2, '0'), ss = String(i % 60).padStart(2, '0');
  return i >= 3600 ? `${Math.floor(i / 3600)}:${mm}:${ss}` : `${Math.floor(i / 60)}:${ss}`;
}

export const Player = forwardRef<PlayerHandle, { item: FeedItem; poster?: string; squarePreview?: { url: string; side: number }; onClose: () => void; onShare: (el: Element) => void; onIdle: (idle: boolean) => void }>(
  function Player({ item, poster, squarePreview, onClose, onShare, onIdle }, ref) {
    const video = useRef<HTMLVideoElement>(null);
    const [t, setT] = useState(position(item.media_id));
    const [d, setD] = useState(0);
    const [paused, setPaused] = useState(false);
    const [hasFrame, setHasFrame] = useState(false);
    const [speed, setSpeed] = useState(1);
    const [shown, setShown] = useState(true);
    const [hud, setHud] = useState<{ text: string; sticky: boolean } | null>(null);
    const scrubbing = useRef(false);
    const hideTimer = useRef<number>(0);
    const hudTimer = useRef<number>(0);
    const holdTimer = useRef<number>(0);
    const boosting = useRef(false);
    const speedRef = useRef(1);
    speedRef.current = speed;

    const flash = useCallback((text: string, sticky = false) => {
      window.clearTimeout(hudTimer.current);
      setHud({ text, sticky });
      if (!sticky) hudTimer.current = window.setTimeout(() => setHud(null), 700);
    }, []);

    /** The controls show; they go again after 2.5 s while it plays. */
    const wake = useCallback(() => {
      window.clearTimeout(hideTimer.current);
      setShown(true);
      onIdle(false);
      hideTimer.current = window.setTimeout(() => {
        const v = video.current;
        if (!v || v.paused) return;
        setShown(false);
        onIdle(true);
      }, 2500);
    }, [onIdle]);

    const togglePlay = useCallback(() => {
      const v = video.current;
      if (!v) return;
      if (v.paused) { v.playbackRate = speedRef.current; void v.play().catch(() => {}); flash('▶︎'); } else { v.pause(); flash('❚❚'); }
      wake();
    }, [flash, wake]);

    useImperativeHandle(ref, () => ({
      togglePlay,
      seek(by: number) {
        const v = video.current;
        if (!v) return;
        const to = Math.min(Math.max(v.currentTime + by, 0), v.duration || 0);
        v.currentTime = to;
        flash(`${fmt(to)} / ${fmt(v.duration)}`);
      },
      volume(by: number) {
        const v = video.current;
        if (!v) return;
        v.volume = Math.round(Math.min(1, Math.max(0, v.volume + by)) * 10) / 10;
        savedVolume = v.volume;
        try { localStorage.setItem('player.volume', String(v.volume)); } catch { /* none */ }
        flash(`🔊 ${Math.round(v.volume * 100)}%`);
      },
    }), [togglePlay, flash]);

    useEffect(() => {
      const v = video.current!;
      v.volume = savedVolume;
      wake();
      // leaving (closed, or another page): the card goes on from here
      return () => {
        window.clearTimeout(hideTimer.current);
        window.clearTimeout(hudTimer.current);
        window.clearTimeout(holdTimer.current);
        onIdle(false);
        if (v.readyState >= 1 && v.currentTime > 0) handBack(item.media_id, v.currentTime);
        v.pause();
      };
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [item.media_id]);

    // the time, 30 times a second while it plays
    useEffect(() => {
      let raf = 0;
      const tick = () => {
        const v = video.current;
        if (v && !scrubbing.current) setT(v.currentTime);
        raf = requestAnimationFrame(tick);
      };
      raf = requestAnimationFrame(tick);
      return () => cancelAnimationFrame(raf);
    }, []);

    const seekTo = (frac: number) => {
      const v = video.current;
      if (!v || !v.duration) return;
      v.currentTime = frac * v.duration;
      setT(v.currentTime);
    };

    const bar = useRef<HTMLDivElement>(null);
    const scrub = (e: React.PointerEvent) => {
      e.stopPropagation();
      const el = bar.current!;
      el.setPointerCapture(e.pointerId);
      scrubbing.current = true;
      const at = (x: number) => { const r = el.getBoundingClientRect(); seekTo(Math.min(1, Math.max(0, (x - r.left) / r.width))); };
      at(e.clientX);
      const move = (ev: PointerEvent) => at(ev.clientX);
      const up = () => { scrubbing.current = false; el.removeEventListener('pointermove', move); el.removeEventListener('pointerup', up); el.removeEventListener('pointercancel', up); };
      el.addEventListener('pointermove', move);
      el.addEventListener('pointerup', up);
      el.addEventListener('pointercancel', up);
      wake();
    };

    // double-click: play/pause; press and hold: 2.5× while held
    const down = (e: React.MouseEvent) => {
      if (e.button !== 0) return;
      if (e.detail === 2) { togglePlay(); return; }
      window.clearTimeout(holdTimer.current);
      holdTimer.current = window.setTimeout(() => {
        const v = video.current;
        if (!v) return;
        boosting.current = true;
        v.playbackRate = 2.5;
        flash('2.5× ▶▶', true);
      }, 250);
    };
    const up = () => {
      window.clearTimeout(holdTimer.current);
      if (boosting.current) {
        boosting.current = false;
        if (video.current) video.current.playbackRate = speedRef.current;
        window.clearTimeout(hudTimer.current);
        hudTimer.current = window.setTimeout(() => setHud(null), 400);
      }
    };

    const frac = d > 0 ? Math.min(1, t / d) : 0;
    return (
      <div className="player" onMouseMove={wake} onMouseDown={down} onMouseUp={up} onMouseLeave={up}>
        <video ref={video} className="player-video" src={core.fileUrl(item.path)} poster={poster} autoPlay playsInline loop
          disablePictureInPicture controlsList="nodownload nofullscreen noremoteplayback" disableRemotePlayback
          onLoadedMetadata={(e) => { const v = e.currentTarget; setD(v.duration); const at = position(item.media_id); if (at > 0 && at < v.duration) v.currentTime = at; }}
          onLoadedData={() => setHasFrame(true)}
          onPlaying={() => setHasFrame(true)}
          onDurationChange={(e) => setD(e.currentTarget.duration)}
          onPlay={() => { setPaused(false); wake(); }} onPause={() => { setPaused(true); wake(); }}
          onContextMenu={(e) => e.preventDefault()} />
        {squarePreview && !poster && !hasFrame && <img className="player-square-preview" src={squarePreview.url} alt="" draggable={false}
          width={squarePreview.side} height={squarePreview.side} />}
        {hud && <div className="player-hud">{hud.text}</div>}
        <div className={`player-controls${shown ? '' : ' hidden'}`} onMouseDown={(e) => e.stopPropagation()} onDoubleClick={(e) => e.stopPropagation()}>
          <button className="player-btn" aria-label={paused ? L('viewer.play') : L('viewer.pause')} onClick={togglePlay}>
            {paused ? <Play size={15} fill="currentColor" strokeWidth={0} /> : <Pause size={15} fill="currentColor" strokeWidth={0} />}
          </button>
          <div className="player-bar" ref={bar} onPointerDown={scrub} role="slider" aria-valuemin={0} aria-valuemax={d} aria-valuenow={t}>
            <div className="player-track"><div className="player-fill" style={{ width: `${frac * 100}%` }} /></div>
            <div className="player-knob" style={{ left: `${frac * 100}%` }} />
          </div>
          <span className="player-time">{fmt(t)} / {fmt(d)}</span>
          <button className="player-btn player-speed" aria-label={L('player.speed')} title={L('player.speed')}
            onClick={(e) => openMenuBelow(e.currentTarget, SPEEDS.map((r) => ({ label: speedText(r), checked: r === speed, run: () => {
              setSpeed(r);
              const v = video.current;
              if (v && !v.paused) v.playbackRate = r;
              wake();
            } })))}>{speedText(speed)}</button>
          <button className="player-btn" aria-label={L('viewer.share')} title={L('viewer.share')} onClick={(e) => onShare(e.currentTarget)}><Share size={15} strokeWidth={2.2} /></button>
          <button className="player-btn" aria-label={L('viewer.close')} title={L('viewer.close')} onClick={onClose}><X size={16} strokeWidth={2.4} /></button>
        </div>
      </div>
    );
  },
);
