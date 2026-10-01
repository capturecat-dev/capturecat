import * as React from "react";
import { Link, useRouterState } from "@tanstack/react-router";
import {
  CircleDotIcon,
  CreditCardIcon,
  FolderOpenIcon,
  ListVideoIcon,
  SettingsIcon,
  UsersIcon,
  VideoIcon,
} from "lucide-react";

import CaptureCatMark from "@/components/brand/CaptureCatMark";
import { trpc } from "@/lib/trpc/client";
import { useGlide, usePill } from "@/components/dashboard/motion";

import {
  Sidebar,
  SidebarContent,

  SidebarGroup,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuBadge,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarRail,
} from "@/components/ui/sidebar";

const NAV_MAIN = [
  { title: "Library", url: "/app", icon: VideoIcon, exact: true },
  { title: "Record", url: "/app/record", icon: CircleDotIcon },
  { title: "Projects", url: "/app/projects", icon: FolderOpenIcon },
  { title: "Team", url: "/app/team", icon: UsersIcon },
  { title: "Settings", url: "/app/settings", icon: SettingsIcon },
  { title: "Billing", url: "/app/billing", icon: CreditCardIcon },
] as const;

/* The menu's own hover/active fills give way to the glide wash and the pill
   (one of each per menu, like the recording bar's keys). */
const BUTTON_QUIET =
  "relative bg-transparent hover:bg-transparent active:bg-white/[0.04] data-[active=true]:bg-transparent data-active:bg-transparent data-[active=true]:text-foreground transition-colors";

export function AppSidebar({
  user,
  pathname: pinnedPath,
  ...props
}: React.ComponentProps<typeof Sidebar> & {
  user: { name: string; email: string; avatar: string };
  /** Overrides the router's pathname (the DEV lab pins its page). */
  pathname?: string;
}) {
  const routerPath = useRouterState({ select: (s) => s.location.pathname });
  const pathname = pinnedPath ?? routerPath;
  const search = useRouterState({ select: (s) => s.location.search as { playlist?: string } });
  // Playlists live in the sidebar so collections feel first-class; selecting
  // one deep-links the library filtered to it.
  const playlists = trpc.videos.playlists.useQuery().data?.playlists ?? [];

  const activeNav =
    NAV_MAIN.find((item) =>
      "exact" in item && item.exact ? pathname === item.url : pathname.startsWith(item.url),
    )?.url ?? null;
  const activePlaylist = pathname === "/app" ? (search?.playlist ?? null) : null;

  const nav = usePill<HTMLDivElement>(activePlaylist ? null : activeNav);
  const navGlide = useGlide({ radius: "0.5rem" });
  const lists = usePill<HTMLDivElement>(activePlaylist, [playlists.length]);
  const listGlide = useGlide({ radius: "0.5rem" });

  return (
    <Sidebar
      collapsible="icon"
      className="border-r border-white/8 [&_[data-slot=sidebar-inner]]:bg-white/[0.03] [&_[data-slot=sidebar-inner]]:backdrop-blur-2xl"
      {...props}
    >
      <SidebarHeader>
        <SidebarMenu>
          <SidebarMenuItem>
            <SidebarMenuButton size="lg" asChild>
              <Link to="/app">
                <div className="flex aspect-square size-8 items-center justify-center overflow-hidden rounded-lg">
                  <CaptureCatMark size={32} />
                </div>
                <div className="grid flex-1 text-left text-sm leading-tight">
                  <span className="truncate font-semibold">CaptureCat</span>
                  <span className="truncate text-xs text-muted-foreground">
                    Dashboard
                  </span>
                </div>
              </Link>
            </SidebarMenuButton>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarHeader>

      <SidebarContent>
        <SidebarGroup>
          <div ref={nav.hostRef} className="relative" {...navGlide.handlers}>
            {nav.pillStyle && <span aria-hidden className="dsh-nav-pill" style={nav.pillStyle} />}
            {navGlide.wash}
            <SidebarMenu>
              {NAV_MAIN.map((item) => {
                const active = !activePlaylist && activeNav === item.url;
                return (
                  <SidebarMenuItem key={item.title} data-pill-key={item.url} data-glide>
                    <SidebarMenuButton asChild isActive={active} tooltip={item.title} className={BUTTON_QUIET}>
                      <Link to={item.url}>
                        <item.icon className={item.url === "/app/record" ? "text-red-400" : undefined} />
                        <span>{item.title}</span>
                      </Link>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                );
              })}
            </SidebarMenu>
          </div>
        </SidebarGroup>

        {playlists.length > 0 && (
          <SidebarGroup className="group-data-[collapsible=icon]:hidden">
            <SidebarGroupLabel>Playlists</SidebarGroupLabel>
            <div ref={lists.hostRef} className="relative" {...listGlide.handlers}>
              {lists.pillStyle && <span aria-hidden className="dsh-nav-pill" style={lists.pillStyle} />}
              {listGlide.wash}
              <SidebarMenu>
                {playlists.map((p) => (
                  <SidebarMenuItem key={p.playlistId} data-pill-key={p.playlistId} data-glide>
                    <SidebarMenuButton asChild isActive={activePlaylist === p.playlistId} className={BUTTON_QUIET}>
                      <Link to="/app" search={{ playlist: p.playlistId }}>
                        <span className="w-4 text-center">
                          {p.emoji || <ListVideoIcon className="size-4" />}
                        </span>
                        <span className="truncate">{p.name}</span>
                      </Link>
                    </SidebarMenuButton>
                    <SidebarMenuBadge className="tabular-nums">{p.videoIds.length}</SidebarMenuBadge>
                  </SidebarMenuItem>
                ))}
              </SidebarMenu>
            </div>
          </SidebarGroup>
        )}
      </SidebarContent>

      <SidebarRail />
    </Sidebar>
  );
}
