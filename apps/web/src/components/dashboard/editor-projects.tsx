/**
 * Projects (/app/projects) — the editable projects the web editor opens:
 * cloud projects (pushed from the Mac with "Open in Web Editor", or recorded
 * here), plus — on the dev server only — this Mac's local projects. A media
 * grid like the Library's; a card opens /app/editor/<UUID>.
 */
import { useEffect, useState, type CSSProperties } from "react";
import { Link, useNavigate } from "@tanstack/react-router";
import { ArrowRightIcon, CircleIcon, CloudIcon, LaptopIcon } from "lucide-react";

import { Button } from "@/components/ui/button";
import { EmptyStage, PageHeader } from "@/components/dashboard/studio";
import { EditorArt } from "@/components/dashboard/empty-art";
import { MEDIA_GRID, SkeletonMediaCard } from "@/components/dashboard/page-skeletons";
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

function ProjectCard({ project: p, index, onOpen }: { project: EditorProjectSummary; index: number; onOpen: () => void }) {
  return (
    <button
      type="button"
      onClick={onOpen}
      className="group glass-panel hairline-top dsh-card dsh-rise relative block w-full overflow-hidden text-left outline-none hover:border-white/16 hover:bg-white/[0.06] focus-visible:border-cyan-300/50"
      style={{ "--i": Math.min(index, 11) } as CSSProperties}
    >
      <span className="relative block aspect-video w-full overflow-hidden rounded-t-[inherit] bg-black">
        {p.thumbnailUrl ? (
          <img
            src={p.thumbnailUrl}
            alt=""
            loading="lazy"
            className="dsh-thumb-media size-full object-cover group-hover:scale-[1.035]"
          />
        ) : (
          <span aria-hidden className="dsh-thumb-media dsh-proj-ph group-hover:scale-[1.035]" />
        )}
        <span aria-hidden className="dsh-thumb-shade" />
        <span className="absolute left-2 top-2 inline-flex items-center gap-1.5 rounded-full border border-white/12 bg-black/55 px-2 py-0.5 text-[11px] font-medium text-white/85 backdrop-blur-md">
          {p.origin === "cloud" ? <CloudIcon className="size-3" /> : <LaptopIcon className="size-3" />}
          {p.origin === "cloud" ? "Cloud" : "This Mac"}
        </span>
        {p.duration > 0 && (
          <span className="absolute bottom-2 right-2 rounded-md border border-white/10 bg-black/60 px-1.5 py-0.5 font-mono text-[11px] tabular-nums text-white/90 backdrop-blur-sm">
            {formatClock(p.duration)}
          </span>
        )}
        <span className="dsh-hover-hint absolute bottom-2 left-2 inline-flex items-center gap-1 rounded-full bg-white px-2.5 py-1 text-[11px] font-semibold text-black shadow-lg">
          Open in editor <ArrowRightIcon className="size-3" />
        </span>
      </span>
      <span className="block px-3.5 pb-3 pt-3">
        <span className="block truncate text-sm font-medium tracking-[-0.005em]">{p.name}</span>
        <span className="mt-0.5 block truncate text-xs text-muted-foreground">
          {p.aspectRatio}
          <span aria-hidden> · </span>
          edited {relative(p.updatedAt)}
        </span>
      </span>
    </button>
  );
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

      {projects === null ? (
        <div className={MEDIA_GRID}>
          {Array.from({ length: 4 }, (_, i) => (
            <SkeletonMediaCard key={i} />
          ))}
        </div>
      ) : projects.length === 0 ? (
        <section className="glass-panel hairline-top studio-panel dsh-rise overflow-hidden">
          <EmptyStage
            art={<EditorArt />}
            title="No projects yet"
            description={
              <>
                Record one here, or in the Mac app open a capture and choose{" "}
                <b className="text-foreground">Open in Web Editor</b>.
              </>
            }
            actions={
              <Button size="sm" className="bg-red-500 text-white hover:bg-red-500/90" asChild>
                <Link to="/app/record">
                  <CircleIcon className="fill-current" /> Record a project
                </Link>
              </Button>
            }
          />
        </section>
      ) : (
        <div className={MEDIA_GRID}>
          {projects.map((p, i) => (
            <ProjectCard
              key={p.id}
              project={p}
              index={i}
              onOpen={() => void navigate({ to: "/app/editor/$projectId", params: { projectId: p.id } })}
            />
          ))}
        </div>
      )}
    </div>
  );
}
