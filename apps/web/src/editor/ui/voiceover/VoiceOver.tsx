/**
 * Voice-over recording on the editor page: the session (state/voiceOver.ts)
 * bound to the mic key, the timeline's live "Recording Voice Over" block,
 * and the house "Voice Over" alert (CCAlert) for the Mac's error messages.
 *
 * The live block grows with the playhead WITHOUT re-rendering React per
 * frame: while recording, each playhead tick pushes the page's snapshot plus
 * `voice.live` straight into the timeline renderer (the same path the
 * Timeline component uses), and React's own snapshot pushes are followed by
 * one with the live block, so it never flickers out.
 */
import { useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode, type RefObject } from "react";
import { createPortal } from "react-dom";

import { VOICE_OVER_ALERT_TITLE, type LiveVoiceBlock } from "../../core/audio/voiceOverRecording";
import { VoiceOverRecorder } from "../../record/voiceOverRecorder";
import type { EditorController } from "../../state/controller";
import type { LoadedEditorProject } from "../../state/projectSource";
import type { EditorStore } from "../../state/store";
import { UploadGate, VoiceOverSession } from "../../state/voiceOver";
import { createVoiceOverMedia } from "../../state/voiceOverMedia";
import { Button, useCCTheme } from "../kit";
import { animateCurve, animateSpring, curves } from "../kit/motion";
import type { TimelineRenderer } from "../timeline/TimelineRenderer";
import type { TimelineSnapshot } from "../timeline/types";

/** The page's snapshot with the live block in the VOICE row. */
export function withLiveVoice(snapshot: TimelineSnapshot, live: LiveVoiceBlock | null): TimelineSnapshot {
  if (!live) return snapshot;
  return { ...snapshot, voice: { ...(snapshot.voice ?? { clips: [] }), live } };
}

export interface VoiceOverBinding {
  isRecording: boolean;
  /** The alert element (render inside ThemeRoot). */
  alert: ReactNode;
}

export function useVoiceOver(opts: {
  store: EditorStore;
  controller: EditorController;
  loaded: LoadedEditorProject | null;
  uploads: UploadGate;
  timeline: TimelineSnapshot;
  rendererRef: RefObject<TimelineRenderer | null>;
}): VoiceOverBinding {
  const { store, controller, loaded, uploads, timeline, rendererRef } = opts;
  const [isRecording, setRecording] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const sessionRef = useRef<VoiceOverSession | null>(null);
  const timelineRef = useRef(timeline);
  timelineRef.current = timeline;

  useEffect(() => {
    if (!loaded) return;
    const session = new VoiceOverSession({
      store,
      controller,
      media: createVoiceOverMedia({ loaded, store, controller, uploads }),
      openRecorder: () => VoiceOverRecorder.open(),
      onAlert: setMessage,
      onChange: () => setRecording(session.isRecording),
    });
    sessionRef.current = session;
    controller.hooks.toggleVoiceOver = () => void session.toggle();
    if (import.meta.env.DEV) {
      const w = window as unknown as { __editor?: Record<string, unknown> };
      if (w.__editor) w.__editor.voiceOver = session;
    }
    return () => {
      session.dispose();
      if (sessionRef.current === session) sessionRef.current = null;
      if (controller.hooks.toggleVoiceOver) controller.hooks.toggleVoiceOver = undefined;
      setRecording(false);
    };
  }, [loaded, store, controller, uploads]);

  const push = useCallback(() => {
    const renderer = rendererRef.current;
    if (!renderer) return;
    const live = sessionRef.current?.live(controller.playhead.get()) ?? null;
    renderer.setSnapshot(withLiveVoice(timelineRef.current, live));
  }, [controller, rendererRef]);

  // After React hands the renderer a new snapshot, re-add the live block.
  useLayoutEffect(() => {
    if (isRecording) push();
  }, [timeline, isRecording, push]);

  // Grow with the playhead (and the meter) while recording; clear after.
  const wasRecording = useRef(false);
  useEffect(() => {
    if (!isRecording) {
      if (wasRecording.current) rendererRef.current?.setSnapshot(timelineRef.current);
      wasRecording.current = false;
      return;
    }
    wasRecording.current = true;
    let frame = 0;
    const schedule = () => {
      if (!frame) {
        frame = requestAnimationFrame(() => {
          frame = 0;
          push();
        });
      }
    };
    const unsubscribe = controller.playhead.subscribe(schedule);
    schedule();
    return () => {
      unsubscribe();
      if (frame) cancelAnimationFrame(frame);
    };
  }, [isRecording, controller, push, rendererRef]);

  const alert = message ? <VoiceOverAlert message={message} onClose={() => setMessage(null)} /> : null;
  return { isRecording, alert };
}

