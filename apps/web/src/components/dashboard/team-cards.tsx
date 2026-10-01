import { useCallback, useEffect, useRef, useState, type CSSProperties } from "react";
import { toast } from "sonner";
import {
  BadgeCheck,
  Copy,
  KeyRound,
  PlayIcon,
  ShieldCheck,
  Trash2,
  UserPlus,
  Users,
  Video,
} from "lucide-react";

import { authClient } from "@/lib/auth-client";
import { API_URL, SITE_URL } from "@/lib/api-url";
import { trpc } from "@/lib/trpc/client";
import type { SsoProvider } from "@/lib/trpc/routers/sso";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import { TeamAvatar } from "@/components/dashboard/team-avatar";
import { TeamSkeleton, SkeletonLines } from "@/components/dashboard/page-skeletons";
import {
  EmptyStage,
  Field,
  LiveDot,
  Panel,
  PlanChip,
  Row,
  Section,
  Sections,
  UpgradeNote,
} from "@/components/dashboard/studio";
import { LibraryArt, SsoArt, TeamArt } from "@/components/dashboard/empty-art";
import { cn } from "@/lib/utils";

/** A teammate: initials on a hue derived from their name (TeamAvatar's
 *  recipe), round where the team's mark is square. */
function PersonAvatar({ name }: { name: string }) {
  const initials = name
    .split(/[\s@.]+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0]!.toUpperCase())
    .join("");
  let hash = 0;
  for (const ch of name) hash = (hash * 31 + ch.charCodeAt(0)) >>> 0;
  const hue = hash % 360;
  return (
    <span
      aria-hidden
      className="flex size-7 shrink-0 items-center justify-center rounded-full text-[10px] font-semibold text-white shadow-[inset_0_1px_0_rgba(255,255,255,0.25)]"
      style={{ background: `linear-gradient(135deg, hsl(${hue} 70% 55%), hsl(${(hue + 40) % 360} 65% 42%))` }}
    >
      {initials || "?"}
    </span>
  );
}

/** Member rows while the organization loads — the rows' own height. */
function MemberRowsSkeleton() {
  return (
    <>
      {Array.from({ length: 3 }, (_, i) => (
        <Skeleton key={i} className="h-[50px] w-full rounded-[0.875rem]" />
      ))}
    </>
  );
}

const ROLE_BADGE: Record<string, string> = {
  owner: "border-cyan-300/30 bg-cyan-400/10 text-cyan-200",
  admin: "border-violet-300/25 bg-violet-400/10 text-violet-200",
};

/**
 * Teams — members and the shared library ride the Better Auth organization
 * plugin directly from the browser (the auth client already speaks those
 * endpoints, credentialed and CSRF-checked server-side). SSO goes through
 * tRPC (`routers/sso.ts`) so the overview, verification and provider CRUD
 * are typed and validated in one place.
 *
 * Invitations are LINK-based: the server deliberately sends no email, so the
 * pending list surfaces a copyable accept URL instead.
 */

type Member = {
  id: string;
  role: string;
  user: { id: string; name: string; email: string };
};
type Invitation = { id: string; email: string; role: string; status: string };
type FullOrg = {
  id: string;
  name: string;
  slug: string;
  logo: string | null;
  members: Member[];
  invitations: Invitation[];
};

export function TeamCards() {
  const { data: orgs, isPending } = authClient.useListOrganizations();
  const org = orgs?.[0] ?? null;

  if (isPending) {
    return <TeamSkeleton />;
  }
  if (!org) return <CreateTeamCard />;
  return <TeamDetail orgId={org.id} orgName={org.name} />;
}

