/**
 * EditorShell — top bar + [ stage over timeline | 1px divider | inspector ],
 * the web twin of EditorWindowContentViewController + EditorShellViewController.
 *
 * Chrome state the shell owns (like EditorShellSelection's chrome half):
 * inspector visibility (persisted per viewer) and width (340…480, drag the
 * divider), the selected tab (uncontrolled unless `inspectorTab` is passed),
 * preview zoom, timeline horizontal scale, and the EFFECTS sub-row count
 * that grows the timeline panel. Everything the user DOES goes out through
 * `callbacks` / `timelineIntents`.
 */
import { useCallback, useEffect, useRef, useState, type CSSProperties, type PointerEvent as ReactPointerEvent } from "react";

import { ContextMenu, tween, type MenuEntry } from "../kit";
import { curves } from "../kit/motion";
import { panelHeight } from "../timeline/metrics";
import { Timeline } from "../timeline/Timeline";
import type { ContextMenuRequest, TimelineRenderer } from "../timeline/TimelineRenderer";
import { Inspector, RevealTab } from "./Inspector";
import { Stage } from "./Stage";
import { timelineMenu } from "./timelineMenus";
import { TopBar } from "./TopBar";
import { TransportBar } from "./TransportBar";
import type { EditorShellProps, InspectorTabId } from "./types";

const INSPECTOR_MIN = 340;
const INSPECTOR_MAX = 480;
const INSPECTOR_DEFAULT = 380;
const VISIBLE_KEY = "cc.editor.inspectorVisible";
const WIDTH_KEY = "cc.editor.inspectorWidth";

function readStored<T>(key: string, parse: (s: string) => T | null): T | null {
  try {
    const raw = window.localStorage.getItem(key);
    return raw == null ? null : parse(raw);
  } catch {
    return null;
  }
}
function writeStored(key: string, value: string) {
  try {
    window.localStorage.setItem(key, value);
  } catch {
    /* ignore */
  }
}

