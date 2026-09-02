import { useRef, useState } from "react";
import { toast } from "sonner";

import { trpc } from "@/lib/trpc/client";
import { THUMBNAIL_ACCEPT, uploadThumbnail } from "@/lib/thumbnails";
import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/switch";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";

/**
 * Owner controls for one share link: download button, password, expiry,
 * view cap, brand accent, and the copyable embed code.
 */
export interface ShareSettingsVideo {
  videoId: string;
  fileName: string;
  allowDownload: boolean;
  hasPassword: boolean;
  expiresAt: string | null;
  maxViews: number | null;
  brandAccent: string | null;
  thumbnailUrl: string | null;
}

export function ShareSettingsDialog({
  video,
  onClose,
}: {
  video: ShareSettingsVideo;
  onClose: () => void;
}) {
  const utils = trpc.useUtils();
  const update = trpc.videos.updateSettings.useMutation({
    onSuccess: () => {
      void utils.videos.list.invalidate();
      toast.success("Share settings saved");
      onClose();
    },
    onError: (error) => toast.error(error.message ?? "Failed to save settings"),
  });

  const [allowDownload, setAllowDownload] = useState(video.allowDownload);
  const [passwordEnabled, setPasswordEnabled] = useState(video.hasPassword);
  const [password, setPassword] = useState("");
  const [expiresAt, setExpiresAt] = useState(
    video.expiresAt ? video.expiresAt.slice(0, 10) : ""
  );
  const [maxViews, setMaxViews] = useState(
    video.maxViews && video.maxViews > 0 ? String(video.maxViews) : ""
  );
  const [accent, setAccent] = useState(video.brandAccent ?? "");

  // Custom thumbnail: uploads go browser → API directly (binary body), the
  // removal rides tRPC. Local state so the preview updates without a refetch;
  // the cache-buster defeats the API's 5-minute edge cache after a replace.
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [thumbnailUrl, setThumbnailUrl] = useState(video.thumbnailUrl);
  const [thumbnailBusy, setThumbnailBusy] = useState(false);
  const deleteThumbnail = trpc.videos.deleteThumbnail.useMutation({
    onSuccess: () => {
      setThumbnailUrl(null);
      void utils.videos.list.invalidate();
      toast.success("Thumbnail removed");
    },
    onError: (error) => toast.error(error.message ?? "Could not remove thumbnail"),
  });

  const onThumbnailFile = async (file: File | undefined) => {
    if (!file) return;
    setThumbnailBusy(true);
    try {
      await uploadThumbnail(video.videoId, file);
      void utils.videos.list.invalidate();
      const fresh = await utils.videos.list.fetch();
      const updated = fresh.videos.find((v) => v.videoId === video.videoId);
      setThumbnailUrl(
        updated?.thumbnailUrl ? `${updated.thumbnailUrl}?r=${Date.now()}` : null
      );
      toast.success("Thumbnail uploaded");
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "Could not upload thumbnail");
    } finally {
      setThumbnailBusy(false);
      if (fileInputRef.current) fileInputRef.current.value = "";
    }
  };

  const scriptEmbed = `<script async src="https://capturecat.so/embed.js" data-capturecat-id="${video.videoId}"></script>`;
  const iframeEmbed = `<iframe src="https://capturecat.so/embed/${video.videoId}" width="800" height="450" frameborder="0" allow="fullscreen" allowfullscreen style="aspect-ratio:16/9;width:100%;height:auto"></iframe>`;

  const save = () => {
    update.mutate({
      videoId: video.videoId,
      allowDownload,
      // Password semantics: toggled off => clear; toggled on with a new value
      // => set; toggled on with the field left blank => keep the existing one.
      ...(passwordEnabled
        ? password.length > 0
          ? { password }
          : {}
        : { password: null }),
      expiresAt: expiresAt ? new Date(`${expiresAt}T23:59:59`).toISOString() : null,
      maxViews: maxViews ? Math.max(0, parseInt(maxViews, 10) || 0) : null,
      brandAccent: /^#[0-9a-fA-F]{6}$/.test(accent) ? accent : null,
    });
  };

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="overflow-hidden sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Share settings</DialogTitle>
          <DialogDescription className="truncate">{video.fileName}</DialogDescription>
        </DialogHeader>

        <div className="space-y-4">
          <label className="flex items-center justify-between gap-4">
            <div>
              <p className="text-sm font-medium">Allow downloads</p>
              <p className="text-xs text-muted-foreground">
                Viewers get a download button on the share page.
              </p>
            </div>
            <Switch checked={allowDownload} onCheckedChange={setAllowDownload} />
          </label>

          <div className="space-y-2">
            <label className="flex items-center justify-between gap-4">
              <div>
                <p className="text-sm font-medium">Password</p>
                <p className="text-xs text-muted-foreground">
                  Viewers must enter it before watching.
                </p>
              </div>
              <Switch checked={passwordEnabled} onCheckedChange={setPasswordEnabled} />
            </label>
            {passwordEnabled && (
              <input
                type="text"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder={video.hasPassword ? "Unchanged — type to replace" : "Choose a password"}
                className="w-full rounded-md border bg-transparent px-3 py-2 text-sm outline-none focus:ring-1 focus:ring-ring"
              />
            )}
          </div>

          <div className="grid min-w-0 grid-cols-2 gap-3">
            <div className="min-w-0 space-y-1">
              <p className="text-sm font-medium">Expires</p>
              <input
                type="date"
                value={expiresAt}
                onChange={(e) => setExpiresAt(e.target.value)}
                className="w-full min-w-0 rounded-md border bg-transparent px-3 py-2 text-sm outline-none focus:ring-1 focus:ring-ring"
              />
            </div>
            <div className="min-w-0 space-y-1">
              <p className="text-sm font-medium">View limit</p>
              <input
                type="number"
                min={0}
                value={maxViews}
                onChange={(e) => setMaxViews(e.target.value)}
                placeholder="Unlimited"
                className="w-full rounded-md border bg-transparent px-3 py-2 text-sm outline-none focus:ring-1 focus:ring-ring"
              />
            </div>
          </div>

          <div className="space-y-1">
            <p className="text-sm font-medium">Brand accent</p>
            <div className="flex items-center gap-2">
              <input
                type="color"
                value={/^#[0-9a-fA-F]{6}$/.test(accent) ? accent : "#FBBF24"}
                onChange={(e) => setAccent(e.target.value.toUpperCase())}
                className="h-9 w-12 cursor-pointer rounded-md border bg-transparent"
              />
              <input
                type="text"
                value={accent}
                onChange={(e) => setAccent(e.target.value)}
                placeholder="Default"
                className="w-28 rounded-md border bg-transparent px-3 py-2 text-sm outline-none focus:ring-1 focus:ring-ring"
              />
              {accent && (
                <Button variant="ghost" size="sm" onClick={() => setAccent("")}>
                  Reset
                </Button>
              )}
            </div>
            <p className="text-xs text-muted-foreground">
              Tints the share-page player chrome.
            </p>
          </div>

          <div className="space-y-2">
            <p className="text-sm font-medium">Thumbnail</p>
            {thumbnailUrl && (
              <img
                src={thumbnailUrl}
                alt="Custom thumbnail"
                className="aspect-video w-full rounded-md border object-cover"
              />
            )}
            <input
              ref={fileInputRef}
              type="file"
              accept={THUMBNAIL_ACCEPT}
              className="hidden"
              onChange={(e) => void onThumbnailFile(e.target.files?.[0])}
            />
            <div className="flex items-center gap-2">
              <Button
                variant="outline"
                size="sm"
                disabled={thumbnailBusy}
                onClick={() => fileInputRef.current?.click()}
              >
                {thumbnailBusy
                  ? "Uploading…"
                  : thumbnailUrl
                    ? "Replace image…"
                    : "Upload image…"}
              </Button>
              {thumbnailUrl && (
                <Button
                  variant="ghost"
                  size="sm"
                  disabled={thumbnailBusy || deleteThumbnail.isPending}
                  onClick={() => deleteThumbnail.mutate({ videoId: video.videoId })}
                >
                  {deleteThumbnail.isPending ? "Removing…" : "Remove"}
                </Button>
              )}
            </div>
            <p className="text-xs text-muted-foreground">
              JPEG, PNG or WebP up to 5 MB. Shown as the poster in the library
              and on the share page.
            </p>
          </div>

          <div className="min-w-0 space-y-2">
            <p className="text-sm font-medium">Embed</p>
            <div className="flex min-w-0 items-center gap-2">
              <code className="block min-w-0 flex-1 truncate rounded-md border px-3 py-2 text-xs text-muted-foreground">
                {scriptEmbed}
              </code>
              <Button
                variant="outline"
                size="sm"
                className="shrink-0"
                onClick={() => {
                  void navigator.clipboard.writeText(scriptEmbed);
                  toast.success("Script embed copied");
                }}
              >
                Copy script
              </Button>
            </div>
            <div className="flex min-w-0 items-center gap-2">
              <code className="block min-w-0 flex-1 truncate rounded-md border px-3 py-2 text-xs text-muted-foreground">
                {iframeEmbed}
              </code>
              <Button
                variant="outline"
                size="sm"
                className="shrink-0"
                onClick={() => {
                  void navigator.clipboard.writeText(iframeEmbed);
                  toast.success("iframe embed copied");
                }}
              >
                Copy iframe
              </Button>
            </div>
            <p className="text-xs text-muted-foreground">
              The script tag drops in a responsive player; use the iframe where
              scripts aren&apos;t allowed.
            </p>
          </div>
        </div>

        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button onClick={save} disabled={update.isPending}>
            {update.isPending ? "Saving…" : "Save"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
