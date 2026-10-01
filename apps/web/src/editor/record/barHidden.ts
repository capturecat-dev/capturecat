/**
 * Keeping the recorder's own UI out of a web take — the web half of the
 * owner's rule "output video must always hide the recording bar".
 *
 * The Mac never records itself: its panels set `sharingType = .none`. A page
 * can't do that. getDisplayMedia records every visible pixel of a display,
 * and neither a DOM element nor a Picture-in-Picture window can opt out. So
 * the web keeps its UI out of the OUTPUT by construction, per shared surface:
 *
 *   tab      another tab (`selfBrowserSurface: "exclude"`, and the capture
 *            handle proves it isn't THIS one) → nothing of ours is in the
 *            frames; the dock stays
 *   window   it may be this browser's window → the in-page UI (bar, notices,
 *            bubble) hides for the take and the controls float in the
 *            Document Picture-in-Picture window, a separate OS window a
 *            window capture doesn't contain. No PiP → as a display.
 *   display  (also: this tab captured, a window without PiP) → the in-page
 *            UI hides BEFORE the first frame is encoded. When it has to come
 *            back — you return to the tab, or rest the pointer on the bottom
 *            edge — every moment it is on screen is logged on the TAKE's
 *            media clock (first-frame zero, pauses collapsed), and the new
 *            project cuts those moments out, padded: `trimStart`/`trimEnd` at
 *            the ends, clip segments in the middle — exactly what a manual
 *            cut in the editor makes. recording.mov keeps every frame, so
 *            un-cutting in the editor restores them.
 *
 * Pure: the policy, the clock mapping and the cut plan. The events live in
 * useRecorder; the engines (session.ts, mediaRecorderSession.ts) own a
 * TakeTimeline each.
 */
import { newUUID, type Project } from "../core/model";
import type { SurfaceKind } from "./capture";

// ── policy ──────────────────────────────────────────────────────────────────

/**
 * none      the in-page UI can't be in the frames: leave it alone
 * floating  the in-page UI hides for the whole take; the controls are in the
 *           floating (PiP) window
 * reveal    the in-page UI hides; when it must come back it is logged and cut
 */
export type ConcealMode = "none" | "floating" | "reveal";

export interface ConcealInput {
  /** The live share's surface (null = nothing chosen). */
  surface: SurfaceKind | null;
  /** The share is THIS tab (its capture handle is ours) — the picker was told to exclude it. */
  capturesThisTab: boolean;
  /** The floating controls window is open. */
  floatingOpen: boolean;
}

export function concealModeFor(s: ConcealInput): ConcealMode {
  if (!s.surface) return "none";
  if (s.surface === "browser" && !s.capturesThisTab) return "none";
  // A window (or this tab) never contains the separate PiP window; a display does.
  if (s.surface !== "monitor" && s.floatingOpen) return "floating";
  return "reveal";
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

/** When the in-page UI was on screen during a take (wall ms). */
export class RevealLog {
  private readonly spans: WallSpan[] = [];

  get open(): boolean {
    return this.spans.at(-1)?.end === null;
  }

  /** The UI is (about to be) on screen from `at`. */
  reveal(at: number): void {
    if (!this.open) this.spans.push({ start: at, end: null });
  }

  /** The UI is off the screen — and out of every frame captured — from `at`. */
  conceal(at: number): void {
    const last = this.spans.at(-1);
    if (last && last.end === null) last.end = Math.max(at, last.start);
  }

  /** Every span, an open one closed at `endAt`. */
  spansUntil(endAt: number): Array<[number, number]> {
    return this.spans.map((s) => [s.start, s.end ?? Math.max(endAt, s.start)]);
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
