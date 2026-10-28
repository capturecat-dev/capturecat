import { useState } from "react";
import { Link } from "@tanstack/react-router";
import { toast } from "sonner";

import { trpc } from "@/lib/trpc/client";
import {
  approvalAction,
  minutesLeft,
  relativeTime,
  requesterName,
  type ApprovalDetail,
} from "@/lib/agent-access";
import { Button } from "@/components/ui/button";
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
import { PageHeader, Panel } from "@/components/dashboard/studio";
import { AppLogo } from "@/components/dashboard/agent-connections";
import { CCIcon } from "@/editor/ui/kit/ccIcon";
import { cn } from "@/lib/utils";

/**
 * /app/approvals/$id — where the account owner decides an agent's "ask me
 * first" request (apps/api/src/lib/agent-approvals.ts): who is asking (the
 * token's name, or the OAuth app), exactly what it wants to do, and which
 * video. Approve runs that one call once, if the agent repeats it within
 * 15 minutes with the same arguments; Deny is final. Session only — the
 * agent that asked can't reach this page's API.
 */
export function ApprovalPage({ id }: { id: string }) {
  const utils = trpc.useUtils();
  const { data, isLoading, error } = trpc.agentApprovals.get.useQuery({ id });
  const [busy, setBusy] = useState<"approve" | "deny" | null>(null);
  const decide = trpc.agentApprovals.decide.useMutation({
    onMutate: (v) => setBusy(v.decision),
    onSettled: () => setBusy(null),
    onSuccess: (result, v) => {
      utils.agentApprovals.get.setData({ id }, result);
      void utils.agentApprovals.pending.invalidate();
      toast.success(v.decision === "approve" ? "Approved — the agent can now do this once" : "Denied");
    },
    onError: (e) => {
      toast.error(e.message);
      void utils.agentApprovals.get.invalidate({ id });
    },
  });

  return (
    <div className="mx-auto max-w-2xl space-y-6">
      <PageHeader
        eyebrow="Agent access"
        title="An agent is asking first"
        description="Agents need your OK before they post where viewers see it or make a video viewable to more people."
      />
      {isLoading ? (
        <Skeleton className="h-72 w-full rounded-[1.25rem]" />
      ) : error || !data ? (
        <Panel>
          <p className="text-sm">This request doesn't exist, or it belongs to another account.</p>
          <Button asChild variant="outline" size="sm" className="mt-4">
            <Link to="/app/settings">Back to Settings</Link>
          </Button>
        </Panel>
      ) : (
        <ApprovalPanel
          approval={data.approval}
          busy={busy}
          onDecide={(decision) => decide.mutate({ id, decision })}
        />
      )}
    </div>
  );
}

