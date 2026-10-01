import { useState } from "react";
import { toast } from "sonner";
import { BadgeCheck, Globe, RefreshCw, Trash2 } from "lucide-react";

import { trpc } from "@/lib/trpc/client";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import { EmptyStage, LiveDot, PlanChip, Row, Section, UpgradeNote } from "@/components/dashboard/studio";
import { DomainArt } from "@/components/dashboard/empty-art";

/**
 * Pro feature: serve share pages from the user's own domain. The card walks
 * through CNAME setup and verifies DNS server-side; unverified domains never
 * route. Free users see the feature with an upgrade nudge — the API refuses
 * the add regardless (deny-by-default plan flags).
 */
export function CustomDomainsCard() {
  const utils = trpc.useUtils();
  const { data, isLoading } = trpc.videos.domains.useQuery();
  const [draft, setDraft] = useState("");

  const add = trpc.videos.addDomain.useMutation({
    onSuccess: () => {
      setDraft("");
      void utils.videos.domains.invalidate();
      toast.success("Domain added — now point its CNAME at us and verify");
    },
    onError: (error) => toast.error(error.message),
  });
  const verify = trpc.videos.verifyDomain.useMutation({
    onSuccess: (result) => {
      void utils.videos.domains.invalidate();
      if (result.verified) toast.success(`${result.domain} verified`);
      else
        toast.error(
          `Not verified yet — found ${result.found.length ? result.found.join(", ") : "no CNAME"}, expected ${result.expected}`
        );
    },
    onError: (error) => toast.error(error.message),
  });
  const remove = trpc.videos.removeDomain.useMutation({
    onSuccess: () => void utils.videos.domains.invalidate(),
  });

  const domains = data?.domains ?? [];

  return (
    <Section
      icon={<Globe />}
      title="Custom share domain"
      badge={<PlanChip plan="pro" />}
      description={
        <>
          Serve share links from your own domain, e.g.{" "}
          <code className="text-xs text-foreground/80">share.yourcompany.com/&lt;video&gt;</code>.
          Point a CNAME at{" "}
          <code className="text-xs text-foreground/80">{data?.cnameTarget ?? "capturecat.so"}</code>{" "}
          and verify.
        </>
      }
    >
      {isLoading ? (
        <div className="space-y-3">
          <Skeleton className="h-[50px] w-full rounded-[0.875rem]" />
          <div className="flex gap-2">
            <Skeleton className="h-9 flex-1 rounded-full" />
            <Skeleton className="h-9 w-28 rounded-full" />
          </div>
        </div>
      ) : (
        <div className="space-y-3">
          {domains.length === 0 ? (
            <EmptyStage
              compact
              art={<DomainArt />}
              title="No domains yet"
              description="Add one below and your share links read share.yourcompany.com instead of ours."
            />
          ) : (
            <div className="space-y-2">
              {domains.map((d, i) => (
                <Row key={d.domain} className="dsh-rise" index={i}>
                  <div className="flex min-w-0 items-center gap-2.5">
                    {d.verified ? (
                      <span aria-hidden className="size-1.5 shrink-0 rounded-full bg-emerald-400 shadow-[0_0_8px_rgba(52,211,153,0.7)]" />
                    ) : (
                      <LiveDot tone="amber" className="size-1.5" />
                    )}
                    <span className="truncate text-sm">{d.domain}</span>
                    {d.verified ? (
                      <Badge variant="outline" className="gap-1 border-emerald-400/25 bg-emerald-400/10 text-[10px] text-emerald-300">
                        <BadgeCheck />
                        verified
                      </Badge>
                    ) : (
                      <Badge variant="outline" className="border-amber-400/25 bg-amber-400/10 text-[10px] text-amber-200">
                        pending DNS
                      </Badge>
                    )}
                  </div>
                  <div className="flex shrink-0 items-center gap-1">
                    {!d.verified && (
                      <Button
                        variant="ghost"
                        size="sm"
                        disabled={verify.isPending}
                        onClick={() => verify.mutate({ domain: d.domain })}
                      >
                        <RefreshCw data-icon="inline-start" />
                        Verify
                      </Button>
                    )}
                    <Button
                      variant="ghost"
                      size="icon-sm"
                      className="text-destructive hover:text-destructive"
                      aria-label={`Remove ${d.domain}`}
                      onClick={() => remove.mutate({ domain: d.domain })}
                    >
                      <Trash2 />
                    </Button>
                  </div>
                </Row>
              ))}
            </div>
          )}

          <form
            className="flex gap-2"
            onSubmit={(e) => {
              e.preventDefault();
              if (draft.trim()) add.mutate({ domain: draft.trim().toLowerCase() });
            }}
          >
            <input
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              placeholder="share.yourcompany.com"
              className="studio-input flex-1"
            />
            <Button type="submit" disabled={add.isPending || !draft.trim()}>
              {add.isPending ? "Adding…" : "Add domain"}
            </Button>
          </form>
          {data && !data.enabled && <UpgradeNote plan="pro">Custom domains are part of Pro.</UpgradeNote>}
        </div>
      )}
    </Section>
  );
}
