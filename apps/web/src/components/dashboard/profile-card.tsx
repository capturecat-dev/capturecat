import { useState } from "react";
import { SkeletonCard } from "@/components/dashboard/page-skeletons";
import { Check, ExternalLink, X } from "lucide-react";
import { toast } from "sonner";

import { trpc } from "@/lib/trpc/client";
import { Button } from "@/components/ui/button";

/**
 * Claim a username and edit the public profile shown at capturecat.so/{username}.
 *
 * Availability is checked against the API as you type (it owns the charset,
 * reserved-word and uniqueness rules), but the claim itself is still validated
 * server-side — this check is a courtesy, not a gate.
 */
export function ProfileCard() {
  const utils = trpc.useUtils();
  const { data: profile, isLoading } = trpc.profile.me.useQuery();

  const [draftUsername, setDraftUsername] = useState<string | null>(null);
  const [bio, setBio] = useState<string | null>(null);
  const [website, setWebsite] = useState<string | null>(null);

  const username = draftUsername ?? profile?.username ?? "";
  const check = trpc.profile.checkUsername.useQuery(
    { username },
    // Only worth asking once it could plausibly be valid and differs from the
    // name already claimed.
    { enabled: username.length >= 3 && username !== (profile?.username ?? "") }
  );

  const update = trpc.profile.update.useMutation({
    onSuccess: () => {
      void utils.profile.me.invalidate();
      setDraftUsername(null);
      toast.success("Profile saved");
    },
    onError: (error) => toast.error(error.message),
  });

  if (isLoading) {
    return <SkeletonCard lines={4} action />;
  }

  const claimed = profile?.username ?? null;
  const changed =
    (draftUsername !== null && draftUsername !== claimed) ||
    (bio !== null && bio !== (profile?.bio ?? "")) ||
    (website !== null && website !== (profile?.website ?? ""));

  const save = () => {
    const payload: { username?: string; bio?: string | null; website?: string | null } = {};
    if (draftUsername !== null && draftUsername !== claimed) {
      payload.username = draftUsername.trim().toLowerCase();
    }
    if (bio !== null) payload.bio = bio.trim() || null;
    if (website !== null) payload.website = website.trim() || null;
    if (Object.keys(payload).length === 0) return;
    update.mutate(payload);
  };

  return (
    <section className="rounded-2xl border border-white/10 bg-white/[0.03] p-5 backdrop-blur-2xl">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-sm font-semibold">Public profile</h2>
          <p className="mt-1 text-xs text-muted-foreground">
            Claim a username to get a public page listing the videos you choose
            to show.
          </p>
        </div>
        {claimed && (
          <a
            href={`/${claimed}`}
            target="_blank"
            rel="noreferrer"
            className="inline-flex shrink-0 items-center gap-1 text-xs text-primary hover:underline"
          >
            View <ExternalLink className="h-3 w-3" />
          </a>
        )}
      </div>

      <div className="mt-4 space-y-3">
        <div className="space-y-1">
          <label className="text-xs font-medium text-muted-foreground">Username</label>
          <div className="flex min-w-0 items-center gap-2">
            <span className="shrink-0 text-sm text-muted-foreground">capturecat.so/</span>
            <input
              type="text"
              value={username}
              onChange={(e) => setDraftUsername(e.target.value.toLowerCase())}
              placeholder="yourname"
              maxLength={30}
              className="min-w-0 flex-1 rounded-md border bg-transparent px-3 py-2 text-sm outline-none focus:ring-1 focus:ring-ring"
            />
            {username.length >= 3 && username !== claimed && !check.isFetching && check.data && (
              <span className="shrink-0">
                {check.data.available ? (
                  <Check className="h-4 w-4 text-emerald-400" />
                ) : (
                  <X className="h-4 w-4 text-destructive" />
                )}
              </span>
            )}
          </div>
          {check.data?.error && username !== claimed && (
            <p className="text-xs text-destructive">{check.data.error}</p>
          )}
          {claimed && draftUsername !== null && draftUsername !== claimed && (
            <p className="text-xs text-amber-400">
              Changing your username breaks the old profile link.
            </p>
          )}
        </div>

        <div className="space-y-1">
          <label className="text-xs font-medium text-muted-foreground">Bio</label>
          <textarea
            value={bio ?? profile?.bio ?? ""}
            onChange={(e) => setBio(e.target.value)}
            placeholder="What you make videos about."
            maxLength={200}
            rows={2}
            className="w-full resize-none rounded-md border bg-transparent px-3 py-2 text-sm outline-none focus:ring-1 focus:ring-ring"
          />
        </div>

        <div className="space-y-1">
          <label className="text-xs font-medium text-muted-foreground">Website</label>
          <input
            type="url"
            value={website ?? profile?.website ?? ""}
            onChange={(e) => setWebsite(e.target.value)}
            placeholder="https://example.com"
            className="w-full rounded-md border bg-transparent px-3 py-2 text-sm outline-none focus:ring-1 focus:ring-ring"
          />
        </div>

        <div className="flex justify-end">
          <Button size="sm" onClick={save} disabled={!changed || update.isPending}>
            {update.isPending ? "Saving…" : "Save profile"}
          </Button>
        </div>
      </div>
    </section>
  );
}
