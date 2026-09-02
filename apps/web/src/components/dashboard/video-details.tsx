import { useState } from "react";
import { Link } from "@tanstack/react-router";
import {
  ArrowLeft,
  BarChart3,
  Copy,
  ExternalLink,
  Globe,
  History,
  Lock,
  RotateCcw,
  Trash2,
} from "lucide-react";
import { toast } from "sonner";

import { API_URL } from "@/lib/api-url";
import { trpc } from "@/lib/trpc/client";
import { formatDateTime, formatDuration, formatSize } from "@/components/dashboard/video-format";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/switch";
import { VideoDetailSkeleton } from "@/components/dashboard/page-skeletons";
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
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

/**
 * Per-video details page — the YouTube-Studio-style home for one share link:
 * preview + link on the right, settings on the left, version history below.
 * Versions exist because a re-share from the app replaces the file at the
 * same link instead of minting a new one.
 */




export function VideoDetails({ videoId }: { videoId: string }) {
  const utils = trpc.useUtils();
  const { data: list, isLoading } = trpc.videos.list.useQuery();
  const { data: history } = trpc.videos.versions.useQuery({ videoId });

  const video = list?.videos.find((v) => v.videoId === videoId);

  const invalidate = () => {
    void utils.videos.list.invalidate();
    void utils.videos.versions.invalidate({ videoId });
  };

  const update = trpc.videos.updateSettings.useMutation({
    onSuccess: () => {
      invalidate();
      toast.success("Settings saved");
    },
    onError: (error) => toast.error(error.message ?? "Failed to save settings"),
  });
  const setPrivacy = trpc.videos.setPrivacy.useMutation({
    onSuccess: invalidate,
    onError: (error) => toast.error(error.message ?? "Failed to update privacy"),
  });
  const restore = trpc.videos.restoreVersion.useMutation({
    onSuccess: (data) => {
      invalidate();
      toast.success(`Version ${data.currentVersion} is now live`);
    },
    onError: (error) => toast.error(error.message ?? "Failed to restore version"),
  });
  const deleteVersion = trpc.videos.deleteVersion.useMutation({
    onSuccess: () => {
      invalidate();
      toast.success("Version deleted");
    },
    onError: (error) => toast.error(error.message ?? "Failed to delete version"),
  });

  // Share-settings form state, seeded once the video loads.
  const [passwordEnabled, setPasswordEnabled] = useState<boolean | null>(null);
  const [password, setPassword] = useState("");
  const [expiresAt, setExpiresAt] = useState<string | null>(null);
  const [maxViews, setMaxViews] = useState<string | null>(null);
  const [accent, setAccent] = useState<string | null>(null);
  const [deleteVersionTarget, setDeleteVersionTarget] = useState<number | null>(null);
  const [ctaLabel, setCtaLabel] = useState<string | null>(null);
  const [ctaUrl, setCtaUrl] = useState<string | null>(null);

  if (isLoading) {
    return <VideoDetailSkeleton />;
  }

  if (!video) {
    return (
      <div className="space-y-4">
        <Link
          to="/app"
          className="inline-flex items-center gap-2 text-sm text-muted-foreground transition-colors hover:text-foreground"
        >
          <ArrowLeft className="h-4 w-4" /> Back to videos
        </Link>
        <p className="text-muted-foreground">Video not found — it may have been deleted.</p>
      </div>
    );
  }

  const currentVersion = history?.currentVersion ?? video.currentVersion;
  // Pin the preview to the live version so the browser cache can never show
  // a stale cut after a replace.
  const previewUrl = `${API_URL}/api/video/${video.videoId}?v=${currentVersion}`;

  const effPasswordEnabled = passwordEnabled ?? video.hasPassword;
  const effExpiresAt = expiresAt ?? (video.expiresAt ? video.expiresAt.slice(0, 10) : "");
  const effMaxViews = maxViews ?? (video.maxViews && video.maxViews > 0 ? String(video.maxViews) : "");
  const effAccent = accent ?? (video.brandAccent ?? "");

  const saveShareControls = () => {
    update.mutate({
      videoId: video.videoId,
      ...(effPasswordEnabled
        ? password.length > 0
          ? { password }
          : {}
        : { password: null }),
      expiresAt: effExpiresAt ? new Date(`${effExpiresAt}T23:59:59`).toISOString() : null,
      maxViews: effMaxViews ? Math.max(0, parseInt(effMaxViews, 10) || 0) : null,
      brandAccent: /^#[0-9a-fA-F]{6}$/.test(effAccent) ? effAccent : null,
    });
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="min-w-0">
          <Link
            to="/app"
            className="inline-flex items-center gap-2 text-sm text-muted-foreground transition-colors hover:text-foreground"
          >
            <ArrowLeft className="h-4 w-4" /> Back to videos
          </Link>
          <h1 className="mt-1 truncate text-xl font-semibold">{video.fileName}</h1>
          <p className="text-sm text-muted-foreground">
            {formatDuration(video.durationSeconds)} · {formatSize(video.fileSizeBytes)} ·
            version {currentVersion} live
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Button variant="outline" size="sm" asChild>
            <Link to="/app/videos/$videoId/analytics" params={{ videoId: video.videoId }}>
              <BarChart3 className="mr-2 h-4 w-4" /> Analytics
            </Link>
          </Button>
          {!video.isPrivate && (
            <Button variant="outline" size="sm" onClick={() => window.open(video.url, "_blank")}>
              <ExternalLink className="mr-2 h-4 w-4" /> View share page
            </Button>
          )}
        </div>
      </div>

      <div className="grid gap-6 lg:grid-cols-[1fr_380px]">
        {/* Left column — settings */}
        <div className="space-y-4">
          <section className="rounded-2xl border border-white/10 bg-white/[0.03] p-5 backdrop-blur-2xl">
            <h2 className="text-sm font-semibold">Visibility</h2>
            <div className="mt-3 space-y-4">
              <label className="flex items-center justify-between gap-4">
                <div>
                  <p className="text-sm font-medium">Public link</p>
                  <p className="text-xs text-muted-foreground">
                    Anyone with the link can watch.
                  </p>
                </div>
                <div className="flex items-center gap-2">
                  <Switch
                    checked={!video.isPrivate}
                    onCheckedChange={(checked) =>
                      setPrivacy.mutate({ videoId: video.videoId, isPrivate: !checked })
                    }
                    disabled={setPrivacy.isPending}
                  />
                  <Badge variant={video.isPrivate ? "secondary" : "default"} className="text-xs">
                    {video.isPrivate ? (
                      <><Lock className="mr-1 h-3 w-3" />Private</>
                    ) : (
                      <><Globe className="mr-1 h-3 w-3" />Public</>
                    )}
                  </Badge>
                </div>
              </label>

              <label className="flex items-center justify-between gap-4">
                <div>
                  <p className="text-sm font-medium">Allow downloads</p>
                  <p className="text-xs text-muted-foreground">
                    Viewers get a download button on the share page.
                  </p>
                </div>
                <Switch
                  checked={video.allowDownload}
                  onCheckedChange={(checked) =>
                    update.mutate({ videoId: video.videoId, allowDownload: checked })
                  }
                  disabled={update.isPending}
                />
              </label>

              <label className="flex items-center justify-between gap-4">
                <div>
                  <p className="text-sm font-medium">List on my profile</p>
                  <p className="text-xs text-muted-foreground">
                    Show this video on your public profile page.
                  </p>
                </div>
                <Switch
                  checked={video.profileVisible}
                  onCheckedChange={(checked) =>
                    update.mutate({ videoId: video.videoId, profileVisible: checked })
                  }
                  disabled={update.isPending}
                />
              </label>

              <label className="flex items-center justify-between gap-4">
                <div>
                  <p className="text-sm font-medium">Show version history</p>
                  <p className="text-xs text-muted-foreground">
                    Viewers can see past versions of this video and play them.
                  </p>
                </div>
                <Switch
                  checked={history?.showVersionHistory ?? video.showVersionHistory}
                  onCheckedChange={(checked) =>
                    update.mutate({ videoId: video.videoId, showVersionHistory: checked })
                  }
                  disabled={update.isPending}
                />
              </label>
            </div>
          </section>

          <section className="rounded-2xl border border-white/10 bg-white/[0.03] p-5 backdrop-blur-2xl">
            <h2 className="text-sm font-semibold">Access controls</h2>
            <div className="mt-3 space-y-4">
              <div className="space-y-2">
                <label className="flex items-center justify-between gap-4">
                  <div>
                    <p className="text-sm font-medium">Password</p>
                    <p className="text-xs text-muted-foreground">
                      Viewers must enter it before watching.
                    </p>
                  </div>
                  <Switch checked={effPasswordEnabled} onCheckedChange={setPasswordEnabled} />
                </label>
                {effPasswordEnabled && (
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
                    value={effExpiresAt}
                    onChange={(e) => setExpiresAt(e.target.value)}
                    className="w-full min-w-0 rounded-md border bg-transparent px-3 py-2 text-sm outline-none focus:ring-1 focus:ring-ring"
                  />
                </div>
                <div className="min-w-0 space-y-1">
                  <p className="text-sm font-medium">View limit</p>
                  <input
                    type="number"
                    min={0}
                    value={effMaxViews}
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
                    value={/^#[0-9a-fA-F]{6}$/.test(effAccent) ? effAccent : "#FBBF24"}
                    onChange={(e) => setAccent(e.target.value.toUpperCase())}
                    className="h-9 w-12 cursor-pointer rounded-md border bg-transparent"
                  />
                  <input
                    type="text"
                    value={effAccent}
                    onChange={(e) => setAccent(e.target.value)}
                    placeholder="Default"
                    className="w-28 rounded-md border bg-transparent px-3 py-2 text-sm outline-none focus:ring-1 focus:ring-ring"
                  />
                  {effAccent && (
                    <Button variant="ghost" size="sm" onClick={() => setAccent("")}>
                      Reset
                    </Button>
                  )}
                </div>
              </div>

              <div className="flex justify-end">
                <Button size="sm" onClick={saveShareControls} disabled={update.isPending}>
                  {update.isPending ? "Saving…" : "Save access controls"}
                </Button>
              </div>
            </div>
          </section>

          <section className="rounded-2xl border border-white/10 bg-white/[0.03] p-5 backdrop-blur-2xl">
            <h2 className="text-sm font-semibold">Call to action</h2>
            <p className="mt-1 text-xs text-muted-foreground">
              A button on the share page — clicks are tracked in analytics as a
              play → watch → click funnel.
            </p>
            <div className="mt-3 grid min-w-0 grid-cols-[1fr_1.5fr_auto] gap-2">
              <input
                type="text"
                value={ctaLabel ?? (video.ctaLabel ?? "")}
                onChange={(e) => setCtaLabel(e.target.value)}
                placeholder="Book a demo"
                maxLength={60}
                className="min-w-0 rounded-md border bg-transparent px-3 py-2 text-sm outline-none focus:ring-1 focus:ring-ring"
              />
              <input
                type="url"
                value={ctaUrl ?? (video.ctaUrl ?? "")}
                onChange={(e) => setCtaUrl(e.target.value)}
                placeholder="https://example.com/demo"
                className="min-w-0 rounded-md border bg-transparent px-3 py-2 text-sm outline-none focus:ring-1 focus:ring-ring"
              />
              <div className="flex gap-1">
                <Button
                  size="sm"
                  disabled={update.isPending}
                  onClick={() => {
                    const label = (ctaLabel ?? video.ctaLabel ?? "").trim();
                    const url = (ctaUrl ?? video.ctaUrl ?? "").trim();
                    if (!label || !/^https:\/\//.test(url)) {
                      toast.error("Needs a label and an https:// link");
                      return;
                    }
                    update.mutate({ videoId: video.videoId, ctaLabel: label, ctaUrl: url });
                  }}
                >
                  Save
                </Button>
                {(video.ctaLabel || ctaLabel) && (
                  <Button
                    size="sm"
                    variant="ghost"
                    disabled={update.isPending}
                    onClick={() => {
                      setCtaLabel("");
                      setCtaUrl("");
                      update.mutate({ videoId: video.videoId, ctaLabel: null, ctaUrl: null });
                    }}
                  >
                    Remove
                  </Button>
                )}
              </div>
            </div>
          </section>

          <section className="rounded-2xl border border-white/10 bg-white/[0.03] p-5 backdrop-blur-2xl">
            <div className="flex items-center gap-2">
              <History className="h-4 w-4 text-muted-foreground" />
              <h2 className="text-sm font-semibold">Version history</h2>
            </div>
            <p className="mt-1 text-xs text-muted-foreground">
              Re-sharing this capture from the app replaces the video at the same
              link — every previous cut is kept here. Restore one to make it live
              again, or delete it to free storage.
            </p>
            <div className="mt-3 overflow-x-auto rounded-lg border">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Version</TableHead>
                    <TableHead className="hidden sm:table-cell">Uploaded</TableHead>
                    <TableHead className="hidden sm:table-cell">Duration</TableHead>
                    <TableHead className="hidden md:table-cell">Size</TableHead>
                    <TableHead className="w-[180px]" />
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {(history?.versions ?? []).map((v) => (
                    <TableRow key={v.version}>
                      <TableCell className="font-medium">
                        <span className="tabular-nums">v{v.version}</span>
                        {v.current && (
                          <Badge className="ml-2 text-xs" variant="default">Live</Badge>
                        )}
                        {v.status === "pending" && (
                          <Badge className="ml-2 text-xs" variant="secondary">Uploading</Badge>
                        )}
                      </TableCell>
                      <TableCell className="hidden sm:table-cell text-muted-foreground">
                        {formatDateTime(v.createdAt)}
                      </TableCell>
                      <TableCell className="hidden sm:table-cell text-muted-foreground">
                        {formatDuration(v.durationSeconds)}
                      </TableCell>
                      <TableCell className="hidden md:table-cell text-muted-foreground">
                        {v.fileSizeBytes > 0 ? formatSize(v.fileSizeBytes) : "—"}
                      </TableCell>
                      <TableCell className="text-right">
                        {!v.current && v.status === "ready" && (
                          <div className="flex justify-end gap-1">
                            <Button
                              variant="ghost"
                              size="sm"
                              disabled={restore.isPending}
                              onClick={() =>
                                restore.mutate({ videoId: video.videoId, version: v.version })
                              }
                            >
                              <RotateCcw className="mr-1 h-3.5 w-3.5" /> Restore
                            </Button>
                            <Button
                              variant="ghost"
                              size="sm"
                              className="text-destructive hover:text-destructive"
                              disabled={deleteVersion.isPending}
                              onClick={() => setDeleteVersionTarget(v.version)}
                            >
                              <Trash2 className="h-3.5 w-3.5" />
                            </Button>
                          </div>
                        )}
                      </TableCell>
                    </TableRow>
                  ))}
                  {(history?.versions ?? []).length === 0 && (
                    <TableRow>
                      <TableCell colSpan={5} className="text-center text-sm text-muted-foreground">
                        {history ? "No versions recorded yet." : "Loading…"}
                      </TableCell>
                    </TableRow>
                  )}
                </TableBody>
              </Table>
            </div>
          </section>
        </div>

        {/* Right column — preview + link */}
        <div className="space-y-4">
          <section className="overflow-hidden rounded-2xl border border-white/10 bg-black">
            <video
              key={previewUrl}
              src={previewUrl}
              controls
              playsInline
              className="aspect-video w-full"
            />
          </section>

          <section className="rounded-2xl border border-white/10 bg-white/[0.03] p-4 backdrop-blur-2xl">
            <p className="text-xs font-medium text-muted-foreground">Share link</p>
            <div className="mt-1 flex min-w-0 items-center gap-2">
              <code className="block min-w-0 flex-1 truncate rounded-md border px-3 py-2 text-xs">
                {video.url}
              </code>
              <Button
                variant="outline"
                size="icon"
                className="h-8 w-8 shrink-0"
                onClick={() => {
                  void navigator.clipboard.writeText(video.url);
                  toast.success("Link copied");
                }}
              >
                <Copy className="h-3.5 w-3.5" />
              </Button>
            </div>
            <p className="mt-2 text-xs text-muted-foreground">
              This link never changes — re-shared edits replace the video in place.
            </p>
          </section>
        </div>
      </div>

      <AlertDialog
        open={deleteVersionTarget !== null}
        onOpenChange={() => setDeleteVersionTarget(null)}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete version {deleteVersionTarget}?</AlertDialogTitle>
            <AlertDialogDescription>
              This permanently deletes this version&apos;s file. The share link and
              other versions are unaffected. This cannot be undone.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              onClick={() => {
                if (deleteVersionTarget !== null) {
                  deleteVersion.mutate({ videoId: video.videoId, version: deleteVersionTarget });
                }
              }}
              disabled={deleteVersion.isPending}
            >
              {deleteVersion.isPending ? "Deleting…" : "Delete version"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
