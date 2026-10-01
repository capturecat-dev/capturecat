/**
 * DEV-ONLY: every signed-in dashboard page, rendered WITHOUT a session — for
 * screenshots and harnesses. The pages are the real components; the data is
 * canned (dashboardFixtures.ts answers every request in the page, nothing
 * reaches a server). The real pages live under the /app layout (auth).
 *
 *   ?page=library|record|projects|team|settings|billing|video|analytics
 *   &state=full|empty|loading   (default full; see dashboardFixtures.ts)
 *   &tier=paid|free  &team=owner|none  &uploads=0  &success=1 (billing)
 *   &playlist=pl-1   (library filtered to a playlist)
 *   &shell=0         content column only, no sidebar/header (as before);
 *                    with &theme=light for the light-theme chrome
 */
// FIRST: installs the fetch wrapper before any page module captures fetch.
import "./dashboardFixtures";

import type { ReactNode } from "react";
import { ThemeProvider } from "next-themes";

import { BillingPageBody, SettingsPageBody, TeamPageBody } from "@/components/dashboard/account-pages";
import { DashboardShell } from "@/components/dashboard/dashboard-shell";
import { EditorProjects } from "@/components/dashboard/editor-projects";
import { Recorder } from "@/components/dashboard/recorder";
import { RecorderDock, RecorderProvider } from "@/components/dashboard/recorder-bar";
import { VideoAnalytics } from "@/components/dashboard/video-analytics";
import { VideoDetails } from "@/components/dashboard/video-details";
import { VideoLibrary } from "@/components/dashboard/video-library";

const params = typeof window === "undefined" ? new URLSearchParams() : new URLSearchParams(window.location.search);

const VIDEO_ID = "lab-video-1";

function pageFor(page: string): { path: string; node: ReactNode } {
  switch (page) {
    case "library":
      return { path: "/app", node: <VideoLibrary playlistFilter={params.get("playlist") ?? undefined} /> };
    case "projects":
      return { path: "/app/projects", node: <EditorProjects /> };
    case "team":
      return { path: "/app/team", node: <TeamPageBody /> };
    case "settings":
      return { path: "/app/settings", node: <SettingsPageBody /> };
    case "billing":
      return { path: "/app/billing", node: <BillingPageBody success={params.get("success") === "1"} /> };
    case "video":
      return { path: `/app/videos/${VIDEO_ID}`, node: <VideoDetails videoId={VIDEO_ID} /> };
    case "analytics":
      return { path: `/app/videos/${VIDEO_ID}/analytics`, node: <VideoAnalytics videoId={VIDEO_ID} /> };
    default:
      return { path: "/app/record", node: <Recorder /> };
  }
}

export default function DashboardLab() {
  const { path, node } = pageFor(params.get("page") ?? "record");

  if (params.get("shell") !== "0") {
    return (
      <DashboardShell user={{ name: "Mike Garland", email: "mike@acme.test", avatar: "" }} pathname={path}>
        {node}
      </DashboardShell>
    );
  }

  const theme = params.get("theme") === "light" ? "light" : "dark";
  return (
    <ThemeProvider attribute="class" forcedTheme={theme} disableTransitionOnChange>
      <div className="relative isolate min-h-screen bg-background text-foreground">
        <div
          aria-hidden
          className="pointer-events-none absolute inset-0 -z-10"
          style={{
            background:
              "radial-gradient(90% 60% at 50% -10%, rgba(120,140,255,0.10), transparent 60%)," +
              "radial-gradient(60% 40% at 90% 20%, rgba(80,220,255,0.06), transparent 55%)",
          }}
        />
        <RecorderProvider>
          <div className="flex min-h-screen flex-col">
            {/* Stand-in for the dashboard header (h-14) so heights match /app. */}
            <div className="h-14 shrink-0 border-b border-white/8" />
            <div className="mx-auto w-full max-w-6xl flex-1 px-4 pb-6 pt-5 md:px-8 md:pt-7">{node}</div>
            <RecorderDock />
          </div>
        </RecorderProvider>
      </div>
    </ThemeProvider>
  );
}
