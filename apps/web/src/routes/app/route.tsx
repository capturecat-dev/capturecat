import { Outlet, createFileRoute, redirect } from "@tanstack/react-router";

import { fetchSession } from "@/lib/session-fns";
import { DashboardShell } from "@/components/dashboard/dashboard-shell";

export const Route = createFileRoute("/app")({
  beforeLoad: async ({ location }) => {
    const session = await fetchSession();
    if (!session) {
      throw redirect({
        to: "/login",
        search: { next: location.pathname },
      });
    }
    return { session };
  },
  component: AppLayout,
});

/** The frame (sidebar, header, recording bar) lives in DashboardShell so the
 *  DEV lab can render the same chrome without a session. */
function AppLayout() {
  const { session } = Route.useRouteContext();
  return (
    <DashboardShell
      user={{
        name: session.user.name ?? "User",
        email: session.user.email,
        avatar: session.user.image ?? "",
      }}
    >
      <Outlet />
    </DashboardShell>
  );
}
