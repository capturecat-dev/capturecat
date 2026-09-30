/**
 * Record — the web recorder page (/app/record). The recorder and its bar live
 * in the /app layout (recorder-bar.tsx: RecorderProvider + RecorderDock, on
 * every dashboard page); this page adds what only makes sense here: the big
 * live preview of the shared surface (camera bubble where the editor puts
 * it), the take's name, and recordings left on this device.
 */
import { useEffect, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { CloudUploadIcon, DownloadIcon, MonitorIcon, Trash2Icon, TriangleAlertIcon, VideoIcon } from "lucide-react";

import { Button } from "@/components/ui/button";
import { PageHeader, Section, Sections } from "@/components/dashboard/studio";
import { StreamVideo, useRecorderContext } from "@/components/dashboard/recorder-bar";
import { cn } from "@/lib/utils";
import type { RecordedTake } from "@/editor/record/session";
import { formatClock, type Recorder } from "@/editor/record/useRecorder";

function bytes(n: number): string {
  if (n >= 1e9) return `${(n / 1e9).toFixed(1)} GB`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(0)} MB`;
  return `${Math.max(1, Math.round(n / 1e3))} KB`;
}

function download(file: Blob, name: string): void {
  const url = URL.createObjectURL(file);
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

function Stage({ rec }: { rec: Recorder }) {
  const { phase } = rec;
  let overlay: ReactNode = null;
  if (phase.kind === "countdown") {
    overlay = (
      <div key={phase.left} className="absolute inset-0 grid place-items-center bg-black/55 backdrop-blur-sm">
        <span className="animate-in zoom-in-50 fade-in text-8xl font-semibold tabular-nums text-white duration-300">{phase.left}</span>
      </div>
    );
  } else if (phase.kind === "saving") {
    const p = phase.progress;
    overlay = (
      <div className="absolute inset-0 grid place-items-center bg-black/70 backdrop-blur-sm">
        <div className="w-72 space-y-3 text-center">
          <div className="text-sm font-medium">{p?.message ?? "Finishing recording…"}</div>
          <div className="h-1.5 w-full overflow-hidden rounded-full bg-white/10">
            <div className="h-full rounded-full bg-primary transition-[width] duration-300" style={{ width: `${Math.round((p?.fraction ?? 0) * 100)}%` }} />
          </div>
          <div className="text-xs text-muted-foreground">
            {formatClock(phase.take.duration)} · {bytes(phase.take.screen.size + (phase.take.camera?.size ?? 0))}
          </div>
          <Button size="sm" variant="ghost" onClick={rec.cancelUpload}>
            Cancel upload
          </Button>
        </div>
      </div>
    );
  } else if (phase.kind === "failed") {
    overlay = (
      <div className="absolute inset-0 grid place-items-center bg-black/75 backdrop-blur-sm">
        <div className="max-w-sm space-y-3 px-6 text-center">
          <TriangleAlertIcon className="mx-auto size-6 text-amber-400" />
          <div className="text-sm font-semibold">Couldn't save to the cloud</div>
          <p className="text-[13px] text-muted-foreground">{phase.message}</p>
          <p className="text-xs text-muted-foreground">The recording is kept on this device.</p>
          <div className="flex justify-center gap-2">
            <Button size="sm" variant="outline" onClick={() => download(phase.take.screen, "recording.mov")}>
              <DownloadIcon /> Download
            </Button>
            <Button size="sm" onClick={() => void rec.publish(phase.take)}>
              <CloudUploadIcon /> Try again
            </Button>
          </div>
        </div>
      </div>
    );
  }

  const showPreview = rec.screen && phase.kind !== "saving" && phase.kind !== "failed";
  return (
    <div className="relative w-full flex-1 overflow-hidden bg-black/60">
      {showPreview ? (
        <StreamVideo stream={rec.screen!} className="absolute inset-0 size-full object-contain" />
      ) : (
        phase.kind === "setup" && (
          <div className="absolute inset-0 grid place-items-center px-6 text-center">
            <div className="space-y-2">
              <MonitorIcon className="mx-auto size-7 text-muted-foreground" />
              <div className="text-sm font-medium">Choose what to record</div>
              <p className="mx-auto max-w-sm text-[13px] text-muted-foreground">
                Pick Display, Window or Tab in the bar below, then press the red key. The bar is on every page, so you
                can start a take from anywhere.
              </p>
            </div>
          </div>
        )
      )}
      {rec.captureInfo && rec.captureInfo.width > 0 && phase.kind !== "saving" && phase.kind !== "failed" && (
        <span
          title={
            rec.captureInfo.maxFps !== null && rec.captureInfo.fps < 55
              ? `This browser's screen capture tops out at ${Math.round(rec.captureInfo.maxFps)} fps`
              : "What the screen capture delivers"
          }
          className="absolute right-3 top-3 inline-flex items-center gap-1.5 rounded-full bg-black/60 px-2.5 py-1 text-[11px] font-medium tabular-nums text-white/85 backdrop-blur"
        >
          {rec.captureInfo.width} × {rec.captureInfo.height} · {rec.captureInfo.fps || "–"} fps
        </span>
      )}
      {phase.kind === "recording" && (
        <span className="absolute left-3 top-3 inline-flex items-center gap-1.5 rounded-full bg-black/60 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-[0.08em] text-white backdrop-blur">
          <span className={cn("size-1.5 rounded-full bg-red-500", !rec.paused && "animate-pulse")} />
          {rec.paused ? "Paused" : "Rec"}
        </span>
      )}
      {rec.camStream && phase.kind !== "saving" && phase.kind !== "failed" && (
        <div className="absolute bottom-3 right-3 aspect-square w-[18%] min-w-24 overflow-hidden rounded-[28%] border border-white/15 shadow-2xl">
          <StreamVideo stream={rec.camStream} mirrored className="size-full object-cover" />
        </div>
      )}
      {overlay}
    </div>
  );
}