function ApprovalPanel({
  approval: a,
  busy,
  onDecide,
}: {
  approval: ApprovalDetail;
  busy: "approve" | "deny" | null;
  onDecide: (decision: "approve" | "deny") => void;
}) {
  const who = requesterName(a);
  const pending = a.status === "pending";
  return (
    <Panel padding="p-0" className="overflow-hidden">
      {/* Who */}
      <div className="flex items-start gap-3 p-5">
        {a.requester.oauthClient ? (
          <AppLogo app={{ name: a.requester.oauthClient.name, logoUri: a.requester.oauthClient.logoUri }} className="size-10" />
        ) : (
          <span className="cc-well grid size-10 shrink-0 place-items-center rounded-[0.75rem]">
            <CCIcon name="terminal" className="size-5 text-muted-foreground" />
          </span>
        )}
        <div className="min-w-0">
          <p className="text-[15px] font-semibold">{who}</p>
          <p className="mt-0.5 text-xs text-muted-foreground">
            {a.requester.kind === "oauth" ? "Connected app" : "Agent token"}
            {a.requester.tokenPrefix && a.requester.kind === "personal" ? (
              <>
                {" "}
                <code className="text-[11px]">{a.requester.tokenPrefix}…</code>
              </>
            ) : null}
            {" · asked "}
            {relativeTime(a.createdAt)}
          </p>
        </div>
        <StatusPill status={a.status} expiresAt={a.expiresAt} />
      </div>

      {/* What */}
      <div className="border-t border-border p-5">
        <span className="studio-eyebrow block">Wants to</span>
        <p className="mt-1 text-sm font-medium">{approvalAction(a.tool)}</p>
        <p className="mt-1 text-sm text-muted-foreground">{a.summary}</p>
        {a.details.length > 0 && (
          <ul className="mt-3 space-y-1.5">
            {a.details.map((line) => (
              <li key={line} className="flex items-start gap-2 text-sm">
                <CCIcon name="chevron-right" size={14} className="mt-0.5 shrink-0 text-muted-foreground" />
                <span className="min-w-0 break-words">{line}</span>
              </li>
            ))}
          </ul>
        )}
      </div>

      {/* Which video */}
      {a.video && (
        <div className="flex min-w-0 items-center gap-3 border-t border-border p-5">
          <CCIcon name="film" className="size-4 shrink-0 text-muted-foreground" />
          <div className="min-w-0 flex-1">
            <p className="truncate text-sm font-medium">{a.video.title}</p>
            <p className="text-xs text-muted-foreground">Now {a.video.isPrivate ? "private" : "public"}</p>
          </div>
          {a.videoShareUrl && (
            <Button asChild variant="ghost" size="sm">
              <a href={a.videoShareUrl} target="_blank" rel="noreferrer">
                Open
                <CCIcon name="arrow-up-right" data-icon="inline-end" />
              </a>
            </Button>
          )}
        </div>
      )}

      {/* Decide */}
      <div className="flex flex-wrap items-center justify-end gap-2 border-t border-border p-5">
        {pending ? (
          <>
            <p className="mr-auto text-xs text-muted-foreground">
              Approving lets {who} do exactly this, once, within 15 minutes.
            </p>
            <Button variant="outline" disabled={busy !== null} onClick={() => onDecide("deny")}>
              {busy === "deny" ? <Spinner data-icon="inline-start" /> : <CCIcon name="close" data-icon="inline-start" />}
              Deny
            </Button>
            <AlertDialog>
              <AlertDialogTrigger asChild>
                <Button disabled={busy !== null}>
                  {busy === "approve" ? <Spinner data-icon="inline-start" /> : <CCIcon name="check" data-icon="inline-start" />}
                  Approve
                </Button>
              </AlertDialogTrigger>
              <AlertDialogContent>
                <AlertDialogHeader>
                  <AlertDialogTitle>Let {who} do this?</AlertDialogTitle>
                  <AlertDialogDescription>
                    {a.summary}. It runs once, only with exactly these details, and only if the agent asks again within 15
                    minutes.
                  </AlertDialogDescription>
                </AlertDialogHeader>
                <AlertDialogFooter>
                  <AlertDialogCancel>Not yet</AlertDialogCancel>
                  <AlertDialogAction onClick={() => onDecide("approve")}>Approve</AlertDialogAction>
                </AlertDialogFooter>
              </AlertDialogContent>
            </AlertDialog>
          </>
        ) : (
          <>
            <p className="mr-auto text-sm text-muted-foreground">{decidedText(a, who)}</p>
            <Button asChild variant="outline" size="sm">
              <Link to="/app/settings">Agent access</Link>
            </Button>
          </>
        )}
      </div>
    </Panel>
  );
}

function decidedText(a: ApprovalDetail, who: string): string {
  switch (a.status) {
    case "approved":
      return `Approved ${a.decidedAt ? relativeTime(a.decidedAt) : ""}. ${who} can do this once, ${minutesLeft(a.expiresAt)}.`;
    case "used":
      return `Approved and done ${a.usedAt ? relativeTime(a.usedAt) : ""}.`;
    case "denied":
      return `You denied this ${a.decidedAt ? relativeTime(a.decidedAt) : ""}.`;
    case "expired":
      return "This request expired. The agent can ask again.";
    default:
      return "";
  }
}

function StatusPill({ status, expiresAt }: { status: ApprovalDetail["status"]; expiresAt: string }) {
  const label = status === "pending" ? minutesLeft(expiresAt) : status;
  return (
    <span
      className={cn(
        "cc-well ml-auto inline-flex h-6 shrink-0 items-center gap-1.5 rounded-full px-2.5 text-[11px] font-medium",
        status === "pending" && "text-cc-amber-text",
        (status === "approved" || status === "used") && "text-cc-green-text",
        (status === "denied" || status === "expired") && "text-muted-foreground",
      )}
    >
      <span
        aria-hidden
        className={cn(
          "size-1.5 rounded-full",
          status === "pending" ? "bg-cc-amber" : status === "approved" || status === "used" ? "bg-cc-green" : "bg-muted-foreground/40",
        )}
      />
      {label}
    </span>
  );
}
