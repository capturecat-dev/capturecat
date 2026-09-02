import { Link } from "@tanstack/react-router";
import { CheckIcon, Globe, Lock, Settings2, Trash2 } from "lucide-react";

import { cn } from "@/lib/utils";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Spinner } from "@/components/ui/spinner";
import { Switch } from "@/components/ui/switch";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { DashboardVideo } from "./video-types";
import { formatDate, formatDuration, formatSize } from "./video-format";

interface UploadJob {
  jobId: string;
  projectName: string | null;
  fileName: string;
  fileSizeBytes: number;
  progress: number;
  state: string;
}

/** Compact list view of the library — the denser sibling of the card grid. */
export function VideoTable({
  items,
  uploads,
  selectedIds,
  onToggleSelect,
  onOpenShareSettings,
  onDelete,
  onTogglePrivacy,
}: {
  items: DashboardVideo[];
  uploads: UploadJob[];
  selectedIds: Set<string>;
  onToggleSelect: (id: string) => void;
  onOpenShareSettings: (v: DashboardVideo) => void;
  onDelete: (id: string) => void;
  onTogglePrivacy: (id: string, isPrivate: boolean) => void;
}) {
  return (
    <div className="glass-panel hairline-top overflow-hidden">
      <Table>
        <TableHeader>
          <TableRow className="border-white/8 hover:bg-transparent">
            <TableHead className="w-10" />
            <TableHead>Name</TableHead>
            <TableHead className="hidden sm:table-cell">Duration</TableHead>
            <TableHead className="hidden sm:table-cell">Size</TableHead>
            <TableHead className="hidden md:table-cell">Date</TableHead>
            <TableHead>Visibility</TableHead>
            <TableHead className="w-24" />
          </TableRow>
        </TableHeader>
        <TableBody>
          {uploads.map((job) => (
            <TableRow key={job.jobId} className="border-white/8 bg-white/[0.02]">
              <TableCell />
              <TableCell className="max-w-[240px] font-medium">
                <div className="truncate">{job.projectName || job.fileName}</div>
                <div className="mt-1.5 h-1 w-full max-w-[180px] overflow-hidden rounded-full bg-white/10">
                  <div
                    className="h-full rounded-full bg-primary transition-[width] duration-500"
                    style={{ width: `${Math.max(2, Math.round(job.progress * 100))}%` }}
                  />
                </div>
              </TableCell>
              <TableCell className="hidden sm:table-cell text-muted-foreground">—</TableCell>
              <TableCell className="hidden sm:table-cell text-muted-foreground">
                {job.fileSizeBytes > 0 ? formatSize(job.fileSizeBytes) : "—"}
              </TableCell>
              <TableCell className="hidden md:table-cell text-muted-foreground">now</TableCell>
              <TableCell colSpan={2}>
                <span className="inline-flex items-center gap-2 text-sm tabular-nums text-muted-foreground">
                  <Spinner className="size-3.5" />
                  {job.state === "completing"
                    ? "Creating share link…"
                    : `Uploading ${Math.round(job.progress * 100)}%`}
                </span>
              </TableCell>
            </TableRow>
          ))}
          {items.map((video) => {
            const selected = selectedIds.has(video.videoId);
            return (
              <TableRow
                key={video.videoId}
                className={cn("border-white/8", selected && "bg-white/[0.05]")}
              >
                <TableCell>
                  <button
                    aria-label={selected ? "Deselect video" : "Select video"}
                    onClick={() => onToggleSelect(video.videoId)}
                    className={cn(
                      "flex size-5 items-center justify-center rounded border transition-colors",
                      selected
                        ? "border-primary bg-primary text-primary-foreground"
                        : "border-white/20 text-transparent hover:border-white/40"
                    )}
                  >
                    <CheckIcon className="size-3.5" />
                  </button>
                </TableCell>
                <TableCell className="max-w-[240px] truncate font-medium">
                  <Link
                    to="/app/videos/$videoId"
                    params={{ videoId: video.videoId }}
                    className="transition-colors hover:text-primary"
                  >
                    {video.fileName}
                  </Link>
                </TableCell>
                <TableCell className="hidden sm:table-cell text-muted-foreground">
                  {formatDuration(video.durationSeconds)}
                </TableCell>
                <TableCell className="hidden sm:table-cell text-muted-foreground">
                  {formatSize(video.fileSizeBytes)}
                </TableCell>
                <TableCell className="hidden md:table-cell text-muted-foreground">
                  {formatDate(video.createdAt)}
                </TableCell>
                <TableCell>
                  <div className="flex items-center gap-2">
                    <Switch
                      checked={!video.isPrivate}
                      onCheckedChange={(checked) =>
                        onTogglePrivacy(video.videoId, !checked)
                      }
                    />
                    <Badge
                      variant={video.isPrivate ? "secondary" : "default"}
                      className="text-xs"
                    >
                      {video.isPrivate ? (
                        <><Lock className="mr-1 size-3" />Private</>
                      ) : (
                        <><Globe className="mr-1 size-3" />Public</>
                      )}
                    </Badge>
                  </div>
                </TableCell>
                <TableCell>
                  <div className="flex justify-end gap-1">
                    <Button
                      variant="ghost"
                      size="icon"
                      className="size-7"
                      title="Share settings"
                      onClick={() => onOpenShareSettings(video)}
                    >
                      <Settings2 className="size-4" />
                    </Button>
                    <Button
                      variant="ghost"
                      size="icon"
                      className="size-7 text-muted-foreground hover:text-destructive"
                      title="Delete"
                      onClick={() => onDelete(video.videoId)}
                    >
                      <Trash2 className="size-4" />
                    </Button>
                  </div>
                </TableCell>
              </TableRow>
            );
          })}
        </TableBody>
      </Table>
    </div>
  );
}
