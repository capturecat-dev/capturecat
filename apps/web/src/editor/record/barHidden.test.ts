import { describe, expect, it } from "vitest";

import { newProject } from "../core/model";
import { effectiveTrimEnd, effectiveTrimStart, effectiveVideoClipSegments, hasVisibleVideo } from "../core/time/clips";
import {
  MIN_KEEP,
  REVEAL_PAD,
  RevealLog,
  TakeTimeline,
  applyRevealCuts,
  concealModeFor,
  cutsForReveals,
  mediaTimeAt,
  wallToMedia,
  type TakeClock,
} from "./barHidden";

/** The editor's clip-edge tolerance: a source time within 1/30 s of a clip still shows its frame. */
const EDGE_TOLERANCE = 1 / 30;

let ids = 0;
const nextId = () => `CLIP-${++ids}`;

function projectWith(duration: number, reveals: Array<[number, number]>) {
  const p = newProject({ id: "0B8D6C1E-3A7F-4E2B-9C5D-1F2E3A4B5C6D", duration });
  applyRevealCuts(p, cutsForReveals(duration, reveals), nextId);
  return p;
}

/** Every source time in [a, b] (sampled at 1 ms) shows NO video in the project's output. */
function hiddenThroughout(p: ReturnType<typeof newProject>, a: number, b: number): boolean {
  for (let t = Math.max(0, a); t <= Math.min(p.duration, b) + 1e-9; t += 0.001) {
    if (hasVisibleVideo(p, t)) return false;
  }
  return true;
}

describe("concealModeFor", () => {
  it("leaves the UI alone when nothing is shared, or the share is another tab", () => {
    expect(concealModeFor({ surface: null, capturesThisTab: false, floatingOpen: false })).toBe("none");
    expect(concealModeFor({ surface: "browser", capturesThisTab: false, floatingOpen: false })).toBe("none");
    expect(concealModeFor({ surface: "browser", capturesThisTab: false, floatingOpen: true })).toBe("none");
  });

  it("a window share: floats the controls when it can, else hides like a display", () => {
    expect(concealModeFor({ surface: "window", capturesThisTab: false, floatingOpen: true })).toBe("floating");
    expect(concealModeFor({ surface: "window", capturesThisTab: false, floatingOpen: false })).toBe("reveal");
  });

  it("a display always hides (a PiP window would be recorded too)", () => {
    expect(concealModeFor({ surface: "monitor", capturesThisTab: false, floatingOpen: false })).toBe("reveal");
    expect(concealModeFor({ surface: "monitor", capturesThisTab: false, floatingOpen: true })).toBe("reveal");
  });

  it("this very tab (a browser ignored selfBrowserSurface: exclude) is treated like a display", () => {
    expect(concealModeFor({ surface: "browser", capturesThisTab: true, floatingOpen: false })).toBe("reveal");
    expect(concealModeFor({ surface: "browser", capturesThisTab: true, floatingOpen: true })).toBe("floating");
  });
});

describe("the take's media clock", () => {
  const clock: TakeClock = {
    zeroMs: 1000,
    pauses: [
      { start: 3000, end: 4000 },
      { start: 6000, end: 6500 },
    ],
  };

  it("zeroes at the first frame", () => {
    expect(mediaTimeAt(clock, 0)).toBe(0);
    expect(mediaTimeAt(clock, 1000)).toBe(0);
    expect(mediaTimeAt(clock, 1500)).toBeCloseTo(0.5, 9);
  });

  it("stands still through a pause and closes the gap after it", () => {
    expect(mediaTimeAt(clock, 3000)).toBeCloseTo(2, 9);
    expect(mediaTimeAt(clock, 3600)).toBeCloseTo(2, 9);
    expect(mediaTimeAt(clock, 4000)).toBeCloseTo(2, 9);
    expect(mediaTimeAt(clock, 4250)).toBeCloseTo(2.25, 9);
    expect(mediaTimeAt(clock, 6250)).toBeCloseTo(4, 9);
    expect(mediaTimeAt(clock, 7500)).toBeCloseTo(5, 9);
  });

  it("an open pause holds the clock to the end", () => {
    const open: TakeClock = { zeroMs: 0, pauses: [{ start: 2000, end: null }] };
    expect(mediaTimeAt(open, 9000)).toBeCloseTo(2, 9);
  });

  it("maps a wall span, or drops it when none of it was recorded", () => {
    expect(wallToMedia(clock, 1500, 2500)).toEqual([0.5, 1.5]);
    // Spanning a pause: contiguous in media time.
    const across = wallToMedia(clock, 2500, 4500)!;
    expect(across[0]).toBeCloseTo(1.5, 9);
    expect(across[1]).toBeCloseTo(2.5, 9);
    // Starting inside a pause: from where the clock resumed.
    const fromPause = wallToMedia(clock, 3500, 4500)!;
    expect(fromPause[0]).toBeCloseTo(2, 9);
    expect(fromPause[1]).toBeCloseTo(2.5, 9);
    // Entirely inside a pause, or before the first frame: never recorded.
    expect(wallToMedia(clock, 3100, 3900)).toBeNull();
    expect(wallToMedia(clock, 200, 900)).toBeNull();
    // Overlapping the first frame: from 0.
    expect(wallToMedia(clock, 500, 1200)).toEqual([0, expect.closeTo(0.2, 9)]);
  });
});

