import { useState } from "react";
import { Link, useNavigate } from "@tanstack/react-router";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { trpc } from "@/lib/trpc/client";
import { authClient } from "@/lib/auth-client";
import {
  confirmationMatches,
  DELETE_ACCOUNT_BODY,
  DELETE_ACCOUNT_TITLE,
  DELETE_CONFIRMATION_WORD,
  DELETED_TOAST,
  NETWORK_FAILURE_MESSAGE,
  type DeleteAccountOutcome,
} from "@/lib/account-deletion";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
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
import { Section } from "@/components/dashboard/studio";
import { CCIcon } from "@/editor/ui/kit/ccIcon";

type Failure = Exclude<DeleteAccountOutcome, { kind: "deleted" }>;

/**
 * Settings → Delete account. The last section of the settings surface: the
 * copy, a destructive button, and an AlertDialog that arms only once the user
 * types DELETE. The API (DELETE /api/me, relayed by trpc.account.delete)
 * cancels any subscription first and refuses — deleting nothing — when that
 * fails or when the user owns a team that still has other members.
 */
export function DeleteAccountSection() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [open, setOpen] = useState(false);
  const [typed, setTyped] = useState("");
  const [failure, setFailure] = useState<Failure | null>(null);

  async function finishSignedOut() {
    // The API already deleted every session, so Better Auth's sign-out may
    // answer an error; it still clears the cookie when it can. Never block on it.
    await authClient.signOut().catch(() => {});
    queryClient.clear();
    toast.success(DELETED_TOAST);
    void navigate({ to: "/", replace: true });
  }

  const remove = trpc.account.delete.useMutation({
    onSuccess: (outcome) => {
      if (outcome.kind === "deleted") {
        setOpen(false);
        void finishSignedOut();
        return;
      }
      setFailure(outcome);
    },
    onError: (error) => {
      // No session any more: a retry after a lost response, or deleted
      // elsewhere — the account is gone either way.
      if (error.data?.code === "UNAUTHORIZED") {
        setOpen(false);
        void finishSignedOut();
        return;
      }
      setFailure({
        kind: "error",
        message: error.data ? error.message : NETWORK_FAILURE_MESSAGE,
      });
    },
  });

  const armed = confirmationMatches(typed) && !remove.isPending;

  return (
    <Section
      icon={<CCIcon name="trash" />}
      title={DELETE_ACCOUNT_TITLE}
      description={DELETE_ACCOUNT_BODY}
    >
      <AlertDialog
        open={open}
        onOpenChange={(next) => {
          if (remove.isPending) return;
          setOpen(next);
          if (!next) {
            setTyped("");
            setFailure(null);
          }
        }}
      >
        <AlertDialogTrigger asChild>
          <Button variant="destructive" size="sm">
            <CCIcon name="trash" data-icon="inline-start" />
            Delete account…
          </Button>
        </AlertDialogTrigger>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete your CaptureCat account?</AlertDialogTitle>
            <AlertDialogDescription>{DELETE_ACCOUNT_BODY}</AlertDialogDescription>
          </AlertDialogHeader>

          <label className="block space-y-1.5">
            <span className="text-xs text-muted-foreground">
              Type <span className="font-mono font-semibold text-foreground">{DELETE_CONFIRMATION_WORD}</span> to
              confirm.
            </span>
            <Input
              value={typed}
              onChange={(e) => {
                setTyped(e.target.value);
                setFailure(null);
              }}
              onKeyDown={(e) => {
                if (e.key === "Enter" && armed) {
                  e.preventDefault();
                  remove.mutate();
                }
              }}
              autoComplete="off"
              autoCapitalize="characters"
              spellCheck={false}
              disabled={remove.isPending}
              aria-label={`Type ${DELETE_CONFIRMATION_WORD} to confirm`}
              placeholder={DELETE_CONFIRMATION_WORD}
            />
          </label>

          {failure && <FailureNote failure={failure} onTeamLink={() => setOpen(false)} />}

          <AlertDialogFooter>
            <AlertDialogCancel disabled={remove.isPending}>Keep my account</AlertDialogCancel>
            <AlertDialogAction
              variant="destructive"
              disabled={!armed}
              onClick={(e) => {
                // Stay open while the request runs, and to show a refusal.
                e.preventDefault();
                if (armed) remove.mutate();
              }}
            >
              {remove.isPending && <Spinner className="size-3.5" />}
              {remove.isPending ? "Deleting…" : "Delete account"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </Section>
  );
}

function FailureNote({ failure, onTeamLink }: { failure: Failure; onTeamLink: () => void }) {
  return (
    <div role="alert" className="flex items-start gap-2 text-xs text-destructive">
      <CCIcon name="warning-fill" className="mt-px size-3.5 shrink-0" />
      <span>
        {failure.message}
        {failure.kind === "team" && (
          <>
            {" "}
            <Link to="/app/team" className="underline underline-offset-2" onClick={onTeamLink}>
              Open the Team page
            </Link>
          </>
        )}
      </span>
    </div>
  );
}
