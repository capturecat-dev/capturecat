/**
 * /app/editor/<UUID> — the full-screen web editor's parent route
 * (app.capturecat.so/editor/<UUID>; the app-host rewrite maps clean URLs onto
 * /app/*). `app_` = NOT nested under the dashboard sidebar layout: the editor
 * is a whole window, like the Mac's. Guarded exactly like routes/app/route.tsx.
 * The project list is a dashboard page (/app/projects); /editor alone
 * redirects there.
 */
import { Outlet, createFileRoute, redirect } from "@tanstack/react-router";

import { fetchSession } from "@/lib/session-fns";
import { webmcpOriginTrialMeta } from "@/editor/webmcp/originTrial";
import editorCss from "@/editor/ui/editor.css?url";

export const Route = createFileRoute("/app_/editor")({
  beforeLoad: async ({ location }) => {
    const session = await fetchSession();
    if (!session) {
      throw redirect({
        to: "/login",
        search: { next: location.pathname },
      });
    }
    // The project list lives in the dashboard (/app/projects); /editor alone
    // is an old bookmark — only /editor/<UUID> opens the full-screen editor.
    if (location.pathname.replace(/\/+$/, "") === "/app/editor") throw redirect({ to: "/app/projects" });
    return { session };
  },
  head: () => ({
    meta: [{ title: "Editor · CaptureCat" }, { name: "robots", content: "noindex" }, ...webmcpOriginTrialMeta()],
    links: [{ rel: "stylesheet", href: editorCss }],
  }),
  component: Outlet,
});
