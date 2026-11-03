import { createFileRoute, redirect } from "@tanstack/react-router";
import { z } from "zod";

import { fetchSession } from "@/lib/session-fns";
import { MacConnectPage } from "@/components/oauth/mac-connect-page";

/**
 * "Sign in to CaptureCat for Mac" — the consent page the API sends the
 * browser to when the Mac app's Sign In starts (apps/api/src/routes/
 * desktop.ts, /desktop/authorize). Signed out → /login, then back here;
 * signed in → who is asking, what it may do, Allow / Cancel. The API owns
 * the request (rid) and re-checks it on every call — nothing here is trusted.
 */
const searchSchema = z.object({ rid: z.string().uuid().optional().catch(undefined) });

export const Route = createFileRoute("/connect/mac")({
  validateSearch: searchSchema,
  beforeLoad: async ({ location }) => {
    const session = await fetchSession();
    if (!session) {
      // Back here, rid and all, after signing in.
      throw redirect({ to: "/login", search: { next: location.href } });
    }
    return { session };
  },
  component: ConnectMacRoute,
  head: () => ({
    meta: [
      { title: "Sign in to CaptureCat for Mac" },
      { name: "robots", content: "noindex" },
    ],
  }),
});

function ConnectMacRoute() {
  const { rid } = Route.useSearch();
  const { session } = Route.useRouteContext();
  if (!rid) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-background px-4 text-center text-sm text-muted-foreground">
        Start signing in from CaptureCat for Mac.
      </main>
    );
  }
  return <MacConnectPage rid={rid} email={session.user.email} name={session.user.name ?? null} />;
}
