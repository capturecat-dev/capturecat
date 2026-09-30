/**
 * DEV-ONLY: the dashboard pages the web editor adds (Record, Projects),
 * rendered in the dashboard's content column WITHOUT a session — for
 * screenshots/harnesses. `?page=record|projects`. The real pages live under
 * the /app layout (sidebar + auth).
 */
import { ThemeProvider } from "next-themes";

import { EditorProjects } from "@/components/dashboard/editor-projects";
import { Recorder } from "@/components/dashboard/recorder";
import { RecorderDock, RecorderProvider } from "@/components/dashboard/recorder-bar";

export default function DashboardLab() {
  const page = typeof window === "undefined" ? "record" : (new URLSearchParams(window.location.search).get("page") ?? "record");
  return (
    <ThemeProvider attribute="class" forcedTheme="dark" disableTransitionOnChange>
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
            <div className="mx-auto w-full max-w-6xl flex-1 px-4 pb-6 pt-5 md:px-8 md:pt-7">
              {page === "projects" ? <EditorProjects /> : <Recorder />}
            </div>
            <RecorderDock />
          </div>
        </RecorderProvider>
      </div>
    </ThemeProvider>
  );
}
