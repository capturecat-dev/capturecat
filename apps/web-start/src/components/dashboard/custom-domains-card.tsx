import { useState } from "react";
import { toast } from "sonner";
import { BadgeCheck, Globe, RefreshCw, Trash2 } from "lucide-react";

import { trpc } from "@/lib/trpc/client";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";

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

  return (
    <div className="rounded-lg border p-4">
      <div className="flex items-center gap-2">
        <Globe className="h-4 w-4" />
        <h2 className="text-sm font-medium">Custom share domain</h2>
        <Badge variant="secondary" className="text-[10px]">PRO</Badge>
      </div>
      <p className="mt-1 text-sm text-muted-foreground">
        Serve share links from your own domain, e.g.{" "}
        <code className="text-xs">share.yourcompany.com/&lt;video&gt;</code>.
        Point a CNAME at <code className="text-xs">{data?.cnameTarget ?? "capturecat.so"}</code>{" "}
        and verify.
      </p>

      {isLoading ? (
        <p className="mt-3 text-sm text-muted-foreground">Loading…</p>
      ) : (
        <>
          <div className="mt-3 space-y-2">
            {(data?.domains ?? []).map((d) => (
              <div
                key={d.domain}
                className="flex items-center justify-between gap-3 rounded-md border px-3 py-2"
              >
                <div className="flex min-w-0 items-center gap-2">
                  <span className="truncate text-sm">{d.domain}</span>
                  {d.verified ? (
                    <Badge className="gap-1 text-[10px]"><BadgeCheck className="h-3 w-3" />verified</Badge>
                  ) : (
                    <Badge variant="secondary" className="text-[10px]">pending DNS</Badge>
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
                      <RefreshCw className="mr-1 h-3.5 w-3.5" />
                      Verify
                    </Button>
                  )}
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-8 w-8 text-destructive"
                    onClick={() => remove.mutate({ domain: d.domain })}
                  >
                    <Trash2 className="h-3.5 w-3.5" />
                  </Button>
                </div>
              </div>
            ))}
          </div>

          <form
            className="mt-3 flex gap-2"
            onSubmit={(e) => {
              e.preventDefault();
              if (draft.trim()) add.mutate({ domain: draft.trim().toLowerCase() });
            }}
          >
            <input
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              placeholder="share.yourcompany.com"
              className="min-w-0 flex-1 rounded-md border bg-transparent px-3 py-2 text-sm outline-none focus:ring-1 focus:ring-ring"
            />
            <Button type="submit" disabled={add.isPending || !draft.trim()}>
              {add.isPending ? "Adding…" : "Add domain"}
            </Button>
          </form>
          {data && !data.enabled && (
            <p className="mt-2 text-xs text-muted-foreground">
              Custom domains are a CaptureCat Pro feature —{" "}
              <a href="/app/billing" className="underline">upgrade</a> to enable.
            </p>
          )}
        </>
      )}
    </div>
  );
}
