import { useRef, useState, type ComponentProps, type CSSProperties } from "react";
import { Link } from "@tanstack/react-router";
import { BarChart3, Lock, MoreHorizontal } from "lucide-react";
import { toast } from "sonner";

import { API_URL } from "@/lib/api-url";
import { cn } from "@/lib/utils";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuCheckboxItem,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { LiveDot, Meter } from "@/components/dashboard/studio";
import type { DashboardVideo, Playlist } from "./video-types";
import { CCIcon } from "@/editor/ui/kit/ccIcon";
import { formatDate, formatDuration, formatSize } from "./video-format";

/** Public / Private, one look everywhere: smoked glass (legible on any
 *  still), cyan when anyone with the link can watch. */
export function VisibilityBadge({
  isPrivate,
  className,
  ...rest
}: { isPrivate: boolean } & Omit<ComponentProps<typeof Badge>, "variant" | "children">) {
  return (
    <Badge
      variant="outline"
      className={cn(
        "gap-1 text-[11px] backdrop-blur-md",
        isPrivate
          ? "border-white/12 bg-black/55 text-white/75"
          : "border-cyan-300/30 bg-black/55 text-cyan-200",
        className,
      )}
      {...rest}
    >
      {isPrivate ? (
        <>
          <Lock className="size-3" />
          Private
        </>
      ) : (
        <>
          <CCIcon name="globe" className="size-3" />
          Public
        </>
      )}
    </Badge>
  );
}

/**
 * One video in the library grid. The thumbnail is the video itself at
 * preload="metadata" (the API has no thumbnail pipeline) — hovering plays a
 * muted preview. The media request rides the same-site session cookie, which
 * is how private videos preview for their owner.
 */