describe("RevealLog / TakeTimeline", () => {
  it("logs spans; a second reveal or a stray conceal changes nothing", () => {
    const log = new RevealLog();
    log.conceal(50);
    log.reveal(100);
    log.reveal(150);
    expect(log.open).toBe(true);
    log.conceal(300);
    log.conceal(400);
    expect(log.open).toBe(false);
    log.reveal(500);
    expect(log.spansUntil(900)).toEqual([
      [100, 300],
      [500, 900],
    ]);
  });

  it("turns wall reveals into media reveals on the take's clock (first-frame offset, pauses)", () => {
    const tl = new TakeTimeline();
    tl.zeroMs = 2000;
    tl.reveals.reveal(1500); // came back while the take was starting
    tl.reveals.conceal(2400);
    tl.pause(5000);
    tl.reveals.reveal(5200); // inside the pause: never recorded
    tl.reveals.conceal(5600);
    tl.reveals.reveal(5800); // straddles the resume
    tl.resume(6000);
    tl.reveals.conceal(6300);
    tl.reveals.reveal(9000); // came back to stop: still open at stop
    const r = tl.mediaReveals(9500, 0);
    expect(r).toHaveLength(3);
    expect(r[0]).toEqual([0, expect.closeTo(0.4, 9)]);
    expect(r[1][0]).toBeCloseTo(3, 9);
    expect(r[1][1]).toBeCloseTo(3.3, 9);
    expect(r[2][0]).toBeCloseTo(6, 9);
    expect(r[2][1]).toBeCloseTo(6.5, 9);
  });

  it("stopping while paused closes the pause at stop", () => {
    const tl = new TakeTimeline();
    tl.zeroMs = 0;
    tl.pause(4000);
    tl.reveals.reveal(4500);
    expect(tl.mediaReveals(8000, 0)).toEqual([]);
  });
});

describe("cutsForReveals", () => {
  it("nothing revealed → nothing cut", () => {
    expect(cutsForReveals(20, [])).toBeNull();
    expect(cutsForReveals(0, [[1, 2]])).toBeNull();
    expect(cutsForReveals(20, [[Number.NaN, 2]])).toBeNull();
  });

  it("a middle reveal → two clips around it, padded", () => {
    const c = cutsForReveals(20, [[5, 7]])!;
    expect(c.trimStart).toBe(0);
    expect(c.trimEnd).toBe(0);
    expect(c.removed).toEqual([[5 - REVEAL_PAD, 7 + REVEAL_PAD]]);
    expect(c.clips).toEqual([
      { startTime: 0, endTime: 5 - REVEAL_PAD },
      { startTime: 7 + REVEAL_PAD, endTime: 20 },
    ]);
  });

  it("a reveal at the very start → trimStart only", () => {
    const c = cutsForReveals(20, [[0, 1.2]])!;
    expect(c.trimStart).toBeCloseTo(1.2 + REVEAL_PAD, 9);
    expect(c.trimEnd).toBe(0);
    expect(c.clips).toBeNull();
  });

  it("a tail reveal (came back to stop) → trimEnd only", () => {
    const c = cutsForReveals(20, [[17.5, 20.3]])!;
    expect(c.trimStart).toBe(0);
    expect(c.trimEnd).toBeCloseTo(17.5 - REVEAL_PAD, 9);
    expect(c.clips).toBeNull();
    expect(c.removed).toEqual([[17.5 - REVEAL_PAD, 20]]);
  });

  it("head, middle and tail together", () => {
    const c = cutsForReveals(30, [
      [0, 1],
      [10, 12],
      [28, 30],
    ])!;
    expect(c.trimStart).toBeCloseTo(1.1, 9);
    expect(c.trimEnd).toBeCloseTo(27.9, 9);
    expect(c.clips).toEqual([
      { startTime: expect.closeTo(1.1, 9), endTime: expect.closeTo(9.9, 9) },
      { startTime: expect.closeTo(12.1, 9), endTime: expect.closeTo(27.9, 9) },
    ]);
  });

  it("overlapping reveals merge; so do ones that would leave a sliver between them", () => {
    expect(cutsForReveals(20, [[5, 7], [6, 8]])!.removed).toEqual([[4.9, 8.1]]);
    // 7.1 … 7.4 would be a 0.3 s clip (< MIN_KEEP): cut with them.
    const c = cutsForReveals(20, [[5, 7], [7.5, 9]])!;
    expect(c.removed).toEqual([[4.9, 9.1]]);
    expect(c.clips).toHaveLength(2);
    // Far enough apart: two cuts, three clips.
    expect(cutsForReveals(20, [[5, 7], [7.2 + MIN_KEEP + 0.01, 9]])!.clips).toHaveLength(3);
  });

  it("slivers at the head or tail go too", () => {
    const c = cutsForReveals(20, [
      [0.5, 2],
      [19.1, 19.6],
    ])!;
    expect(c.trimStart).toBeCloseTo(2.1, 9);
    expect(c.trimEnd).toBeCloseTo(19.0, 9);
    expect(c.clips).toBeNull();
  });

  it("revealed throughout → an empty trim window (nothing of it is output)", () => {
    const c = cutsForReveals(5, [[0, 5]])!;
    expect(c.trimStart).toBe(5);
    expect(c.trimEnd).toBe(5);
    const p = projectWith(5, [[0, 5]]);
    expect(effectiveVideoClipSegments(p)).toEqual([]);
    expect(hiddenThroughout(p, 0, 5)).toBe(true);
  });
});

