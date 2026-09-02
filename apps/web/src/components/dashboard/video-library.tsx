import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import {
  ArrowUpDown,
  HardDrive,
  LayoutGrid,
  ListVideo,
  Plus,
  Rows3,
  Search,
  Trash2,
  Video as VideoIcon,
  X,
} from "lucide-react";
import { toast } from "sonner";

import { trpc } from "@/lib/trpc/client";
import { cn } from "@/lib/utils";
import {
  ShareSettingsDialog,
  type ShareSettingsVideo,
} from "@/components/dashboard/share-settings-dialog";
import { VideoCard, UploadingCard } from "@/components/dashboard/video-card";
import { VideoTable } from "@/components/dashboard/video-table";
import type { DashboardVideo } from "@/components/dashboard/video-types";
import { formatSize } from "@/components/dashboard/video-format";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { LibrarySkeleton } from "@/components/dashboard/page-skeletons";
import {
  Empty,
  EmptyDescription,
  EmptyHeader,
  EmptyMedia,
  EmptyTitle,
} from "@/components/ui/empty";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
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

type SortKey = "newest" | "oldest" | "name" | "size" | "duration";
const SORT_LABELS: Record<SortKey, string> = {
  newest: "Newest first",
  oldest: "Oldest first",
  name: "Name",
  size: "Size",
  duration: "Duration",
};

/** In-flight desktop share uploads, mirrored from the ShareJobs Durable
 *  Object. Polls while anything is active so bars move in real time. */
function useActiveUploads() {
  const utils = trpc.useUtils();
  const { data } = trpc.videos.uploadJobs.useQuery(undefined, {
    refetchInterval: (query) =>
      query.state.data?.jobs.some(
        (j) => j.state === "uploading" || j.state === "completing"
      )
        ? 2000
        : 30000,
  });

  const doneCount = (data?.jobs ?? []).filter((j) => j.state === "done").length;
  useEffect(() => {
    if (doneCount > 0) void utils.videos.list.invalidate();
  }, [doneCount, utils]);

  return (data?.jobs ?? []).filter(
    (j) => j.state === "uploading" || j.state === "completing"
  );
}

function StorageMeter({
  usedBytes,
  limitBytes,
}: {
  usedBytes: number;
  limitBytes: number | undefined;
}) {
  if (!limitBytes) return null;
  const ratio = Math.min(1, usedBytes / limitBytes);
  const barColor =
    ratio >= 0.95 ? "bg-red-500" : ratio >= 0.8 ? "bg-amber-500" : "bg-primary";
  return (
    <div className="flex items-center gap-3 text-xs text-muted-foreground">
      <HardDrive className="size-3.5 shrink-0" />
      <div className="h-1.5 w-28 overflow-hidden rounded-full bg-white/10">
        <div
          className={cn("h-full rounded-full transition-[width]", barColor)}
          style={{ width: `${Math.max(1, ratio * 100)}%` }}
        />
      </div>
      <span className="tabular-nums">
        {formatSize(usedBytes)} / {formatSize(limitBytes)}
      </span>
    </div>
  );
}

