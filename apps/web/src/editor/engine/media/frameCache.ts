/**
 * Decoded-frame cache. Owns every VideoFrame it holds and ALWAYS `close()`s
 * on eviction / clear — a leaked VideoFrame pins a hardware decoder surface
 * and eventually stalls the decoder.
 *
 * Eviction is by distance from the current target frame rather than pure
 * recency: for video, the frames just ahead of the playhead are the most
 * valuable, frames behind it (kept for backward scrubbing) the least.
 * Pinned frames (the one on screen / in flight on the GPU) are never evicted.
 */
export class FrameCache {
  private frames = new Map<number, VideoFrame>();
  private pins = new Map<number, number>();
  private bytes = 0;
  evictions = 0;

  constructor(
    public maxFrames: number,
    private readonly frameBytes: number,
  ) {}

  get size(): number {
    return this.frames.size;
  }
  get residentBytes(): number {
    return this.bytes;
  }

  has(index: number): boolean {
    return this.frames.has(index);
  }

  get(index: number): VideoFrame | null {
    return this.frames.get(index) ?? null;
  }

  /** Nearest cached frame at or before `index` (for playback fallback). */
  nearestAtOrBefore(index: number): { index: number; frame: VideoFrame } | null {
    let best = -1;
    for (const k of this.frames.keys()) if (k <= index && k > best) best = k;
    return best >= 0 ? { index: best, frame: this.frames.get(best)! } : null;
  }

  put(index: number, frame: VideoFrame, target: number): void {
    const old = this.frames.get(index);
    if (old) {
      if (old === frame) return;
      old.close();
      this.bytes -= this.frameBytes;
    }
    this.frames.set(index, frame);
    this.bytes += this.frameBytes;
    this.evict(target);
  }

  pin(index: number): void {
    this.pins.set(index, (this.pins.get(index) ?? 0) + 1);
  }
  unpin(index: number): void {
    const n = (this.pins.get(index) ?? 0) - 1;
    if (n <= 0) this.pins.delete(index);
    else this.pins.set(index, n);
  }

  /** Frames in [from, to] that are cached. */
  countInRange(from: number, to: number): number {
    let n = 0;
    for (const k of this.frames.keys()) if (k >= from && k <= to) n++;
    return n;
  }

  /**
   * Eviction priority: larger = evicted first. Default: distance from the
   * target, frames behind it counting double (VideoStream installs a cyclic
   * version while looping).
   */
  score: ((index: number) => number) | null = null;

  /** Drops every unpinned frame `keep` rejects. */
  retain(keep: (index: number) => boolean): void {
    for (const [k, f] of this.frames) {
      if (!keep(k) && !this.pins.has(k)) {
        f.close();
        this.frames.delete(k);
        this.bytes -= this.frameBytes;
        this.evictions++;
      }
    }
  }

  evict(target: number): void {
    while (this.frames.size > this.maxFrames) {
      let worst = -1;
      let worstScore = -Infinity;
      for (const k of this.frames.keys()) {
        if (this.pins.has(k)) continue;
        // Behind the target costs double: prefer keeping what playback needs next.
        const score = this.score ? this.score(k) : k < target ? (target - k) * 2 : k - target;
        if (score > worstScore) {
          worstScore = score;
          worst = k;
        }
      }
      if (worst < 0) return; // everything pinned
      this.frames.get(worst)!.close();
      this.frames.delete(worst);
      this.bytes -= this.frameBytes;
      this.evictions++;
    }
  }

  clear(): void {
    for (const [k, f] of this.frames) {
      if (this.pins.has(k)) continue;
      f.close();
      this.frames.delete(k);
      this.bytes -= this.frameBytes;
    }
  }

  /** Closes everything, pinned included (dispose). */
  destroy(): void {
    for (const f of this.frames.values()) f.close();
    this.frames.clear();
    this.pins.clear();
    this.bytes = 0;
  }
}
