/**
 * Keeping the recorder's own UI out of a web take — the web half of the
 * owner's rules "output video must always hide the recording bar" and "keep
 * it visible at all times — it's the video that hides it".
 *
 * The Mac never records itself: its panels set `sharingType = .none`. A page
 * can't do that. getDisplayMedia records every visible pixel of a display,
 * and neither a DOM element nor a Picture-in-Picture window can opt out. So
 * the controls stay on screen for the person, and the OUTPUT leaves them out,
 * per shared surface:
 *
 *   tab      another tab (`selfBrowserSurface: "exclude"`, and the capture
 *            handle proves it isn't THIS one) → nothing of ours is in the
 *            frames; the dock stays (and floats in Picture-in-Picture too)
 *   window   the controls float in the Document Picture-in-Picture window
 *            (pip.ts), a separate OS window a window capture doesn't contain;
 *            the in-page UI hides (the window may be this browser's).
 *            No PiP (Safari, Firefox, floating off) → the in-page bar STAYS
 *            on screen while you're on the page — and since the shared
 *            window may be this browser's, every moment it's shown is logged
 *            and cut ("shown")
 *   display  the controls float in Picture-in-Picture over every app, and
 *            each recorded frame gets a clean plate painted over that window
 *            (plate.ts: a frame of the display grabbed before the window
 *            appeared, composited by plateWorker.ts between the share and
 *            the encoder; anywhere the window can't be vouched for is cut).
 *            The in-page UI hides — this tab may be on that display.
 *            Where that can't run — Safari (MediaRecorder: no frame access),
 *            no PiP, several displays (which one is shared is unknowable),
 *            the window not found where it's reported — the in-page UI hides
 *            BEFORE the first frame, and every moment it has to come back is
 *            logged on the take's media clock (first-frame zero, pauses
 *            collapsed) and CUT from the new project ("reveal")
 *   this tab (a browser that ignored the exclusion) → PiP when it can
 *            ("floating", the PiP isn't in a tab capture), else "reveal"
 *
 * A cut is exactly what a manual cut in the editor makes: `trimStart` /
 * `trimEnd` at the ends, clip segments in the middle. recording.mov keeps
 * every frame, so un-cutting in the editor restores them.
 *
 * Pure: the policy, the clock mapping and the cut plan. The events live in
 * useRecorder / useConceal / platePipeline; the engines (session.ts,
 * mediaRecorderSession.ts) own a TakeTimeline each.
 */
import { newUUID, type Project } from "../core/model";
import type { SurfaceKind } from "./capture";

// ── policy ──────────────────────────────────────────────────────────────────

/**
 * How a take keeps the page's recorder UI out of its output:
 *
 * none      the share can't contain this page: leave the UI alone
 * floating  the controls are in the floating (PiP) window, which the share
 *           can't contain (a window, this tab); the in-page UI hides for the
 *           take (a dialog that must show is logged and cut)
 * plate     a display: the controls are in the floating window and the share
 *           DOES contain it — every frame is painted over it with the clean
 *           plate (plate.ts); the in-page UI hides as for "floating"
 * shown     a window, no floating window: the in-page UI stays on screen while
 *           you're on the page, and each such moment is logged and cut
 * reveal    a display (or this tab) without floating controls: the in-page UI
 *           hides; whenever it must come back it is logged and cut
 */
export type ConcealMode = "none" | "floating" | "plate" | "shown" | "reveal";

export interface ConcealInput {
  /** The live share's surface (null = nothing chosen). */
  surface: SurfaceKind | null;
  /** The share is THIS tab (its capture handle is ours) — the picker was told to exclude it. */
  capturesThisTab: boolean;
  /** The floating controls window is open. */
  floatingOpen: boolean;
  /**
   * The clean plate paints the floating window out of every frame (a display
   * take on the WebCodecs engine whose window was found where it's reported).
   */
  plateLive: boolean;
}

export function concealModeFor(s: ConcealInput): ConcealMode {
  if (!s.surface) return "none";
  if (s.surface === "browser" && !s.capturesThisTab) return "none";
  if (s.surface === "monitor") {
    // A display contains the floating window: it may only float with the
    // plate painting it out (useRecorder never opens it otherwise).
    return s.floatingOpen && s.plateLive ? "plate" : "reveal";
  }
  // A window (or this tab) never contains the separate PiP window.
  if (s.floatingOpen) return "floating";
  return s.surface === "window" ? "shown" : "reveal";
}

// ── timing ──────────────────────────────────────────────────────────────────