function Leftovers({ rec }: { rec: Recorder }) {
  if (rec.phase.kind !== "setup" || rec.leftovers.length === 0) return null;
  return (
    <Sections>
      <Section title="Not uploaded yet" description="Recordings kept on this device because the upload didn't finish." icon={<CloudUploadIcon />}>
        <div className="divide-y divide-white/8">
          {rec.leftovers.map((t: RecordedTake) => (
            <div key={t.id} className="flex flex-wrap items-center gap-3 py-2.5 first:pt-0 last:pb-0">
              <VideoIcon className="size-4 text-muted-foreground" />
              <div className="min-w-0 flex-1">
                <div className="truncate text-sm font-medium">{t.sourceLabel || "Recording"}</div>
                <div className="text-xs text-muted-foreground">
                  {formatClock(t.duration)} · {bytes(t.screen.size + (t.camera?.size ?? 0))}
                </div>
              </div>
              <Button size="sm" variant="ghost" onClick={() => download(t.screen, "recording.mov")}>
                <DownloadIcon /> Download
              </Button>
              <Button size="sm" variant="ghost" onClick={() => void rec.deleteLeftover(t)}>
                <Trash2Icon /> Delete
              </Button>
              <Button size="sm" onClick={() => void rec.publish(t)}>
                <CloudUploadIcon /> Upload
              </Button>
            </div>
          ))}
        </div>
      </Section>
    </Sections>
  );
}

export function Recorder() {
  const rec = useRecorderContext();
  const { support, phase, arm } = rec;
  // This page is where recording happens: open the camera/mic (meters, bubble).
  useEffect(() => arm(), [arm]);

  return (
    // Fill the window below the dashboard header; the layout's bar docks below.
    <div className="flex min-h-[calc(100svh-12rem)] flex-col gap-6">
      <PageHeader
        eyebrow="Capture"
        title="Record"
        description="Record a display, a window or a browser tab with your camera and microphone. When you stop, it opens in the web editor."
        actions={
          <>
            <input
              className="studio-input h-8 !w-52"
              placeholder="Untitled Recording"
              aria-label="Recording name"
              value={rec.name}
              maxLength={200}
              disabled={phase.kind !== "setup"}
              onChange={(e) => rec.setName(e.target.value)}
            />
            <Button variant="outline" size="sm" asChild>
              <Link to="/app/projects">Projects</Link>
            </Button>
          </>
        }
      />

      {support && (!support.screen || !support.encode) ? (
        <section className="glass-panel hairline-top p-8 text-center">
          <TriangleAlertIcon className="mx-auto size-6 text-amber-400" />
          <div className="mt-3 text-sm font-semibold">This browser can't record</div>
          <p className="mx-auto mt-1 max-w-md text-[13px] text-muted-foreground">
            Recording needs screen sharing and video encoding — use a current Chrome, Edge or Safari on a computer.
          </p>
        </section>
      ) : (
        <section className="glass-panel hairline-top flex min-h-[320px] flex-1 flex-col overflow-hidden">
          <Stage rec={rec} />
          {phase.kind === "recording" && (
            <p className="border-t border-white/8 px-4 py-2.5 text-xs text-muted-foreground">
              {rec.floating
                ? "The controls are also floating above your other windows."
                : "Stop from the bar below or the browser's sharing indicator."}
            </p>
          )}
        </section>
      )}

      <Leftovers rec={rec} />
    </div>
  );
}
