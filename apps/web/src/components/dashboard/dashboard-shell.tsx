import type { ReactNode } from "react";
import { Link, useRouterState } from "@tanstack/react-router";
import { ThemeProvider } from "next-themes";

import { AppSidebar } from "@/components/dashboard/app-sidebar";
import { RecorderDock, RecorderProvider } from "@/components/dashboard/recorder-bar";
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

/** Ordered most-specific first: the analytics prefix must win over the
 *  video prefix it extends. */
const CRUMBS: Array<{ prefix: string; label: string }> = [
  { prefix: "/app/record", label: "Record" },
  { prefix: "/app/projects", label: "Projects" },
  { prefix: "/app/settings", label: "Settings" },
  { prefix: "/app/billing", label: "Billing" },
  { prefix: "/app/team", label: "Team" },
  { prefix: "/app/videos", label: "Video" },
];

export type ShellUser = { name: string; email: string; avatar: string };

/**
 * The signed-in dashboard's frame: sidebar, glass header with breadcrumbs,
 * one content column, and the recording bar docked under every page. The
 * /app route renders it around its <Outlet />; the DEV lab renders it around
 * a page with `pathname` pinned, so screenshots show the real chrome.
 */
export function DashboardShell({
  user,
  children,
  pathname: pinnedPath,
}: {
  user: ShellUser;
  children: ReactNode;
  /** Overrides the router's pathname (the DEV lab pins the page it shows). */
  pathname?: string;
}) {
  const routerPath = useRouterState({ select: (s) => s.location.pathname });
  const pathname = pinnedPath ?? routerPath;
  const crumb = CRUMBS.find((c) => pathname.startsWith(c.prefix));
  const isAnalytics = /^\/app\/videos\/[^/]+\/analytics/.test(pathname);

  return (
    /* forcedTheme: the liquid-glass surfaces are dark-only (white-opacity
       borders and washes) — a light theme renders them invisible. */
    <ThemeProvider attribute="class" forcedTheme="dark" disableTransitionOnChange>
      {/* The vendored sidebar's tooltip'd menu buttons need a provider —
          this sidebar.tsx doesn't bundle its own. */}
      <TooltipProvider delayDuration={300}>
      <SidebarProvider>
        <AppSidebar user={user} pathname={pathname} />
        <SidebarInset className="relative isolate">
          {/* Ambient light — same glass language as the marketing site; two
              soft glows drift very slowly behind the glass (static under
              reduced motion). */}
          <div aria-hidden className="dsh-ambient">
            <i />
            <i />
          </div>
          <div
            aria-hidden
            className="pointer-events-none absolute inset-0 -z-10"
            style={{
              background:
                "radial-gradient(90% 60% at 50% -10%, rgba(120,140,255,0.07), transparent 60%)," +
                "radial-gradient(60% 40% at 90% 20%, rgba(80,220,255,0.04), transparent 55%)",
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
                  {isAnalytics && (
                    <>
                      <BreadcrumbSeparator />
                      <BreadcrumbItem>
                        <BreadcrumbPage>Analytics</BreadcrumbPage>
                      </BreadcrumbItem>
                    </>
                  )}
                </BreadcrumbList>
              </Breadcrumb>
              <div className="ml-auto">
                <HeaderUser user={user} />
              </div>
            </div>
          </header>
          {/* One content width for every page so panels line up as you
              move between them. The recording bar (the Mac recording panel)
              docks at the bottom of every page — the recorder lives here, so
              a take keeps running while you browse. */}
          <RecorderProvider>
            <div className="flex flex-1 flex-col">
              <div className="mx-auto w-full max-w-6xl flex-1 px-4 pb-6 pt-5 md:px-8 md:pt-7">
                {children}
              </div>
              <RecorderDock />
            </div>
          </RecorderProvider>
        </SidebarInset>
      </SidebarProvider>
      </TooltipProvider>
    </ThemeProvider>
  );
}