export function VideoCard({
  video,
  playlists,
  selected,
  selectionActive,
  onToggleSelect,
  onOpenShareSettings,
  onDelete,
  onTogglePrivacy,
  onGenerateAi,
  onTogglePlaylist,
  aiPending,
  index = 0,
}: {
  video: DashboardVideo;
  playlists: Playlist[];
  selected: boolean;
  selectionActive: boolean;
  onToggleSelect: () => void;
  onOpenShareSettings: () => void;
  onDelete: () => void;
  onTogglePrivacy: (isPrivate: boolean) => void;
  onGenerateAi: () => void;
  onTogglePlaylist: (playlistId: string, inPlaylist: boolean) => void;
  aiPending: boolean;
  /** Position in the grid — staggers the arrival. */
  index?: number;
}) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [previewing, setPreviewing] = useState(false);

  const startPreview = () => {
    const el = videoRef.current;
    if (!el) return;
    setPreviewing(true);
    void el.play().catch(() => {});
  };
  const stopPreview = () => {
    const el = videoRef.current;
    if (!el) return;
    setPreviewing(false);
    el.pause();
    el.currentTime = 0;
  };

  const copyLink = () => {
    void navigator.clipboard.writeText(video.url);
    toast.success("Link copied");
  };

  return (
    <div
      className={cn(
        "group glass-panel hairline-top dsh-card dsh-rise relative overflow-hidden",
        selected
          ? "border-primary/50 bg-cc-ink/[0.07] ring-1 ring-primary/30"
          : "hover:border-cc-ink/16 hover:bg-cc-ink/[0.06]"
      )}
      style={{ "--i": Math.min(index, 11) } as CSSProperties}
    >
      {/* Thumbnail */}
      <Link
        to="/app/videos/$videoId"
        params={{ videoId: video.videoId }}
        className="relative block aspect-video w-full overflow-hidden rounded-t-[inherit] bg-black"
        onMouseEnter={startPreview}
        onMouseLeave={stopPreview}
        onClick={(e) => {
          if (selectionActive) {
            e.preventDefault();
            onToggleSelect();
          }
        }}
      >
        <video
          ref={videoRef}
          // #t=0.5 forces the browser to decode and PAINT a frame at 0.5s as
          // the still — plain preload="metadata" left cards black until hover
          // (recordings often have a black/dead frame at t=0).
          src={`${API_URL}/api/video/${video.videoId}?v=${video.currentVersion}#t=0.5`}
          // A custom thumbnail wins as the still; playback replaces it on
          // hover. Without one the #t=0.5 fragment paints a decoded frame.
          poster={video.thumbnailUrl ?? undefined}
          preload="metadata"
          muted
          loop
          playsInline
          className={cn(
            "dsh-thumb-media h-full w-full object-cover",
            previewing && "scale-[1.035]"
          )}
        />
        <span aria-hidden className="dsh-thumb-shade" />
        <span className="absolute bottom-2 right-2 rounded-md border border-white/10 bg-black/60 px-1.5 py-0.5 font-mono text-[11px] tabular-nums text-white/90 backdrop-blur-sm">
          {formatDuration(video.durationSeconds)}
        </span>
        {video.hasPassword && (
          <span className="absolute bottom-2 left-2 rounded-md border border-white/10 bg-black/60 p-1 text-white/80 backdrop-blur-sm">
            <Lock className="size-3" />
          </span>
        )}
        {previewing && (
          <span className="dsh-pop absolute bottom-2 left-1/2 inline-flex -translate-x-1/2 items-center gap-1.5 rounded-full border border-white/10 bg-black/60 px-2 py-0.5 text-[10px] font-medium uppercase tracking-[0.08em] text-white/85 backdrop-blur-sm">
            <LiveDot tone="green" className="size-1.5" /> Preview
          </span>
        )}
      </Link>

      {/* Visibility — on the still, top-right; click to flip. A video
          CaptureCat took down says so instead (nothing to flip). */}
      {video.removed ? (
        <Badge
          variant="destructive"
          className="absolute right-2 top-2 z-10 select-none"
          title={video.removed.reason ? `Removed by CaptureCat: ${video.removed.reason}` : "Removed by CaptureCat"}
        >
          Removed
        </Badge>
      ) : (
        <VisibilityBadge
          isPrivate={video.isPrivate}
          className="absolute right-2 top-2 z-10 cursor-pointer select-none"
          onClick={() => onTogglePrivacy(!video.isPrivate)}
          title={video.isPrivate ? "Private — click to publish" : "Public — click to make private"}
        />
      )}

      {/* Selection checkbox — appears on hover or while a selection exists. */}
      <button
        aria-label={selected ? "Deselect video" : "Select video"}
        onClick={onToggleSelect}
        className={cn(
          "absolute left-2 top-2 z-10 flex size-6 items-center justify-center rounded-md border backdrop-blur-md transition-opacity",
          selected
            ? "border-primary bg-primary text-white opacity-100"
            : "border-white/30 bg-black/50 text-transparent opacity-0 hover:text-white/60 group-hover:opacity-100",
          selectionActive && "opacity-100"
        )}
      >
        <CCIcon name="check" className="size-4" />
      </button>

      {/* Meta row */}
      <div className="flex items-start gap-2 px-3.5 pb-3 pt-3">
        <div className="min-w-0 flex-1">
          <Link
            to="/app/videos/$videoId"
            params={{ videoId: video.videoId }}
            className="block truncate text-sm font-medium tracking-[-0.005em] transition-colors hover:text-primary"
            title={video.fileName}
          >
            {video.fileName}
          </Link>
          <p className="mt-0.5 truncate text-xs text-muted-foreground">
            {formatDate(video.createdAt)}
            <span aria-hidden> · </span>
            <span className="tabular-nums">{formatSize(video.fileSizeBytes)}</span>
          </p>
        </div>

        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button
              variant="ghost"
              size="icon"
              aria-label={`More actions for ${video.fileName}`}
              className="-mr-1.5 size-7 shrink-0 text-muted-foreground hover:text-foreground"
            >
              <MoreHorizontal className="size-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem asChild>
              <Link to="/app/videos/$videoId" params={{ videoId: video.videoId }}>
                <CCIcon name="sliders" />
                Details &amp; versions
              </Link>
            </DropdownMenuItem>
            <DropdownMenuItem asChild>
              <Link
                to="/app/videos/$videoId/analytics"
                params={{ videoId: video.videoId }}
              >
                <BarChart3 />
                Analytics
              </Link>
            </DropdownMenuItem>
            <DropdownMenuItem onClick={onOpenShareSettings}>
              <CCIcon name="share" />
              Share settings
            </DropdownMenuItem>
            {playlists.length > 0 && (
              <DropdownMenuSub>
                <DropdownMenuSubTrigger>
                  <CCIcon name="film" />
                  Playlists
                </DropdownMenuSubTrigger>
                <DropdownMenuSubContent>
                  {playlists.map((p) => {
                    const inPlaylist = p.videoIds.includes(video.videoId);
                    return (
                      <DropdownMenuCheckboxItem
                        key={p.playlistId}
                        checked={inPlaylist}
                        onCheckedChange={() => onTogglePlaylist(p.playlistId, inPlaylist)}
                      >
                        <span className="cc-dd-glyph" aria-hidden>
                          {p.emoji ?? ""}
                        </span>
                        {p.name}
                      </DropdownMenuCheckboxItem>
                    );
                  })}
                </DropdownMenuSubContent>
              </DropdownMenuSub>
            )}
            {video.projectId && (
              <DropdownMenuItem asChild>
                {/* capturecat:// is handled by the app's DeepLinkHandler. */}
                <a href={`capturecat://open-project?id=${video.projectId}`}>
                  <CCIcon name="window" />
                  Open in CaptureCat
                </a>
              </DropdownMenuItem>
            )}
            <DropdownMenuItem disabled={aiPending} onClick={onGenerateAi}>
              <CCIcon name="sparkles" />
              {aiPending ? "Generating…" : "Generate AI summary"}
            </DropdownMenuItem>
            {!video.isPrivate && (
              <>
                <DropdownMenuSeparator />
                <DropdownMenuItem onClick={() => window.open(video.url, "_blank")}>
                  <CCIcon name="arrow-up-right" />
                  Open share link
                </DropdownMenuItem>
                <DropdownMenuItem onClick={copyLink}>
                  <CCIcon name="clipboard" />
                  Copy link
                </DropdownMenuItem>
              </>
            )}
            <DropdownMenuSeparator />
            <DropdownMenuItem variant="destructive" onClick={onDelete}>
              <CCIcon name="trash" />
              Delete
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
    </div>
  );
}

