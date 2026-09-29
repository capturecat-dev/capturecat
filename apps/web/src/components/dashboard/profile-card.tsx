import { useState } from "react";
import { SkeletonLines } from "@/components/dashboard/page-skeletons";
import { Check, ExternalLink, UserRound, X } from "lucide-react";
import { toast } from "sonner";

import { trpc } from "@/lib/trpc/client";
import { Button } from "@/components/ui/button";
import { Field, Section } from "@/components/dashboard/studio";

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
    return (
      <Section title="Public profile">
        <SkeletonLines lines={4} />
      </Section>
    );
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

  const availability =
    username.length >= 3 && username !== claimed && !check.isFetching && check.data
      ? check.data.available
      : null;

  return (
    <Section
      icon={<UserRound />}
      title="Public profile"
      description="Claim a username to get a public page listing the videos you choose to show."
      actions={
        claimed ? (
          <Button variant="outline" size="sm" asChild>
            <a href={`/${claimed}`} target="_blank" rel="noreferrer">
              View <ExternalLink data-icon="inline-end" />
            </a>
          </Button>
        ) : undefined
      }
    >
      <div className="space-y-4">
        <Field
          label="Username"
          error={check.data?.error && username !== claimed ? check.data.error : undefined}
          hint={
            claimed && draftUsername !== null && draftUsername !== claimed ? (
              <span className="text-amber-400">Changing your username breaks the old profile link.</span>
            ) : undefined
          }
        >
          <div className="flex min-w-0 items-center gap-2">
            <span className="shrink-0 text-sm text-muted-foreground">capturecat.so/</span>
            <div className="relative min-w-0 flex-1">
              <input
                type="text"
                value={username}
                onChange={(e) => setDraftUsername(e.target.value.toLowerCase())}
                placeholder="yourname"
                maxLength={30}
                className="studio-input pr-9"
              />
              {availability !== null && (
                <span className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2">
                  {availability ? (
                    <Check className="size-4 text-emerald-400" />
                  ) : (
                    <X className="size-4 text-destructive" />
                  )}
                </span>
              )}
            </div>
          </div>
        </Field>

        <Field label="Bio">
          <textarea
            value={bio ?? profile?.bio ?? ""}
            onChange={(e) => setBio(e.target.value)}
            placeholder="What you make videos about."
            maxLength={200}
            rows={2}
            className="studio-input"
          />
        </Field>

        <Field label="Website">
          <input
            type="url"
            value={website ?? profile?.website ?? ""}
            onChange={(e) => setWebsite(e.target.value)}
            placeholder="https://example.com"
            className="studio-input"
          />
        </Field>

        <div className="flex justify-end">
          <Button size="sm" onClick={save} disabled={!changed || update.isPending}>
            {update.isPending ? "Saving…" : "Save profile"}
          </Button>
        </div>
      </div>
    </Section>
  );
}
