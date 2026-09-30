/**
 * Playback master clock (OUTPUT seconds).
 *
 * Free-running on the wall clock (`performance.timeOrigin + now`, so the
 * main thread and the worker share one time base) unless an external master
 * syncs it — the WebAudio clock when the project has audio. AudioContext only
 * exists on the main thread, so the client posts `(mediaTime, wallMs)` pairs
 * sampled from `AudioContext.getOutputTimestamp()`; this clock slews toward
 * them (hard-resyncs past 60 ms) so video follows audio without visible jumps.
 *
 * Animation phases are always derived from this clock, never from frame
 * counts, so scrubbing, playback and export agree (CLAUDE.md §2).
 */
export function wallNow(): number {
  return performance.timeOrigin + performance.now();
}

export class PlaybackClock {
  private anchorMedia = 0;
  private anchorWall = 0;
  private _rate = 1;
  private _playing = false;
  /** Anchor on the first rendered tick after play (keeps vsync cadence stable). */
  private pendingStart = false;
  /** Largest correction applied by the external master (diagnostics). */
  lastSyncErrorMs = 0;
  externalMaster = false;

  get playing(): boolean {
    return this._playing;
  }
  get rate(): number {
    return this._rate;
  }

  now(wall = wallNow()): number {
    if (!this._playing || this.pendingStart) return this.anchorMedia;
    return this.anchorMedia + ((wall - this.anchorWall) / 1000) * this._rate;
  }

  /** True between play/seek and the tick that anchors the clock to a vsync. */
  get awaitingAnchor(): boolean {
    return this._playing && this.pendingStart;
  }

  /** Wall time the running clock was anchored at (valid while playing). */
  get anchor(): { media: number; wall: number } {
    return { media: this.anchorMedia, wall: this.anchorWall };
  }

  /** Called by the render loop with the vsync-aligned wall time of the tick. */
  tick(wall: number): number {
    if (this._playing && this.pendingStart) {
      this.pendingStart = false;
      this.anchorWall = wall;
    }
    return this.now(wall);
  }

  play(): void {
    if (this._playing) return;
    this._playing = true;
    this.pendingStart = true;
  }

  pause(wall = wallNow()): void {
    if (!this._playing) return;
    this.anchorMedia = this.now(wall);
    this._playing = false;
    this.pendingStart = false;
  }

  seek(t: number, wall = wallNow()): void {
    this.anchorMedia = t;
    this.anchorWall = wall;
    if (this._playing) this.pendingStart = true;
  }

  setRate(rate: number, wall = wallNow()): void {
    const r = Math.max(0.0625, Math.min(16, rate));
    this.anchorMedia = this.now(wall);
    this.anchorWall = wall;
    this._rate = r;
  }

  /** External master sample: the master says `mediaTime` at wall time `wall`. */
  sync(mediaTime: number, wall: number): void {
    if (!this._playing || this.pendingStart) return;
    const predicted = this.now(wall);
    const err = mediaTime - predicted;
    this.lastSyncErrorMs = err * 1000;
    if (Math.abs(err) > 0.06) {
      this.anchorMedia = mediaTime;
      this.anchorWall = wall;
      return;
    }
    // Slew toward the master: 10% of the error per sync, capped at 1 ms per
    // step (<= 2% speed change at the 50 ms sync cadence) so a correction can
    // never shift the vsync-to-frame cadence by more than a millisecond at a time.
    this.anchorMedia += Math.max(-0.001, Math.min(0.001, err * 0.1));
  }
}
