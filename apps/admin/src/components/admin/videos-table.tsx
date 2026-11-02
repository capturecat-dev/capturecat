import { useState } from "react";
import { Film } from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Empty, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/components/ui/empty";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { TableLoading } from "@/components/ui/table-loading";
import { ProjectsList, SearchBox } from "@/components/admin/projects-table";
import { VideoModerationSheet } from "@/components/admin/video-moderation-sheet";
import { API_URL } from "@/lib/api-url";
import { formatBytes, formatDuration, relativeTime } from "@/lib/format";
import type { AdminVideo, VideoFilter } from "@/lib/moderation-types";
import { trpc } from "@/lib/trpc/client";

const FILTERS: Array<{ id: VideoFilter; label: string }> = [
  { id: "all", label: "All uploads" },
  { id: "reported", label: "Reported" },
  { id: "removed", label: "Removed" },
];

const VISIBILITY: Record<AdminVideo["visibility"], string> = {
  public: "Public",
  unlisted: "Link",
  password: "Password",
  private: "Private",
};

const EMPTY: Record<VideoFilter, { title: string; body: string }> = {
  all: { title: "No uploads yet", body: "Shared videos appear here the moment they're uploaded." },
  reported: { title: "Nothing reported", body: "When a viewer reports a video from its share page, it lands here." },
  removed: { title: "Nothing taken down", body: "Videos you take down are listed here, so you can restore them." },
};

/**
 * Every shared video, newest first — or the Reported queue (open viewer
 * reports, most recent first) or what was taken down. Search by title, file
 * name, owner email or video id. A row opens the moderation sheet.
 *
 * "Never shared" lists the recordings users have on CaptureCat that were
 * never shared as a video (cloud projects; the Projects page has them all).
 */
export function VideosTable() {
  const [filter, setFilter] = useState<VideoFilter>("reported");
  // Its own flag, so the videos query keeps its input (and its counts).
  const [unshared, setUnshared] = useState(false);
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  const [open, setOpen] = useState<string | null>(null);

  const list = trpc.admin.listVideos.useInfiniteQuery(
    { filter, q: query || undefined },
    { getNextPageParam: (last) => last.nextCursor ?? undefined, enabled: !unshared },
  );
  const unsharedCount = trpc.admin.listProjects.useQuery({ filter: "unshared", limit: 1 }).data?.counts.unshared;
  const pages = list.data?.pages ?? [];
  const videos = pages.flatMap((p) => p.videos);
  const counts = pages[0]?.counts;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div role="tablist" aria-label="Which videos" className="flex flex-wrap gap-1.5">
          {FILTERS.map((f) => (
            <Button
              key={f.id}
              role="tab"
              aria-selected={!unshared && filter === f.id}
              size="sm"
              variant={!unshared && filter === f.id ? "secondary" : "ghost"}
              onClick={() => {
                setFilter(f.id);
                setUnshared(false);
              }}
            >
              {f.label}
              {counts && (
                <Badge variant={f.id === "reported" && counts.reported > 0 ? "destructive" : "outline"} className="ml-1.5">
                  {counts[f.id]}
                </Badge>
              )}
            </Button>
          ))}
          <Button
            role="tab"
            aria-selected={unshared}
            size="sm"
            variant={unshared ? "secondary" : "ghost"}
            onClick={() => setUnshared(true)}
          >
            Never shared
            {unsharedCount !== undefined && (
              <Badge variant="outline" className="ml-1.5">
                {unsharedCount}
              </Badge>
            )}
          </Button>
        </div>
        <SearchBox
          value={search}
          placeholder={unshared ? "Name, owner email or project id" : "Title, owner email or video id"}
          label={unshared ? "Search projects" : "Search videos"}
          onChange={(v) => {
            setSearch(v);
            if (!v) setQuery("");
          }}
          onSubmit={() => setQuery(search.trim())}
        />
      </div>

      {unshared && <ProjectsList filter="unshared" query={query} />}

      {!unshared && list.error && <p className="text-sm text-destructive">{list.error.message}</p>}

      {unshared ? null : list.isLoading ? (
        <TableLoading />
      ) : videos.length === 0 && !list.error ? (
        <Empty className="border">
          <EmptyHeader>
            <EmptyMedia variant="icon">
              <Film />
            </EmptyMedia>
            <EmptyTitle>{query ? "No matches" : EMPTY[filter].title}</EmptyTitle>
            <EmptyDescription>{query ? `Nothing matches “${query}”.` : EMPTY[filter].body}</EmptyDescription>
          </EmptyHeader>
        </Empty>
      ) : (
        <div className="overflow-x-auto rounded-2xl border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-[45%]">Video</TableHead>
                <TableHead>Uploaded</TableHead>
                <TableHead>Who can watch</TableHead>
                <TableHead className="text-right">Views</TableHead>
                <TableHead className="text-right">Reports</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {videos.map((v) => (
                <TableRow key={v.videoId} className="cursor-pointer" onClick={() => setOpen(v.videoId)}>
                  <TableCell>
                    <div className="flex min-w-0 items-center gap-3">
                      <Thumb video={v} />
                      <div className="min-w-0">
                        <p className="truncate font-medium">{v.title}</p>
                        <p className="truncate text-xs text-muted-foreground">
                          {v.owner.email ?? "unknown owner"} · {formatDuration(v.durationSeconds)} · {formatBytes(v.sizeBytes)}
                        </p>
                      </div>
                    </div>
                  </TableCell>
                  <TableCell className="whitespace-nowrap text-muted-foreground">{relativeTime(v.createdAt)}</TableCell>
                  <TableCell>
                    {v.removed ? (
                      <Badge variant="destructive">Removed</Badge>
                    ) : v.status !== "ready" ? (
                      <Badge variant="outline">Uploading</Badge>
                    ) : (
                      <Badge variant="outline">{VISIBILITY[v.visibility]}</Badge>
                    )}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">{v.views}</TableCell>
                  <TableCell className="text-right">
                    {v.openReports > 0 ? (
                      <Badge variant="destructive" title={v.lastReportAt ? `Last ${relativeTime(v.lastReportAt)}` : undefined}>
                        {v.openReports}
                      </Badge>
                    ) : (
                      <span className="text-muted-foreground">—</span>
                    )}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}

      {!unshared && list.hasNextPage && (
        <div className="flex justify-center">
          <Button size="sm" variant="outline" disabled={list.isFetchingNextPage} onClick={() => list.fetchNextPage()}>
            {list.isFetchingNextPage ? "Loading…" : "Load more"}
          </Button>
        </div>
      )}

      <VideoModerationSheet videoId={open} onClose={() => setOpen(null)} />
    </div>
  );
}

/** The owner's custom poster when there is one (admin route — it shows even
 *  removed or private videos), else a placeholder. */
function Thumb({ video }: { video: AdminVideo }) {
  const [failed, setFailed] = useState(false);
  return (
    <div className="grid h-10 w-16 shrink-0 place-items-center overflow-hidden rounded-md bg-muted text-muted-foreground">
      {video.hasThumbnail && !failed ? (
        <img
          src={`${API_URL}/api/admin/videos/${encodeURIComponent(video.videoId)}/thumbnail`}
          alt=""
          loading="lazy"
          className="h-full w-full object-cover"
          onError={() => setFailed(true)}
        />
      ) : (
        <Film className="h-4 w-4" />
      )}
    </div>
  );
}
