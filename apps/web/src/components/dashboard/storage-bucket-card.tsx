import { useEffect, useState } from "react";
import { toast } from "sonner";
import { BadgeCheck, Copy, HardDrive, Pencil, RefreshCw, TriangleAlert, Unplug } from "lucide-react";

import { trpc } from "@/lib/trpc/client";
import type { BucketState, StorageProvider } from "@/lib/trpc/routers/storage";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import { Spinner } from "@/components/ui/spinner";
import { Switch } from "@/components/ui/switch";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import { Field, PlanChip, Row, Section, UpgradeNote } from "@/components/dashboard/studio";
import { cn } from "@/lib/utils";

/**
 * Bring-your-own bucket: share videos upload to — and play from — the
 * user's own S3-compatible bucket instead of CaptureCat's. The API test-writes
 * the bucket before saving (routes/storage.ts); this card adds the one check
 * only a browser can make — that the bucket's CORS lets the web recorder PUT
 * to it. The Mac app has the same settings in its Storage pane.
 */

const PROVIDERS: Array<{
  id: StorageProvider;
  label: string;
  region: string;
  endpoint: string | null;
  pathStyle?: boolean;
}> = [
  { id: "aws", label: "AWS S3", region: "us-east-1", endpoint: null },
  { id: "r2", label: "Cloudflare R2", region: "auto", endpoint: "https://<account-id>.r2.cloudflarestorage.com" },
  { id: "b2", label: "Backblaze B2", region: "us-west-004", endpoint: "https://s3.us-west-004.backblazeb2.com" },
  { id: "wasabi", label: "Wasabi", region: "us-east-1", endpoint: "https://s3.us-east-1.wasabisys.com" },
  { id: "minio", label: "MinIO", region: "us-east-1", endpoint: "https://minio.yourcompany.com", pathStyle: true },
  { id: "other", label: "Other", region: "us-east-1", endpoint: "https://s3.yourprovider.com" },
];

const providerLabel = (id: StorageProvider) => PROVIDERS.find((p) => p.id === id)?.label ?? id;

type Draft = {
  provider: StorageProvider;
  endpoint: string;
  region: string;
  bucket: string;
  pathPrefix: string;
  forcePathStyle: boolean;
  publicBaseUrl: string;
  accessKeyId: string;
  secretAccessKey: string;
};

const emptyDraft = (): Draft => ({
  provider: "aws",
  endpoint: "",
  region: "us-east-1",
  bucket: "",
  pathPrefix: "capturecat/",
  forcePathStyle: false,
  publicBaseUrl: "",
  accessKeyId: "",
  secretAccessKey: "",
});

type CorsCheck = { state: "idle" } | { state: "running" } | { state: "ok" } | { state: "blocked"; detail: string };

