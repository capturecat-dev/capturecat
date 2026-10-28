import { useState, type CSSProperties } from "react";
import { toast } from "sonner";

import { trpc } from "@/lib/trpc/client";
import {
  CONNECTOR_URL,
  DEFAULT_SCOPES,
  EXPIRY_OPTIONS,
  MCP_ENDPOINT,
  SCOPE_GROUPS,
  SCOPE_INFO,
  claudeMcpAddCommand,
  describeExpiry,
  isWriteScope,
  mcpJsonConfig,
  relativeTime,
  sortTokens,
  tokenStatus,
  type AgentScope,
  type AgentTokenSummary,
} from "@/lib/agent-access";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import { Spinner } from "@/components/ui/spinner";
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
import { EmptyStage, Field, Row, Section } from "@/components/dashboard/studio";
import { PlanUnavailableNote } from "@/components/dashboard/plan-unavailable-note";
import { ConnectedApps, PendingApprovals } from "@/components/dashboard/agent-connections";
import { CCIcon } from "@/editor/ui/kit/ccIcon";
import { cn } from "@/lib/utils";

/**
 * Agent access: scoped, revocable tokens for cloud agents (a Claude.ai
 * connector, Claude Code over HTTP, ChatGPT, a scheduled agent) calling the
 * remote MCP server at mcp.capturecat.so/mcp. One Section in Settings' single
 * surface: create (name, scopes, expiry) → the token shown ONCE with ready
 * snippets → the list with revoke → recent agent activity from the audit log.
 * Above the tokens: requests waiting for the owner's approval ("ask me
 * first"); below them: apps connected with OAuth ("Sign in with
 * CaptureCat"). A plan without `agentAccess` shows the upgrade state instead
 * of a form the API would refuse. Every rule (scopes, caps, hashing, plan
 * gates) is the API's; this only asks.
 */
export function AgentAccessCard() {
  const utils = trpc.useUtils();
  const { data, isLoading } = trpc.agentTokens.list.useQuery();
  const audit = trpc.agentTokens.audit.useQuery();
  const approvals = trpc.agentApprovals.pending.useQuery(undefined, { refetchInterval: 30_000 });
  const apps = trpc.oauth.apps.useQuery();
  const [creating, setCreating] = useState(false);
  // The plaintext token lives only here, only until "Done".
  const [created, setCreated] = useState<{ token: string; name: string } | null>(null);

  const create = trpc.agentTokens.create.useMutation({
    onSuccess: (result) => {
      setCreated({ token: result.token, name: result.name });
      setCreating(false);
      void utils.agentTokens.list.invalidate();
    },
    onError: (error) => toast.error(error.message),
  });
  const revoke = trpc.agentTokens.revoke.useMutation({
    onSuccess: () => {
      void utils.agentTokens.list.invalidate();
      toast.success("Token revoked — it stops working on its next request");
    },
    onError: (error) => toast.error(error.message),
  });

  const tokens = sortTokens(data?.tokens ?? []);
  const activeCount = tokens.filter((t) => tokenStatus(t) === "active").length;
  const atLimit = data ? activeCount >= data.maxActive : false;
  const entries = audit.data?.entries ?? [];
  // The plan gate (lib/agent-features.ts on the API): off → upgrade state.
  const unavailable = data?.features ? !data.features.agentAccess : false;

  return (
    <Section
      icon={<CCIcon name="terminal" />}
      title="Agent access"
      description={
        <>
          Let a cloud agent (Claude, ChatGPT, a scheduled job) read your videos and act on them through CaptureCat's MCP
          server at <code className="text-xs text-foreground/80">{MCP_ENDPOINT.replace("https://", "")}</code>. Each token
          gets only the scopes you pick, never more than your plan allows, and can be revoked at any time. Agents ask you
          first before they post a comment or make a video more visible.
        </>
      }
      actions={
        !unavailable && !creating && !created && tokens.length > 0 ? (
          <Button size="sm" variant="outline" disabled={atLimit} onClick={() => setCreating(true)}>
            <CCIcon name="plus" data-icon="inline-start" />
            New token
          </Button>
        ) : null
      }
    >
      <div className="space-y-3">
        <PendingApprovals approvals={approvals.data?.approvals ?? []} />

        {unavailable ? (
          <PlanUnavailableNote>
            Agent access isn't part of your {data?.plan?.displayName ?? "current"} plan, so agents and connected apps
            can't reach your account. Existing tokens stay listed so you can revoke them.
          </PlanUnavailableNote>
        ) : (
          <ConnectorHint />
        )}

        {created && <NewTokenReveal token={created.token} name={created.name} onDone={() => setCreated(null)} />}

        {creating && (
          <CreateTokenForm
            pending={create.isPending}
            onCancel={() => setCreating(false)}
            onSubmit={(input) => create.mutate(input)}
          />
        )}

        {isLoading ? (
          <div className="space-y-2">
            <Skeleton className="h-[62px] w-full rounded-[0.875rem]" />
            <Skeleton className="h-[62px] w-full rounded-[0.875rem]" />
          </div>
        ) : tokens.length === 0 ? (
          !unavailable &&
          !creating &&
          !created && (
            <EmptyStage
              compact
              art={<AgentArt />}
              title="No agent tokens yet"
              description="Create one, paste the command into your agent, and ask it about your videos, comments and views."
              actions={
                <Button size="sm" onClick={() => setCreating(true)}>
                  <CCIcon name="plus" data-icon="inline-start" />
                  Create a token
                </Button>
              }
            />
          )
        ) : (
          <div className="space-y-2">
            {tokens.map((t, i) => (
              <TokenRow
                key={t.id}
                token={t}
                index={i}
                revoking={revoke.isPending && revoke.variables?.id === t.id}
                onRevoke={() => revoke.mutate({ id: t.id })}
              />
            ))}
            {atLimit && (
              <p className="text-xs text-muted-foreground">
                You have {data?.maxActive} active tokens, the most allowed. Revoke one to create another.
              </p>
            )}
          </div>
        )}

        <ConnectedApps apps={apps.data?.apps ?? []} />

        {entries.length > 0 && <RecentActivity entries={entries.slice(0, 8)} />}
      </div>
    </Section>
  );
}

