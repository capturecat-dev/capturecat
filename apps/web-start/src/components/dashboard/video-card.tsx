import { useRef, useState } from "react";
import { Link } from "@tanstack/react-router";
import {
  AppWindowMac,
  BarChart3,
  CheckIcon,
  Copy,
  ExternalLink,
  Globe,
  ListVideo,
  Lock,
  MoreHorizontal,
  Settings2,
  Sparkles,
  Trash2,
} from "lucide-react";
import { toast } from "sonner";

import { API_URL } from "@/lib/api-url";
import { cn } from "@/lib/utils";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Spinner } from "@/components/ui/spinner";
import type { DashboardVideo, Playlist } from "./video-types";
import { formatDate, formatDuration, formatSize } from "./video-format";

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
        "group glass-panel hairline-top relative overflow-hidden transition-colors",
        selected
          ? "border-primary/60 bg-white/[0.07]"
          : "hover:border-white/16 hover:bg-white/[0.06]"
      )}
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
            "h-full w-full object-cover transition-transform duration-500",
            previewing && "scale-[1.03]"
          )}
        />
        <span className="absolute bottom-2 right-2 rounded-md bg-black/70 px-1.5 py-0.5 font-mono text-[11px] tabular-nums text-white/90 backdrop-blur-sm">
          {formatDuration(video.durationSeconds)}
        </span>
        {video.hasPassword && (
          <span className="absolute bottom-2 left-2 rounded-md bg-black/70 p-1 text-white/80 backdrop-blur-sm">
            <Lock className="size-3" />
          </span>
        )}
      </Link>

      {/* Selection checkbox — appears on hover or while a selection exists. */}
      <button
        aria-label={selected ? "Deselect video" : "Select video"}
        onClick={onToggleSelect}
        className={cn(
          "absolute left-2 top-2 z-10 flex size-6 items-center justify-center rounded-md border backdrop-blur-md transition-opacity",
          selected
            ? "border-primary bg-primary text-primary-foreground opacity-100"
            : "border-white/30 bg-black/50 text-transparent opacity-0 hover:text-white/60 group-hover:opacity-100",
          selectionActive && "opacity-100"
        )}
      >
        <CheckIcon className="size-4" />
      </button>

      {/* Meta row */}
      <div className="flex items-start gap-2 p-3">
        <div className="min-w-0 flex-1">
          <Link
            to="/app/videos/$videoId"
            params={{ videoId: video.videoId }}
            className="block truncate text-sm font-medium transition-colors hover:text-primary"
            title={video.fileName}
          >
            {video.fileName}
          </Link>
          <p className="mt-0.5 flex items-center gap-1.5 text-xs text-muted-foreground">
            <span>{formatDate(video.createdAt)}</span>
            <span aria-hidden>·</span>
            <span>{formatSize(video.fileSizeBytes)}</span>
          </p>
        </div>

        <Badge
          variant={video.isPrivate ? "secondary" : "default"}
          className="mt-0.5 shrink-0 cursor-pointer select-none text-[11px]"
          onClick={() => onTogglePrivacy(!video.isPrivate)}
          title={video.isPrivate ? "Private — click to publish" : "Public — click to make private"}
        >
          {video.isPrivate ? (
            <><Lock className="mr-1 size-3" />Private</>
          ) : (
            <><Globe className="mr-1 size-3" />Public</>
          )}
        </Badge>

        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="ghost" size="icon" className="size-7 shrink-0">
              <MoreHorizontal className="size-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem asChild>
              <Link to="/app/videos/$videoId" params={{ videoId: video.videoId }}>
                <Settings2 className="mr-2 size-4" />
                Details &amp; versions
              </Link>
            </DropdownMenuItem>
            <DropdownMenuItem asChild>
              <Link
                to="/app/videos/$videoId/analytics"
                params={{ videoId: video.videoId }}
              >
                <BarChart3 className="mr-2 size-4" />
                Analytics
              </Link>
            </DropdownMenuItem>
            <DropdownMenuItem onClick={onOpenShareSettings}>
              <Settings2 className="mr-2 size-4" />
              Share settings
            </DropdownMenuItem>
            {playlists.length > 0 && (
              <DropdownMenuSub>
                <DropdownMenuSubTrigger>
                  <ListVideo className="mr-2 size-4" />
                  Playlists
                </DropdownMenuSubTrigger>
                <DropdownMenuSubContent>
                  {playlists.map((p) => {
                    const inPlaylist = p.videoIds.includes(video.videoId);
                    return (
                      <DropdownMenuItem
                        key={p.playlistId}
                        onClick={() => onTogglePlaylist(p.playlistId, inPlaylist)}
                      >
                        <span className="mr-2 w-4 text-center">
                          {inPlaylist ? "✓" : (p.emoji ?? "")}
                        </span>
                        {p.name}
                      </DropdownMenuItem>
                    );
                  })}
                </DropdownMenuSubContent>
              </DropdownMenuSub>
            )}
            {video.projectId && (
              <DropdownMenuItem asChild>
                {/* capturecat:// is handled by the app's DeepLinkHandler. */}
                <a href={`capturecat://open-project?id=${video.projectId}`}>
                  <AppWindowMac className="mr-2 size-4" />
                  Open in CaptureCat
                </a>
              </DropdownMenuItem>
            )}
            <DropdownMenuItem disabled={aiPending} onClick={onGenerateAi}>
              <Sparkles className="mr-2 size-4" />
              {aiPending ? "Generating…" : "Generate AI summary"}
            </DropdownMenuItem>
            {!video.isPrivate && (
              <>
                <DropdownMenuSeparator />
                <DropdownMenuItem onClick={() => window.open(video.url, "_blank")}>
                  <ExternalLink className="mr-2 size-4" />
                  Open share link
                </DropdownMenuItem>
                <DropdownMenuItem onClick={copyLink}>
                  <Copy className="mr-2 size-4" />
                  Copy link
                </DropdownMenuItem>
              </>
            )}
            <DropdownMenuSeparator />
            <DropdownMenuItem
              className="text-destructive focus:text-destructive"
              onClick={onDelete}
            >
              <Trash2 className="mr-2 size-4" />
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
    <div className="glass-panel hairline-top overflow-hidden">
      <div className="relative flex aspect-video w-full items-center justify-center rounded-t-[inherit] bg-black/60">
        <Spinner className="size-6 text-muted-foreground" />
        <div className="absolute inset-x-4 bottom-3 h-1 overflow-hidden rounded-full bg-white/10">
          <div
            className="h-full rounded-full bg-primary transition-[width] duration-500"
            style={{ width: `${Math.max(2, percent)}%` }}
          />
        </div>
      </div>
      <div className="p-3">
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