export function StorageBucketCard() {
  const utils = trpc.useUtils();
  const { data, isLoading } = trpc.storage.bucket.useQuery();
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState<Draft>(emptyDraft);
  const [formError, setFormError] = useState<string | null>(null);
  const [cors, setCors] = useState<CorsCheck>({ state: "idle" });

  const corsProbe = trpc.storage.corsProbe.useMutation();
  const corsProbeDone = trpc.storage.corsProbeDone.useMutation();

  /** PUT a 2-byte object from THIS browser with a presigned URL. A CORS
   *  refusal surfaces as a TypeError with no status — that is the signal. */
  async function checkBrowserUploads() {
    setCors({ state: "running" });
    try {
      const probe = await corsProbe.mutateAsync();
      try {
        const res = await fetch(probe.uploadUrl, {
          method: "PUT",
          headers: { "Content-Type": probe.contentType },
          body: probe.body,
        });
        setCors(res.ok ? { state: "ok" } : { state: "blocked", detail: `The bucket answered HTTP ${res.status}.` });
      } catch {
        setCors({
          state: "blocked",
          detail: "The browser was blocked from uploading — the bucket's CORS doesn't allow this site yet.",
        });
      }
      corsProbeDone.mutate();
    } catch (err) {
      setCors({ state: "blocked", detail: err instanceof Error ? err.message : "Could not run the check." });
    }
  }

  const connect = trpc.storage.connect.useMutation({
    onSuccess: (state) => {
      utils.storage.bucket.setData(undefined, state);
      setEditing(false);
      setFormError(null);
      setDraft(emptyDraft());
      toast.success("Bucket connected — new share videos upload there");
      void checkBrowserUploads();
    },
    onError: (error) => setFormError(error.message),
  });

  const disconnect = trpc.storage.disconnect.useMutation({
    onSuccess: (result) => {
      void utils.storage.bucket.invalidate();
      setCors({ state: "idle" });
      toast.success(
        result.retained
          ? `Disconnected. Your ${result.videoCount} video${result.videoCount === 1 ? "" : "s"} in that bucket keep playing from it.`
          : "Disconnected. New share videos upload to CaptureCat."
      );
    },
    onError: (error) => toast.error(error.message),
  });

  const bucket = data?.bucket ?? null;
  const showForm = !bucket || editing;
  const locked = !data?.enabled || !data?.available;

  // Editing an existing bucket starts from its settings; the keys are never
  // sent back, so they are re-entered.
  useEffect(() => {
    if (editing && bucket) {
      setDraft({
        provider: bucket.provider,
        endpoint: bucket.endpoint ?? "",
        region: bucket.region,
        bucket: bucket.bucket,
        pathPrefix: bucket.pathPrefix,
        forcePathStyle: bucket.forcePathStyle,
        publicBaseUrl: bucket.publicBaseUrl ?? "",
        accessKeyId: "",
        secretAccessKey: "",
      });
    }
  }, [editing, bucket]);

  return (
    <Section
      icon={<HardDrive />}
      title="Your own storage"
      badge={<PlanChip plan="pro" />}
      description="Keep share videos in your own S3-compatible bucket — AWS S3, Cloudflare R2, Backblaze B2, Wasabi or MinIO. Uploads from the Mac app and the web recorder go straight to it, and share links play from it."
    >
      {isLoading || !data ? (
        <div className="space-y-3">
          <Skeleton className="h-[50px] w-full rounded-[0.875rem]" />
          <Skeleton className="h-9 w-40 rounded-full" />
        </div>
      ) : (
        <div className="space-y-4">
          {bucket && !editing && (
            <ConnectedRow
              state={data}
              disconnecting={disconnect.isPending}
              onEdit={() => setEditing(true)}
              onDisconnect={() => disconnect.mutate()}
            />
          )}

          {bucket && !editing && (
            <BrowserUploadCheck cors={cors} origins={data.corsOrigins} onRun={() => void checkBrowserUploads()} />
          )}

          {showForm && (
            <BucketForm
              draft={draft}
              setDraft={(patch) => {
                setFormError(null);
                setDraft((d) => ({ ...d, ...patch }));
              }}
              disabled={locked || connect.isPending}
              pending={connect.isPending}
              error={formError}
              origins={data.corsOrigins}
              onCancel={bucket ? () => setEditing(false) : undefined}
              onSubmit={() =>
                connect.mutate({
                  provider: draft.provider,
                  endpoint: draft.provider === "aws" ? null : draft.endpoint.trim() || null,
                  region: draft.region.trim(),
                  bucket: draft.bucket.trim(),
                  pathPrefix: draft.pathPrefix.trim(),
                  forcePathStyle: draft.forcePathStyle,
                  publicBaseUrl: draft.publicBaseUrl.trim() || null,
                  accessKeyId: draft.accessKeyId.trim(),
                  secretAccessKey: draft.secretAccessKey.trim(),
                })
              }
            />
          )}

          {data.retainedCount > 0 && (
            <p className="text-xs text-muted-foreground">
              {data.retainedCount} video{data.retainedCount === 1 ? "" : "s"} still play from a bucket you disconnected.
              Delete {data.retainedCount === 1 ? "it" : "them"} to forget that bucket's keys.
            </p>
          )}
          {!data.enabled && <UpgradeNote plan="pro">Storing videos in your own bucket is part of Pro.</UpgradeNote>}
          {data.enabled && !data.available && (
            <p className="text-xs text-muted-foreground">Custom storage isn't available right now — try again later.</p>
          )}
        </div>
      )}
    </Section>
  );
}

