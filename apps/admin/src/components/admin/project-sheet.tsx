import { ExternalLink } from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Spinner } from "@/components/ui/spinner";
import { Facts, Section } from "@/components/admin/user-activity-sheet";
import { formatBytes, plural, relativeTime } from "@/lib/format";
import { trpc } from "@/lib/trpc/client";

const EDITED_IN: Record<"mac" | "web", string> = { mac: "Mac app", web: "web editor" };

/**
 * One cloud project, read-only and METADATA ONLY: who made it, its size and
 * history, the videos shared from it and its file list. The recording itself
 * is the owner's — the console never plays or downloads a project's files (a
 * shared video opens on its share page, like anyone's link).
 */
export function ProjectSheet({ projectId, onClose }: { projectId: string | null; onClose: () => void }) {
  const { data, isLoading, error } = trpc.admin.projectDetail.useQuery({ id: projectId ?? "" }, { enabled: projectId !== null });
  const project = data?.project;

  return (
    <Sheet open={projectId !== null} onOpenChange={(open) => !open && onClose()}>
      <SheetContent className="w-full overflow-y-auto data-[side=right]:sm:max-w-2xl">
        <SheetHeader>
          <SheetTitle className="flex items-center gap-2 pr-8">
            <span className="truncate">{project?.name ?? "Project"}</span>
            {project && !project.uploaded && <Badge variant="outline">Uploading</Badge>}
            {project?.uploaded && project.shares === 0 && <Badge variant="outline">Never shared</Badge>}
          </SheetTitle>
          <SheetDescription>
            {project ? `${project.owner.email ?? "Unknown owner"} · created ${relativeTime(project.createdAt)}` : " "}
          </SheetDescription>
        </SheetHeader>

        {isLoading && (
          <div className="flex justify-center p-8">
            <Spinner />
          </div>
        )}
        {error && <p className="px-4 text-sm text-destructive">{error.message}</p>}

        {data && project && (
          <div className="flex flex-col divide-y px-4 pb-8">
            <Section title="Details">
              <Facts
                rows={[
                  ["Owner", `${project.owner.name ?? "—"} · ${project.owner.email ?? "unknown"}${project.owner.blocked ? " · blocked" : ""}`],
                  ["Team", project.team ? (project.team.name ?? project.team.id) : "Personal"],
                  ["Created", relativeTime(project.createdAt)],
                  ["Last edited", `${relativeTime(project.updatedAt)}${data.lastEditedIn ? ` · in the ${EDITED_IN[data.lastEditedIn]}` : ""}`],
                  ["Saves", `${plural(project.revision, "save")} · ${plural(data.versions, "version")} in history`],
                  ["Size", `${formatBytes(project.totalBytes)} · ${plural(project.fileCount, "file")}`],
                  ["Project id", project.projectId],
                ]}
              />
            </Section>

            <Section title={`Shared videos (${data.videos.length})`}>
              {data.videos.length === 0 ? (
                <p className="text-muted-foreground">Never shared — this recording has no share link.</p>
              ) : (
                <ul className="space-y-2">
                  {data.videos.map((v) => (
                    <li key={v.videoId} className="flex flex-wrap items-center justify-between gap-2">
                      <div className="flex min-w-0 items-center gap-2">
                        <span className="truncate">{v.title}</span>
                        {v.removed && <Badge variant="destructive">Removed</Badge>}
                        {v.status !== "ready" && <Badge variant="outline">Uploading</Badge>}
                        <span className="text-xs text-muted-foreground">{relativeTime(v.createdAt)}</span>
                      </div>
                      <Button size="sm" variant="outline" asChild>
                        <a href={v.shareUrl} target="_blank" rel="noopener noreferrer">
                          <ExternalLink className="mr-1 h-4 w-4" /> Share page
                        </a>
                      </Button>
                    </li>
                  ))}
                </ul>
              )}
            </Section>

            <Section title={`Files (${data.files.length})`}>
              {data.files.length === 0 ? (
                <p className="text-muted-foreground">No files committed yet.</p>
              ) : (
                <ul className="space-y-1.5 text-sm">
                  {data.files.map((f) => (
                    <li key={f.path} className="flex justify-between gap-4">
                      <span className="min-w-0 truncate font-mono text-xs">{f.path}</span>
                      <span className="shrink-0 text-xs text-muted-foreground">{formatBytes(f.bytes)}</span>
                    </li>
                  ))}
                </ul>
              )}
            </Section>
          </div>
        )}
      </SheetContent>
    </Sheet>
  );
}