function CreateTeamCard() {
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);

  const create = async () => {
    const trimmed = name.trim();
    if (!trimmed) return;
    setBusy(true);
    const slug =
      trimmed.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") +
      "-" + Math.random().toString(36).slice(2, 6);
    const { error } = await authClient.organization.create({ name: trimmed, slug });
    setBusy(false);
    if (error) toast.error(error.message ?? "Could not create team");
    else toast.success(`Team “${trimmed}” created`);
  };

  return (
    <Panel
      className="max-w-3xl"
      icon={<Users />}
      title="Create your team"
      description="A shared library for your company’s recordings — invite teammates, collect every share in one place, and (on Business) bring your own single sign-on."
    >
      <EmptyStage
        compact
        art={<TeamArt />}
        title="Everyone’s shares, one library"
        description="Name your team, then invite teammates with a link. Their shared videos collect here."
      />
      <form
        className="mt-4 flex gap-2"
        onSubmit={(e) => {
          e.preventDefault();
          void create();
        }}
      >
        <input
          className="studio-input flex-1"
          placeholder="Team name, e.g. Acme Inc"
          value={name}
          onChange={(e) => setName(e.target.value)}
        />
        <Button type="submit" disabled={busy || !name.trim()}>
          Create team
        </Button>
      </form>
    </Panel>
  );
}

function TeamDetail({ orgId, orgName }: { orgId: string; orgName: string }) {
  const { data: session } = authClient.useSession();
  const [full, setFull] = useState<FullOrg | null>(null);

  const refresh = useCallback(async () => {
    const { data } = await authClient.organization.getFullOrganization({
      query: { organizationId: orgId },
    });
    if (data) setFull(data as unknown as FullOrg);
  }, [orgId]);

  // Settled = the first members fetch finished, with or without data (a
  // failed fetch still shows the page, as before, with members loading).
  const [membersSettled, setMembersSettled] = useState(false);
  useEffect(() => {
    void refresh().finally(() => setMembersSettled(true));
  }, [refresh]);

  const library = useTeamLibrary(orgId);

  const myRole =
    full?.members.find((m) => m.user.id === session?.user.id)?.role ?? "member";
  const canManage = myRole === "owner" || myRole === "admin";

  // One skeleton until the members AND the team library are in, then the
  // whole surface lands at once — groups growing one after another would
  // push the ones below them down (layout shift).
  if (!membersSettled || !library.loaded) return <TeamSkeleton />;

  return (
    <Sections className="max-w-3xl">
      <MembersCard
        orgId={orgId}
        orgName={orgName}
        full={full}
        canManage={canManage}
        refresh={refresh}
      />
      <TeamLibraryCard videos={library.videos} loaded={library.loaded} />
      {canManage && <SsoCard orgId={orgId} />}
    </Sections>
  );
}

