/**
 * Seek resolution gate for per-frame inputs beyond the screen frame — the
 * webcam's second decode stream (passes/cameraBubble.ts `inputsReady`).
 *
 * The Mac seeks the camera player with zero tolerance alongside the screen
 * player (EditorPlaybackController.syncCameraPlayer), so a parked playhead
 * always shows the webcam frame for that time. The web decodes the camera
 * separately; without this gate a seek resolved on the screen frame alone
 * and a stale (or poster) webcam frame could sit under a "settled" seek.
 *
 * A seek whose screen frame is on screen resolves once every pass has its
 * inputs — or `timeoutMs` after the screen frame was first ready, so a
 * stalled camera decode never hangs a scrub (the camera frame still lands on
 * screen when it decodes: its arrival requests a render). Rendering is never
 * held: the gate only delays the `seeked` answer.
 */
export const SEEK_INPUT_TIMEOUT_MS = 1500;

export class SeekInputGate {
  private readonly since = new Map<number, number>();

  constructor(
    private readonly timeoutMs = SEEK_INPUT_TIMEOUT_MS,
    private readonly now: () => number = () => performance.now(),
  ) {}

  /** Seek `id` has its screen frame on screen: may it resolve now? */
  ready(id: number, inputsReady: boolean): boolean {
    if (inputsReady) {
      this.since.delete(id);
      return true;
    }
    const t = this.now();
    const first = this.since.get(id);
    if (first === undefined) {
      this.since.set(id, t);
      return false;
    }
    if (t - first >= this.timeoutMs) {
      this.since.delete(id);
      return true;
    }
    return false;
  }

  /** The seek resolved or was superseded. */
  forget(id: number): void {
    this.since.delete(id);
  }

  get pending(): number {
    return this.since.size;
  }
}
