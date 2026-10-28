/**
 * The recording bar — the Mac recording panel (RecordingPanelViewController),
 * docked at the bottom of EVERY dashboard page. The recorder lives in the
 * /app layout (RecorderProvider), so a take keeps going while you browse the
 * Library or Projects; the Record page adds the big live preview.
 *
 *   setup  [×] [Display|Window|Tab] | [▢ Choose Display ▾] | [▢ Mic · No Cam ▾] [▢ Audio On] [⚙] [●]
 *   live   [● 0:42] | [source] [❚❚] [↺] | [■] [🗑]
 *
 * Look: the 2026 recording-bar spec the Mac bar shares (RecordingPanelKit):
 *   card       ONE floating card like the menus — popover tint + top light,
 *              the 0.5px hairline, floatShadow at the bar's height, radius 20
 *              (app-2026.css `.cc-recbar*`, the app's own tokens; light and
 *              dark follow the app)
 *   ghosts     every control is a ghost button (radius 9): no surface at
 *              rest, ONE hover wash that glides between them, icons resting
 *              at the secondary ink, primary on hover / when selected
 *   chip       the selected source tab is a floating chip that GLIDES
 *   tiles      inputs show their glyph in a 24px tile: accent + white glyph
 *              when on, an ink-8% tile + muted glyph when off (it replaces
 *              the Mac's old "on" dot); on/off crossfades
 *   keys       Record / Stop are raised red keys; press scales to 0.96
 *   timer      a recessed well: red dot breathing while live, amber and
 *              steady while paused
 * Icons are CaptureCat's own kit (CCIcon), never lucide.
 *
 * Motion is the Mac panel's RecordingMotion family (app.css `--rec-*`):
 *   hover      ONE wash that glides from key to key (CCGlideHighlight), fades
 *              in/out over 120 ms — keys never light up on their own
 *   selection  ONE chip that springs between the source tabs (response
 *              0.35 s, a whisper of settle; its width never overshoots)
 *   morph      setup ↔ recording: the bar breathes to its new width over
 *              0.45 s on the resize curve while the rows crossfade — out over
 *              the first half, in over the second with a 0.98 → 1 settle
 *   press      ghosts tint in place; the red keys scale to 0.96
 * Reduce-motion keeps the fades (120 ms) and drops the movement.
 *
 * With a camera on, the dock also floats the camera bubble (camera-bubble.tsx,
 * the Mac's CameraFloatPreview) over whichever dashboard page you're on.
 *
 * During a take the controls stay on screen (editor/record/barHidden.ts):
 * floating in Picture-in-Picture where the browser has it — over a whole
 * display too, painted out of every frame by the clean plate, whose beacon
 * stripe tops the floating window (`PlateBeacon`) — else this bar.
 */
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ButtonHTMLAttributes,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from "react";
import { createPortal } from "react-dom";
import { useBlocker, useNavigate } from "@tanstack/react-router";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";