/** The concealed UI's fade — app.css `.rec-conceal` (= --rec-fade). */
export const CONCEAL_FADE_MS = 150;
/**
 * After a style change, how long until no captured frame can still show the
 * old state: ~2 frames for it to reach the screen, plus the capture's own
 * latency (a frame is stamped when the page RECEIVES it, tens of ms after
 * the screen showed it).
 */
export const PAINT_SLACK_MS = 100;
/** Each reveal is cut with this much more on either side (seconds). */
export const REVEAL_PAD = 0.1;
/**
 * A piece left between two cuts (or before the first / after the last) that
 * is shorter than the editor's minimum clip (VIDEO_MIN_DURATION) goes too.
 */
export const MIN_KEEP = 0.5;

// ── the take's media clock ──────────────────────────────────────────────────

export interface WallSpan {
  start: number;
  /** null = still open. */
  end: number | null;
}

/**
 * How a take's file time relates to `performance.now()`: media time 0 is the
 * take's first frame (`zeroMs`), and the clock stands still while paused —
 * both engines drop paused frames and close the gap (mediabunny re-bases
 * timestamps; MediaRecorder resumes where it paused).
 */
export interface TakeClock {
  /** performance.now() (ms) at media time 0. */
  zeroMs: number;
  /** Paused wall intervals (ms), in order, not overlapping; `end` null = still paused. */
  pauses: readonly WallSpan[];
}

/** Recorded (not paused, not before zero) wall milliseconds inside [a, b]. */
function recordedMs(clock: TakeClock, a: number, b: number): number {
  const lo = Math.max(a, clock.zeroMs);
  if (!(b > lo)) return 0;
  let ms = b - lo;
  for (const p of clock.pauses) {
    const s = Math.max(p.start, lo);
    const e = Math.min(p.end ?? b, b);
    if (e > s) ms -= e - s;
  }
  return Math.max(0, ms);
}

/** Media seconds at a wall time: 0 before the first frame, held through a pause. */
export function mediaTimeAt(clock: TakeClock, wallMs: number): number {
  return recordedMs(clock, -Infinity, wallMs) / 1000;
}

/**
 * A wall interval in media seconds — null when none of it was recorded
 * (it ended before the first frame, or sits inside one pause).
 */
export function wallToMedia(clock: TakeClock, a: number, b: number): [number, number] | null {
  if (!(recordedMs(clock, a, b) > 0)) return null;
  return [mediaTimeAt(clock, a), mediaTimeAt(clock, b)];
}

/**
 * Who logged a span: "page" = the in-page recorder UI (useConceal), "plate" =
 * frames the clean plate couldn't vouch for (platePipeline). Each source's
 * spans are sequential; spans of different sources may overlap (the cut
 * merges them).
 */
export type RevealSource = "page" | "plate";

/** When recorder UI was (or may have been) in the frames during a take (wall ms). */
export class RevealLog {
  private readonly spans: Array<WallSpan & { source: RevealSource }> = [];

  /** A span of `source` is open. */
  isOpen(source: RevealSource = "page"): boolean {
    return this.lastOf(source)?.end === null;
  }

  get open(): boolean {
    return this.isOpen("page");
  }

  /** The UI is (about to be) on screen from `at`. */
  reveal(at: number, source: RevealSource = "page"): void {
    if (!this.isOpen(source)) this.spans.push({ start: at, end: null, source });
  }

  /** The UI is off the screen — and out of every frame captured — from `at`. */
  conceal(at: number, source: RevealSource = "page"): void {
    const last = this.lastOf(source);
    if (last && last.end === null) last.end = Math.max(at, last.start);
  }

  /** Every span (any source) in start order, an open one closed at `endAt`. */
  spansUntil(endAt: number): Array<[number, number]> {
    return this.spans
      .map((s): [number, number] => [s.start, s.end ?? Math.max(endAt, s.start)])
      .sort((a, b) => a[0] - b[0]);
  }

  private lastOf(source: RevealSource) {
    for (let i = this.spans.length - 1; i >= 0; i--) if (this.spans[i].source === source) return this.spans[i];
    return undefined;
  }
}

/**
 * One take's clock + reveal log, shared by both engines: zero is set when the
 * first frame is known, pauses as they happen, reveals by the page.
 */
export class TakeTimeline {
  zeroMs: number | null = null;
  readonly pauses: WallSpan[] = [];
  readonly reveals = new RevealLog();

  pause(at: number): void {
    if (this.pauses.at(-1)?.end !== null) this.pauses.push({ start: at, end: null });
  }

  resume(at: number): void {
    const last = this.pauses.at(-1);
    if (last && last.end === null) last.end = Math.max(at, last.start);
  }

