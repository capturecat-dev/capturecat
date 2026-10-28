import { useMemo, useState } from "react";

import { trpc } from "@/lib/trpc/client";
import type { AgentScope, ConsentInfo } from "@/lib/agent-access";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { Spinner } from "@/components/ui/spinner";
import { AppLogo } from "@/components/dashboard/agent-connections";
import { ScopeCheckbox } from "@/components/dashboard/agent-access-card";
import { PlanUnavailableNote } from "@/components/dashboard/plan-unavailable-note";
import { CCIcon } from "@/editor/ui/kit/ccIcon";

/**
 * The OAuth consent page's body (routes/oauth.authorize.tsx): who is asking
 * (name, logo, the verified host of a metadata-document client, where the
 * browser goes back to), the permissions to narrow, Allow / Deny. The API
 * re-validates the whole request on both calls (apps/api/src/routes/oauth.ts).
 * A component of its own so the DEV dashboard lab can render it.
 */
export function ConsentPage({ params, email }: { params: Record<string, string | undefined>; email: string }) {
  const info = trpc.oauth.info.useQuery(params, { retry: false, refetchOnWindowFocus: false });

  return (
    <main className="flex min-h-screen flex-col bg-background">
      <div className="flex flex-1 items-center justify-center px-4 py-16">
        <div className="relative w-full max-w-md overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] p-6 backdrop-blur-2xl sm:p-8">
          <span
            aria-hidden
            className="absolute inset-x-8 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
          />
          {info.isLoading ? (
            <div className="space-y-4">
              <Skeleton className="h-12 w-2/3" />
              <Skeleton className="h-40 w-full" />
            </div>
          ) : info.error ? (
            <Problem description={info.error.message} redirect={null} />
          ) : info.data && !info.data.ok ? (
            <Problem description={info.data.description} redirect={info.data.redirect} />
          ) : info.data ? (
            <Consent info={info.data} params={params} email={email} />
          ) : null}
        </div>
      </div>
    </main>
  );
}

function Problem({ description, redirect: back }: { description: string; redirect: string | null }) {
  return (
    <div className="space-y-4 text-center">
      <CCIcon name="warning-fill" className="mx-auto size-6 text-cc-amber-text" />
      <h1 className="text-lg font-semibold">This app can't connect</h1>
      <p className="text-sm text-muted-foreground">{description}</p>
      {back ? (
        <Button onClick={() => window.location.assign(back)}>Back to the app</Button>
      ) : (
        <p className="text-xs text-muted-foreground">Tell the developer of the app you came from.</p>
      )}
    </div>
  );
}

function Consent({
  info,
  params,
  email,
}: {
  info: ConsentInfo;
  params: Record<string, string | undefined>;
  email: string;
}) {
  const [scopes, setScopes] = useState<AgentScope[]>(info.scopes);
  const [leaving, setLeaving] = useState<"allow" | "deny" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const decide = trpc.oauth.decide.useMutation({
    onSuccess: (result) => {
      if (result.redirect) {
        window.location.assign(result.redirect);
        return;
      }
      setLeaving(null);
      setError(result.error ?? "This request can't be completed.");
    },
    onError: (e) => {
      setLeaving(null);
      setError(e.message);
    },
  });
  const client = info.client;
  const writes = useMemo(() => scopes.filter((s) => s.endsWith(":write") || s === "screenshots"), [scopes]);
  const toggle = (s: AgentScope) => setScopes((cur) => (cur.includes(s) ? cur.filter((x) => x !== s) : [...cur, s]));
  const go = (approve: boolean) => {
    setError(null);
    setLeaving(approve ? "allow" : "deny");
    decide.mutate({ params, approve, ...(approve ? { scopes } : {}) });
  };

  return (
    <div className="space-y-5">
      <div className="flex items-center gap-3">
        <AppLogo app={{ name: client.name, logoUri: client.logoUri }} className="size-11 rounded-[0.875rem]" />
        <CCIcon name="arrow-right-line" className="size-4 shrink-0 text-muted-foreground" />
        <span className="grid size-11 shrink-0 place-items-center rounded-[0.875rem] bg-primary text-primary-foreground">
          <CCIcon name="record-fill" className="size-5" />
        </span>
      </div>

      <div>
        <h1 className="text-xl font-semibold tracking-[-0.01em]">{client.name} wants to use your CaptureCat account</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Signed in as <span className="text-foreground">{email}</span>
        </p>
      </div>

      <div className="cc-well space-y-1.5 rounded-[0.875rem] px-3 py-2.5 text-xs text-muted-foreground">
        {client.verifiedHost ? (
          <p className="flex items-center gap-1.5">
            <CCIcon name="seal-check" size={14} className="shrink-0 text-cc-green-text" />
            Published by <span className="font-medium text-foreground">{client.verifiedHost}</span>
          </p>
        ) : (
          <p className="flex items-start gap-1.5">
            <CCIcon name="info-fill" size={14} className="mt-px shrink-0" />
            <span>
              This app registered itself as “{client.name}” — CaptureCat can't verify that name. Check where it sends you.
            </span>
          </p>
        )}
        <p className="flex items-center gap-1.5">
          <CCIcon name="arrow-up-right" size={14} className="shrink-0" />
          Sends you back to <span className="font-medium text-foreground">{client.redirectHost}</span>
        </p>
      </div>

      {info.available ? (
        <div className="space-y-2">
          <span className="studio-eyebrow block">It will be able to</span>
          <div className="space-y-2">
            {info.scopes.map((s) => (
              <ScopeCheckbox key={s} scope={s} checked={scopes.includes(s)} onToggle={() => toggle(s)} />
            ))}
          </div>
          <p className="text-xs text-muted-foreground">
            Untick anything you don't want to allow. It can never delete videos, spend money or manage your tokens
            {writes.length > 0 ? ", and it asks you first before posting a comment or making a video more visible" : ""}.
            Disconnect it any time in Settings → Agent access.
          </p>
        </div>
      ) : (
        <PlanUnavailableNote>{info.unavailableReason ?? "Agent access isn't part of your plan."}</PlanUnavailableNote>
      )}

      {error && <p className="text-sm text-destructive">{error}</p>}

      <div className="flex items-center justify-end gap-2">
        <Button variant="outline" disabled={leaving !== null} onClick={() => go(false)}>
          {leaving === "deny" && <Spinner data-icon="inline-start" />}
          {info.available ? "Deny" : "Cancel"}
        </Button>
        {info.available && (
          <Button disabled={leaving !== null || scopes.length === 0} onClick={() => go(true)}>
            {leaving === "allow" && <Spinner data-icon="inline-start" />}
            Allow
          </Button>
        )}
      </div>
    </div>
  );
}
