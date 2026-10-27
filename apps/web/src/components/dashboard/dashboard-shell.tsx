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
 * The signed-in dashboard's frame: sidebar, header with breadcrumbs, one
 * content column, and the recording bar docked under every page. The
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
    /* The app's palette follows the system appearance through CSS
       (app-2026.css, `prefers-color-scheme` under [data-cc-app]) — the Mac's
       CCThemeMode.system. next-themes stays pinned to "dark" so <html> keeps
       the root layout's permanent `.dark` class across client navigations
       back to the (dark-only) marketing site. */
    <ThemeProvider attribute="class" forcedTheme="dark" disableTransitionOnChange>
      {/* The vendored sidebar's tooltip'd menu buttons need a provider —
          this sidebar.tsx doesn't bundle its own. */}
      <TooltipProvider delayDuration={300}>
      {/* data-cc-app: the app's 2026 tokens + material (app-2026.css) apply
          while this frame is mounted — portals included. */}
      <SidebarProvider data-cc-app="">
        <AppSidebar user={user} pathname={pathname} />
        <SidebarInset className="relative isolate">
          {/* The window is one airy plane (the Mac's 2026 look): panels float
              on it with hairlines and soft shadows — no ambient glows. */}
          <header className="sticky top-0 z-40 flex h-14 shrink-0 items-center gap-2 bg-background/85 backdrop-blur-xl">
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