function MembersCard({
  orgId,
  orgName,
  full,
  canManage,
  refresh,
}: {
  orgId: string;
  orgName: string;
  full: FullOrg | null;
  canManage: boolean;
  refresh: () => Promise<void>;
}) {
  const [email, setEmail] = useState("");
  const [busy, setBusy] = useState(false);

  const invite = async () => {
    const trimmed = email.trim();
    if (!trimmed) return;
    setBusy(true);
    const { error } = await authClient.organization.inviteMember({
      email: trimmed,
      role: "member",
      organizationId: orgId,
    });
    setBusy(false);
    if (error) toast.error(error.message ?? "Invite failed");
    else {
      setEmail("");
      toast.success("Invitation created — copy the link and send it");
      await refresh();
    }
  };

  const copyInviteLink = (invitationId: string) => {
    void navigator.clipboard.writeText(`${SITE_URL}/accept-invitation/${invitationId}`);
    toast.success("Invite link copied");
  };

  const pending = (full?.invitations ?? []).filter((i) => i.status === "pending");
  const memberCount = full?.members.length;

  return (
    <Section
      title={
        <span className="flex items-center gap-3">
          <TeamAvatar name={orgName} logo={full?.logo} size={32} />
          {orgName}
        </span>
      }
      description={
        memberCount === undefined
          ? "Loading members…"
          : `${memberCount} member${memberCount === 1 ? "" : "s"}${pending.length ? ` · ${pending.length} invited` : ""}`
      }
      actions={canManage ? <LogoUploadButton orgId={orgId} onUploaded={refresh} /> : undefined}
    >
      <div className="space-y-2">
        {!full && <MemberRowsSkeleton />}
        {(full?.members ?? []).map((m, i) => (
          <Row key={m.id} className="dsh-rise" index={i}>
            <div className="flex min-w-0 items-center gap-3">
              <PersonAvatar name={m.user.name || m.user.email} />
              <div className="min-w-0">
                <span className="block truncate text-sm">{m.user.name || m.user.email}</span>
                <span className="block truncate text-xs text-muted-foreground">{m.user.email}</span>
              </div>
            </div>
            <div className="flex items-center gap-2">
              <Badge
                variant="outline"
                className={cn("text-[10px] capitalize", ROLE_BADGE[m.role] ?? "border-white/12 bg-white/[0.04] text-muted-foreground")}
              >
                {m.role}
              </Badge>
              {canManage && m.role !== "owner" && (
                <Button
                  variant="ghost"
                  size="icon-xs"
                  aria-label="Remove from team"
                  onClick={async () => {
                    const { error } = await authClient.organization.removeMember({
                      memberIdOrEmail: m.user.email,
                      organizationId: orgId,
                    });
                    if (error) toast.error(error.message ?? "Remove failed");
                    else await refresh();
                  }}
                >
                  <Trash2 />
                </Button>
              )}
            </div>
          </Row>
        ))}

        {pending.map((i) => (
          <Row key={i.id} dashed className="dsh-rise">
            <div className="flex min-w-0 items-center gap-3">
              <span aria-hidden className="flex size-7 shrink-0 items-center justify-center rounded-full border border-dashed border-white/25 text-muted-foreground">
                <UserPlus className="size-3.5" />
              </span>
              <span className="truncate text-sm">{i.email}</span>
              <Badge variant="outline" className="gap-1.5 border-amber-400/25 bg-amber-400/10 text-[10px] text-amber-200">
                <LiveDot tone="amber" className="size-1.5" />
                invited
              </Badge>
            </div>
            {canManage && (
              <div className="flex items-center gap-1">
                <Button variant="ghost" size="xs" onClick={() => copyInviteLink(i.id)}>
                  <Copy data-icon="inline-start" /> Copy link
                </Button>
                <Button
                  variant="ghost"
                  size="icon-xs"
                  aria-label="Cancel invitation"
                  onClick={async () => {
                    await authClient.organization.cancelInvitation({ invitationId: i.id });
                    await refresh();
                  }}
                >
                  <Trash2 />
                </Button>
              </div>
            )}
          </Row>
        ))}
      </div>

      {canManage && (
        <form
          className="mt-3 flex gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            void invite();
          }}
        >
          <input
            className="studio-input flex-1"
            placeholder="teammate@company.com"
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
          <Button type="submit" disabled={busy || !email.trim()}>
            <UserPlus data-icon="inline-start" /> Invite
          </Button>
        </form>
      )}
    </Section>
  );
}

function LogoUploadButton({
  orgId,
  onUploaded,
}: {
  orgId: string;
  onUploaded: () => Promise<void>;
}) {
  const fileRef = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);

  const upload = async (file: File) => {
    if (file.size > 1024 * 1024) {
      toast.error("Logo must be under 1 MB");
      return;
    }
    setBusy(true);
    try {
      const res = await fetch(`${API_URL}/api/org/${encodeURIComponent(orgId)}/logo`, {
        method: "PUT",
        credentials: "include",
        headers: { "Content-Type": file.type },
        body: file,
      });
      if (!res.ok) {
        const data = (await res.json().catch(() => null)) as { error?: string } | null;
        toast.error(data?.error ?? "Upload failed");
      } else {
        toast.success("Team logo updated");
        await onUploaded();
      }
    } catch {
      toast.error("Upload failed — is the API reachable?");
    } finally {
      setBusy(false);
      if (fileRef.current) fileRef.current.value = "";
    }
  };

  return (
    <>
      <input
        ref={fileRef}
        type="file"
        accept="image/png,image/jpeg,image/webp"
        className="hidden"
        onChange={(e) => {
          const f = e.target.files?.[0];
          if (f) void upload(f);
        }}
      />
      <Button variant="outline" size="sm" disabled={busy} onClick={() => fileRef.current?.click()}>
        {busy ? "Uploading…" : "Upload logo"}
      </Button>
    </>
  );
}

