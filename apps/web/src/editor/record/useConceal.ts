/**
 * useConceal — the page half of barHidden.ts. During a take whose share could
 * contain this page, the recorder UI (dock, notices, bubble, the Record
 * page's live chrome) is off screen; in "reveal" mode it comes back when you
 * come back for it:
 *
 *   return   the tab becomes visible / the window regains focus after you
 *            left it (switched tab, app or window) — to stop, usually
 *   edge     the pointer rests on the bottom edge of the page (focused) for
 *            EDGE_DWELL_MS; it hides again once the pointer leaves the dock
 *   dialog   recorder UI outside the dock has to show (the "A recording is
 *            in progress" leave-route dialog) — `showFor` / `hideAfter`
 *
 * and hides again when you leave. Every reveal is logged on the take
 * (`markUi`) BEFORE the UI renders, and its end only once the fade and a
 * capture's latency have passed — so the logged span always contains every
 * frame that can show it. Publishing cuts those spans out.
 */
import { useCallback, useEffect, useRef, useState, type RefObject } from "react";

import { CONCEAL_FADE_MS, PAINT_SLACK_MS, recorderProbe, type ConcealMode } from "./barHidden";
import type { TakeRecorder } from "./takeRecorder";

/** How close to the bottom edge (px) the pointer must rest… */
export const EDGE_PX = 6;
/** …and for how long (ms) before the dock comes up. */
export const EDGE_DWELL_MS = 300;
/** An edge reveal hides this long (ms) after the pointer leaves the dock. */
export const EDGE_LEAVE_MS = 700;
/**
 * A share switched TO this tab mid-take ("Share this tab instead"): its
 * capturehandlechange event arrives after the new surface's first frames, so
 * the logged span starts this much earlier.
 */
const SWITCH_LEAD_MS = 250;

export type RevealReason = "return" | "edge" | "dialog";

function nextFrame(): Promise<void> {
  // rAF stalls in a hidden tab; a hidden tab isn't on screen anyway.
  return new Promise((resolve) => {
    const t = window.setTimeout(resolve, 100);
    requestAnimationFrame(() => {
      window.clearTimeout(t);
      resolve();
    });
  });
}

/**
 * Wait until a style change has left the screen — committed, faded for
 * `fadeMs`, two frames presented (`offScreen`; at once while the tab is
 * hidden) — and then out of the capture pipeline too: a recorder can start
 * on the newest frame already delivered, so wait out the capture's latency
 * (`ready`). A take that starts after `ready` can't contain it.
 */
export async function untilOffScreen(fadeMs: number): Promise<{ offScreen: number; ready: number }> {
  const onScreen = () => document.visibilityState !== "hidden";
  if (onScreen()) {
    await nextFrame();
    await nextFrame();
    if (fadeMs > 0) await new Promise((r) => setTimeout(r, fadeMs));
    if (onScreen()) {
      await nextFrame();
      await nextFrame();
    }
  }
  const offScreen = performance.now();
  await new Promise((r) => setTimeout(r, PAINT_SLACK_MS));
  return { offScreen, ready: performance.now() };
}

function pageAway(): boolean {
  return document.visibilityState === "hidden" || !document.hasFocus();
}

export interface Conceal {
  /** The in-page recorder UI must be off screen right now. */
  hidden: boolean;
  /** Mid-take, it is on screen and being logged for the cut ("reveal" mode). */
  revealed: RevealReason | null;
  /** A take is about to start: hide (in `mode`) and resolve once no frame can show the UI. */
  hideForTake: (mode: ConcealMode, extraMs?: number) => Promise<number>;
  /** The take is over (stopped, deleted, failed to start): the UI is back. */
  release: () => void;
  /** Some recorder UI must show mid-take (a dialog): log it like a return. No-op when nothing is concealed. */
  showFor: (reason: RevealReason) => void;
  /** …and it's gone again: conceal, unless something else revealed the UI meanwhile. */
  hideAfter: (reason: RevealReason) => void;
}

