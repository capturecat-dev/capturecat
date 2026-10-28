import { Link } from "@tanstack/react-router";
import { toast } from "sonner";

import { trpc } from "@/lib/trpc/client";
import {
  SCOPE_INFO,
  approvalAction,
  isWriteScope,
  minutesLeft,
  relativeTime,
  requesterName,
  type AgentScope,
  type ApprovalDetail,
  type ConnectedApp,
} from "@/lib/agent-access";
import { Button } from "@/components/ui/button";
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
import { Row } from "@/components/dashboard/studio";
import { CCIcon } from "@/editor/ui/kit/ccIcon";
import { cn } from "@/lib/utils";

/**
 * Two groups of the Agent access section (agent-access-card.tsx):
 *
 *   Pending approvals "ask me first" requests from agents (post a comment,
 *                     make a video more visible) — each opens its approval
 *                     page (/app/approvals/$id), where the owner decides.
 *   Connected apps    OAuth clients ("Sign in with CaptureCat": Claude.ai,
 *                     ChatGPT…), grouped by app, each with Revoke.
 */

export function PendingApprovals({ approvals }: { approvals: ApprovalDetail[] }) {
  if (approvals.length === 0) return null;
  return (
    <div className="space-y-2">
      <span className="studio-eyebrow flex items-center gap-1.5">
        <span aria-hidden className="size-1.5 rounded-full bg-cc-amber" />
        Pending approvals
      </span>
      {approvals.map((a, i) => (
        <Row key={a.id} index={i} className="dsh-rise items-start">
          <div className="flex min-w-0 items-start gap-2.5">
            <CCIcon name={a.tool === "post_comment" ? "text-bubble" : "eye"} className="mt-0.5 size-4 shrink-0 text-cc-amber-text" />
            <div className="min-w-0">
              <p className="text-sm font-medium">
                {requesterName(a)} asks: {approvalAction(a.tool).toLowerCase()}
              </p>
              <p className="mt-0.5 line-clamp-2 text-xs text-muted-foreground">{a.summary}</p>
              <p className="mt-1 text-xs text-muted-foreground">
                {relativeTime(a.createdAt)} · {minutesLeft(a.expiresAt)}
              </p>
            </div>
          </div>
          <Button asChild size="sm" className="shrink-0">
            <Link to="/app/approvals/$id" params={{ id: a.id }}>
              Review
            </Link>
          </Button>
        </Row>
      ))}
    </div>
  );
}

export function ConnectedApps({ apps }: { apps: ConnectedApp[] }) {
  const utils = trpc.useUtils();
  const revoke = trpc.oauth.revokeApp.useMutation({
    onSuccess: () => {
      void utils.oauth.apps.invalidate();
      void utils.agentTokens.audit.invalidate();
      toast.success("Disconnected — the app loses access on its next request");
    },
    onError: (error) => toast.error(error.message),
  });
  if (apps.length === 0) return null;
  return (
    <div className="space-y-2">
      <span className="studio-eyebrow block">Connected apps</span>
      {apps.map((app, i) => (
        <AppRow
          key={app.clientId}
          app={app}
          index={i}
          revoking={revoke.isPending && revoke.variables?.clientId === app.clientId}
          onRevoke={() => revoke.mutate({ clientId: app.clientId })}
        />
      ))}
    </div>
  );
}

export function AppLogo({ app, className }: { app: Pick<ConnectedApp, "logoUri" | "name">; className?: string }) {
  return app.logoUri ? (
    <img
      src={app.logoUri}
      alt=""
      referrerPolicy="no-referrer"
      className={cn("size-8 shrink-0 rounded-[0.625rem] bg-white object-contain", className)}
    />
  ) : (
    <span
      aria-hidden
      className={cn(
        "cc-well grid size-8 shrink-0 place-items-center rounded-[0.625rem] text-sm font-semibold text-foreground/80",
        className,
      )}
    >
      {app.name.slice(0, 1).toUpperCase()}
    </span>
  );
}

function AppRow({ app, index, revoking, onRevoke }: { app: ConnectedApp; index: number; revoking: boolean; onRevoke: () => void }) {
  return (
    <Row className="dsh-rise items-start" index={index}>
      <div className="flex min-w-0 items-start gap-2.5">
        <AppLogo app={app} />
        <div className="min-w-0">
          <div className="flex min-w-0 flex-wrap items-center gap-2">
            <span className="truncate text-sm font-medium">{app.name}</span>
            {app.verifiedHost ? (
              <span className="inline-flex items-center gap-1 text-[11px] text-muted-foreground">
                <CCIcon name="seal-check" size={12} className="text-cc-green-text" />
                {app.verifiedHost}
              </span>
            ) : (
              <span className="text-[11px] text-muted-foreground">registered app</span>
            )}
          </div>
          <div className="mt-1 flex flex-wrap gap-1">
            {app.scopes.map((scope) => (
              <span
                key={scope}
                title={SCOPE_INFO[scope as AgentScope]?.description}
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
            Connected {relativeTime(app.connectedAt)} · {app.lastUsedAt ? `last used ${relativeTime(app.lastUsedAt)}` : "not used yet"}
            {app.connections > 1 ? ` · ${app.connections} sign-ins` : ""}
          </p>
        </div>
      </div>
      <AlertDialog>
        <AlertDialogTrigger asChild>
          <Button variant="ghost" size="sm" className="shrink-0 text-destructive hover:text-destructive" disabled={revoking}>
            {revoking ? <Spinner data-icon="inline-start" /> : <CCIcon name="close" data-icon="inline-start" />}
            Revoke
          </Button>
        </AlertDialogTrigger>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Disconnect {app.name}?</AlertDialogTitle>
            <AlertDialogDescription>
              {app.name} loses access to your CaptureCat account on its next request. To use it again, connect it again
              and sign in with CaptureCat.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Keep it</AlertDialogCancel>
            <AlertDialogAction variant="destructive" onClick={onRevoke}>
              Disconnect
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </Row>
  );
}
