// Two-finger trackpad gestures from wheel events. A browser gives no phases (began / ended /
// momentum, as AppKit does), and after the fingers lift the trackpad keeps sending a decaying
// stream of momentum events — which, treated as part of the gesture, swallowed the next swipe and
// any scroll for as long as it lasted. A new gesture starts when the events stop for a moment, when
// they turn round on the main axis, or when they grow again after decaying (fingers back on the
// trackpad while the momentum was still running).

export class WheelStream {
  private last = 0;
  private lastMag = 0;
  private decaying = false;
  private dirX = 0;
  private dirY = 0;
  /** Momentum after the fingers lifted (the events have only been getting smaller). */
  momentum = false;

  /** Feeds one event; true when it begins a new gesture. */
  next(e: WheelEvent): boolean {
    const now = e.timeStamp || performance.now();
    const mag = Math.abs(e.deltaX) + Math.abs(e.deltaY);
    const dx = Math.sign(e.deltaX), dy = Math.sign(e.deltaY);
    const horizontal = Math.abs(e.deltaX) >= Math.abs(e.deltaY);
    const gap = now - this.last;
    // a pause alone is not enough: the app may have been busy for a frame or two while the
    // momentum kept shrinking; after a pause the movement must also grow (or the pause be long)
    let fresh = gap > 400 || (gap > 90 && mag > this.lastMag + 1);
    if (!fresh && mag > 2) {
      if (horizontal && dx !== 0 && this.dirX !== 0 && dx !== this.dirX) fresh = true;
      else if (!horizontal && dy !== 0 && this.dirY !== 0 && dy !== this.dirY) fresh = true;
      else if (this.decaying && mag > this.lastMag * 1.6 + 4) fresh = true;
    }
    if (fresh) { this.decaying = false; this.momentum = false; this.dirX = 0; this.dirY = 0; }
    else if (mag < this.lastMag - 0.5) { this.decaying = true; }
    // a long run of shrinking events is the momentum
    if (this.decaying && mag <= this.lastMag) this.momentum = true;
    if (dx !== 0 && Math.abs(e.deltaX) > 1) this.dirX = dx;
    if (dy !== 0 && Math.abs(e.deltaY) > 1) this.dirY = dy;
    this.last = now;
    this.lastMag = mag;
    return fresh;
  }
}