  clock(endAt: number, fallbackZero: number): TakeClock {
    return {
      zeroMs: this.zeroMs ?? fallbackZero,
      pauses: this.pauses.map((p) => ({ start: p.start, end: p.end ?? endAt })),
    };
  }

  /** The take's `uiReveals`: media seconds, unpadded, in order (anything left open ends at `endAt`). */
  mediaReveals(endAt: number, fallbackZero: number): Array<[number, number]> {
    const clock = this.clock(endAt, fallbackZero);
    return this.reveals
      .spansUntil(endAt)
      .map(([a, b]) => wallToMedia(clock, a, b))
      .filter((r): r is [number, number] => r !== null);
  }
}

/**
 * DEV-only event log for the recorder-bar-hidden gate
 * (scripts/editor-lab/recorder-bar-hidden.mjs): appended to
 * `globalThis.__ccRecorderProbe` when the harness created that array.
 * Compiled out of production builds.
 */
export function recorderProbe(kind: string, data: Record<string, unknown> = {}): void {
  if (!import.meta.env.DEV) return;
  const log = (globalThis as { __ccRecorderProbe?: unknown }).__ccRecorderProbe;
  if (Array.isArray(log)) log.push({ kind, t: performance.now(), ...data });
}

// ── the cut ─────────────────────────────────────────────────────────────────

export interface RevealCuts {
  /** Source seconds; 0 = nothing cut at the head. */
  trimStart: number;
  /** Source seconds; 0 = nothing cut at the tail (the project's "unset"). */
  trimEnd: number;
  /** The kept source ranges when a cut falls inside the take; null = the trim alone. */
  clips: Array<{ startTime: number; endTime: number }> | null;
  /** What goes, padded and merged (source seconds). */
  removed: Array<[number, number]>;
}

/**
 * Turn a take's reveals (media seconds) into the project's cut: each padded
 * by `pad`, clamped to the take, merged when they overlap or leave less than
 * `minKeep` between them (or before the first / after the last). Null when
 * nothing needs cutting. Everything revealed → an empty trim window.
 */
export function cutsForReveals(
  duration: number,
  reveals: ReadonlyArray<readonly [number, number]>,
  pad = REVEAL_PAD,
  minKeep = MIN_KEEP,
): RevealCuts | null {
  if (!(duration > 0)) return null;
  const clamp = (t: number) => Math.min(duration, Math.max(0, t));
  const padded = reveals
    .filter(([a, b]) => Number.isFinite(a) && Number.isFinite(b))
    .map(([a, b]) => [clamp(Math.min(a, b) - pad), clamp(Math.max(a, b) + pad)] as [number, number])
    .filter(([a, b]) => b > a)
    .sort((x, y) => x[0] - y[0]);
  if (padded.length === 0) return null;

  const removed: Array<[number, number]> = [];
  for (const [a, b] of padded) {
    const last = removed.at(-1);
    if (last && a - last[1] < minKeep) last[1] = Math.max(last[1], b);
    else removed.push([a, b]);
  }
  if (removed[0][0] < minKeep) removed[0][0] = 0;
  const tail = removed[removed.length - 1];
  if (duration - tail[1] < minKeep) tail[1] = duration;

  const keeps: Array<[number, number]> = [];
  let cursor = 0;
  for (const [a, b] of removed) {
    if (a > cursor) keeps.push([cursor, a]);
    cursor = b;
  }
  if (cursor < duration) keeps.push([cursor, duration]);
  if (keeps.length === 0) return { trimStart: duration, trimEnd: duration, clips: null, removed };

  const lastKeep = keeps[keeps.length - 1];
  return {
    trimStart: keeps[0][0],
    trimEnd: lastKeep[1] < duration ? lastKeep[1] : 0,
    clips: keeps.length > 1 ? keeps.map(([startTime, endTime]) => ({ startTime, endTime })) : null,
    removed,
  };
}

/**
 * Write the cut into a new project the way the editor's own edits do:
 * the whole-track trim for the ends (VideoTrackCommits.commitWholeDrag), and
 * for a middle cut the clip list with its split points (deleteVideoClip).
 */
export function applyRevealCuts(project: Project, cuts: RevealCuts | null, newId: () => string = newUUID): void {
  if (!cuts) return;
  project.trimStart = cuts.trimStart;
  project.trimEnd = cuts.trimEnd;
  if (cuts.clips) {
    project.videoClipSegments = cuts.clips.map((c) => ({ id: newId(), startTime: c.startTime, endTime: c.endTime }));
    project.splitPoints = cuts.clips.slice(1).map((c) => c.startTime);
  }
}