type TeamVideo = { videoId: string; fileName: string; createdAt: string; url: string };

/** The team's shared videos (the API's REST route, credentialed). */
function useTeamLibrary(orgId: string) {
  const [videos, setVideos] = useState<TeamVideo[]>([]);
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const res = await fetch(`${API_URL}/api/org/${encodeURIComponent(orgId)}/videos`, {
          credentials: "include",
        });
        if (!res.ok) return;
        const data = (await res.json()) as { videos: typeof videos };
        if (!cancelled) setVideos(data.videos);
      } finally {
        if (!cancelled) setLoaded(true);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [orgId]);

  return { videos, loaded };
}

function TeamLibraryCard({ videos, loaded }: { videos: TeamVideo[]; loaded: boolean }) {
  return (
    <Section
      icon={<Video />}
      title="Team library"
      badge={<PlanChip plan="pro" />}
      description="Videos teammates shared to the team. Add yours from a video’s share settings."
    >
      <div className="space-y-2">
        {!loaded && <SkeletonLines lines={2} />}
        {loaded && videos.length === 0 && (
          <EmptyStage
            compact
            art={<LibraryArt />}
            title="Nothing here yet."
            description="Shares added to the team land here for everyone in it."
          />
        )}
        {videos.map((v, i) => (
          <a
            key={v.videoId}
            href={v.url}
            target="_blank"
            rel="noreferrer"
            className="studio-row dsh-rise group"
            style={{ "--i": i } as CSSProperties}
          >
            <span className="flex min-w-0 items-center gap-3">
              <span
                aria-hidden
                className="flex size-7 shrink-0 items-center justify-center rounded-lg border border-white/10 bg-white/[0.05] text-white/70 transition-colors group-hover:text-white"
              >
                <PlayIcon className="size-3 fill-current" />
              </span>
              <span className="truncate text-sm">{v.fileName}</span>
            </span>
            <span className="text-xs text-muted-foreground tabular-nums">
              {new Date(v.createdAt).toLocaleDateString()}
            </span>
          </a>
        ))}
      </div>
    </Section>
  );
}

/* ------------------------------------------------------------------ */
/* Single sign-on                                                      */
/* ------------------------------------------------------------------ */

function CopyValue({ label, value, mono = true }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="min-w-0">
      <span className="studio-eyebrow block">{label}</span>
      <div className="mt-1 flex min-w-0 items-center gap-2">
        <code className={"studio-well block min-w-0 flex-1 truncate px-3 py-2 text-xs " + (mono ? "" : "font-sans")}>
          {value}
        </code>
        <Button
          variant="outline"
          size="icon-sm"
          aria-label={`Copy ${label}`}
          onClick={() => {
            void navigator.clipboard.writeText(value);
            toast.success(`${label} copied`);
          }}
        >
          <Copy />
        </Button>
      </div>
    </div>
  );
}

