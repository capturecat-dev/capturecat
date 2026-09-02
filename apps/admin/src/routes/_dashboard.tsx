import {
  Outlet,
  createFileRoute,
  notFound,
  redirect,
} from "@tanstack/react-router";

import { fetchSession } from "@/lib/session-fns";
import { AdminSidebar } from "@/components/admin/admin-sidebar";
import {
  SidebarInset,
  SidebarProvider,
  SidebarTrigger,
} from "@/components/ui/sidebar";
import { Separator } from "@/components/ui/separator";
import { TooltipProvider } from "@/components/ui/tooltip";

/**
 * Pathless layout route — URLs stay /users, /beta, /plans, matching the Next
 * app's (dashboard) route group.
 *
 * Guards every child page. A signed-in non-admin gets 404, NOT a redirect:
 * the root of this app redirects to /users, so bouncing a signed-in non-admin
 * there produced an infinite / -> /users -> / loop that rate-limit self-DoSed
 * the API. 404 is also the same answer the API gives, which does not confirm
 * the admin surface exists to someone without the role.
 */
export const Route = createFileRoute("/_dashboard")({
  beforeLoad: async () => {
    const session = await fetchSession();
    if (!session) {
      throw redirect({ to: "/login" });
    }
    if (session.user.role !== "admin") {
      throw notFound();
    }
    return { session };
  },
  component: AdminLayout,
});

function AdminLayout() {
  return (
    <TooltipProvider>
      <SidebarProvider>
        <AdminSidebar />
        <SidebarInset>
          <header className="flex h-16 shrink-0 items-center gap-2 border-b px-4">
            <SidebarTrigger className="-ml-1" />
            <Separator orientation="vertical" className="mr-2 h-4" />
            <span className="text-sm font-medium">Admin</span>
          </header>
          <main className="flex-1 p-6">
            <Outlet />
          </main>
        </SidebarInset>
      </SidebarProvider>
    </TooltipProvider>
  );
}