/** Claude.ai / ChatGPT custom connectors need no token: just the URL, then
 *  they sign in with CaptureCat (OAuth) and appear under Connected apps. */
function ConnectorHint() {
  return (
    <div className="cc-well flex min-w-0 flex-wrap items-center gap-x-3 gap-y-2 rounded-[0.875rem] px-3 py-2.5">
      <CCIcon name="link" className="size-4 shrink-0 text-muted-foreground" />
      <p className="min-w-0 flex-1 text-xs text-muted-foreground">
        <span className="font-medium text-foreground">Claude.ai or ChatGPT?</span> Add a custom connector with this URL —
        it signs in with CaptureCat, no token needed.
      </p>
      <CopyBlock label="Connector URL" value={CONNECTOR_URL} inline />
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* Create                                                              */
/* ------------------------------------------------------------------ */

function CreateTokenForm({
  pending,
  onCancel,
  onSubmit,
}: {
  pending: boolean;
  onCancel: () => void;
  onSubmit: (input: { name: string; scopes: AgentScope[]; expiresInDays: number | null }) => void;
}) {
  const [name, setName] = useState("");
  const [scopes, setScopes] = useState<AgentScope[]>(DEFAULT_SCOPES);
  const [expiresInDays, setExpiresInDays] = useState<number | null>(90);

  const toggle = (scope: AgentScope) =>
    setScopes((current) => (current.includes(scope) ? current.filter((s) => s !== scope) : [...current, scope]));
  const ready = name.trim().length > 0 && scopes.length > 0;

  return (
    <form
      className="studio-well dsh-rise space-y-4 p-4"
      onSubmit={(e) => {
        e.preventDefault();
        if (ready) onSubmit({ name: name.trim(), scopes, expiresInDays });
      }}
    >
      <Field label="Name" hint="So you can tell tokens apart, e.g. “Claude Code on my laptop”.">
        <input
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Claude"
          maxLength={60}
          className="studio-input w-full"
          autoFocus
          autoComplete="off"
        />
      </Field>

      <div className="space-y-2">
        <span className="studio-eyebrow block">What it can do</span>
        <div className="space-y-3">
          {SCOPE_GROUPS.map((group) => (
            <div key={group.title} className="grid gap-2 sm:grid-cols-2">
              {group.scopes.map((scope) => (
                <ScopeCheckbox key={scope} scope={scope} checked={scopes.includes(scope)} onToggle={() => toggle(scope)} />
              ))}
            </div>
          ))}
        </div>
        <p className="text-xs text-muted-foreground">
          There are no delete or billing scopes. Plan limits apply exactly as they do for you.
        </p>
      </div>

      <div className="space-y-2">
        <span className="studio-eyebrow block">Expires</span>
        <div role="radiogroup" aria-label="Expires" className="cc-well inline-flex flex-wrap gap-0.5 rounded-full p-0.5">
          {EXPIRY_OPTIONS.map((option) => {
            const on = expiresInDays === option.days;
            return (
              <button
                key={option.label}
                type="button"
                role="radio"
                aria-checked={on}
                onClick={() => setExpiresInDays(option.days)}
                className={cn(
                  "h-7 rounded-full px-3 text-[13px] transition-[color,background-color,box-shadow] duration-200",
                  on ? "cc-chip-on" : "text-muted-foreground hover:text-foreground",
                )}
              >
                {option.label}
              </button>
            );
          })}
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <Button type="submit" disabled={!ready || pending}>
          {pending ? (
            <>
              <Spinner data-icon="inline-start" />
              Creating…
            </>
          ) : (
            "Create token"
          )}
        </Button>
        <Button type="button" variant="ghost" onClick={onCancel} disabled={pending}>
          Cancel
        </Button>
        {scopes.length === 0 && <span className="text-xs text-muted-foreground">Pick at least one scope.</span>}
      </div>
    </form>
  );
}

export function ScopeCheckbox({ scope, checked, onToggle }: { scope: AgentScope; checked: boolean; onToggle: () => void }) {
  const info = SCOPE_INFO[scope];
  return (
    <button
      type="button"
      role="checkbox"
      aria-checked={checked}
      onClick={onToggle}
      className={cn(
        "flex min-w-0 items-start gap-2.5 rounded-[0.875rem] px-3 py-2.5 text-left transition-[color,background-color,box-shadow] duration-200",
        checked ? "cc-chip-on" : "cc-well text-muted-foreground hover:text-foreground",
      )}
    >
      <span
        aria-hidden
        className={cn(
          "mt-0.5 grid size-4 shrink-0 place-items-center rounded-[5px] transition-colors duration-200",
          checked ? "bg-primary text-primary-foreground" : "cc-float-chip",
        )}
      >
        {checked && <CCIcon name="check" size={12} weight="semibold" />}
      </span>
      <span className="min-w-0">
        <span className="flex items-center gap-1.5 text-sm font-medium text-foreground">
          {info.label}
          <code className="text-[10.5px] font-normal text-muted-foreground">{scope}</code>
        </span>
        <span className="mt-0.5 block text-xs leading-snug text-muted-foreground">{info.description}</span>
      </span>
    </button>
  );
}

/* ------------------------------------------------------------------ */
/* Shown once                                                          */
/* ------------------------------------------------------------------ */

function NewTokenReveal({ token, name, onDone }: { token: string; name: string; onDone: () => void }) {
  return (
    <div className="studio-well dsh-rise space-y-4 p-4">
      <div className="flex items-start gap-2.5">
        <CCIcon name="seal-check" className="mt-0.5 size-4 shrink-0 text-cc-green-text" />
        <div className="min-w-0">
          <p className="text-sm font-medium">“{name}” is ready</p>
          <p className="mt-0.5 text-xs text-muted-foreground">
            Copy it now: this is the only time the token is shown. CaptureCat keeps only a hash of it.
          </p>
        </div>
      </div>

      <CopyBlock label="Token" value={token} />
      <CopyBlock label="Claude Code" value={claudeMcpAddCommand(token)} />
      <CopyBlock label="Other MCP clients (JSON config)" value={mcpJsonConfig(token)} multiline />

      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-xs text-muted-foreground">
          Endpoint <code className="text-foreground/80">{MCP_ENDPOINT}</code>, sent as{" "}
          <code className="text-foreground/80">Authorization: Bearer</code>.
        </p>
        <Button size="sm" onClick={onDone}>
          Done
        </Button>
      </div>
    </div>
  );
}

export function CopyBlock({
  label,
  value,
  multiline = false,
  inline = false,
}: {
  label: string;
  value: string;
  multiline?: boolean;
  /** Just the value and its copy button, no label row. */
  inline?: boolean;
}) {
  const copy = () => {
    void navigator.clipboard.writeText(value).then(
      () => toast.success(`${label} copied`),
      () => toast.error("Could not copy — select the text and copy it instead"),
    );
  };
  if (inline) {
    return (
      <div className="flex min-w-0 items-center gap-1.5">
        <code className="truncate text-xs text-foreground/85" title={value}>
          {value}
        </code>
        <Button variant="outline" size="icon-sm" aria-label={`Copy ${label}`} onClick={copy}>
          <CCIcon name="clipboard" />
        </Button>
      </div>
    );
  }
  return (
    <div className="min-w-0">
      <span className="studio-eyebrow block">{label}</span>
      <div className="mt-1 flex min-w-0 items-start gap-2">
        {multiline ? (
          <pre className="cc-well min-w-0 flex-1 overflow-x-auto rounded-[0.75rem] px-3 py-2 text-[11.5px] leading-relaxed text-foreground/85">
            {value}
          </pre>
        ) : (
          <code className="cc-well block min-w-0 flex-1 truncate rounded-[0.75rem] px-3 py-2 text-xs" title={value}>
            {value}
          </code>
        )}
        <Button variant="outline" size="icon-sm" aria-label={`Copy ${label}`} onClick={copy}>
          <CCIcon name="clipboard" />
        </Button>
      </div>
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* List                                                                */
/* ------------------------------------------------------------------ */

function TokenRow({
  token,
  index,
  revoking,
  onRevoke,
}: {
  token: AgentTokenSummary;
  index: number;
  revoking: boolean;
  onRevoke: () => void;
}) {
  const status = tokenStatus(token);
  const active = status === "active";
  return (
    <Row className={cn("dsh-rise items-start", !active && "opacity-60")} index={index}>
      <div className="flex min-w-0 items-start gap-2.5">
        <span
          aria-hidden
          className={cn("mt-1.5 size-1.5 shrink-0 rounded-full", active ? "bg-cc-green" : "bg-muted-foreground/40")}
        />
        <div className="min-w-0">
          <div className="flex min-w-0 flex-wrap items-center gap-2">
            <span className="truncate text-sm font-medium">{token.name}</span>
            <code className="text-[11px] text-muted-foreground">{token.prefix}…</code>
            {!active && (
              <Badge variant="outline" className="text-[10px]">
                {status}
              </Badge>
            )}
          </div>
          <div className="mt-1 flex flex-wrap gap-1">
            {token.scopes.map((scope) => (
              <span
                key={scope}
                className={cn(
                  "cc-well inline-flex h-5 items-center rounded-full px-2 font-mono text-[10.5px]",
                  isWriteScope(scope as AgentScope) ? "text-foreground/85" : "text-muted-foreground",
                )}
              >
                {scope}
              </span>
            ))}
          </div>
          <p className="mt-1 text-xs text-muted-foreground">
            Created {relativeTime(token.createdAt)} · {token.lastUsedAt ? `last used ${relativeTime(token.lastUsedAt)}` : "never used"}
            {" · "}
            {status === "revoked" && token.revokedAt ? `revoked ${relativeTime(token.revokedAt)}` : describeExpiry(token.expiresAt)}
          </p>
        </div>
      </div>
      {active && (
        <AlertDialog>
          <AlertDialogTrigger asChild>
            <Button variant="ghost" size="sm" className="shrink-0 text-destructive hover:text-destructive" disabled={revoking}>
              {revoking ? <Spinner data-icon="inline-start" /> : <CCIcon name="close" data-icon="inline-start" />}
              Revoke
            </Button>
          </AlertDialogTrigger>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>Revoke “{token.name}”?</AlertDialogTitle>
              <AlertDialogDescription>
                Any agent using {token.prefix}… loses access on its next request. This can't be undone; create a new
                token if you need one again.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Keep it</AlertDialogCancel>
              <AlertDialogAction variant="destructive" onClick={onRevoke}>
                Revoke
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      )}
    </Row>
  );
}

/* ------------------------------------------------------------------ */
/* Audit                                                               */
/* ------------------------------------------------------------------ */

function RecentActivity({
  entries,
}: {
  entries: Array<{ id: string; tool: string; tokenName: string | null; videoId: string | null; ok: boolean; error: string | null; at: string }>;
}) {
  return (
    <div className="pt-2">
      <span className="studio-eyebrow block">Recent agent activity</span>
      <ul className="mt-2 divide-y divide-border">
        {entries.map((e, i) => (
          <li
            key={e.id}
            className="dsh-rise flex min-w-0 items-start gap-2.5 py-2 first:pt-0 last:pb-0"
            style={{ "--i": i } as CSSProperties}
          >
            <span
              aria-hidden
              className={cn("mt-1.5 size-1.5 shrink-0 rounded-full", e.ok ? "bg-cc-green" : "bg-cc-amber")}
            />
            <div className="min-w-0 flex-1">
              <div className="flex min-w-0 flex-wrap items-baseline gap-x-2 text-[13px]">
                <code className="text-foreground/90">{e.tool}</code>
                {e.videoId && <span className="truncate text-xs text-muted-foreground">{e.videoId}</span>}
                <span className="text-xs text-muted-foreground">
                  {e.tokenName ?? "deleted token"} · {relativeTime(e.at)}
                </span>
              </div>
              {!e.ok && e.error && <p className="mt-0.5 truncate text-xs text-cc-amber-text">{e.error}</p>}
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}

/** Empty-state art: a tiny terminal where an agent calls two tools. */
function AgentArt() {
  return (
    <div aria-hidden className="cc-well overflow-hidden rounded-[0.875rem] p-3 font-mono text-[10.5px] leading-relaxed">
      <div className="mb-2 flex gap-1">
        <i className="size-1.5 rounded-full bg-foreground/20" />
        <i className="size-1.5 rounded-full bg-foreground/20" />
        <i className="size-1.5 rounded-full bg-foreground/20" />
      </div>
      <div className="truncate text-muted-foreground">› what did viewers say this week?</div>
      <div className="truncate">
        <span className="text-cc-green-text">●</span> list_comments <span className="text-muted-foreground">12 threads</span>
      </div>
      <div className="truncate">
        <span className="text-cc-green-text">●</span> post_comment <span className="text-muted-foreground">via agent</span>
      </div>
    </div>
  );
}
