import { Outlet, createFileRoute, redirect, useRouterState, Link } from "@tanstack/react-router";
import { ThemeProvider } from "next-themes";

import { fetchSession } from "@/lib/session-fns";
import { AppSidebar } from "@/components/dashboard/app-sidebar";
import { HeaderUser } from "@/components/dashboard/header-user";
import { TooltipProvider } from "@/components/ui/tooltip";
import {
  Breadcrumb,
  BreadcrumbItem,
  BreadcrumbLink,
  BreadcrumbList,
  BreadcrumbPage,
  BreadcrumbSeparator,
} from "@/components/ui/breadcrumb";
import { Separator } from "@/components/ui/separator";
import {
  SidebarInset,
  SidebarProvider,
  SidebarTrigger,
} from "@/components/ui/sidebar";

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

const CRUMBS: Array<{ prefix: string; label: string }> = [
  { prefix: "/app/settings", label: "Settings" },
  { prefix: "/app/billing", label: "Billing" },
  { prefix: "/app/videos", label: "Video" },
];

function AppLayout() {
  const { session } = Route.useRouteContext();
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const crumb = CRUMBS.find((c) => pathname.startsWith(c.prefix));

  return (
    /* forcedTheme: the liquid-glass surfaces are dark-only (white-opacity
       borders and washes) — a light theme renders them invisible. */
    <ThemeProvider attribute="class" forcedTheme="dark" disableTransitionOnChange>
      {/* The vendored sidebar's tooltip'd menu buttons need a provider —
          this sidebar.tsx doesn't bundle its own. */}
      <TooltipProvider delayDuration={300}>
      <SidebarProvider>
        <AppSidebar
          user={{
            name: session.user.name ?? "User",
            email: session.user.email,
            avatar: session.user.image ?? "",
          }}
        />
        <SidebarInset className="relative isolate">
          {/* Ambient light — same glass language as the marketing site. */}
          <div
            aria-hidden
            className="pointer-events-none absolute inset-0 -z-10"
            style={{
              background:
                "radial-gradient(90% 60% at 50% -10%, rgba(120,140,255,0.10), transparent 60%)," +
                "radial-gradient(60% 40% at 90% 20%, rgba(80,220,255,0.06), transparent 55%)",
            }}
          />
          <header className="sticky top-0 z-40 flex h-14 shrink-0 items-center gap-2 border-b border-white/8 bg-background/60 backdrop-blur-2xl">
            <span
              aria-hidden
              className="absolute inset-x-12 bottom-0 h-px bg-gradient-to-r from-transparent via-white/15 to-transparent"
            />
            <div className="flex w-full items-center gap-2 px-4">
              <SidebarTrigger className="-ml-1" />
              <Separator
                orientation="vertical"
                className="mr-2 data-[orientation=vertical]:h-4"
              />
              <Breadcrumb>
                <BreadcrumbList>
                  <BreadcrumbItem>
                    {crumb ? (
                      <BreadcrumbLink asChild>
                        <Link to="/app">Library</Link>
                      </BreadcrumbLink>
                    ) : (
                      <BreadcrumbPage>Library</BreadcrumbPage>
                    )}
                  </BreadcrumbItem>
                  {crumb && (
                    <>
                      <BreadcrumbSeparator />
                      <BreadcrumbItem>
                        <BreadcrumbPage>{crumb.label}</BreadcrumbPage>
                      </BreadcrumbItem>
                    </>
                  )}
                </BreadcrumbList>
              </Breadcrumb>
              <div className="ml-auto">
                <HeaderUser
                  user={{
                    name: session.user.name ?? "User",
                    email: session.user.email,
                    avatar: session.user.image ?? "",
                  }}
                />
              </div>
            </div>
          </header>
          <div className="flex flex-1 flex-col gap-4 p-4 md:p-6">
            <Outlet />
          </div>
        </SidebarInset>
      </SidebarProvider>
      </TooltipProvider>
    </ThemeProvider>
  );
}