describe("applyRevealCuts → what the editor and exporter show", () => {
  it("a middle cut is the editor's own clip list (ids, split points)", () => {
    const p = projectWith(20, [[5, 7]]);
    expect(p.videoClipSegments.map((c) => [c.startTime, c.endTime])).toEqual([
      [0, 4.9],
      [7.1, 20],
    ]);
    expect(p.videoClipSegments.every((c) => /^CLIP-\d+$/.test(c.id))).toBe(true);
    expect(p.splitPoints).toEqual([7.1]);
    expect(effectiveVideoClipSegments(p).map((c) => [c.startTime, c.endTime])).toEqual([
      [0, 4.9],
      [7.1, 20],
    ]);
  });

  it("no frame inside a reveal is visible — even with the clip-edge tolerance", () => {
    const reveals: Array<[number, number]> = [
      [0, 0.8],
      [4.2, 5.05],
      [9.7, 9.9],
      [13.3, 15.1],
    ];
    const p = projectWith(15.1, reveals);
    for (const [a, b] of reveals) expect(hiddenThroughout(p, a, b)).toBe(true);
    // …and the pad really is margin beyond the tolerance.
    for (const [a, b] of reveals) expect(hiddenThroughout(p, a - (REVEAL_PAD - EDGE_TOLERANCE) + 0.002, b + (REVEAL_PAD - EDGE_TOLERANCE) - 0.002)).toBe(true);
    // The kept stretches still play.
    for (const t of [2, 7, 11.5]) expect(hasVisibleVideo(p, t)).toBe(true);
    expect(effectiveTrimStart(p)).toBeCloseTo(0.9, 9);
    expect(effectiveTrimEnd(p)).toBeCloseTo(13.2, 9);
  });

  it("a take without reveals is untouched (old takes, tab shares)", () => {
    const p = newProject({ duration: 12 });
    const before = JSON.stringify(p);
    applyRevealCuts(p, cutsForReveals(12, []));
    expect(JSON.stringify(p)).toBe(before);
  });

  it("end to end: wall reveals on a paused take never reach the output", () => {
    const tl = new TakeTimeline();
    tl.zeroMs = 10_350; // first frame 350 ms after Record's clock origin
    const reveals: Array<[number, number]> = [
      [12_000, 13_400], // came back, left
      [14_900, 16_200], // came back, paused inside, …
      [20_000, 23_000], // came back to stop (closed at stop)
    ];
    tl.reveals.reveal(reveals[0][0]);
    tl.reveals.conceal(reveals[0][1]);
    tl.reveals.reveal(reveals[1][0]);
    tl.pause(15_200);
    tl.resume(15_900); // … and resumed before leaving
    tl.reveals.conceal(reveals[1][1]);
    tl.reveals.reveal(reveals[2][0]);
    const stopAt = 23_000;
    const media = tl.mediaReveals(stopAt, 0);
    const duration = mediaTimeAt(tl.clock(stopAt, 0), stopAt);
    const p = projectWith(duration, media);
    const clock = tl.clock(stopAt, 0);
    for (const [a, b] of reveals) {
      for (let w = a; w <= b; w += 5) expect(hasVisibleVideo(p, mediaTimeAt(clock, w))).toBe(false);
    }
    // Recorded, never revealed: kept.
    expect(hasVisibleVideo(p, mediaTimeAt(clock, 11_000))).toBe(true);
    expect(hasVisibleVideo(p, mediaTimeAt(clock, 18_000))).toBe(true);
    expect(p.trimEnd).toBeGreaterThan(0);
  });
});
