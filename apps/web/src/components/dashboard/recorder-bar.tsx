/**
 * The recording bar — the Mac recording panel (RecordingPanelViewController),
 * docked at the bottom of EVERY dashboard page. The recorder lives in the
 * /app layout (RecorderProvider), so a take keeps going while you browse the
 * Library or Projects; the Record page adds the big live preview.
 *
 *   setup  [×] [Display|Window|Tab] | [Choose Display ▾] | [Mic · No Cam ▾] [Audio On] [⚙] [●]
 *   live   [● 0:42] [source] [❚❚] [↺] [■] [🗑]
 *
 * Motion is the Mac panel's RecordingMotion family (app.css `--rec-*`):
 *   hover      ONE wash that glides from key to key (CCGlideHighlight), fades
 *              in/out over 150 ms — keys never light up on their own
 *   selection  ONE pill that springs between the source tabs (response
 *              0.35 s, a whisper of settle; its width never overshoots)
 *   morph      setup ↔ recording: the bar breathes to its new width over
 *              0.45 s on the resize curve while the rows crossfade — out over
 *              the first half, in over the second with a 0.98 → 1 settle
 *   press      the key tints in place; nothing moves, no ring
 * Reduce-motion keeps the fades (120 ms) and drops the movement.
 *
 * With a camera on, the dock also floats the camera bubble (camera-bubble.tsx,
 * the Mac's CameraFloatPreview) over whichever dashboard page you're on.
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
import {
  AppWindowIcon,
  ChevronDownIcon,
  CircleDotIcon,
  GlobeIcon,
  MonitorIcon,
  PauseIcon,
  PlayIcon,
  RotateCcwIcon,
  SettingsIcon,
  SlidersHorizontalIcon,
  SquareIcon,
  Trash2Icon,
  TriangleAlertIcon,
  VideoOffIcon,
  Volume2Icon,
  VolumeXIcon,
  XIcon,
} from "lucide-react";

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
import { Spinner } from "@/components/ui/spinner";
import { cn } from "@/lib/utils";
import type { SurfaceKind } from "@/editor/record/capture";
import { bubblePolicy } from "@/editor/record/cameraBubble";
import {
  COUNTDOWN_CHOICES,
  LIMIT_CHOICES,
  limitTitle,
  useInputLevel,
  useRecorder,
  type Recorder,
} from "@/editor/record/useRecorder";

export const SURFACES: Array<{ kind: SurfaceKind; label: string; choose: string; icon: typeof MonitorIcon }> = [
  { kind: "monitor", label: "Display", choose: "Choose Display", icon: MonitorIcon },
  { kind: "window", label: "Window", choose: "Choose Window", icon: AppWindowIcon },
  { kind: "browser", label: "Tab", choose: "Choose Tab", icon: GlobeIcon },
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
  const rec = useRecorder({
    onSaved: (id) => void navigate({ to: "/app/editor/$projectId", params: { projectId: id } }),
  });
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
  const uploading = rec.phase.kind === "saving";
  return (
    <RecorderContext.Provider value={rec}>
      {children}
      <AlertDialog open={blocker.status === "blocked"} onOpenChange={(open) => !open && blocker.reset?.()}>
        <AlertDialogContent>
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
        <span
          key={t}
          className={cn("w-[3px] rounded-full transition-colors duration-75", level > t ? "bg-emerald-400" : "bg-white/15")}
          style={{ height: `${40 + t * 60}%` }}
        />
      ))}
    </span>
  );
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
 * `[data-glide]` key is under the pointer, and fades out when it leaves.
 * Appearing from nothing it snaps into place (only the fade animates).
 */