/**
 * CCAlert(title: "Voice Over", message:) with one primary "OK" — the Mac's
 * `presentVoiceOverError`: scrim fade + Keynote scale-in, title over a muted
 * message (≤ 296 wide), the button trailing; Return/Escape dismiss.
 */
export function VoiceOverAlert({ message, onClose }: { message: string; onClose: () => void }) {
  const { portal } = useCCTheme();
  const cardRef = useRef<HTMLDivElement>(null);
  const scrimRef = useRef<HTMLDivElement>(null);
  const [top, setTop] = useState<number | null>(null);
  const closing = useRef(false);

  const dismiss = useCallback(() => {
    if (closing.current) return;
    closing.current = true;
    const card = cardRef.current;
    const scrim = scrimRef.current;
    if (!card || !scrim) return onClose();
    animateSpring(card, [{ transform: "scale(1)" }, { transform: "scale(0.97)" }], "snappy");
    animateCurve(scrim, [{ opacity: 1 }, { opacity: 0 }], { duration: 0.18, curve: curves.glide });
    const a = animateCurve(card, [{ opacity: 1 }, { opacity: 0 }], { duration: 0.18, curve: curves.glide });
    if (!a) return onClose();
    a.addEventListener("finish", onClose, { once: true });
  }, [onClose]);

  useLayoutEffect(() => {
    const card = cardRef.current;
    if (!card) return;
    // CCAlert centres on the parent, nudged 20pt above the middle.
    setTop(Math.max(16, Math.round((window.innerHeight - card.offsetHeight) / 2 - 20)));
    card.style.transformOrigin = "50% 50%";
    animateSpring(card, [{ transform: "scale(0.96)" }, { transform: "scale(1)" }], "smooth");
    animateCurve(card, [{ opacity: 0 }, { opacity: 1 }], { duration: 0.22, curve: curves.glide });
    if (scrimRef.current) animateCurve(scrimRef.current, [{ opacity: 0 }, { opacity: 1 }], { duration: 0.22, curve: curves.glide });
    card.querySelector<HTMLButtonElement>("button")?.focus({ preventScroll: true });
  }, [portal]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape" && e.key !== "Enter") return;
      e.preventDefault();
      e.stopPropagation();
      dismiss();
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [dismiss]);

  if (!portal) return null;
  const width = typeof window === "undefined" ? 340 : Math.max(280, Math.min(340, window.innerWidth - 32));
  return createPortal(
    <div className="cc-export" data-voice-over-alert="">
      <div ref={scrimRef} className="cc-export__scrim" onPointerDown={(e) => e.target === e.currentTarget && e.preventDefault()} />
      <div
        ref={cardRef}
        className="cc-dialog cc-mat-matte"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="cc-voice-over-alert-title"
        aria-describedby="cc-voice-over-alert-message"
        style={{ width, top: top ?? undefined, visibility: top === null ? "hidden" : undefined, gap: "var(--cc-space-sm)" }}
      >
        <div id="cc-voice-over-alert-title" className="cc-dialog__title">
          {VOICE_OVER_ALERT_TITLE}
        </div>
        <div
          id="cc-voice-over-alert-message"
          style={{ fontSize: 12, lineHeight: "16px", color: "var(--cc-muted)", maxWidth: 296 }}
        >
          {message}
        </div>
        <div className="cc-dialog__footer" style={{ marginTop: "var(--cc-space-sm)" }}>
          <Button variant="primary" onClick={dismiss}>
            OK
          </Button>
        </div>
      </div>
    </div>,
    portal,
  );
}
