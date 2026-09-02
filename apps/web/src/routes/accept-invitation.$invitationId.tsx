import { createFileRoute, redirect, useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { fetchSession } from "@/lib/session-fns";
import { authClient } from "@/lib/auth-client";
import { API_URL } from "@/lib/api-url";
import { Button } from "@/components/ui/button";
import { TeamAvatar } from "@/components/dashboard/team-avatar";

/** Team invite landing. Invites are link-based (no email sender), so this is
 *  the whole acceptance flow: sign in first if needed, see WHO you're
 *  joining (name, logo, inviter), then one click. */
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

type InvitationInfo = {
  organizationId: string;
  organizationName: string;
  inviterEmail?: string | null;
  email: string;
  status: string;
};

function AcceptInvitationPage() {
  const { invitationId } = Route.useParams();
  const navigate = useNavigate();
  const [busy, setBusy] = useState(false);
  const [info, setInfo] = useState<InvitationInfo | null>(null);
  const [invalid, setInvalid] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const { data, error } = await authClient.organization.getInvitation({
        query: { id: invitationId },
      });
      if (cancelled) return;
      if (error || !data) {
        setInvalid(
          error?.message ??
            "This invitation is invalid, expired, or was sent to a different email address."
        );
      } else {
        setInfo(data as unknown as InvitationInfo);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [invitationId]);

  const accept = async () => {
    setBusy(true);
    const { error } = await authClient.organization.acceptInvitation({ invitationId });
    setBusy(false);
    if (error) toast.error(error.message ?? "This invitation is no longer valid");
    else {
      toast.success(`Welcome to ${info?.organizationName ?? "the team"}!`);
      void navigate({ to: "/app/team" });
    }
  };

  return (
    <main className="flex min-h-svh items-center justify-center p-6">
      <div className="w-full max-w-sm rounded-lg border p-6 text-center">
        {invalid ? (
          <>
            <h1 className="text-lg font-semibold">Invitation not found</h1>
            <p className="mt-1 text-sm text-muted-foreground">{invalid}</p>
            <Button variant="outline" className="mt-4 w-full" onClick={() => void navigate({ to: "/app" })}>
              Go to your library
            </Button>
          </>
        ) : !info ? (
          <p className="text-sm text-muted-foreground">Loading invitation…</p>
        ) : (
          <>
            <div className="flex justify-center">
              <TeamAvatar
                name={info.organizationName}
                logo={`${API_URL}/api/org/${info.organizationId}/logo`}
                size={56}
              />
            </div>
            <h1 className="mt-3 text-lg font-semibold">
              Join {info.organizationName}?
            </h1>
            <p className="mt-1 text-sm text-muted-foreground">
              {info.inviterEmail ? (
                <>
                  <span className="text-foreground">{info.inviterEmail}</span> invited
                  you to their team’s shared CaptureCat library.
                </>
              ) : (
                "You’ve been invited to this team’s shared CaptureCat library."
              )}
            </p>
            <Button className="mt-4 w-full" onClick={() => void accept()} disabled={busy}>
              {busy ? "Joining…" : `Join ${info.organizationName}`}
            </Button>
            <p className="mt-2 text-xs text-muted-foreground">
              Invitation for {info.email}
            </p>
          </>
        )}
      </div>
    </main>
  );
}
