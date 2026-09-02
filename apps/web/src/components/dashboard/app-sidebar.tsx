import * as React from "react";
import { Link, useRouterState } from "@tanstack/react-router";
import {
  CreditCardIcon,
  ListVideoIcon,
  SettingsIcon,
  VideoIcon,
} from "lucide-react";

import CaptureCatMark from "@/components/brand/CaptureCatMark";
import { trpc } from "@/lib/trpc/client";

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
  { title: "Settings", url: "/app/settings", icon: SettingsIcon },
  { title: "Billing", url: "/app/billing", icon: CreditCardIcon },
] as const;

export function AppSidebar({
  user,
  ...props
}: React.ComponentProps<typeof Sidebar> & {
  user: { name: string; email: string; avatar: string };
}) {
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  // Playlists live in the sidebar so collections feel first-class; selecting
  // one deep-links the library filtered to it.
  const playlists = trpc.videos.playlists.useQuery().data?.playlists ?? [];

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
          <SidebarMenu>
            {NAV_MAIN.map((item) => {
              const active =
                "exact" in item && item.exact
                  ? pathname === item.url
                  : pathname.startsWith(item.url);
              return (
                <SidebarMenuItem key={item.title}>
                  <SidebarMenuButton asChild isActive={active} tooltip={item.title}>
                    <Link to={item.url}>
                      <item.icon />
                      <span>{item.title}</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>
              );
            })}
          </SidebarMenu>
        </SidebarGroup>

        {playlists.length > 0 && (
          <SidebarGroup className="group-data-[collapsible=icon]:hidden">
            <SidebarGroupLabel>Playlists</SidebarGroupLabel>
            <SidebarMenu>
              {playlists.map((p) => (
                <SidebarMenuItem key={p.playlistId}>
                  <SidebarMenuButton asChild>
                    <Link to="/app" search={{ playlist: p.playlistId }}>
                      <span className="w-4 text-center">
                        {p.emoji || <ListVideoIcon className="size-4" />}
                      </span>
                      <span className="truncate">{p.name}</span>
                    </Link>
                  </SidebarMenuButton>
                  <SidebarMenuBadge>{p.videoIds.length}</SidebarMenuBadge>
                </SidebarMenuItem>
              ))}
            </SidebarMenu>
          </SidebarGroup>
        )}
      </SidebarContent>

      <SidebarRail />
    </Sidebar>
  );
}