/** A desktop upload still in flight, as a grid card with a live progress bar. */
export function UploadingCard({
  name,
  fileSizeBytes,
  progress,
  completing,
}: {
  name: string;
  fileSizeBytes: number;
  progress: number;
  completing: boolean;
}) {
  const percent = Math.round(progress * 100);
  return (
    <div className="glass-panel hairline-top dsh-pop relative overflow-hidden border-primary/20">
      <div className="relative flex aspect-video w-full items-center justify-center overflow-hidden rounded-t-[inherit] bg-cc-elevated">
        <span aria-hidden className="dsh-sweep" />
        <span className="cc-float-chip inline-flex items-center gap-2 rounded-full px-3 py-1 text-[12px] font-medium text-foreground">
          <LiveDot />
          {completing ? "Finishing" : "Uploading"}
        </span>
        <Meter value={Math.max(0.02, progress)} className="absolute inset-x-4 bottom-3 h-1" />
      </div>
      <div className="px-3.5 pb-3 pt-3">
        <p className="truncate text-sm font-medium">{name}</p>
        <p className="mt-0.5 text-xs tabular-nums text-muted-foreground">
          {completing
            ? "Creating share link…"
            : `Uploading ${percent}%${fileSizeBytes > 0 ? ` · ${formatSize(fileSizeBytes)}` : ""}`}
        </p>
      </div>
    </div>
  );
}
