import { useState } from "react";
import { ExternalLink } from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
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
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Spinner } from "@/components/ui/spinner";
import { Facts, Section } from "@/components/admin/user-activity-sheet";
import { API_URL } from "@/lib/api-url";
import { formatBytes, formatDuration, relativeTime } from "@/lib/format";
import type { AdminVideo, AdminVideoDetail } from "@/lib/moderation-types";
import { trpc } from "@/lib/trpc/client";

const VISIBILITY_LABEL: Record<AdminVideo["visibility"], string> = {
  public: "Public (on their profile)",
  unlisted: "Anyone with the link",
  password: "Password protected",
  private: "Private (owner only)",
};

const ACTION_LABEL: Record<AdminVideoDetail["history"][number]["action"], string> = {
  remove: "Taken down",
  restore: "Restored",
  dismiss: "Reports dismissed",
  delete: "Deleted",
};

/** Quick reasons for a takedown; the owner sees whichever is sent. */
const REMOVAL_PRESETS = [
  "Sexual content",
  "Violence or gore",
  "Hate speech or harassment",
  "Spam or scam",
  "Illegal content",
  "Copyright infringement",
];

/**
 * One video, for moderating it: the player (the admin stream — it plays even
 * removed or private videos), who uploaded it, who can watch it, the reports
 * and what admins already did. Actions: take down (with a reason the owner
 * sees), restore, dismiss the reports, or delete for good.
 */
export function VideoModerationSheet({ videoId, onClose }: { videoId: string | null; onClose: () => void }) {
  const { data, isLoading, error } = trpc.admin.videoDetail.useQuery({ id: videoId ?? "" }, { enabled: videoId !== null });
  const utils = trpc.useUtils();
  const refresh = async () => {
    await Promise.all([utils.admin.videoDetail.invalidate(), utils.admin.listVideos.invalidate()]);
  };
  const [removing, setRemoving] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);

  const restore = trpc.admin.restoreVideo.useMutation({
    onSuccess: async () => {
      toast.success("Video restored — its link plays again");
      await refresh();
    },
    onError: (e) => toast.error(e.message),
  });
  const dismiss = trpc.admin.dismissVideoReports.useMutation({
    onSuccess: async (r) => {
      toast.success(r.dismissed === 1 ? "Report dismissed" : `${r.dismissed} reports dismissed`);
      await refresh();
    },
    onError: (e) => toast.error(e.message),
  });

  const video = data?.video;
  const openReports = data?.reports.filter((r) => !r.resolvedAt) ?? [];

  return (
    <Sheet open={videoId !== null} onOpenChange={(open) => !open && onClose()}>
      <SheetContent className="w-full overflow-y-auto data-[side=right]:sm:max-w-2xl">
        <SheetHeader>
          <SheetTitle className="flex items-center gap-2 pr-8">
            <span className="truncate">{video?.title ?? "Video"}</span>
            {video?.removed && <Badge variant="destructive">Removed</Badge>}
          </SheetTitle>
          <SheetDescription>
            {video ? `${video.owner.email ?? "Unknown owner"} · uploaded ${relativeTime(video.createdAt)}` : " "}
          </SheetDescription>
        </SheetHeader>

        {isLoading && (
          <div className="flex justify-center p-8">
            <Spinner />
          </div>
        )}
        {error && <p className="px-4 text-sm text-destructive">{error.message}</p>}

        {data && video && (
          <div className="flex flex-col divide-y px-4 pb-8">
            <div className="pb-4">
              {video.status === "ready" ? (
                <video
                  key={video.videoId}
                  src={`${API_URL}/api/admin/videos/${encodeURIComponent(video.videoId)}/stream`}
                  controls
                  playsInline
                  preload="metadata"
                  className="aspect-video w-full rounded-xl bg-black"
                />
              ) : (
                <p className="rounded-xl bg-muted p-6 text-center text-sm text-muted-foreground">Still uploading — nothing to play yet.</p>
              )}
              <div className="mt-3 flex flex-wrap gap-2">
                {video.removed ? (
                  <Button size="sm" variant="outline" disabled={restore.isPending} onClick={() => restore.mutate({ id: video.videoId })}>
                    Restore
                  </Button>
                ) : (
                  <Button size="sm" variant="destructive" onClick={() => setRemoving(true)}>
                    Take down
                  </Button>
                )}
                {openReports.length > 0 && (
                  <Button size="sm" variant="outline" disabled={dismiss.isPending} onClick={() => dismiss.mutate({ id: video.videoId })}>
                    Dismiss {openReports.length === 1 ? "report" : `${openReports.length} reports`}
                  </Button>
                )}
                <Button size="sm" variant="outline" asChild>
                  <a href={video.shareUrl} target="_blank" rel="noopener noreferrer">
                    <ExternalLink className="mr-1 h-4 w-4" /> Share page
                  </a>
                </Button>
                <Button size="sm" variant="ghost" className="text-destructive" onClick={() => setConfirmDelete(true)}>
                  Delete permanently
                </Button>
              </div>
              {video.removed && (
                <p className="mt-3 text-sm text-muted-foreground">
                  Removed {relativeTime(video.removed.at)}
                  {video.removed.reason ? ` — “${video.removed.reason}”` : ""}. Its link shows a removal notice; the owner sees
                  the reason in their dashboard.
                </p>
              )}
            </div>

            <Section title="Details">
              <Facts
                rows={[
                  ["Owner", `${video.owner.name ?? "—"} · ${video.owner.email ?? "unknown"}${video.owner.blocked ? " · blocked" : ""}`],
                  ["Who can watch", VISIBILITY_LABEL[video.visibility]],
                  ["Views", String(video.views)],
                  ["Length", `${formatDuration(video.durationSeconds)} · ${formatBytes(video.sizeBytes)}`],
                  ["File", video.fileName],
                  ["Video id", video.videoId],
                ]}
              />
            </Section>

            <Section title={`Reports (${data.reports.length})`}>
              {data.reports.length === 0 ? (
                <p className="text-muted-foreground">Nobody has reported this video.</p>
              ) : (
                <ul className="space-y-3">
                  {data.reports.map((r) => (
                    <li key={r.id} className="space-y-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <span className="font-medium">{r.reasonLabel}</span>
                        {r.resolution ? (
                          <Badge variant="outline">{r.resolution === "removed" ? "Acted on" : "Dismissed"}</Badge>
                        ) : (
                          <Badge variant="destructive">Open</Badge>
                        )}
                        <span className="text-xs text-muted-foreground">
                          {relativeTime(r.createdAt)} · {r.signedIn ? "signed-in viewer" : "anonymous viewer"}
                        </span>
                      </div>
                      {r.details && <p className="whitespace-pre-wrap break-words text-muted-foreground">{r.details}</p>}
                    </li>
                  ))}
                </ul>
              )}
            </Section>

            {data.history.length > 0 && (
              <Section title="History">
                <ul className="space-y-1.5 text-sm">
                  {data.history.map((h) => (
                    <li key={h.id} className="flex flex-wrap justify-between gap-x-4">
                      <span>
                        {ACTION_LABEL[h.action] ?? h.action}
                        {h.reason ? ` — “${h.reason}”` : ""}
                      </span>
                      <span className="text-xs text-muted-foreground">
                        {h.adminEmail ?? "admin"} · {relativeTime(h.createdAt)}
                      </span>
                    </li>
                  ))}
                </ul>
              </Section>
            )}
          </div>
        )}
      </SheetContent>

      {video && (
        <TakeDownDialog
          video={video}
          open={removing}
          onOpenChange={setRemoving}
          onDone={async () => {
            setRemoving(false);
            await refresh();
          }}
        />
      )}
      {video && (
        <DeleteVideoDialog
          video={video}
          open={confirmDelete}
          onOpenChange={setConfirmDelete}
          onDeleted={async () => {
            setConfirmDelete(false);
            onClose();
            await utils.admin.listVideos.invalidate();
          }}
        />
      )}
    </Sheet>
  );
}

