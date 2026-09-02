import { createFileRoute, redirect, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { toast } from "sonner";

import { fetchSession } from "@/lib/session-fns";
import { authClient } from "@/lib/auth-client";
import { Button } from "@/components/ui/button";

/** Team invite landing. Invites are link-based (no email sender), so this is
 *  the whole acceptance flow: sign in first if needed, then one click. */
export const Route = createFileRoute("/accept-invitation/$invitationId")({
  beforeLoad: async ({ params, location }) => {
    const session = await fetchSession();
    if (!session) {
      throw redirect({ to: "/login", search: { next: location.pathname } });
    }
    return { invitationId: params.invitationId };
  },
  component: AcceptInvitationPage,
  head: () => ({ meta: [{ title: "Join team — CaptureCat" }] }),
});

function AcceptInvitationPage() {
  const { invitationId } = Route.useParams();
  const navigate = useNavigate();
  const [busy, setBusy] = useState(false);

  const accept = async () => {
    setBusy(true);
    const { error } = await authClient.organization.acceptInvitation({ invitationId });
    setBusy(false);
    if (error) toast.error(error.message ?? "This invitation is no longer valid");
    else {
      toast.success("Welcome to the team!");
      void navigate({ to: "/app/team" });
    }
  };

  return (
    <main className="flex min-h-svh items-center justify-center p-6">
      <div className="w-full max-w-sm rounded-lg border p-6 text-center">
        <h1 className="text-lg font-semibold">Join the team?</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          You’ve been invited to a CaptureCat team — a shared library for your
          company’s recordings.
        </p>
        <Button className="mt-4 w-full" onClick={() => void accept()} disabled={busy}>
          {busy ? "Joining…" : "Accept invitation"}
        </Button>
      </div>
    </main>
  );
}