function ConnectedRow({
  state,
  disconnecting,
  onEdit,
  onDisconnect,
}: {
  state: BucketState;
  disconnecting: boolean;
  onEdit: () => void;
  onDisconnect: () => void;
}) {
  const b = state.bucket!;
  return (
    <Row className="dsh-rise">
      <div className="flex min-w-0 items-center gap-2.5">
        <span aria-hidden className="size-1.5 shrink-0 rounded-full bg-emerald-400 shadow-[0_0_8px_rgba(52,211,153,0.7)]" />
        <div className="min-w-0">
          <div className="flex min-w-0 items-center gap-2">
            <span className="truncate text-sm">
              {b.bucket}
              {b.pathPrefix && <span className="text-muted-foreground">/{b.pathPrefix.replace(/\/$/, "")}</span>}
            </span>
            <Badge variant="outline" className="gap-1 border-emerald-400/25 bg-emerald-400/10 text-[10px] text-emerald-300">
              <BadgeCheck />
              connected
            </Badge>
          </div>
          <div className="mt-0.5 truncate text-xs text-muted-foreground">
            {providerLabel(b.provider)} · {b.region} · key {b.accessKeyIdHint} · {b.videoCount} video
            {b.videoCount === 1 ? "" : "s"} · {b.publicBaseUrl ? `plays from ${b.publicBaseUrl}` : "plays by signed link"}
          </div>
        </div>
      </div>
      <div className="flex shrink-0 items-center gap-1">
        <Button variant="ghost" size="sm" onClick={onEdit}>
          <Pencil data-icon="inline-start" />
          Edit
        </Button>
        <AlertDialog>
          <AlertDialogTrigger asChild>
            <Button variant="ghost" size="sm" className="text-destructive hover:text-destructive" disabled={disconnecting}>
              <Unplug data-icon="inline-start" />
              Disconnect
            </Button>
          </AlertDialogTrigger>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>Disconnect {b.bucket}?</AlertDialogTitle>
              <AlertDialogDescription>
                New share videos will upload to CaptureCat storage again.
                {b.videoCount > 0
                  ? ` The ${b.videoCount} video${b.videoCount === 1 ? "" : "s"} already in this bucket keep playing from it, so CaptureCat keeps its keys until they're deleted.`
                  : " Nothing is stored in this bucket yet, so its keys are forgotten now."}
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Keep it</AlertDialogCancel>
              <AlertDialogAction variant="destructive" onClick={onDisconnect}>
                Disconnect
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </div>
    </Row>
  );
}

function corsRules(origins: string[]): string {
  return JSON.stringify(
    [{ AllowedOrigins: origins, AllowedMethods: ["PUT"], AllowedHeaders: ["content-type"], MaxAgeSeconds: 3600 }],
    null,
    2
  );
}

function CorsSnippet({ origins }: { origins: string[] }) {
  const rules = corsRules(origins);
  return (
    <div className="studio-well space-y-2 p-3">
      <div className="flex items-center justify-between gap-2">
        <span className="studio-eyebrow">Bucket CORS for web uploads</span>
        <Button
          variant="ghost"
          size="sm"
          onClick={() => {
            void navigator.clipboard.writeText(rules).then(() => toast.success("CORS rules copied"));
          }}
        >
          <Copy data-icon="inline-start" />
          Copy
        </Button>
      </div>
      <pre className="overflow-x-auto text-[11px] leading-relaxed text-foreground/80">{rules}</pre>
      <p className="text-xs text-muted-foreground">
        Paste into the bucket's CORS settings. The Mac app doesn't need this; the web recorder does. Playback needs no
        CORS.
      </p>
    </div>
  );
}

function BrowserUploadCheck({ cors, origins, onRun }: { cors: CorsCheck; origins: string[]; onRun: () => void }) {
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2 text-sm">
          {cors.state === "running" && <Spinner className="size-3.5" />}
          {cors.state === "ok" && <BadgeCheck className="size-4 text-emerald-300" />}
          {cors.state === "blocked" && <TriangleAlert className="size-4 text-amber-300" />}
          <span className={cn(cors.state === "idle" && "text-muted-foreground")}>
            {cors.state === "idle" && "Web recorder uploads: not checked yet"}
            {cors.state === "running" && "Checking uploads from this browser…"}
            {cors.state === "ok" && "Web recorder uploads work"}
            {cors.state === "blocked" && cors.detail}
          </span>
        </div>
        <Button variant="ghost" size="sm" disabled={cors.state === "running"} onClick={onRun}>
          <RefreshCw data-icon="inline-start" />
          {cors.state === "idle" ? "Check now" : "Check again"}
        </Button>
      </div>
      {cors.state === "blocked" && <CorsSnippet origins={origins} />}
    </div>
  );
}

