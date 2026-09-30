/**
 * Voice-over recording on the editor page: the session (state/voiceOver.ts)
 * bound to the mic key, the timeline's live "Recording Voice Over" block,
 * and the Mac's "Voice Over" error alert through the page's CCAlert presenter.
 *
 * The live block grows with the playhead WITHOUT re-rendering React per
 * frame: while recording, each playhead tick pushes the page's snapshot plus
 * `voice.live` straight into the timeline renderer (the same path the
 * Timeline component uses), and React's own snapshot pushes are followed by
 * one with the live block, so it never flickers out.
 */
import { useCallback, useEffect, useLayoutEffect, useRef, useState, type RefObject } from "react";

import { VOICE_OVER_ALERT_TITLE, type LiveVoiceBlock } from "../../core/audio/voiceOverRecording";
import { VoiceOverRecorder } from "../../record/voiceOverRecorder";
import type { EditorController } from "../../state/controller";
import type { LoadedEditorProject } from "../../state/projectSource";
import type { EditorStore } from "../../state/store";
import { VoiceOverSession } from "../../state/voiceOver";
import { createVoiceOverMedia } from "../../state/voiceOverMedia";
import type { AlertPresenter } from "../kit";
import type { TimelineRenderer } from "../timeline/TimelineRenderer";
import type { TimelineSnapshot } from "../timeline/types";

/** The page's snapshot with the live block in the VOICE row. */
export function withLiveVoice(snapshot: TimelineSnapshot, live: LiveVoiceBlock | null): TimelineSnapshot {
  if (!live) return snapshot;
  return { ...snapshot, voice: { ...(snapshot.voice ?? { clips: [] }), live } };
}

export interface VoiceOverBinding {
  isRecording: boolean;
}

export function useVoiceOver(opts: {
  store: EditorStore;
  controller: EditorController;
  loaded: LoadedEditorProject | null;
  timeline: TimelineSnapshot;
  rendererRef: RefObject<TimelineRenderer | null>;
  /** The page's CCAlert queue — the Mac's `presentVoiceOverError`. */
  alerts: AlertPresenter;
}): VoiceOverBinding {
  const { store, controller, loaded, timeline, rendererRef, alerts } = opts;
  const [isRecording, setRecording] = useState(false);
  const sessionRef = useRef<VoiceOverSession | null>(null);
  const timelineRef = useRef(timeline);
  timelineRef.current = timeline;

  useEffect(() => {
    if (!loaded) return;
    const session = new VoiceOverSession({
      store,
      controller,
      media: createVoiceOverMedia({ media: loaded.media }),
      openRecorder: () => VoiceOverRecorder.open(),
      onAlert: (message) =>
        void alerts.present({ title: VOICE_OVER_ALERT_TITLE, message, buttons: [{ title: "OK", role: "primary" }] }),
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
  }, [loaded, store, controller, alerts]);

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

  return { isRecording };
}