export function VideoLibrary({ playlistFilter }: { playlistFilter?: string }) {
  const navigate = useNavigate();
  const utils = trpc.useUtils();
  const { data, isLoading } = trpc.videos.list.useQuery();
  const activeUploads = useActiveUploads();

  const invalidate = () => void utils.videos.list.invalidate();

  const setPrivacy = trpc.videos.setPrivacy.useMutation({
    onSuccess: invalidate,
    onError: (e) => toast.error(e.message ?? "Failed to update privacy"),
  });
  const deleteVideo = trpc.videos.delete.useMutation();
  const generateAi = trpc.videos.generateAiSummary.useMutation({
    onSuccess: (d) => {
      toast.success(d.title ? `AI: "${d.title}"` : "AI summary generated");
      invalidate();
    },
    onError: (e) => toast.error(e.message),
  });

  // Playlists
  const playlistsQuery = trpc.videos.playlists.useQuery();
  const playlists = playlistsQuery.data?.playlists ?? [];
  const invalidatePlaylists = () => void utils.videos.playlists.invalidate();
  const createPlaylist = trpc.videos.createPlaylist.useMutation({
    onSuccess: (p) => {
      invalidatePlaylists();
      void navigate({ to: "/app", search: { playlist: p.playlistId } });
      setCreatingPlaylist(false);
      setNewPlaylistName("");
    },
    onError: (e) => toast.error(e.message),
  });
  const deletePlaylist = trpc.videos.deletePlaylist.useMutation({
    onSuccess: () => {
      invalidatePlaylists();
      void navigate({ to: "/app", search: {} });
    },
    onError: (e) => toast.error(e.message),
  });
  const addToPlaylist = trpc.videos.addToPlaylist.useMutation({
    onSuccess: invalidatePlaylists,
    onError: (e) => toast.error(e.message),
  });
  const removeFromPlaylist = trpc.videos.removeFromPlaylist.useMutation({
    onSuccess: invalidatePlaylists,
    onError: (e) => toast.error(e.message),
  });

  // UI state
  const [searchQ, setSearchQ] = useState("");
  const [sort, setSort] = useState<SortKey>("newest");
  const [view, setView] = useState<"grid" | "list">("grid");
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [deleteTargets, setDeleteTargets] = useState<string[]>([]);
  const [deleting, setDeleting] = useState(false);
  const [settingsTarget, setSettingsTarget] = useState<ShareSettingsVideo | null>(null);
  const [creatingPlaylist, setCreatingPlaylist] = useState(false);
  const [newPlaylistName, setNewPlaylistName] = useState("");

  const transcriptSearch = trpc.videos.transcriptSearch.useQuery(
    { q: searchQ },
    { enabled: searchQ.trim().length >= 2 }
  );

  const allItems: DashboardVideo[] = data?.videos ?? [];
  const selectedPlaylist =
    playlists.find((p) => p.playlistId === playlistFilter) ?? null;

  const items = useMemo(() => {
    let out = selectedPlaylist
      ? allItems.filter((v) => selectedPlaylist.videoIds.includes(v.videoId))
      : allItems;
    const q = searchQ.trim().toLowerCase();
    if (q) out = out.filter((v) => v.fileName.toLowerCase().includes(q));
    const sorted = [...out];
    switch (sort) {
      case "newest":
        sorted.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
        break;
      case "oldest":
        sorted.sort((a, b) => a.createdAt.localeCompare(b.createdAt));
        break;
      case "name":
        sorted.sort((a, b) => a.fileName.localeCompare(b.fileName));
        break;
      case "size":
        sorted.sort((a, b) => b.fileSizeBytes - a.fileSizeBytes);
        break;
      case "duration":
        sorted.sort((a, b) => b.durationSeconds - a.durationSeconds);
        break;
    }
    return sorted;
  }, [allItems, selectedPlaylist, searchQ, sort]);

  const toggleSelect = (id: string) =>
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  const runDelete = async (ids: string[]) => {
    setDeleting(true);
    let failed = 0;
    for (const id of ids) {
      try {
        await deleteVideo.mutateAsync({ videoId: id });
      } catch {
        failed += 1;
      }
    }
    setDeleting(false);
    setDeleteTargets([]);
    setSelectedIds(new Set());
    invalidate();
    invalidatePlaylists();
    if (failed > 0) toast.error(`${failed} video${failed > 1 ? "s" : ""} could not be deleted`);
    else toast.success(ids.length > 1 ? `${ids.length} videos deleted` : "Video deleted");
  };

  const openShareSettings = (v: DashboardVideo) =>
    setSettingsTarget({
      videoId: v.videoId,
      orgId: v.orgId,
      fileName: v.fileName,
      allowDownload: v.allowDownload,
      hasPassword: v.hasPassword,
      expiresAt: v.expiresAt,
      maxViews: v.maxViews,
      brandAccent: v.brandAccent,
      thumbnailUrl: v.thumbnailUrl,
    });

  if (isLoading) return <LibrarySkeleton />;

  if (allItems.length === 0 && activeUploads.length === 0) {
    return (
      <Empty className="glass-panel hairline-top min-h-[420px]">
        <EmptyHeader>
          <EmptyMedia variant="icon">
            <VideoIcon />
          </EmptyMedia>
          <EmptyTitle>No videos yet</EmptyTitle>
          <EmptyDescription>
            Record and share a video from the CaptureCat app to see it here.
          </EmptyDescription>
        </EmptyHeader>
      </Empty>
    );
  }

  const cardProps = (v: DashboardVideo) => ({
    video: v,
    playlists,
    selected: selectedIds.has(v.videoId),
    selectionActive: selectedIds.size > 0,
    onToggleSelect: () => toggleSelect(v.videoId),
    onOpenShareSettings: () => openShareSettings(v),
    onDelete: () => setDeleteTargets([v.videoId]),
    onTogglePrivacy: (isPrivate: boolean) =>
      setPrivacy.mutate({ videoId: v.videoId, isPrivate }),
    onGenerateAi: () => generateAi.mutate({ videoId: v.videoId }),
    onTogglePlaylist: (playlistId: string, inPlaylist: boolean) =>
      inPlaylist
        ? removeFromPlaylist.mutate({ playlistId, videoId: v.videoId })
        : addToPlaylist.mutate({ playlistId, videoId: v.videoId }),
    aiPending: generateAi.isPending,
  });

  return (
    <div className="space-y-4">
      {/* Title row */}
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold tracking-tight">
            {selectedPlaylist
              ? `${selectedPlaylist.emoji ? `${selectedPlaylist.emoji} ` : ""}${selectedPlaylist.name}`
              : "Library"}
          </h1>
          <p className="mt-0.5 text-sm text-muted-foreground">
            {items.length} video{items.length === 1 ? "" : "s"}
            {activeUploads.length > 0 &&
              ` · ${activeUploads.length} uploading`}
          </p>
        </div>
        <StorageMeter
          usedBytes={data?.storageUsedBytes ?? 0}
          limitBytes={data?.storageLimitBytes}
        />
      </div>

      {/* Toolbar */}
      <div className="flex flex-wrap items-center gap-2">
        <div className="relative min-w-52 flex-1">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={searchQ}
            onChange={(e) => setSearchQ(e.target.value)}
            placeholder="Search titles and transcripts…"
            className="rounded-full border-white/10 bg-white/[0.04] pl-9 backdrop-blur-xl"
          />
          {searchQ && (
            <button
              aria-label="Clear search"
              onClick={() => setSearchQ("")}
              className="absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
            >
              <X className="size-4" />
            </button>
          )}
        </div>

        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="outline" size="sm" className="rounded-full border-white/10 bg-white/[0.04]">
              <ArrowUpDown className="mr-1.5 size-3.5" />
              {SORT_LABELS[sort]}
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            {(Object.keys(SORT_LABELS) as SortKey[]).map((k) => (
              <DropdownMenuItem key={k} onClick={() => setSort(k)}>
                {SORT_LABELS[k]}
                {sort === k && <span className="ml-auto">✓</span>}
              </DropdownMenuItem>
            ))}
          </DropdownMenuContent>
        </DropdownMenu>

        <div className="flex overflow-hidden rounded-full border border-white/10 bg-white/[0.04]">
          <button
            aria-label="Grid view"
            onClick={() => setView("grid")}
            className={cn(
              "px-3 py-1.5 transition-colors",
              view === "grid" ? "bg-white/10 text-foreground" : "text-muted-foreground hover:text-foreground"
            )}
          >
            <LayoutGrid className="size-4" />
          </button>
          <button
            aria-label="List view"
            onClick={() => setView("list")}
            className={cn(
              "px-3 py-1.5 transition-colors",
              view === "list" ? "bg-white/10 text-foreground" : "text-muted-foreground hover:text-foreground"
            )}
          >
            <Rows3 className="size-4" />
          </button>
        </div>
      </div>

      {/* Playlist chips */}
      <div className="flex flex-wrap items-center gap-2">
        <button
          onClick={() => void navigate({ to: "/app", search: {} })}
          className={cn(
            "rounded-full px-3 py-1 text-sm transition-colors",
            !selectedPlaylist
              ? "bg-primary text-primary-foreground"
              : "bg-white/[0.06] text-muted-foreground hover:text-foreground"
          )}
        >
          All videos
        </button>
        {playlists.map((p) => (
          <button
            key={p.playlistId}
            onClick={() =>
              void navigate({
                to: "/app",
                search:
                  playlistFilter === p.playlistId ? {} : { playlist: p.playlistId },
              })
            }
            className={cn(
              "rounded-full px-3 py-1 text-sm transition-colors",
              playlistFilter === p.playlistId
                ? "bg-primary text-primary-foreground"
                : "bg-white/[0.06] text-muted-foreground hover:text-foreground"
            )}
          >
            {p.emoji ? `${p.emoji} ` : ""}
            {p.name}
            <span className="ml-1 opacity-60">{p.videoIds.length}</span>
          </button>
        ))}
        {creatingPlaylist ? (
          <form
            className="flex items-center gap-1"
            onSubmit={(e) => {
              e.preventDefault();
              const name = newPlaylistName.trim();
              if (name) createPlaylist.mutate({ name });
            }}
          >
            <input
              autoFocus
              value={newPlaylistName}
              onChange={(e) => setNewPlaylistName(e.target.value)}
              onKeyDown={(e) => e.key === "Escape" && setCreatingPlaylist(false)}
              placeholder="Playlist name"
              maxLength={60}
              className="w-36 rounded-full border border-white/10 bg-transparent px-3 py-1 text-sm outline-none focus:ring-1 focus:ring-ring"
            />
            <Button size="sm" type="submit" disabled={createPlaylist.isPending}>
              Add
            </Button>
          </form>
        ) : (
          <button
            onClick={() => setCreatingPlaylist(true)}
            className="inline-flex items-center gap-1 rounded-full px-3 py-1 text-sm text-muted-foreground transition-colors hover:text-foreground"
          >
            <Plus className="size-3.5" /> New playlist
          </button>
        )}
        {selectedPlaylist && (
          <Button
            variant="ghost"
            size="sm"
            className="ml-auto text-muted-foreground hover:text-destructive"
            disabled={deletePlaylist.isPending}
            onClick={() =>
              deletePlaylist.mutate({ playlistId: selectedPlaylist.playlistId })
            }
          >
            <Trash2 className="mr-1 size-3.5" /> Delete playlist
          </Button>
        )}
      </div>

      {/* Transcript matches */}
      {searchQ.trim().length >= 2 && (
        <div className="glass-panel hairline-top p-4 text-sm">
          <p className="mb-2 text-xs font-medium uppercase tracking-wide text-muted-foreground">
            Transcript matches
          </p>
          {(transcriptSearch.data?.results ?? []).length === 0 ? (
            <p className="text-muted-foreground">
              {transcriptSearch.isFetching ? "Searching…" : "No transcript matches."}
            </p>
          ) : (
            <div className="space-y-3">
              {transcriptSearch.data!.results.map((r) => {
                const video = allItems.find((v) => v.videoId === r.videoId);
                return (
                  <div key={r.videoId}>
                    <p className="font-medium">{video?.fileName ?? r.videoId}</p>
                    <div className="mt-1 space-y-0.5">
                      {r.segments.map((seg, i) => (
                        <a
                          key={i}
                          href={`/share/${r.videoId}?t=${Math.floor(seg.start)}`}
                          target="_blank"
                          rel="noreferrer"
                          className="block rounded px-2 py-1 text-muted-foreground transition-colors hover:bg-white/[0.06] hover:text-foreground"
                        >
                          <span className="mr-2 font-mono text-xs tabular-nums">
                            {`${Math.floor(seg.start / 60)}:${String(Math.floor(seg.start % 60)).padStart(2, "0")}`}
                          </span>
                          {seg.text}
                        </a>
                      ))}
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}

      {/* Content */}
      {view === "grid" ? (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
          {activeUploads.map((job) => (
            <UploadingCard
              key={job.jobId}
              name={job.projectName || job.fileName}
              fileSizeBytes={job.fileSizeBytes}
              progress={job.progress}
              completing={job.state === "completing"}
            />
          ))}
          {items.map((v) => (
            <VideoCard key={v.videoId} {...cardProps(v)} />
          ))}
        </div>
      ) : (
        <VideoTable
          items={items}
          uploads={activeUploads}
          selectedIds={selectedIds}
          onToggleSelect={toggleSelect}
          onOpenShareSettings={openShareSettings}
          onDelete={(id) => setDeleteTargets([id])}
          onTogglePrivacy={(id, isPrivate) =>
            setPrivacy.mutate({ videoId: id, isPrivate })
          }
        />
      )}

      {/* Bulk-selection bar */}
      {selectedIds.size > 0 && (
        <div className="fixed inset-x-0 bottom-6 z-50 mx-auto flex w-fit items-center gap-3 rounded-full border border-white/12 bg-background/80 px-4 py-2 shadow-2xl backdrop-blur-2xl">
          <span className="text-sm tabular-nums">
            {selectedIds.size} selected
          </span>
          {playlists.length > 0 && (
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button variant="outline" size="sm" className="rounded-full">
                  <ListVideo className="mr-1.5 size-3.5" /> Add to playlist
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="center" side="top">
                {playlists.map((p) => (
                  <DropdownMenuItem
                    key={p.playlistId}
                    onClick={() => {
                      for (const id of selectedIds) {
                        if (!p.videoIds.includes(id)) {
                          addToPlaylist.mutate({ playlistId: p.playlistId, videoId: id });
                        }
                      }
                      setSelectedIds(new Set());
                    }}
                  >
                    <span className="mr-2 w-4 text-center">{p.emoji ?? ""}</span>
                    {p.name}
                  </DropdownMenuItem>
                ))}
              </DropdownMenuContent>
            </DropdownMenu>
          )}
          <Button
            variant="destructive"
            size="sm"
            className="rounded-full"
            onClick={() => setDeleteTargets([...selectedIds])}
          >
            <Trash2 className="mr-1.5 size-3.5" /> Delete
          </Button>
          <Button
            variant="ghost"
            size="sm"
            className="rounded-full"
            onClick={() => setSelectedIds(new Set())}
          >
            Clear
          </Button>
        </div>
      )}

      {settingsTarget && (
        <ShareSettingsDialog
          video={settingsTarget}
          onClose={() => setSettingsTarget(null)}
        />
      )}

      <AlertDialog
        open={deleteTargets.length > 0}
        onOpenChange={(open) => !open && !deleting && setDeleteTargets([])}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              Delete {deleteTargets.length > 1 ? `${deleteTargets.length} videos` : "video"}?
            </AlertDialogTitle>
            <AlertDialogDescription>
              This permanently deletes the video
              {deleteTargets.length > 1 ? "s" : ""} and share link
              {deleteTargets.length > 1 ? "s" : ""}. This cannot be undone.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={deleting}>Cancel</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              onClick={() => void runDelete(deleteTargets)}
              disabled={deleting}
            >
              {deleting ? "Deleting…" : "Delete"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