import { Button } from "@/components/ui/button";
import { CameraBubble, CameraSquircle } from "@/components/dashboard/camera-bubble";
import {
  DropdownMenu,
  DropdownMenuCheckboxItem,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { cn } from "@/lib/utils";
import { CCIcon } from "@/editor/ui/kit/ccIcon";
import type { SurfaceKind } from "@/editor/record/capture";
import { bubblePolicy } from "@/editor/record/cameraBubble";
import { BEACON } from "@/editor/record/plate";
import {
  COUNTDOWN_CHOICES,
  DISPLAY_FALLBACK,
  LIMIT_CHOICES,
  limitTitle,
  useInputLevel,
  useRecorder,
  type Recorder,
} from "@/editor/record/useRecorder";

/** The source tabs; `icon` is a kit name (CCIcon). */
export const SURFACES: Array<{ kind: SurfaceKind; label: string; choose: string; icon: string }> = [
  { kind: "monitor", label: "Display", choose: "Choose Display", icon: "display" },
  { kind: "window", label: "Window", choose: "Choose Window", icon: "window" },
  { kind: "browser", label: "Tab", choose: "Choose Tab", icon: "globe" },
];

// ── provider (in the /app layout) ────────────────────────────────────────────

const RecorderContext = createContext<Recorder | null>(null);

export function useRecorderContext(): Recorder {
  const rec = useContext(RecorderContext);
  if (!rec) throw new Error("useRecorderContext needs <RecorderProvider> (the /app layout)");
  return rec;
}

export function RecorderProvider({ children }: { children: ReactNode }) {
  const navigate = useNavigate();
  // The project a finished upload just created. It opens in the editor from
  // the effect below, once the recorder is idle again — never from inside
  // the save: the save flips the phase back to setup and reports the id in
  // the same tick, before the blocker's check has seen that render, so
  // navigating right there was blocked as "A recording is in progress" and
  // the take never opened (2026-10-28).
  const [savedProject, setSavedProject] = useState<string | null>(null);
  const rec = useRecorder({ onSaved: setSavedProject });
  const busy = rec.phase.kind === "recording" || rec.phase.kind === "countdown" || rec.phase.kind === "saving";
  // Leaving the dashboard (the editor, the marketing site) unmounts the
  // recorder — ask first while a take is live or uploading, in the house
  // dialog (closing the tab still gets the browser's own prompt: browsers
  // allow nothing else there).
  const blocker = useBlocker({
    shouldBlockFn: ({ next }) => {
      if (!busy) return false;
      return !(next.pathname.startsWith("/app") && !next.pathname.startsWith("/app/editor"));
    },
    enableBeforeUnload: busy,
    withResolver: true,
  });
  // After useBlocker, so its check is already re-armed with this render's
  // (idle) state when the navigation runs.
  useEffect(() => {
    if (!savedProject || busy) return;
    setSavedProject(null);
    void navigate({ to: "/app/editor/$projectId", params: { projectId: savedProject } });
  }, [savedProject, busy, navigate]);
  const uploading = rec.phase.kind === "saving";
  const blocked = blocker.status === "blocked";
  // A block decided on a state that is already over (the take finished in
  // the same tick as the navigation) protects nothing: let it through
  // instead of asking about a recording that no longer exists.
  useEffect(() => {
    if (blocked && !busy) blocker.proceed?.();
  }, [blocked, busy, blocker]);
  const asking = blocked && busy;
  // Mid-take this dialog is recorder UI on the page: logged (before it
  // paints) and cut like any return of the bar.
  const { showUiFor, hideUiAfter } = rec;
  useLayoutEffect(() => {
    if (!asking) return;
    showUiFor("dialog");
    return () => hideUiAfter("dialog");
  }, [asking, showUiFor, hideUiAfter]);
  return (
    <RecorderContext.Provider value={rec}>
      {children}
      <AlertDialog open={asking} onOpenChange={(open) => !open && blocker.reset?.()}>
        <AlertDialogContent data-rec-ui="dialog">
          <AlertDialogHeader>
            <AlertDialogTitle>{uploading ? "Your recording is still uploading" : "A recording is in progress"}</AlertDialogTitle>
            <AlertDialogDescription>
              {uploading
                ? "If you leave now, the recording stays on this device and you can upload it later from the Record page."
                : "If you leave now, this recording is lost."}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel onClick={() => blocker.reset?.()}>Stay</AlertDialogCancel>
            <AlertDialogAction
              variant={uploading ? "default" : "destructive"}
              onClick={() => blocker.proceed?.()}
            >
              {uploading ? "Leave" : "Leave and Lose It"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </RecorderContext.Provider>
  );
}

// ── shared bits ──────────────────────────────────────────────────────────────

export function StreamVideo({ stream, mirrored, className }: { stream: MediaStream; mirrored?: boolean; className?: string }) {
  const ref = useRef<HTMLVideoElement>(null);
  useEffect(() => {
    const v = ref.current;
    if (!v) return;
    v.srcObject = stream;
    void v.play().catch(() => undefined);
    return () => {
      v.srcObject = null;
    };
  }, [stream]);
  return <video ref={ref} muted playsInline className={className} style={mirrored ? { transform: "scaleX(-1)" } : undefined} />;
}

/** Four-bar input meter (the devices key). */
function LevelMeter({ level }: { level: number }) {
  return (
    <span aria-hidden className="flex h-3.5 items-end gap-[2px]">
      {[0.15, 0.35, 0.6, 0.85].map((t) => (
        <span key={t} data-lit={level > t} className="cc-recbar-meter" style={{ height: `${40 + t * 60}%` }} />
      ))}
    </span>
  );
}

/** CCSpinner stand-in: an ink arc (white on a red key). */
function BarSpinner() {
  return <span role="status" aria-label="Loading" className="cc-recbar-spin" />;
}

function usePrefersReducedMotion(): boolean {
  const [reduce, setReduce] = useState(false);
  useEffect(() => {
    const mq = window.matchMedia("(prefers-reduced-motion: reduce)");
    const sync = () => setReduce(mq.matches);
    sync();
    mq.addEventListener("change", sync);
    return () => mq.removeEventListener("change", sync);
  }, []);
  return reduce;
}

// ── motion primitives ────────────────────────────────────────────────────────

interface GlideRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/**
 * CCGlideHighlight: ONE hover wash per bar that glides to whichever
 * `[data-glide]` key is under the pointer, and fades out when it leaves
 * (or reaches a `[data-glide-off]` key — the red keys brighten instead).
 * Appearing from nothing it snaps into place (only the fade animates).
 */
function useGlide() {
  const [rect, setRect] = useState<GlideRect | null>(null);
  const [visible, setVisible] = useState(false);
  const snapRef = useRef(true);
  const onPointerOver = useCallback((e: ReactPointerEvent<HTMLElement>) => {
    const target = e.target as HTMLElement;
    const host = e.currentTarget;
    if (target.closest("[data-glide-off]")) {
      setVisible(false);
      snapRef.current = true;
      return;
    }
    const key = target.closest<HTMLElement>("[data-glide]");
    if (!key || !host.contains(key) || key.matches(":disabled")) return;
    const a = key.getBoundingClientRect();
    const b = host.getBoundingClientRect();
    setRect({ x: a.left - b.left, y: a.top - b.top, w: a.width, h: a.height });
    setVisible((was) => {
      snapRef.current = !was;
      return true;
    });
  }, []);
  const onPointerLeave = useCallback(() => {
    setVisible(false);
    snapRef.current = true;
  }, []);
  const wash = rect ? (
    <span
      aria-hidden
      className="dsh-glide-wash"
      style={{
        transform: `translate(${rect.x}px, ${rect.y}px)`,
        width: rect.w,
        height: rect.h,
        borderRadius: 9,
        opacity: visible ? 1 : 0,
        transition: snapRef.current
          ? "opacity 120ms var(--cc-ease-glide)"
          : "transform 300ms var(--rec-settle), width 300ms var(--rec-settle), height 300ms var(--rec-settle), opacity 120ms var(--cc-ease-glide)",
      }}
    />
  ) : null;
  return { wash, onPointerOver, onPointerLeave };
}

/**
 * The phase morph. `phaseKey` changes → the previous row is kept (inert,
 * absolutely placed) and fades out over the first half while the bar's
 * width eases to the incoming row's; the incoming row fades in over the
 * second half. Content-driven width changes (a longer source name) ride the
 * standalone resize clock. Clips sideways only, so the floating chip's and
 * the keys' shadows still fall below the row.
 */
function MorphShell({ phaseKey, children, className }: { phaseKey: string; children: ReactNode; className?: string }) {
  const reduce = usePrefersReducedMotion();
  const contentRef = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState<number | null>(null);
  const [prevKey, setPrevKey] = useState(phaseKey);
  const [outgoing, setOutgoing] = useState<{ key: string; node: ReactNode } | null>(null);
  const [morphing, setMorphing] = useState(false);
  const lastNode = useRef<ReactNode>(children);

  if (prevKey !== phaseKey) {
    setPrevKey(phaseKey);
    setOutgoing({ key: prevKey, node: lastNode.current });
    setMorphing(true);
  }
  useEffect(() => {
    lastNode.current = children;
  });
  useEffect(() => {
    if (!outgoing) return;
    const t = window.setTimeout(() => {
      setOutgoing(null);
      setMorphing(false);
    }, reduce ? 120 : 450);
    return () => window.clearTimeout(t);
  }, [outgoing, reduce]);

  useLayoutEffect(() => {
    const el = contentRef.current;
    if (!el) return;
    const measure = () => setWidth(Math.ceil(el.scrollWidth));
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, [phaseKey]);

  return (
    <div
      className={cn("relative overflow-x-clip", className)}
      style={{
        width: width ?? undefined,
        transition: reduce
          ? "none"
          : morphing
            ? "width var(--rec-morph) var(--rec-resize)"
            : "width 400ms var(--rec-settle)",
      }}
    >
      {outgoing && (
        <div aria-hidden inert className="rec-row-out pointer-events-none absolute inset-y-0 left-0 flex items-center gap-1">
          {outgoing.node}
        </div>
      )}
      <div key={phaseKey} ref={contentRef} className={cn("flex w-max items-center gap-1", outgoing && "rec-row-in")}>
        {children}
      </div>
    </div>
  );
}

// ── keys ─────────────────────────────────────────────────────────────────────

/**
 * A ghost key: no surface at rest; hover is the bar's glide wash, press tints
 * in place (no movement, no ring). `size`: "label" fits its content, "icon"
 * is 36×36, "small" is 28×28 (Close).
 */
function BarKey({
  children,
  className,
  size = "label",
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { children: ReactNode; size?: "label" | "icon" | "small" }) {
  return (
    <button
      type="button"
      data-glide
      aria-label={rest.title}
      className={cn("cc-recbar-key", size === "icon" && "cc-recbar-key--icon", size === "small" && "cc-recbar-key--small", className)}
      {...rest}
    >
      {children}
    </button>
  );
}

/** A kit glyph at the ghost keys' resting (secondary) ink; primary on hover. */
function KeyIcon({ name, size = 16, className }: { name: string; size?: number; className?: string }) {
  return <CCIcon name={name} size={size} className={cn("cc-recbar-ico", className)} />;
}

/**
 * An input's icon tile (the 2026 menus' tile): accent with a white glyph when
 * on, an ink-8% tile with a muted glyph when off. With `offIcon` the glyphs
 * crossfade along with the fill (Audio On ⇄ Off).
 */
function Tile({ on, icon, offIcon }: { on: boolean; icon: string; offIcon?: string }) {
  return (
    <span aria-hidden data-on={on} className="cc-recbar-tile">
      <CCIcon name={icon} size={14} data-glyph={offIcon ? "on" : undefined} />
      {offIcon && <CCIcon name={offIcon} size={14} data-glyph="off" />}
    </span>
  );
}

function BarDivider() {
  return <span aria-hidden className="cc-recbar-div" />;
}

/** The source tabs with ONE floating chip that glides between them. */
function SourceTabs({ rec }: { rec: Recorder }) {
  const { prefs, setPrefs } = rec;
  const reduce = usePrefersReducedMotion();
  const groupRef = useRef<HTMLDivElement>(null);
  const [chip, setChip] = useState<GlideRect | null>(null);
  const settled = useRef(false);
  useLayoutEffect(() => {
    const group = groupRef.current;
    const el = group?.querySelector<HTMLElement>(`[data-surface="${prefs.surface}"]`);
    if (!group || !el) return;
    setChip({ x: el.offsetLeft, y: el.offsetTop, w: el.offsetWidth, h: el.offsetHeight });
  }, [prefs.surface]);
  useEffect(() => {
    // First placement lands without motion; later moves spring.
    const t = window.setTimeout(() => (settled.current = true), 0);
    return () => window.clearTimeout(t);
  }, []);
  return (
    <div ref={groupRef} role="radiogroup" aria-label="Source" className="relative flex items-center gap-0.5">
      {chip && (
        <span
          aria-hidden
          data-recbar-chip
          className="cc-float-chip cc-recbar-chip"
          style={{
            transform: `translate(${chip.x}px, ${chip.y}px)`,
            width: chip.w,
            height: chip.h,
            transition:
              settled.current && !reduce
                ? "transform 350ms var(--rec-settle), width 350ms cubic-bezier(0.25, 1, 0.5, 1)"
                : "none",
          }}
        />
      )}
      {SURFACES.map((s) => (
        <button
          key={s.kind}
          type="button"
          role="radio"
          data-glide
          data-surface={s.kind}
          aria-checked={prefs.surface === s.kind}
          onClick={() => {
            setPrefs({ surface: s.kind });
            rec.clearSource();
          }}
          className="cc-recbar-tab"
        >
          <CCIcon name={s.icon} size={16} weight="medium" />
          {s.label}
        </button>
      ))}
    </div>
  );
}

// ── rows ─────────────────────────────────────────────────────────────────────

function SetupRow({ rec }: { rec: Recorder }) {
  const { prefs, setPrefs, devices } = rec;
  const level = useInputLevel(rec.micStream);
  const current = SURFACES.find((s) => s.kind === prefs.surface) ?? SURFACES[0];
  const labelsHidden = devices.mics.length === 0 || devices.mics.every((d) => /^Microphone \d+$/.test(d.label));
  return (
    <>
      {rec.armed && (
        <BarKey title="Close — release the camera, microphone and source" onClick={rec.disarm} size="small">
          <KeyIcon name="close" size={14} />
        </BarKey>
      )}
      <SourceTabs rec={rec} />
      <BarDivider />
      <BarKey title="Choose what to record" onClick={() => void rec.chooseSource()} className="max-w-[244px] pl-1.5">
        <Tile on={false} icon={current.icon} />
        <span className="max-w-[200px] truncate">{rec.screen ? rec.sourceLabel : current.choose}</span>
        <KeyIcon name="chevron-down" size={12} className="cc-recbar-chev" />
      </BarKey>
      <BarDivider />
      <DropdownMenu onOpenChange={(open) => open && rec.arm()}>
        <DropdownMenuTrigger asChild>
          <BarKey title="Microphone and camera" className="pl-1.5">
            <Tile on={prefs.micId !== null || prefs.camId !== null} icon="sliders" />
            {rec.armed && prefs.micId !== null && <LevelMeter level={level} />}
            <span>
              {prefs.micId === null ? "No Mic" : "Mic"} · {prefs.camId === null ? "No Cam" : "Cam"}
            </span>
            <KeyIcon name="chevron-down" size={12} className="cc-recbar-chev" />
          </BarKey>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="center" side="top" sideOffset={12} className="w-64">
          <DropdownMenuLabel>Microphone</DropdownMenuLabel>
          <DropdownMenuRadioGroup
            value={prefs.micId === null ? "none" : prefs.micId === "" ? "default" : prefs.micId}
            onValueChange={(v) => setPrefs({ micId: v === "none" ? null : v === "default" ? "" : v })}
          >
            <DropdownMenuRadioItem value="none">No Microphone</DropdownMenuRadioItem>
            <DropdownMenuRadioItem value="default">System Default</DropdownMenuRadioItem>
            {devices.mics.map((d) => (
              <DropdownMenuRadioItem key={d.deviceId} value={d.deviceId}>
                <span className="truncate">{d.label}</span>
              </DropdownMenuRadioItem>
            ))}
          </DropdownMenuRadioGroup>
          <DropdownMenuSeparator />
          <DropdownMenuLabel>Camera Overlay</DropdownMenuLabel>
          <DropdownMenuRadioGroup value={prefs.camId ?? "none"} onValueChange={(v) => setPrefs({ camId: v === "none" ? null : v })}>
            <DropdownMenuRadioItem value="none">No Overlay</DropdownMenuRadioItem>
            {devices.cameras.map((d) => (
              <DropdownMenuRadioItem key={d.deviceId} value={d.deviceId}>
                <span className="truncate">{d.label}</span>
              </DropdownMenuRadioItem>
            ))}
          </DropdownMenuRadioGroup>
          {(labelsHidden || devices.cameras.length === 0) && (
            <>
              <DropdownMenuSeparator />
              <DropdownMenuItem onSelect={() => void rec.allowDevices()}>Allow Camera &amp; Microphone…</DropdownMenuItem>
            </>
          )}
        </DropdownMenuContent>
      </DropdownMenu>
      {rec.engine === "mediarecorder" ? (
        <BarKey title="Safari can't record system audio — your microphone is recorded" disabled className="pl-1.5">
          <Tile on={false} icon="speaker-off-fill" />
          No System Audio
        </BarKey>
      ) : (
        <BarKey
          title="Record system or tab audio"
          aria-pressed={prefs.systemAudio}
          className="pl-1.5"
          onClick={() => {
            setPrefs({ systemAudio: !prefs.systemAudio });
            rec.clearSource(); // audio is chosen with the share — pick the source again
          }}
        >
          <Tile on={prefs.systemAudio} icon="speaker-fill" offIcon="speaker-off-fill" />
          {prefs.systemAudio ? "Audio On" : "Audio Off"}
        </BarKey>
      )}
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <BarKey title="Recording settings" size="icon">
            <KeyIcon name="gear" />
          </BarKey>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" side="top" sideOffset={12} className="w-64">
          <DropdownMenuLabel>Recording Countdown</DropdownMenuLabel>
          <DropdownMenuRadioGroup value={String(prefs.countdown)} onValueChange={(v) => setPrefs({ countdown: Number(v) })}>
            {COUNTDOWN_CHOICES.map((c) => (
              <DropdownMenuRadioItem key={c} value={String(c)}>
                {c === 0 ? "Off" : `${c}s`}
              </DropdownMenuRadioItem>
            ))}
          </DropdownMenuRadioGroup>
          <DropdownMenuSeparator />
          <DropdownMenuLabel>Duration Limit</DropdownMenuLabel>
          <DropdownMenuRadioGroup value={String(prefs.limit)} onValueChange={(v) => setPrefs({ limit: Number(v) })}>
            {LIMIT_CHOICES.map((l) => (
              <DropdownMenuRadioItem key={l} value={String(l)}>
                {limitTitle(l)}
              </DropdownMenuRadioItem>
            ))}
          </DropdownMenuRadioGroup>
          <DropdownMenuSeparator />
          <DropdownMenuCheckboxItem
            checked={prefs.floatControls}
            disabled={!rec.pipSupported}
            onCheckedChange={(v) => setPrefs({ floatControls: v === true })}
          >
            Floating controls
          </DropdownMenuCheckboxItem>
        </DropdownMenuContent>
      </DropdownMenu>
      <button
        type="button"
        data-glide-off
        title={rec.screen ? "Start recording" : "Choose what to record first"}
        aria-label="Record"
        disabled={!rec.screen}
        onClick={() => void rec.record()}
        className="cc-recbar-redkey ml-1"
      >
        <CCIcon name="record" size={18} weight="medium" />
      </button>
    </>
  );
}

/** During a take: ● timer | source · pause · restart | stop · delete (Mac order). */
function LiveRow({ rec, compact = false }: { rec: Recorder; compact?: boolean }) {
  const [confirm, setConfirm] = useState<null | "restart" | "delete">(null);
  if (confirm) {
    const restart = confirm === "restart";
    return (
      <div className="flex items-center gap-2 px-1" role="alertdialog">
        <span className="px-1 text-[13px] font-medium">{restart ? "Restart recording from beginning?" : "Delete this recording?"}</span>
        <Button size="sm" variant="outline" onClick={() => setConfirm(null)}>
          {restart ? "Keep Recording" : "Cancel"}
        </Button>
        <Button
          size="sm"
          className="bg-[var(--cc-destructive,#ff453a)] text-white hover:bg-[var(--cc-destructive,#ff453a)] hover:brightness-110"
          onClick={() => {
            setConfirm(null);
            void (restart ? rec.restart() : rec.remove());
          }}
        >
          {restart ? "Restart" : "Delete"}
        </Button>
      </div>
    );
  }
  return (
    <>
      <span
        data-paused={rec.paused}
        data-warn={rec.clockWarn}
        className="cc-well cc-recbar-timer"
      >
        <span className="cc-recbar-dot" aria-hidden />
        <span>{rec.clock}</span>
        {rec.paused && <span className="cc-recbar-timer-state">Paused</span>}
      </span>
      <BarDivider />
      {!compact && (
        <BarKey title={rec.sourceLabel || "Source"} className="max-w-[200px] text-[var(--cc-muted)]">
          <KeyIcon name="display" />
          <span className="truncate font-normal">{rec.sourceLabel}</span>
        </BarKey>
      )}
      <BarKey title={rec.paused ? "Resume" : "Pause"} disabled={rec.busy} onClick={rec.pauseResume} size="icon">
        <KeyIcon name={rec.paused ? "play-fill" : "pause-fill"} />
      </BarKey>
      <BarKey title="Restart" disabled={rec.busy} onClick={() => setConfirm("restart")} size="icon">
        <KeyIcon name="rotate-ccw" />
      </BarKey>
      <BarDivider />
      <button
        type="button"
        data-glide-off
        title="Stop"
        aria-label="Stop"
        disabled={rec.busy}
        onClick={() => void rec.stop()}
        className="cc-recbar-redkey cc-recbar-redkey--stop"
      >
        {rec.busy ? <BarSpinner /> : <CCIcon name="stop-fill" size={16} />}
      </button>
      <BarKey title="Delete" disabled={rec.busy} onClick={() => setConfirm("delete")} size="icon" className="cc-recbar-key--danger">
        <CCIcon name="trash-fill" size={16} />
      </BarKey>
    </>
  );
}

/** Saves a take's screen file to the user's Downloads (a failed upload's way out). */
function downloadTake(file: Blob): void {
  const url = URL.createObjectURL(file);
  const a = document.createElement("a");
  a.href = url;
  a.download = "recording.mov";
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

/**
 * Countdown / saving / failed. The bar is on every dashboard page, so this row
 * is never a dead end: saving can be cancelled, and a failed upload keeps its
 * controls — try again, download, or record another (the take stays on this
 * device as a leftover) — and says WHY it failed.
 */
function StatusRow({ rec }: { rec: Recorder }) {
  const { phase } = rec;
  if (phase.kind === "failed") {
    return (
      <>
        <span className="inline-flex h-9 min-w-0 items-center gap-2.5 pl-3 pr-1 text-[13px] font-medium" title={phase.message}>
          <CCIcon name="warning-fill" size={16} className="shrink-0 text-[var(--cc-amber,#ff9f0a)]" />
          <span className="min-w-0 max-w-[22rem] truncate">
            Upload failed<span className="font-normal text-[var(--cc-muted)]"> — {phase.message}</span>
          </span>
        </span>
        <BarDivider />
        <BarKey title="Download the recording" onClick={() => downloadTake(phase.take.screen)}>
          <KeyIcon name="arrow-down-line" />
          Download
        </BarKey>
        <BarKey title="Keep this recording on this device and record another" onClick={rec.keepForLater}>
          <KeyIcon name="record" />
          Record another
        </BarKey>
        <BarKey title="Try the upload again" onClick={() => void rec.publish(phase.take)} className="cc-recbar-key--primary">
          <CCIcon name="cloud-upload" size={16} />
          Try again
        </BarKey>
      </>
    );
  }
  const label =
    phase.kind === "countdown"
      ? `Starting in ${phase.left}…`
      : phase.kind === "saving"
        ? `${phase.progress?.message ?? "Finishing…"}${phase.progress ? ` ${Math.round(phase.progress.fraction * 100)}%` : ""}`
        : "";
  return (
    <>
      <span className="inline-flex h-9 items-center gap-2.5 px-3 text-[13px] font-medium tabular-nums">
        <BarSpinner />
        {label}
      </span>
      {phase.kind === "saving" && (
        <BarKey title="Cancel the upload — the recording stays on this device" onClick={rec.cancelUpload}>
          Cancel
        </BarKey>
      )}
    </>
  );
}

// ── the bar ──────────────────────────────────────────────────────────────────

export function RecordingBar({ rec, compact = false }: { rec: Recorder; compact?: boolean }) {
  const glide = useGlide();
  const phase = rec.phase.kind;
  const phaseKey = phase === "recording" ? "live" : phase === "setup" ? "setup" : "status";
  return (
    <div
      data-rec-ui="bar"
      className="cc-recbar pointer-events-auto relative flex h-14 items-center px-2"
      onPointerOver={glide.onPointerOver}
      onPointerLeave={glide.onPointerLeave}
      aria-label="Recording panel"
    >
      {glide.wash}
      <MorphShell phaseKey={phaseKey}>
        {phaseKey === "live" ? <LiveRow rec={rec} compact={compact} /> : phaseKey === "setup" ? <SetupRow rec={rec} /> : <StatusRow rec={rec} />}
      </MorphShell>
    </div>
  );
}

/** A notice above the bar (the recorder's warnings, the bubble's note) — a small floating card. */
function DockNotice({ icon, children, onDismiss }: { icon: ReactNode; children: ReactNode; onDismiss?: () => void }) {
  return (
    <div data-rec-ui="notice" className="cc-recbar-notice pointer-events-auto flex max-w-lg items-start gap-2 px-3.5 py-2 text-[12.5px]">
      {icon}
      <span className="flex-1">{children}</span>
      {onDismiss && (
        <button
          type="button"
          aria-label="Dismiss"
          onClick={onDismiss}
          className="mt-px text-[var(--cc-muted)] transition-colors duration-[120ms] hover:text-[var(--cc-foreground)]"
        >
          <CCIcon name="close" size={14} />
        </button>
      )}
    </div>
  );
}

/** A notice's leading glyph (kit icon at the secondary ink, or a tone). */
function NoticeIcon({ name, className }: { name: string; className?: string }) {
  return <CCIcon name={name} size={14} className={cn("mt-0.5 shrink-0 text-[var(--cc-muted)]", className)} />;
}

/**
 * The top edge of the floating controls window: a recording-red stripe over a
 * near-black band. A whole-display take checks its frames for it — the window
 * must be found exactly where it's painted out (editor/record/plate.ts) — so
 * it is always drawn, at full strength, above everything in the window.
 */
function PlateBeacon() {
  return (
    <span
      aria-hidden
      data-plate-beacon
      className="pointer-events-none absolute inset-x-0 top-0 z-50"
      style={{
        height: BEACON.stripe + BEACON.band,
        background: `linear-gradient(${BEACON.red} 0 ${BEACON.stripe}px, ${BEACON.dark} ${BEACON.stripe}px 100%)`,
      }}
    />
  );
}

/**
 * Docks the bar at the bottom of the dashboard content, riding the viewport
 * as pages scroll, with the recorder's notices just above it — plus the
 * floating camera bubble and the floating Picture-in-Picture copy of the
 * live controls (which carries the bubble while it's open).
 *
 * The output never shows any of it (barHidden.ts): for a share that could
 * contain this page the whole dock fades out before the take's first frame
 * (`rec.uiHidden`; it keeps its layout, so nothing on the page moves) while
 * the controls float — or, without the floating window, stays up while you're
 * on the page (a window share) or comes back when you return (a display);
 * those moments are cut.
 *
 * `[data-recorder-dock]` is the bar's frame (the bubble keeps clear of it,
 * useConceal's edge reveal sits above it) and scrolls the bar sideways in a
 * narrow window — which clips everything outside it, so the bar's float
 * shadow is cast by a sibling behind it (`.cc-recbar-cast`).
 */
export function RecorderDock() {
  const rec = useRecorderContext();
  const [tipDismissed, setTipDismissed] = useState(false);
  const bubble = bubblePolicy({
    cameraOn: rec.armed && rec.prefs.camId !== null,
    phase: rec.phase.kind,
    conceal: rec.concealMode,
    starting: rec.starting,
    floatingOpen: rec.floating !== null,
    cameraPipOpen: rec.cameraPip,
  });
  if (!rec.support?.screen || !rec.support.encode) return null;
  const hidesForTake = rec.concealMode === "reveal" && rec.phase.kind === "countdown";
  const displayTip = rec.phase.kind === "setup" && !tipDismissed ? rec.displayTip : null;
  return (
    <>
      <div
        data-recorder-dock-root
        data-concealed={rec.uiHidden}
        aria-hidden={rec.uiHidden || undefined}
        className="rec-conceal pointer-events-none sticky bottom-5 z-40 mt-auto flex flex-col items-center gap-2 px-4 pb-1"
      >
        {rec.revealed && (
          <DockNotice icon={<NoticeIcon name="eye-off" />}>
            {rec.revealed === "focus"
              ? "Recording a window — the moments you spend on this page are cut, so this bar never reaches your video."
              : "Recording — the bar is hidden from your recording."}
          </DockNotice>
        )}
        {displayTip && (
          <DockNotice icon={<NoticeIcon name="picture-in-picture" />} onDismiss={() => setTipDismissed(true)}>
            {displayTip === "plate"
              ? "The controls float above your screen while you record, and stay out of the video: the spot they cover shows your screen as it was when you pressed Record. Tip: park them over a quiet corner."
              : DISPLAY_FALLBACK.displays}
          </DockNotice>
        )}
        {hidesForTake && (
          <DockNotice icon={<NoticeIcon name="eye-off" />}>
            This bar hides while you record, so it stays out of your video
            {bubble.hiddenForScreen ? " — so does the camera bubble; your camera is still recorded" : ""}. Come back to
            this tab to stop, or press <kbd className="font-sans font-semibold">{rec.stopShortcut}</kbd> here.
          </DockNotice>
        )}
        {rec.notice && (
          <DockNotice icon={<NoticeIcon name="warning-fill" className="text-[var(--cc-amber,#ff9f0a)]" />} onDismiss={() => rec.setNotice(null)}>
            {rec.notice}
          </DockNotice>
        )}
        <div className="relative max-w-[calc(100%-1rem)]">
          <span aria-hidden className="cc-recbar-cast" />
          <div data-recorder-dock className="relative overflow-x-auto overflow-y-visible">
            <RecordingBar rec={rec} />
          </div>
        </div>
      </div>
      <CameraBubble stream={rec.camStream} show={bubble.host === "page"} />
      {rec.floating &&
        createPortal(
          // data-cc-app: the floating window is its own document — this puts
          // the app's 2026 tokens (app-2026.css) on its :root, so the bar
          // there matches the dock in either appearance.
          <div data-cc-app="" className="dark relative flex size-full items-center justify-center bg-background p-3 text-foreground">
            <PlateBeacon />
            <div className="flex flex-col items-center gap-2">
              {bubble.host === "floating" && (
                <div className="relative size-40">
                  <CameraSquircle stream={rec.camStream} />
                </div>
              )}
              <RecordingBar rec={rec} compact />
            </div>
          </div>,
          rec.floating.mount,
        )}
    </>
  );
}
