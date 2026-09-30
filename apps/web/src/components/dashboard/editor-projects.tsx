/**
 * Projects (/app/projects) — the editable projects the web editor opens:
 * cloud projects (pushed from the Mac with "Open in Web Editor", or recorded
 * here), plus — on the dev server only — this Mac's local projects. Same
 * glass table as the Library; a row opens /app/editor/<UUID>.
 */
import { useEffect, useState } from "react";
import { Link, useNavigate } from "@tanstack/react-router";
import { ChevronRightIcon, CircleIcon, CloudIcon, FolderOpenIcon, LaptopIcon } from "lucide-react";

import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { EmptyNote, PageHeader } from "@/components/dashboard/studio";
import { formatClock } from "@/editor/record/useRecorder";
import { listEditorProjects, type EditorProjectSummary } from "@/editor/state/projectSource";

function relative(iso: string | null): string {
  if (!iso) return "—";
  const mins = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins} min ago`;
  const hours = Math.round(mins / 60);
  if (hours < 24) return `${hours} h ago`;
  const days = Math.round(hours / 24);
  if (days < 30) return `${days} d ago`;
  return new Date(iso).toLocaleDateString();
}

export function EditorProjects() {
  const navigate = useNavigate();
  const [projects, setProjects] = useState<EditorProjectSummary[] | null>(null);
  useEffect(() => {
    let alive = true;
    void listEditorProjects().then((p) => alive && setProjects(p));
    return () => {
      alive = false;
    };
  }, []);

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="Web Editor"
        title="Projects"
        description={
          import.meta.env.DEV
            ? "Cloud projects and — on this dev server — the projects on this Mac. Open one to edit it in the browser."
            : "Your editable projects. Open one to edit it in the browser; changes sync back to the Mac app."
        }
        actions={
          <Button size="sm" className="bg-red-500 text-white hover:bg-red-500/90" asChild>
            <Link to="/app/record">
              <CircleIcon className="fill-current" /> Record
            </Link>
          </Button>
        }
      />

      <section className="glass-panel hairline-top overflow-hidden">
        {projects === null ? (
          <div className="divide-y divide-white/8">
            {Array.from({ length: 4 }, (_, i) => (
              <div key={i} className="flex items-center gap-4 px-4 py-3">
                <Skeleton className="h-10 w-16 rounded-md" />
                <div className="flex-1 space-y-2">
                  <Skeleton className="h-3.5 w-48" />
                  <Skeleton className="h-3 w-32" />
                </div>
              </div>
            ))}
          </div>
        ) : projects.length === 0 ? (
          <div className="p-5">
            <EmptyNote className="flex-col gap-2">
              <FolderOpenIcon className="size-5" />
              <span className="font-medium text-foreground">No projects yet</span>
              <span>
                Record one here, or in the Mac app open a capture and choose <b>Open in Web Editor</b>.
              </span>
            </EmptyNote>
          </div>
        ) : (
          <div className="divide-y divide-white/8">
            {projects.map((p) => (
              <button
                key={p.id}
                type="button"
                onClick={() => void navigate({ to: "/app/editor/$projectId", params: { projectId: p.id } })}
                className="group flex w-full items-center gap-4 px-4 py-3 text-left transition-colors hover:bg-white/[0.04]"
              >
                <span className="grid h-10 w-16 shrink-0 place-items-center overflow-hidden rounded-md border border-white/8 bg-black/40">
                  {p.thumbnailUrl ? (
                    <img src={p.thumbnailUrl} alt="" className="size-full object-cover" loading="lazy" />
                  ) : (
                    <FolderOpenIcon className="size-4 text-muted-foreground" />
                  )}
                </span>
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-sm font-medium">{p.name}</span>
                  <span className="mt-0.5 flex items-center gap-1.5 text-xs text-muted-foreground">
                    {p.duration > 0 && <span className="tabular-nums">{formatClock(p.duration)}</span>}
                    {p.duration > 0 && <span aria-hidden>·</span>}
                    <span>{p.aspectRatio}</span>
                    <span aria-hidden>·</span>
                    <span>edited {relative(p.updatedAt)}</span>
                  </span>
                </span>
                <span className="hidden items-center gap-1.5 rounded-full border border-white/10 bg-white/[0.04] px-2 py-0.5 text-[11px] text-muted-foreground sm:inline-flex">
                  {p.origin === "cloud" ? <CloudIcon className="size-3" /> : <LaptopIcon className="size-3" />}
                  {p.origin === "cloud" ? "Cloud" : "This Mac"}
                </span>
                <ChevronRightIcon className="size-4 text-muted-foreground transition-transform group-hover:translate-x-0.5" />
              </button>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}