function ProviderRow({
  orgId,
  provider,
  canManage,
  onChanged,
}: {
  orgId: string;
  provider: SsoProvider;
  canManage: boolean;
  onChanged: () => void;
}) {
  const [open, setOpen] = useState(!provider.domainVerified);
  const verify = trpc.sso.verifyDomain.useMutation({
    onSuccess: (r) => {
      if (r.domainVerified) toast.success(`${provider.domain} verified — teammates can sign in with SSO`);
      else
        toast.error(
          r.found.length
            ? `TXT record found but it does not match yet (${r.found.length} value${r.found.length === 1 ? "" : "s"}). DNS can take a few minutes.`
            : "No TXT record found yet. DNS can take a few minutes.",
        );
      onChanged();
    },
    onError: (e) => toast.error(e.message),
  });
  const remove = trpc.sso.remove.useMutation({
    onSuccess: () => {
      toast.success("Identity provider removed");
      onChanged();
    },
    onError: (e) => toast.error(e.message),
  });

  return (
    <div className="dsh-rise rounded-[0.875rem] border border-white/8 bg-white/[0.025]">
      <div className="flex items-center justify-between gap-3 px-3.5 py-2.5">
        <div className="flex min-w-0 items-center gap-2">
          {provider.domainVerified ? (
            <span aria-hidden className="size-1.5 shrink-0 rounded-full bg-emerald-400 shadow-[0_0_8px_rgba(52,211,153,0.7)]" />
          ) : (
            <LiveDot tone="amber" className="size-1.5" />
          )}
          <span className="truncate text-sm">{provider.domain}</span>
          <Badge variant="outline" className="text-[10px] uppercase">
            {provider.type}
          </Badge>
          {provider.domainVerified ? (
            <Badge variant="outline" className="gap-1 border-emerald-400/25 bg-emerald-400/10 text-[10px] text-emerald-300">
              <BadgeCheck /> verified
            </Badge>
          ) : (
            <Badge variant="outline" className="border-amber-400/25 bg-amber-400/10 text-[10px] text-amber-200">
              pending DNS
            </Badge>
          )}
        </div>
        <div className="flex shrink-0 items-center gap-1">
          <Button variant="ghost" size="xs" onClick={() => setOpen((v) => !v)}>
            {open ? "Hide setup" : "Setup"}
          </Button>
          {canManage && (
            <Button
              variant="ghost"
              size="icon-xs"
              className="text-destructive hover:text-destructive"
              aria-label={`Remove ${provider.providerId}`}
              disabled={remove.isPending}
              onClick={() => {
                if (window.confirm(`Remove the ${provider.domain} identity provider? Teammates will no longer be able to sign in with it.`)) {
                  remove.mutate({ providerId: provider.providerId });
                }
              }}
            >
              <Trash2 />
            </Button>
          )}
        </div>
      </div>

      {open && (
        <div className="space-y-4 border-t border-white/8 px-3.5 py-3.5">
          {!provider.domainVerified && provider.dnsRecord && (
            <div className="space-y-3">
              <p className="text-[13px] text-muted-foreground">
                <span className="text-foreground">Step 1 — prove you own {provider.domain}.</span>{" "}
                Add this TXT record at your DNS host, then click Verify. Sign-in stays off until it
                passes.
              </p>
              <div className="grid gap-3 md:grid-cols-2">
                <CopyValue label="TXT name" value={provider.dnsRecord.name} />
                <CopyValue label="TXT value" value={provider.dnsRecord.value} />
              </div>
              {canManage && (
                <Button
                  size="sm"
                  disabled={verify.isPending}
                  onClick={() => verify.mutate({ organizationId: orgId, providerId: provider.providerId })}
                >
                  <ShieldCheck data-icon="inline-start" />
                  {verify.isPending ? "Checking DNS…" : "Verify domain"}
                </Button>
              )}
            </div>
          )}

          <div className="space-y-3">
            <p className="text-[13px] text-muted-foreground">
              <span className="text-foreground">
                {provider.domainVerified ? "In your identity provider." : "Step 2 — in your identity provider."}
              </span>{" "}
              {provider.type === "oidc"
                ? "Register this redirect URI on the OIDC application."
                : "Configure the service provider with these values."}
            </p>
            {provider.type === "oidc" ? (
              <div className="grid gap-3">
                <CopyValue label="Redirect URI" value={provider.redirectUri} />
                {provider.oidc?.discoveryEndpoint && (
                  <CopyValue label="Discovery" value={provider.oidc.discoveryEndpoint} />
                )}
              </div>
            ) : (
              <div className="grid gap-3 md:grid-cols-2">
                <CopyValue label="ACS URL" value={provider.samlAcsUrl} />
                <CopyValue label="SP metadata" value={provider.samlMetadataUrl} />
              </div>
            )}
          </div>

          {provider.domainVerified && (
            <p className="text-[13px] text-muted-foreground">
              Teammates sign in at{" "}
              <a href={`${SITE_URL}/login`} className="text-foreground underline underline-offset-4">
                {SITE_URL.replace(/^https?:\/\//, "")}/login
              </a>{" "}
              with “Use single sign-on” and their @{provider.domain} address, or from the app’s
              sign-in screen. They join this team automatically.
            </p>
          )}
        </div>
      )}
    </div>
  );
}

function SsoCard({ orgId }: { orgId: string }) {
  const utils = trpc.useUtils();
  const { data, isLoading } = trpc.sso.overview.useQuery({ organizationId: orgId });
  const refresh = () => void utils.sso.overview.invalidate({ organizationId: orgId });

  const [kind, setKind] = useState<"oidc" | "saml">("oidc");
  const [adding, setAdding] = useState(false);
  const [domain, setDomain] = useState("");
  const [providerId, setProviderId] = useState("");
  const [issuer, setIssuer] = useState("");
  const [clientId, setClientId] = useState("");
  const [clientSecret, setClientSecret] = useState("");
  const [entryPoint, setEntryPoint] = useState("");
  const [cert, setCert] = useState("");

  const reset = () => {
    setAdding(false);
    setDomain("");
    setProviderId("");
    setIssuer("");
    setClientId("");
    setClientSecret("");
    setEntryPoint("");
    setCert("");
  };
  const onRegistered = () => {
    toast.success("Identity provider added — publish the TXT record, then verify");
    reset();
    refresh();
  };
  const registerOidc = trpc.sso.registerOidc.useMutation({ onSuccess: onRegistered, onError: (e) => toast.error(e.message) });
  const registerSaml = trpc.sso.registerSaml.useMutation({ onSuccess: onRegistered, onError: (e) => toast.error(e.message) });

  const suggestedId = providerId.trim() || domain.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  const busy = registerOidc.isPending || registerSaml.isPending;
  const canSubmit =
    !!domain.trim() &&
    !!issuer.trim() &&
    (kind === "oidc" ? !!clientId.trim() && !!clientSecret.trim() : !!entryPoint.trim() && cert.trim().length > 40);

  const submit = () => {
    if (kind === "oidc") {
      registerOidc.mutate({ organizationId: orgId, providerId: suggestedId, domain, issuer, clientId, clientSecret });
    } else {
      registerSaml.mutate({ organizationId: orgId, providerId: suggestedId, domain, issuer, entryPoint, cert, apiOrigin: API_URL });
    }
  };

  const providers = data?.providers ?? [];

  return (
    <Section
      icon={<KeyRound />}
      title="Single sign-on"
      badge={<PlanChip plan="business" />}
      description="Connect your identity provider — Okta, Microsoft Entra, Google Workspace, or any OIDC or SAML IdP. Teammates on your email domain sign in through it and join this team automatically."
      actions={
        data?.enabled && data.canManage && !adding ? (
          <Button size="sm" onClick={() => setAdding(true)}>
            Add provider
          </Button>
        ) : undefined
      }
    >
      {isLoading ? (
        <SkeletonLines lines={3} />
      ) : (
        <div className="space-y-4">
          {providers.length === 0 && !adding ? (
            <EmptyStage
              compact
              art={<SsoArt />}
              title="No identity provider connected yet."
              description="Once it’s connected, teammates on your email domain sign in with one press and join this team."
            />
          ) : (
            <div className="space-y-2">
              {providers.map((p) => (
                <ProviderRow key={p.providerId} orgId={orgId} provider={p} canManage={!!data?.canManage} onChanged={refresh} />
              ))}
            </div>
          )}

          {adding && data?.enabled && (
            <form
              className="dsh-rise space-y-4 rounded-[0.875rem] border border-white/8 bg-white/[0.025] p-4"
              onSubmit={(e) => {
                e.preventDefault();
                if (canSubmit && !busy) submit();
              }}
            >
              <div className="flex items-center gap-1 rounded-full border border-white/10 bg-white/[0.04] p-0.5 text-xs">
                {(["oidc", "saml"] as const).map((k) => (
                  <button
                    key={k}
                    type="button"
                    onClick={() => setKind(k)}
                    className={
                      "rounded-full px-3 py-1 font-medium uppercase tracking-[0.06em] transition-colors " +
                      (kind === k ? "bg-white text-black" : "text-muted-foreground hover:text-foreground")
                    }
                  >
                    {k}
                  </button>
                ))}
              </div>

              <div className="grid gap-4 md:grid-cols-2">
                <Field label="Email domain" hint="Teammates with this domain use SSO.">
                  <input className="studio-input" placeholder="acme.com" value={domain} onChange={(e) => setDomain(e.target.value)} />
                </Field>
                <Field label="Provider ID" hint={`Used in your redirect URI. Defaults to ${suggestedId || "the domain"}.`}>
                  <input className="studio-input" placeholder="acme-okta" value={providerId} onChange={(e) => setProviderId(e.target.value)} />
                </Field>
                <Field
                  label={kind === "oidc" ? "Issuer URL" : "Issuer / entity ID"}
                  hint={kind === "oidc" ? "We read /.well-known/openid-configuration from it." : "From the IdP’s SAML metadata."}
                  className="md:col-span-2"
                >
                  <input className="studio-input" placeholder={kind === "oidc" ? "https://acme.okta.com" : "https://sts.windows.net/…/"} value={issuer} onChange={(e) => setIssuer(e.target.value)} />
                </Field>
                {kind === "oidc" ? (
                  <>
                    <Field label="Client ID">
                      <input className="studio-input" value={clientId} onChange={(e) => setClientId(e.target.value)} />
                    </Field>
                    <Field label="Client secret" hint="Stored encrypted at rest by the API; never shown again.">
                      <input className="studio-input" type="password" value={clientSecret} onChange={(e) => setClientSecret(e.target.value)} />
                    </Field>
                  </>
                ) : (
                  <>
                    <Field label="Sign-on URL" hint="The IdP’s SAML 2.0 endpoint (HTTP-Redirect)." className="md:col-span-2">
                      <input className="studio-input" placeholder="https://login.microsoftonline.com/…/saml2" value={entryPoint} onChange={(e) => setEntryPoint(e.target.value)} />
                    </Field>
                    <Field label="Signing certificate (PEM)" className="md:col-span-2">
                      <textarea className="studio-input" rows={4} placeholder="-----BEGIN CERTIFICATE-----" value={cert} onChange={(e) => setCert(e.target.value)} />
                    </Field>
                  </>
                )}
              </div>

              <div className="flex items-center justify-end gap-2">
                <Button type="button" variant="ghost" size="sm" onClick={reset} disabled={busy}>
                  Cancel
                </Button>
                <Button type="submit" size="sm" disabled={!canSubmit || busy}>
                  {busy ? "Adding…" : "Add provider"}
                </Button>
              </div>
            </form>
          )}

          {data && !data.enabled && (
            <UpgradeNote plan="business">Single sign-on is part of Business.</UpgradeNote>
          )}
        </div>
      )}
    </Section>
  );
}
