import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import {
  Copy,
  KeyRound,
  Trash2,
  UserPlus,
  Users,
  Video,
} from "lucide-react";

import { authClient } from "@/lib/auth-client";
import { API_URL, SITE_URL } from "@/lib/api-url";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { TeamAvatar } from "@/components/dashboard/team-avatar";
import { TeamSkeleton, SkeletonLines } from "@/components/dashboard/page-skeletons";
import { useRef } from "react";

/**
 * Teams — backed entirely by the Better Auth organization plugin on the API
 * (no tRPC layer: the auth client already speaks these endpoints, credentialed
 * and CSRF-checked server-side).
 *
 * Invitations are LINK-based: the server deliberately sends no email, so the
 * pending list surfaces a copyable accept URL instead. SSO registration is
 * entitlement-gated server-side (features.sso); this card renders for org
 * owners/admins and lets the API refuse.
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
    <div className="rounded-lg border p-4">
      <div className="flex items-center gap-2">
        <Users className="h-4 w-4" />
        <h2 className="text-sm font-medium">Create your team</h2>
      </div>
      <p className="mt-1 text-sm text-muted-foreground">
        A shared library for your company’s recordings — invite teammates,
        collect every share in one place, and (on Business) bring your own
        SSO.
      </p>
      <div className="mt-3 flex gap-2">
        <Input
          placeholder="Team name, e.g. Acme Inc"
          value={name}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && void create()}
        />
        <Button onClick={() => void create()} disabled={busy || !name.trim()}>
          Create team
        </Button>
      </div>
    </div>
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

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const myRole =
    full?.members.find((m) => m.user.id === session?.user.id)?.role ?? "member";
  const canManage = myRole === "owner" || myRole === "admin";

  return (
    <div className="space-y-6">
      <MembersCard
        orgId={orgId}
        orgName={orgName}
        full={full}
        canManage={canManage}
        refresh={refresh}
      />
      <TeamLibraryCard orgId={orgId} />
      {canManage && <SsoCard orgId={orgId} />}
    </div>
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
    void navigator.clipboard.writeText(
      `${SITE_URL}/accept-invitation/${invitationId}`
    );
    toast.success("Invite link copied");
  };

  const pending = (full?.invitations ?? []).filter((i) => i.status === "pending");

  return (
    <div className="rounded-lg border p-4">
      <div className="flex items-center gap-3">
        <TeamAvatar name={orgName} logo={full?.logo} size={40} />
        <div className="min-w-0 flex-1">
          <h2 className="text-sm font-medium">{orgName}</h2>
          <p className="text-xs text-muted-foreground">
            {full?.members.length ?? "…"} member{full?.members.length === 1 ? "" : "s"}
          </p>
        </div>
        {canManage && <LogoUploadButton orgId={orgId} onUploaded={refresh} />}
      </div>

      <div className="mt-3 space-y-2">
        {(full?.members ?? []).map((m) => (
          <div
            key={m.id}
            className="flex items-center justify-between gap-3 rounded-md border px-3 py-2"
          >
            <div className="min-w-0">
              <span className="truncate text-sm">{m.user.name || m.user.email}</span>
              <span className="ml-2 text-xs text-muted-foreground">{m.user.email}</span>
            </div>
            <div className="flex items-center gap-2">
              <Badge variant={m.role === "owner" ? "default" : "secondary"} className="text-[10px]">
                {m.role}
              </Badge>
              {canManage && m.role !== "owner" && (
                <Button
                  variant="ghost"
                  size="icon"
                  className="h-7 w-7"
                  title="Remove from team"
                  onClick={async () => {
                    const { error } = await authClient.organization.removeMember({
                      memberIdOrEmail: m.user.email,
                      organizationId: orgId,
                    });
                    if (error) toast.error(error.message ?? "Remove failed");
                    else await refresh();
                  }}
                >
                  <Trash2 className="h-3.5 w-3.5" />
                </Button>
              )}
            </div>
          </div>
        ))}

        {pending.map((i) => (
          <div
            key={i.id}
            className="flex items-center justify-between gap-3 rounded-md border border-dashed px-3 py-2"
          >
            <div className="min-w-0">
              <span className="truncate text-sm">{i.email}</span>
              <Badge variant="outline" className="ml-2 text-[10px]">invited</Badge>
            </div>
            {canManage && (
              <div className="flex items-center gap-1">
                <Button
                  variant="ghost"
                  size="sm"
                  className="h-7 gap-1 text-xs"
                  onClick={() => copyInviteLink(i.id)}
                >
                  <Copy className="h-3 w-3" /> Copy link
                </Button>
                <Button
                  variant="ghost"
                  size="icon"
                  className="h-7 w-7"
                  title="Cancel invitation"
                  onClick={async () => {
                    await authClient.organization.cancelInvitation({ invitationId: i.id });
                    await refresh();
                  }}
                >
                  <Trash2 className="h-3.5 w-3.5" />
                </Button>
              </div>
            )}
          </div>
        ))}
      </div>

      {canManage && (
        <div className="mt-3 flex gap-2">
          <Input
            placeholder="teammate@company.com"
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && void invite()}
          />
          <Button onClick={() => void invite()} disabled={busy || !email.trim()}>
            <UserPlus className="mr-1 h-4 w-4" /> Invite
          </Button>
        </div>
      )}
    </div>
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

function TeamLibraryCard({ orgId }: { orgId: string }) {
  const [videos, setVideos] = useState<
    Array<{ videoId: string; fileName: string; createdAt: string; url: string }>
  >([]);
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

  return (
    <div className="rounded-lg border p-4">
      <div className="flex items-center gap-2">
        <Video className="h-4 w-4" />
        <h2 className="text-sm font-medium">Team library</h2>
      </div>
      <p className="mt-1 text-sm text-muted-foreground">
        Videos teammates shared to the team. Add yours from a video’s share
        settings.
      </p>
      <div className="mt-3 space-y-2">
        {!loaded && <SkeletonLines lines={2} />}
        {loaded && videos.length === 0 && (
          <p className="text-sm text-muted-foreground">Nothing here yet.</p>
        )}
        {videos.map((v) => (
          <a
            key={v.videoId}
            href={v.url}
            target="_blank"
            rel="noreferrer"
            className="flex items-center justify-between gap-3 rounded-md border px-3 py-2 hover:bg-muted/40"
          >
            <span className="truncate text-sm">{v.fileName}</span>
            <span className="text-xs text-muted-foreground">
              {new Date(v.createdAt).toLocaleDateString()}
            </span>
          </a>
        ))}
      </div>
    </div>
  );
}

function SsoCard({ orgId }: { orgId: string }) {
  const [providerId, setProviderId] = useState("");
  const [domain, setDomain] = useState("");
  const [issuer, setIssuer] = useState("");
  const [clientId, setClientId] = useState("");
  const [clientSecret, setClientSecret] = useState("");
  const [busy, setBusy] = useState(false);

  const register = async () => {
    setBusy(true);
    const { error } = await authClient.sso.register({
      providerId: providerId.trim() || domain.trim().replace(/\W+/g, "-"),
      issuer: issuer.trim(),
      domain: domain.trim().toLowerCase(),
      organizationId: orgId,
      oidcConfig: {
        clientId: clientId.trim(),
        clientSecret: clientSecret.trim(),
        issuer: issuer.trim(),
        discoveryEndpoint: `${issuer.trim().replace(/\/$/, "")}/.well-known/openid-configuration`,
      },
    } as Parameters<typeof authClient.sso.register>[0]);
    setBusy(false);
    if (error) toast.error(error.message ?? "SSO registration failed");
    else {
      toast.success("Identity provider registered — test with an @" + domain + " account");
      setProviderId(""); setDomain(""); setIssuer(""); setClientId(""); setClientSecret("");
    }
  };

  return (
    <div className="rounded-lg border p-4">
      <div className="flex items-center gap-2">
        <KeyRound className="h-4 w-4" />
        <h2 className="text-sm font-medium">Single sign-on</h2>
        <Badge variant="secondary" className="text-[10px]">BUSINESS</Badge>
      </div>
      <p className="mt-1 text-sm text-muted-foreground">
        Connect your identity provider (Okta, Entra, Google Workspace — any
        OIDC IdP). Teammates on your email domain sign in through it and join
        this team automatically.
      </p>
      <div className="mt-3 grid gap-2 sm:grid-cols-2">
        <Input placeholder="Email domain, e.g. acme.com" value={domain} onChange={(e) => setDomain(e.target.value)} />
        <Input placeholder="Issuer URL, e.g. https://acme.okta.com" value={issuer} onChange={(e) => setIssuer(e.target.value)} />
        <Input placeholder="OIDC client ID" value={clientId} onChange={(e) => setClientId(e.target.value)} />
        <Input placeholder="OIDC client secret" type="password" value={clientSecret} onChange={(e) => setClientSecret(e.target.value)} />
        <Input placeholder="Provider ID (optional, e.g. acme-okta)" value={providerId} onChange={(e) => setProviderId(e.target.value)} className="sm:col-span-2" />
      </div>
      <Button
        className="mt-3"
        onClick={() => void register()}
        disabled={busy || !domain.trim() || !issuer.trim() || !clientId.trim() || !clientSecret.trim()}
      >
        Register provider
      </Button>
    </div>
  );
}