function TakeDownDialog({
  video,
  open,
  onOpenChange,
  onDone,
}: {
  video: AdminVideo;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onDone: () => void;
}) {
  const [reason, setReason] = useState("");
  const remove = trpc.admin.removeVideo.useMutation({
    onSuccess: () => {
      toast.success("Video taken down");
      setReason("");
      onDone();
    },
    onError: (e) => toast.error(e.message),
  });
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Take down “{video.title}”?</DialogTitle>
          <DialogDescription>
            Its share link, embeds and profile listing show a removal notice at once (other locations within about a
            minute). The file is kept, so you can restore it. The owner sees the reason below.
          </DialogDescription>
        </DialogHeader>
        <div className="flex flex-wrap gap-1.5">
          {REMOVAL_PRESETS.map((p) => (
            <Button key={p} type="button" size="sm" variant={reason === p ? "secondary" : "outline"} onClick={() => setReason(p)}>
              {p}
            </Button>
          ))}
        </div>
        <textarea
          value={reason}
          onChange={(e) => setReason(e.target.value.slice(0, 500))}
          placeholder="Reason the owner will see"
          rows={3}
          className="w-full min-w-0 rounded-2xl border border-input bg-input/30 px-3 py-2 text-sm outline-none placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/50"
        />
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button
            variant="destructive"
            disabled={!reason.trim() || remove.isPending}
            onClick={() => remove.mutate({ id: video.videoId, reason: reason.trim() })}
          >
            Take down
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function DeleteVideoDialog({
  video,
  open,
  onOpenChange,
  onDeleted,
}: {
  video: AdminVideo;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onDeleted: () => void;
}) {
  const del = trpc.admin.deleteVideo.useMutation({
    onSuccess: (r) => {
      toast.success(r.leftInBucket?.length ? "Deleted — some files stay in the owner's own bucket" : "Video deleted");
      onDeleted();
    },
    onError: (e) => toast.error(e.message),
  });
  return (
    <AlertDialog open={open} onOpenChange={onOpenChange}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>Delete “{video.title}” permanently?</AlertDialogTitle>
          <AlertDialogDescription>
            The file, every version and the share link are gone for good, for the owner too, and the link will 404. This
            can&rsquo;t be undone; to hide it and keep the file, take it down instead.
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Cancel</AlertDialogCancel>
          <AlertDialogAction variant="destructive" disabled={del.isPending} onClick={() => del.mutate({ id: video.videoId })}>
            Delete permanently
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