function BucketForm({
  draft,
  setDraft,
  disabled,
  pending,
  error,
  origins,
  onCancel,
  onSubmit,
}: {
  draft: Draft;
  setDraft: (patch: Partial<Draft>) => void;
  disabled: boolean;
  pending: boolean;
  error: string | null;
  origins: string[];
  onCancel?: () => void;
  onSubmit: () => void;
}) {
  const preset = PROVIDERS.find((p) => p.id === draft.provider)!;
  const ready =
    draft.bucket.trim() &&
    draft.region.trim() &&
    draft.accessKeyId.trim() &&
    draft.secretAccessKey.trim() &&
    (draft.provider === "aws" || draft.endpoint.trim());

  return (
    <form
      className="space-y-4"
      onSubmit={(e) => {
        e.preventDefault();
        if (ready && !disabled) onSubmit();
      }}
    >
      <fieldset disabled={disabled} className="space-y-4 disabled:opacity-60">
        <div className="flex flex-wrap gap-1.5" role="radiogroup" aria-label="Storage provider">
          {PROVIDERS.map((p) => (
            <button
              key={p.id}
              type="button"
              role="radio"
              aria-checked={draft.provider === p.id}
              onClick={() =>
                setDraft({
                  provider: p.id,
                  region: p.region,
                  endpoint: "",
                  forcePathStyle: p.pathStyle ?? false,
                })
              }
              className={cn(
                "h-8 rounded-full border px-3 text-xs transition-colors",
                draft.provider === p.id
                  ? "border-white/25 bg-white/[0.12] text-foreground"
                  : "border-white/10 bg-white/[0.03] text-muted-foreground hover:bg-white/[0.07] hover:text-foreground"
              )}
            >
              {p.label}
            </button>
          ))}
        </div>

        <div className="grid gap-3 sm:grid-cols-2">
          {preset.endpoint && (
            <Field label="Endpoint" className="sm:col-span-2" hint="The S3 API host only — no bucket name in it.">
              <input
                value={draft.endpoint}
                onChange={(e) => setDraft({ endpoint: e.target.value })}
                placeholder={preset.endpoint}
                className="studio-input w-full"
                autoComplete="off"
                spellCheck={false}
              />
            </Field>
          )}
          <Field label="Bucket">
            <input
              value={draft.bucket}
              onChange={(e) => setDraft({ bucket: e.target.value })}
              placeholder="my-videos"
              className="studio-input w-full"
              autoComplete="off"
              spellCheck={false}
            />
          </Field>
          <Field label="Region" hint={draft.provider === "r2" ? "R2 uses auto." : undefined}>
            <input
              value={draft.region}
              onChange={(e) => setDraft({ region: e.target.value })}
              placeholder={preset.region}
              className="studio-input w-full"
              autoComplete="off"
              spellCheck={false}
            />
          </Field>
          <Field label="Access key ID">
            <input
              value={draft.accessKeyId}
              onChange={(e) => setDraft({ accessKeyId: e.target.value })}
              className="studio-input w-full"
              autoComplete="off"
              spellCheck={false}
            />
          </Field>
          <Field label="Secret access key" hint="Stored encrypted and never shown again.">
            <input
              type="password"
              value={draft.secretAccessKey}
              onChange={(e) => setDraft({ secretAccessKey: e.target.value })}
              className="studio-input w-full"
              autoComplete="new-password"
              spellCheck={false}
            />
          </Field>
          <Field label="Folder" hint="Optional. Videos are stored under this path.">
            <input
              value={draft.pathPrefix}
              onChange={(e) => setDraft({ pathPrefix: e.target.value })}
              placeholder="capturecat/"
              className="studio-input w-full"
              autoComplete="off"
              spellCheck={false}
            />
          </Field>
          <Field
            label="Public URL"
            hint="Optional. Leave empty to play through short-lived signed links, which work with private buckets."
          >
            <input
              value={draft.publicBaseUrl}
              onChange={(e) => setDraft({ publicBaseUrl: e.target.value })}
              placeholder="https://videos.yourcompany.com"
              className="studio-input w-full"
              autoComplete="off"
              spellCheck={false}
            />
          </Field>
        </div>

        {draft.provider !== "aws" && (
          <label className="flex items-center justify-between gap-4">
            <span className="min-w-0">
              <span className="block text-sm font-medium">Path-style URLs</span>
              <span className="mt-0.5 block text-xs text-muted-foreground">
                For MinIO and other servers that don't support bucket subdomains.
              </span>
            </span>
            <Switch checked={draft.forcePathStyle} onCheckedChange={(on) => setDraft({ forcePathStyle: on })} />
          </label>
        )}

        {draft.publicBaseUrl.trim() && (
          <p className="text-xs text-amber-200/90">
            With a public URL, anyone who has a video's file address can play it, even if the share link has a password or
            has expired.
          </p>
        )}
      </fieldset>

      {error && <p className="text-sm text-destructive">{error}</p>}

      <div className="flex flex-wrap items-center gap-2">
        <Button type="submit" disabled={disabled || !ready}>
          {pending ? (
            <>
              <Spinner data-icon="inline-start" />
              Testing bucket…
            </>
          ) : (
            "Test & connect"
          )}
        </Button>
        {onCancel && (
          <Button type="button" variant="ghost" onClick={onCancel} disabled={pending}>
            Cancel
          </Button>
        )}
        <span className="text-xs text-muted-foreground">
          We write, read and delete a small test file before saving.
        </span>
      </div>

      {!disabled && <CorsSnippet origins={origins} />}
    </form>
  );
}