function useGlide() {
  const [rect, setRect] = useState<GlideRect | null>(null);
  const [visible, setVisible] = useState(false);
  const snapRef = useRef(true);
  const onPointerOver = useCallback((e: ReactPointerEvent<HTMLElement>) => {
    const key = (e.target as HTMLElement).closest<HTMLElement>("[data-glide]");
    const host = e.currentTarget;
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
      className="pointer-events-none absolute left-0 top-0 rounded-lg bg-white/[0.08]"
      style={{
        transform: `translate(${rect.x}px, ${rect.y}px)`,
        width: rect.w,
        height: rect.h,
        opacity: visible ? 1 : 0,
        transition: snapRef.current
          ? "opacity var(--rec-fade) ease-out"
          : "transform 300ms var(--rec-settle), width 300ms var(--rec-settle), height 300ms var(--rec-settle), opacity var(--rec-fade) ease-out",
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
 * standalone resize clock.
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
      className={cn("relative overflow-hidden", className)}
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
        <div aria-hidden inert className="rec-row-out pointer-events-none absolute inset-y-0 left-0 flex items-center">
          {outgoing.node}
        </div>
      )}
      <div key={phaseKey} ref={contentRef} className={cn("flex w-max items-center", outgoing && "rec-row-in")}>
        {children}
      </div>
    </div>
  );
}

// ── keys ─────────────────────────────────────────────────────────────────────

/** A panel key: tints in place when pressed (no movement, no ring). Hover is the bar's glide. */
function BarKey({
  children,
  className,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { children: ReactNode }) {
  return (
    <button
      type="button"
      data-glide
      aria-label={rest.title}
      className={cn(
        "relative inline-flex h-9 shrink-0 items-center justify-center gap-1.5 rounded-lg px-2.5 text-[13px] font-medium text-white/85 outline-none transition-[background-color,opacity] duration-[80ms] focus-visible:bg-white/[0.08] active:bg-white/[0.12] disabled:pointer-events-none disabled:opacity-35 [&_svg]:size-4",
        className,
      )}
      {...rest}
    >
      {children}
    </button>
  );
}

function BarDivider() {
  return <span aria-hidden className="mx-1 h-6 w-px shrink-0 bg-white/10" />;
}

/** The source tabs with ONE selection pill that springs between them. */
function SourceTabs({ rec }: { rec: Recorder }) {
  const { prefs, setPrefs } = rec;
  const groupRef = useRef<HTMLDivElement>(null);
  const [pill, setPill] = useState<GlideRect | null>(null);
  const settled = useRef(false);
  useLayoutEffect(() => {
    const group = groupRef.current;
    const el = group?.querySelector<HTMLElement>(`[data-surface="${prefs.surface}"]`);
    if (!group || !el) return;
    setPill({ x: el.offsetLeft, y: el.offsetTop, w: el.offsetWidth, h: el.offsetHeight });
  }, [prefs.surface]);
  useEffect(() => {
    // First placement lands without motion; later moves spring.
    const t = window.setTimeout(() => (settled.current = true), 0);
    return () => window.clearTimeout(t);
  }, []);
  return (
    <div ref={groupRef} role="radiogroup" aria-label="Source" className="relative flex items-center gap-0.5">
      {pill && (
        <span
          aria-hidden
          className="pointer-events-none absolute left-0 top-0 rounded-lg bg-white/[0.11] shadow-[inset_0_1px_0_rgba(255,255,255,0.06)]"
          style={{
            transform: `translate(${pill.x}px, ${pill.y}px)`,
            width: pill.w,
            height: pill.h,
            transition: settled.current
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
          className={cn(
            "relative inline-flex h-11 w-[58px] shrink-0 flex-col items-center justify-center gap-0.5 rounded-lg text-[10px] font-medium text-white/55 outline-none transition-colors duration-150 active:bg-white/[0.06] [&_svg]:size-[18px]",
            prefs.surface === s.kind && "text-white",
          )}
        >
          <s.icon strokeWidth={1.6} />
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
  const SourceIcon = current.icon;
  const labelsHidden = devices.mics.length === 0 || devices.mics.every((d) => /^Microphone \d+$/.test(d.label));
  return (
    <>
      {rec.armed && (
        <BarKey title="Close — release the camera, microphone and source" onClick={rec.disarm} className="px-2 text-white/60">
          <XIcon />
        </BarKey>
      )}
      <SourceTabs rec={rec} />
      <BarDivider />
      <BarKey title="Choose what to record" onClick={() => void rec.chooseSource()} className="max-w-[230px]">
        <SourceIcon className="text-white/65" />
        <span className="truncate">{rec.screen ? rec.sourceLabel : current.choose}</span>
        <ChevronDownIcon className="!size-3.5 text-white/45" />
      </BarKey>
      <BarDivider />
      <DropdownMenu onOpenChange={(open) => open && rec.arm()}>
        <DropdownMenuTrigger asChild>
          <BarKey title="Microphone and camera">
            <SlidersHorizontalIcon className="text-white/65" />
            {rec.armed && prefs.micId !== null && <LevelMeter level={level} />}
            <span>
              {prefs.micId === null ? "No Mic" : "Mic"} · {prefs.camId === null ? "No Cam" : "Cam"}
            </span>
            <ChevronDownIcon className="!size-3.5 text-white/45" />
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
        <BarKey title="Safari can't record system audio — your microphone is recorded" disabled>
          <VolumeXIcon className="text-white/65" />
          No System Audio
        </BarKey>
      ) : (
        <BarKey
          title="Record system or tab audio"
          aria-pressed={prefs.systemAudio}
          onClick={() => {
            setPrefs({ systemAudio: !prefs.systemAudio });
            rec.clearSource(); // audio is chosen with the share — pick the source again
          }}
        >
          {prefs.systemAudio ? <Volume2Icon className="text-white/65" /> : <VolumeXIcon className="text-white/65" />}
          {prefs.systemAudio ? "Audio On" : "Audio Off"}
        </BarKey>
      )}
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <BarKey title="Recording settings" className="px-2">
            <SettingsIcon className="text-white/65" />
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
        title={rec.screen ? "Start recording" : "Choose what to record first"}
        aria-label="Record"
        disabled={!rec.screen}
        onClick={() => void rec.record()}
        className="ml-1 grid size-11 shrink-0 place-items-center rounded-xl bg-[#ff3b30] text-white shadow-[inset_0_1px_0_rgba(255,255,255,0.25),0_4px_12px_-2px_rgba(255,59,48,0.55)] outline-none transition-[filter,opacity,box-shadow] duration-150 hover:brightness-110 active:brightness-95 disabled:opacity-40 disabled:shadow-none"
      >
        <CircleDotIcon className="size-[18px]" strokeWidth={2.2} />
      </button>
    </>
  );
}

/** During a take: ● timer · source · pause · restart · stop · delete (Mac order). */
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
          className="bg-red-500 text-white hover:bg-red-500/90"
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
      <span className={cn("inline-flex h-9 min-w-[78px] items-center gap-2 px-2.5 text-[13px] font-semibold tabular-nums", rec.clockWarn && "text-red-400")}>
        <span className={cn("size-2 rounded-full bg-red-500 transition-opacity duration-150", rec.paused ? "opacity-40" : "animate-pulse")} aria-hidden />
        {rec.paused ? "Paused" : rec.clock}
      </span>
      {!compact && (
        <BarKey title={rec.sourceLabel || "Source"} className="max-w-[200px] text-white/55">
          <MonitorIcon />
          <span className="truncate text-[12px] font-normal">{rec.sourceLabel}</span>
        </BarKey>
      )}
      <BarKey title={rec.paused ? "Resume" : "Pause"} disabled={rec.busy} onClick={rec.pauseResume} className="px-2">
        {rec.paused ? <PlayIcon className="fill-current" /> : <PauseIcon className="fill-current" />}
      </BarKey>
      <BarKey title="Restart" disabled={rec.busy} onClick={() => setConfirm("restart")} className="px-2">
        <RotateCcwIcon />
      </BarKey>
      <BarKey title="Stop" disabled={rec.busy} onClick={() => void rec.stop()} className="px-2 text-[#ff453a]">
        {rec.busy ? <Spinner className="size-4" /> : <SquareIcon className="fill-current" />}
      </BarKey>
      <BarKey title="Delete" disabled={rec.busy} onClick={() => setConfirm("delete")} className="px-2 text-[#ff453a]">
        <Trash2Icon />
      </BarKey>
    </>
  );
}

function StatusRow({ rec }: { rec: Recorder }) {
  const { phase } = rec;
  const label =
    phase.kind === "countdown"
      ? `Starting in ${phase.left}…`
      : phase.kind === "saving"
        ? `${phase.progress?.message ?? "Finishing…"}${phase.progress ? ` ${Math.round(phase.progress.fraction * 100)}%` : ""}`
        : "Upload failed — the recording is kept on this device";
  return (
    <span className="inline-flex h-9 items-center gap-2.5 px-3 text-[13px] font-medium tabular-nums">
      {phase.kind === "failed" ? <TriangleAlertIcon className="size-4 text-amber-400" /> : <Spinner className="size-4" />}
      {label}
    </span>
  );
}

// ── the bar ──────────────────────────────────────────────────────────────────

const SHELL =
  "pointer-events-auto relative flex h-14 items-center rounded-2xl border border-white/10 bg-[#1b1b1e]/95 px-2 text-white shadow-[0_24px_60px_-16px_rgba(0,0,0,0.85),inset_0_1px_0_rgba(255,255,255,0.06)] backdrop-blur-2xl";

export function RecordingBar({ rec, compact = false }: { rec: Recorder; compact?: boolean }) {
  const glide = useGlide();
  const phase = rec.phase.kind;
  const phaseKey = phase === "recording" ? "live" : phase === "setup" ? "setup" : "status";
  return (
    <div className={SHELL} onPointerOver={glide.onPointerOver} onPointerLeave={glide.onPointerLeave} aria-label="Recording panel">
      {glide.wash}
      <MorphShell phaseKey={phaseKey}>
        {phaseKey === "live" ? <LiveRow rec={rec} compact={compact} /> : phaseKey === "setup" ? <SetupRow rec={rec} /> : <StatusRow rec={rec} />}
      </MorphShell>
    </div>
  );
}

/** A notice above the bar (the recorder's warnings, the bubble's note). */
function DockNotice({ icon, children, onDismiss }: { icon: ReactNode; children: ReactNode; onDismiss: () => void }) {
  return (
    <div className="pointer-events-auto flex max-w-lg items-start gap-2 rounded-xl border border-white/10 bg-[#1b1b1e]/95 px-3.5 py-2 text-[12.5px] shadow-lg backdrop-blur-xl">
      {icon}
      <span className="flex-1">{children}</span>
      <button type="button" aria-label="Dismiss" onClick={onDismiss} className="text-white/50 hover:text-white">
        <XIcon className="size-3.5" />
      </button>
    </div>
  );
}

/** How long the "bubble hidden" note stays up — brief, since a whole-screen take records the dock too. */
const SCREEN_NOTE_MS = 4500;

/** True for a few seconds each time the bubble steps aside for a whole-screen take. */
function useScreenNote(active: boolean): [boolean, () => void] {
  const [shown, setShown] = useState(false);
  useEffect(() => {
    setShown(active);
    if (!active) return;
    const t = window.setTimeout(() => setShown(false), SCREEN_NOTE_MS);
    return () => window.clearTimeout(t);
  }, [active]);
  return [shown, () => setShown(false)];
}

/**
 * Docks the bar at the bottom of the dashboard content, riding the viewport
 * as pages scroll, with the recorder's notices just above it — plus the
 * floating camera bubble and the floating Picture-in-Picture copy of the
 * live controls (which carries the bubble while it's open).
 */
export function RecorderDock() {
  const rec = useRecorderContext();
  const bubble = bubblePolicy({
    cameraOn: rec.armed && rec.prefs.camId !== null,
    phase: rec.phase.kind,
    surface: rec.sourceSurface,
    starting: rec.starting,
    floatingOpen: rec.floating !== null,
  });
  const [screenNote, dismissScreenNote] = useScreenNote(bubble.hiddenForScreen);
  if (!rec.support?.screen || !rec.support.encode) return null;
  return (
    <>
      <div className="pointer-events-none sticky bottom-5 z-40 mt-auto flex flex-col items-center gap-2 px-4 pb-1">
        {screenNote && (
          <DockNotice icon={<VideoOffIcon className="mt-0.5 size-3.5 shrink-0 text-white/60" />} onDismiss={dismissScreenNote}>
            Camera bubble hidden while recording your whole screen — your camera is still being recorded.
          </DockNotice>
        )}
        {rec.notice && (
          <DockNotice icon={<TriangleAlertIcon className="mt-0.5 size-3.5 shrink-0 text-amber-400" />} onDismiss={() => rec.setNotice(null)}>
            {rec.notice}
          </DockNotice>
        )}
        <div data-recorder-dock className="max-w-[calc(100%-1rem)] overflow-x-auto overflow-y-visible">
          <RecordingBar rec={rec} />
        </div>
      </div>
      <CameraBubble stream={rec.camStream} show={bubble.host === "page"} />
      {rec.floating &&
        createPortal(
          <div className="dark flex size-full items-center justify-center bg-background p-3 text-foreground">
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
