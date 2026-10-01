import { useState, type CSSProperties } from "react";
import { Link } from "@tanstack/react-router";
import {
  BarChart3,
  Copy,
  ExternalLink,
  Eye,
  History,
  MousePointerClick,
  RotateCcw,
  ShieldCheck,
  Trash2,
} from "lucide-react";
import { toast } from "sonner";

import { API_URL } from "@/lib/api-url";
import { cn } from "@/lib/utils";
import { trpc } from "@/lib/trpc/client";
import { formatDateTime, formatDuration, formatSize } from "@/components/dashboard/video-format";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/switch";
import { VideoDetailSkeleton } from "@/components/dashboard/page-skeletons";
import { LiveDot, PageHeader, Section, Sections, SettingRow } from "@/components/dashboard/studio";
import { VisibilityBadge } from "@/components/dashboard/video-card";
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

/**
 * Per-video details page — the YouTube-Studio-style home for one share link:
 * the preview + link in a media bezel on the right (first on phones), and
 * the settings as ONE surface on the left — visibility, access, call to
 * action, version history. Versions exist because a re-share from the app
 * replaces the file at the same link instead of minting a new one.
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
        <PageHeader
          back={{ to: "/app", label: "Library" }}
          eyebrow="Video"
          title="Not found"
          description="This video may have been deleted."
        />
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
      <PageHeader
        back={{ to: "/app", label: "Library" }}
        eyebrow="Video"
        title={video.fileName}
        description={
          <span className="tabular-nums">
            {formatDuration(video.durationSeconds)} · {formatSize(video.fileSizeBytes)} · version{" "}
            {currentVersion} live
          </span>
        }
        actions={
          <>
            <Button variant="outline" size="sm" asChild>
              <Link to="/app/videos/$videoId/analytics" params={{ videoId: video.videoId }}>
                <BarChart3 data-icon="inline-start" /> Analytics
              </Link>
            </Button>
            {!video.isPrivate && (
              <Button variant="outline" size="sm" onClick={() => window.open(video.url, "_blank")}>
                <ExternalLink data-icon="inline-start" /> Share page
              </Button>
            )}
          </>
        }
      />

      <div className="grid items-start gap-6 xl:grid-cols-[minmax(0,1fr)_360px]">
        {/* Preview + link — the media itself, in the site's glass bezel.
            First on phones; beside the settings (and pinned) on wide screens. */}
        <aside className="dsh-pop min-w-0 max-w-3xl xl:sticky xl:top-20 xl:order-2 xl:max-w-none">
          <div className="relative rounded-[22px] border border-white/12 bg-white/[0.04] p-1.5 shadow-[0_40px_100px_-30px_rgba(0,0,0,0.85)] backdrop-blur-2xl">
            <span
              aria-hidden
              className="absolute inset-x-10 top-0 h-px bg-gradient-to-r from-transparent via-white/40 to-transparent"
            />
            <div className="overflow-hidden rounded-[16px] bg-black">
              <video
                key={previewUrl}
                src={previewUrl}
                controls
                playsInline
                className="aspect-video w-full"
              />
            </div>
            <div className="px-2.5 pb-2 pt-3.5">
              <div className="flex items-center justify-between gap-2">
                <p className="studio-eyebrow">Share link</p>
                <VisibilityBadge isPrivate={video.isPrivate} />
              </div>
              <div className="mt-2 flex min-w-0 items-center gap-2">
                <code className="studio-well block min-w-0 flex-1 truncate px-3 py-2 text-xs">
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
            </div>
          </div>
        </aside>

        {/* Settings — ONE surface, hairline-divided sections. */}
        <Sections className="max-w-3xl xl:order-1 xl:max-w-none">
          <Section icon={<Eye />} title="Visibility">
            <div className="divide-y divide-white/8">
              <SettingRow label="Public link" description="Anyone with the link can watch.">
                <Switch
                  checked={!video.isPrivate}
                  onCheckedChange={(checked) =>
                    setPrivacy.mutate({ videoId: video.videoId, isPrivate: !checked })
                  }
                  disabled={setPrivacy.isPending}
                />
              </SettingRow>

              <SettingRow label="Allow downloads" description="Viewers get a download button on the share page.">
                <Switch
                  checked={video.allowDownload}
                  onCheckedChange={(checked) =>
                    update.mutate({ videoId: video.videoId, allowDownload: checked })
                  }
                  disabled={update.isPending}
                />
              </SettingRow>

              <SettingRow label="List on my profile" description="Show this video on your public profile page.">
                <Switch
                  checked={video.profileVisible}
                  onCheckedChange={(checked) =>
                    update.mutate({ videoId: video.videoId, profileVisible: checked })
                  }
                  disabled={update.isPending}
                />
              </SettingRow>

              <SettingRow
                label="Show version history"
                description="Viewers can see past versions of this video and play them."
              >
                <Switch
                  checked={history?.showVersionHistory ?? video.showVersionHistory}
                  onCheckedChange={(checked) =>
                    update.mutate({ videoId: video.videoId, showVersionHistory: checked })
                  }
                  disabled={update.isPending}
                />
              </SettingRow>
            </div>
          </Section>

          <Section icon={<ShieldCheck />} title="Access controls">
            <div className="space-y-4">
              <div className="space-y-2">
                <SettingRow label="Password" description="Viewers must enter it before watching.">
                  <Switch checked={effPasswordEnabled} onCheckedChange={setPasswordEnabled} />
                </SettingRow>
                {effPasswordEnabled && (
                  <input
                    type="text"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    placeholder={video.hasPassword ? "Unchanged — type to replace" : "Choose a password"}
                    className="studio-input dsh-rise"
                  />
                )}
              </div>

              <div className="grid min-w-0 grid-cols-2 gap-3">
                <div className="min-w-0 space-y-1">
                  <p className="studio-eyebrow">Expires</p>
                  <input
                    type="date"
                    value={effExpiresAt}
                    onChange={(e) => setExpiresAt(e.target.value)}
                    className="studio-input"
                  />
                </div>
                <div className="min-w-0 space-y-1">
                  <p className="studio-eyebrow">View limit</p>
                  <input
                    type="number"
                    min={0}
                    value={effMaxViews}
                    onChange={(e) => setMaxViews(e.target.value)}
                    placeholder="Unlimited"
                    className="studio-input"
                  />
                </div>
              </div>

              <div className="space-y-1">
                <p className="studio-eyebrow">Brand accent</p>
                <div className="flex items-center gap-2">
                  <input
                    type="color"
                    value={/^#[0-9a-fA-F]{6}$/.test(effAccent) ? effAccent : "#FBBF24"}
                    onChange={(e) => setAccent(e.target.value.toUpperCase())}
                    className="studio-input"
                  />
                  <input
                    type="text"
                    value={effAccent}
                    onChange={(e) => setAccent(e.target.value)}
                    placeholder="Default"
                    className="studio-input w-28"
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
          </Section>

          <Section
            icon={<MousePointerClick />}
            title="Call to action"
            description="A button on the share page — clicks are tracked in analytics as a play → watch → click funnel."
          >
            <div className="grid min-w-0 grid-cols-1 gap-2 sm:grid-cols-[1fr_1.5fr_auto]">
              <input
                type="text"
                value={ctaLabel ?? (video.ctaLabel ?? "")}
                onChange={(e) => setCtaLabel(e.target.value)}
                placeholder="Book a demo"
                maxLength={60}
                className="studio-input"
              />
              <input
                type="url"
                value={ctaUrl ?? (video.ctaUrl ?? "")}
                onChange={(e) => setCtaUrl(e.target.value)}
                placeholder="https://example.com/demo"
                className="studio-input"
              />
              <div className="flex justify-end gap-1">
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
          </Section>

          <Section
            icon={<History />}
            title="Version history"
            description="Re-sharing this capture from the app replaces the video at the same link — every previous cut is kept here. Restore one to make it live again, or delete it to free storage."
          >
            <div className="studio-well divide-y divide-white/8 overflow-hidden">
              {(history?.versions ?? []).map((v, i) => (
                <div
                  key={v.version}
                  className={cn(
                    "dsh-rise flex items-center gap-3 px-3.5 py-2.5",
                    v.current && "bg-cyan-400/[0.04]",
                  )}
                  style={{ "--i": i } as CSSProperties}
                >
                  <span className="w-9 shrink-0 text-sm font-medium tabular-nums">v{v.version}</span>
                  <span className="min-w-0 flex-1">
                    <span className="block truncate text-sm">{formatDateTime(v.createdAt)}</span>
                    <span className="block truncate text-xs tabular-nums text-muted-foreground">
                      {formatDuration(v.durationSeconds)}
                      {v.fileSizeBytes > 0 && ` · ${formatSize(v.fileSizeBytes)}`}
                    </span>
                  </span>
                  {v.current && (
                    <Badge
                      variant="outline"
                      className="gap-1.5 border-cyan-300/30 bg-cyan-400/10 text-xs text-cyan-200"
                    >
                      <LiveDot className="size-1.5" />
                      Live
                    </Badge>
                  )}
                  {v.status === "pending" && (
                    <Badge className="text-xs" variant="secondary">Uploading</Badge>
                  )}
                  {!v.current && v.status === "ready" && (
                    <div className="flex shrink-0 justify-end gap-1">
                      <Button
                        variant="ghost"
                        size="sm"
                        disabled={restore.isPending}
                        onClick={() =>
                          restore.mutate({ videoId: video.videoId, version: v.version })
                        }
                      >
                        <RotateCcw className="h-3.5 w-3.5 sm:mr-1" />
                        <span className="sr-only sm:not-sr-only">Restore</span>
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
                </div>
              ))}
              {(history?.versions ?? []).length === 0 && (
                <p className="px-3.5 py-4 text-center text-sm text-muted-foreground">
                  {history ? "No versions recorded yet." : "Loading…"}
                </p>
              )}
            </div>
          </Section>
        </Sections>
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
              variant="destructive"
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