export function EditorShell(props: EditorShellProps & { timelineRendererRef?: { current: TimelineRenderer | null } }) {
  const { project, transport, playhead, callbacks, timeline, timelineIntents, stage, panes, topBarAccessory } = props;

  const [tabState, setTabState] = useState<InspectorTabId>(props.inspectorTab ?? "background");
  const tab = props.inspectorTab ?? tabState;
  const selectTab = useCallback(
    (next: InspectorTabId) => {
      setTabState(next);
      callbacks.onInspectorTabChange?.(next);
    },
    [callbacks],
  );

  // ── Inspector visibility + width (animated, divider-resizable) ────────
  const [visible, setVisible] = useState(true);
  const [width, setWidth] = useState(INSPECTOR_DEFAULT);
  const colRef = useRef<HTMLDivElement>(null);
  const liveWidth = useRef(INSPECTOR_DEFAULT);
  const cancelTween = useRef<() => void>(() => {});

  useEffect(() => {
    const storedVisible = readStored(VISIBLE_KEY, (s) => s === "true");
    const storedWidth = readStored(WIDTH_KEY, (s) => Number.parseFloat(s) || null);
    const w = Math.min(INSPECTOR_MAX, Math.max(INSPECTOR_MIN, storedWidth ?? INSPECTOR_DEFAULT));
    setWidth(w);
    if (storedVisible === false) {
      setVisible(false);
      liveWidth.current = 0;
      colRef.current?.style.setProperty("--insp-w", "0px");
    } else {
      liveWidth.current = w;
      colRef.current?.style.setProperty("--insp-w", `${w}px`);
    }
  }, []);

  const setInspectorVisible = useCallback(
    (show: boolean) => {
      setVisible(show);
      writeStored(VISIBLE_KEY, String(show));
      cancelTween.current();
      const from = liveWidth.current;
      const to = show ? width : 0;
      // Growth lands on the house bounce (pushed edge only); the collapse
      // settles — NSSplitView's animated collapse, CCMotion-curved.
      cancelTween.current = tween(
        from,
        to,
        (v) => {
          liveWidth.current = v;
          colRef.current?.style.setProperty("--insp-w", `${Math.max(0, v)}px`);
        },
        { duration: show ? 0.38 : 0.28, curve: show ? curves.bounce : curves.settle },
      );
    },
    [width],
  );

  // Selecting a region / effect / annotation re-shows a collapsed inspector
  // (the Mac's `selection.showInspector = true`).
  const revealKey = props.inspectorRevealKey;
  const lastReveal = useRef(revealKey);
  useEffect(() => {
    if (revealKey === lastReveal.current) return;
    lastReveal.current = revealKey;
    if (!visible) setInspectorVisible(true);
  }, [revealKey, visible, setInspectorVisible]);

  // Divider drag → live width (clamped 340…480), committed + persisted on release.
  const onDividerDown = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (!visible || e.button !== 0) return;
    e.currentTarget.setPointerCapture(e.pointerId);
    const startX = e.clientX;
    const startW = liveWidth.current;
    const el = e.currentTarget;
    const move = (ev: PointerEvent) => {
      const w = Math.min(INSPECTOR_MAX, Math.max(INSPECTOR_MIN, startW + (startX - ev.clientX)));
      liveWidth.current = w;
      colRef.current?.style.setProperty("--insp-w", `${w}px`);
      colRef.current?.style.setProperty("--insp-open", `${w}px`);
    };
    const up = () => {
      el.removeEventListener("pointermove", move);
      el.removeEventListener("pointerup", up);
      el.removeEventListener("pointercancel", up);
      setWidth(liveWidth.current);
      writeStored(WIDTH_KEY, String(liveWidth.current));
    };
    el.addEventListener("pointermove", move);
    el.addEventListener("pointerup", up);
    el.addEventListener("pointercancel", up);
  };

  // ── Preview zoom, timeline scale, panel growth ───────────────────────
  const [zoom, setZoom] = useState(1);
  const onZoom = (z: number) => {
    setZoom(z);
    callbacks.onPreviewZoomChange?.(z);
  };
  const [scale, setScale] = useState(1);
  const [effectsRows, setEffectsRows] = useState(1);
  const [menu, setMenu] = useState<{ at: { x: number; y: number }; entries: MenuEntry[] } | null>(null);

  const onContextMenu = useCallback(
    (req: ContextMenuRequest) => {
      const entries = timelineMenu(req, (a) => timelineIntents.action?.(a));
      if (entries?.length) setMenu({ at: { x: req.clientX, y: req.clientY }, entries });
    },
    [timelineIntents],
  );

  // ── Keyboard (TimelineRootView.keyDown / performKeyEquivalent) ────────
  const cbRef = useRef(callbacks);
  cbRef.current = callbacks;
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const cb = cbRef.current;
      const mod = e.metaKey || e.ctrlKey;
      // ⌘O "Browse Captures…" — a menu key equivalent, so it fires from text fields too.
      if (mod && !e.altKey && !e.shiftKey && e.key.toLowerCase() === "o") {
        e.preventDefault();
        cb.onShowProjects?.();
        return;
      }
      const target = e.target as HTMLElement | null;
      if (target && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName))) return;
      if (mod && e.altKey && e.code === "KeyI") {
        e.preventDefault();
        setInspectorVisible(!visible);
        return;
      }
      if (mod && !e.altKey && !e.shiftKey) {
        const k = e.key.toLowerCase();
        if (k === "z") {
          e.preventDefault();
          cb.onUndo?.();
        } else if (k === "d") {
          e.preventDefault();
          cb.onDuplicate?.();
        } else if (k === "b") {
          e.preventDefault();
          cb.onSplitAtPlayhead?.();
        }
        return;
      }
      if (mod && e.shiftKey && e.key.toLowerCase() === "z") {
        e.preventDefault();
        cb.onRedo?.();
        return;
      }
      if (mod || e.altKey) return;
      switch (e.key) {
        case " ":
          e.preventDefault();
          cb.onTogglePlay?.();
          break;
        case "ArrowLeft":
        case "ArrowRight":
          e.preventDefault();
          cb.onStep?.((e.key === "ArrowLeft" ? -1 : 1) * (e.shiftKey ? 1 : 1 / 30));
          break;
        case "Home":
          e.preventDefault();
          cb.onGoToStart?.();
          break;
        case "End":
          e.preventDefault();
          cb.onGoToEnd?.();
          break;
        case "Escape":
          cb.onEscape?.();
          break;
        case "Backspace":
        case "Delete":
          e.preventDefault();
          cb.onDelete?.();
          break;
        default:
          if (e.key.toLowerCase() === "b") cb.onToggleSlice?.();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [visible, setInspectorVisible]);

  return (
    <div className="cc-editor">
      <TopBar
        project={project}
        callbacks={callbacks}
        inspectorVisible={visible}
        onToggleInspector={() => setInspectorVisible(!visible)}
        accessory={topBarAccessory}
      />
      <div className="cc-body">
        <div className="cc-stagecol">
          <Stage aspect={project.canvasAspect} mount={stage} zoom={zoom} onZoomChange={onZoom} notice={props.stageNotice} />
          <div className="cc-tlpanel" style={{ height: panelHeight(effectsRows) }}>
            <TransportBar
              project={project}
              transport={transport}
              playhead={playhead}
              callbacks={callbacks}
              scale={scale}
              onScaleChange={(s) => setScale(Math.min(30, Math.max(1, s)))}
            />
            <Timeline
              snapshot={timeline}
              intents={timelineIntents}
              playhead={playhead}
              isPlaying={transport.isPlaying}
              scale={scale}
              onScaleChange={setScale}
              onContextMenu={onContextMenu}
              onEffectsRows={setEffectsRows}
              rendererRef={props.timelineRendererRef}
            />
          </div>
        </div>
        <div className="cc-split" data-hidden={!visible || undefined} onPointerDown={onDividerDown} />
        <div
          ref={colRef}
          className="cc-inspectorcol"
          aria-hidden={!visible || undefined}
          style={{ "--insp-open": `${width}px` } as CSSProperties}
        >
          <Inspector selected={tab} onSelect={selectTab} panes={panes} />
        </div>
        {!visible && <RevealTab onClick={() => setInspectorVisible(true)} />}
      </div>
      {menu && <ContextMenu at={menu.at} entries={menu.entries} onDismiss={() => setMenu(null)} />}
    </div>
  );
}