export function useConceal({
  mode,
  sessionRef,
}: {
  mode: ConcealMode;
  sessionRef: RefObject<TakeRecorder | null>;
}): Conceal {
  const [live, setLive] = useState(false);
  const [revealed, setRevealed] = useState<RevealReason | null>(null);
  const revealedRef = useRef<RevealReason | null>(null);
  const awayRef = useRef(false);

  const loggable = useCallback(() => {
    const s = sessionRef.current;
    // A session exists from the moment its outputs start (state "idle"
    // while it waits for first frames — those frames are already encoded).
    return s && s.state !== "stopping" && s.state !== "stopped" && s.state !== "discarded" ? s : null;
  }, [sessionRef]);

  const reveal = useCallback(
    (reason: RevealReason) => {
      if (revealedRef.current) return;
      const s = loggable();
      if (!s) return;
      const at = performance.now();
      s.markUi(true, at); // logged first: the UI can't reach a frame before this
      revealedRef.current = reason;
      setRevealed(reason);
      recorderProbe("reveal", { at, reason });
    },
    [loggable],
  );

  const conceal = useCallback(() => {
    if (!revealedRef.current) return;
    const at = performance.now();
    // Off the screen once the fade has run and the last frame showing it has been captured.
    const end = at + CONCEAL_FADE_MS + PAINT_SLACK_MS;
    sessionRef.current?.markUi(false, end);
    revealedRef.current = null;
    setRevealed(null);
    recorderProbe("hide", { at, end });
  }, [sessionRef]);

  // A share that stops containing this page (a tab share switched to
  // another tab) needs nothing hidden any more; one that starts containing
  // it mid-take (switched TO this tab) had the UI in its frames until the
  // hide lands — log that span.
  const prevMode = useRef(mode);
  useEffect(() => {
    const was = prevMode.current;
    prevMode.current = mode;
    recorderProbe("mode", { mode, was, live });
    if (!live) return;
    if (mode !== "reveal") conceal();
    if (was === "none" && mode !== "none") {
      const s = loggable();
      if (s) {
        const at = performance.now();
        // The switch event trails the first frames of the new surface.
        const end = at + CONCEAL_FADE_MS + PAINT_SLACK_MS;
        s.markUi(true, at - SWITCH_LEAD_MS);
        s.markUi(false, end);
        recorderProbe("reveal", { at: at - SWITCH_LEAD_MS, reason: "switch" });
        recorderProbe("hide", { at, end });
      }
      awayRef.current = pageAway();
    }
  }, [mode, live, conceal, loggable]);

  // "reveal" mode: come back for it, and it's there.
  useEffect(() => {
    if (!live || mode !== "reveal") return;
    awayRef.current ||= pageAway();
    let dwell = 0;
    let leave = 0;
    const clearDwell = () => {
      window.clearTimeout(dwell);
      dwell = 0;
    };
    const clearLeave = () => {
      window.clearTimeout(leave);
      leave = 0;
    };
    const left = () => {
      awayRef.current = true;
      clearDwell();
      clearLeave();
      conceal();
    };
    const back = () => {
      if (!awayRef.current || document.visibilityState === "hidden" || !document.hasFocus()) return;
      awayRef.current = false;
      reveal("return");
    };
    const onVisibility = () => (document.visibilityState === "hidden" ? left() : back());
    const onPointerMove = (e: PointerEvent) => {
      const h = window.innerHeight;
      if (!revealedRef.current) {
        clearLeave();
        if (document.hasFocus() && e.clientY >= h - EDGE_PX) {
          if (!dwell) dwell = window.setTimeout(() => ((dwell = 0), reveal("edge")), EDGE_DWELL_MS);
        } else clearDwell();
        return;
      }
      if (revealedRef.current !== "edge") return;
      const dock = document.querySelector<HTMLElement>("[data-recorder-dock]")?.getBoundingClientRect();
      const top = dock && dock.height > 0 ? dock.top - 24 : h - 120;
      if (e.clientY < top) {
        if (!leave) leave = window.setTimeout(() => ((leave = 0), conceal()), EDGE_LEAVE_MS);
      } else clearLeave();
    };
    const onPointerOut = (e: PointerEvent) => {
      if (e.relatedTarget) return; // still inside the page
      clearDwell();
      if (revealedRef.current === "edge" && !leave) leave = window.setTimeout(() => ((leave = 0), conceal()), EDGE_LEAVE_MS);
    };
    document.addEventListener("visibilitychange", onVisibility);
    window.addEventListener("blur", left);
    window.addEventListener("focus", back);
    window.addEventListener("pointermove", onPointerMove, { passive: true });
    document.addEventListener("pointerout", onPointerOut);
    return () => {
      clearDwell();
      clearLeave();
      document.removeEventListener("visibilitychange", onVisibility);
      window.removeEventListener("blur", left);
      window.removeEventListener("focus", back);
      window.removeEventListener("pointermove", onPointerMove);
      document.removeEventListener("pointerout", onPointerOut);
    };
  }, [live, mode, reveal, conceal]);

  const hideForTake = useCallback(
    async (takeMode: ConcealMode, extraMs = 0) => {
      // A restart hides a revealed dock again; the old take's log goes with it.
      revealedRef.current = null;
      setRevealed(null);
      setLive(true);
      awayRef.current = pageAway();
      const at = performance.now();
      if (takeMode === "none") return at;
      const { offScreen, ready } = await untilOffScreen(Math.max(CONCEAL_FADE_MS, extraMs));
      recorderProbe("conceal", { at, offScreen, painted: ready, mode: takeMode });
      return ready;
    },
    [],
  );

  const release = useCallback(() => {
    revealedRef.current = null;
    setRevealed(null);
    setLive(false);
  }, []);

  const liveRef = useRef(live);
  liveRef.current = live;
  const modeRef = useRef(mode);
  modeRef.current = mode;
  const showFor = useCallback(
    (reason: RevealReason) => {
      if (liveRef.current && modeRef.current !== "none") reveal(reason);
    },
    [reveal],
  );
  const hideAfter = useCallback(
    (reason: RevealReason) => {
      if (revealedRef.current === reason) conceal();
    },
    [conceal],
  );

  return {
    hidden: live && mode !== "none" && !(mode === "reveal" && revealed !== null),
    revealed: live && mode === "reveal" ? revealed : null,
    hideForTake,
    release,
    showFor,
    hideAfter,
  };
}
