/**
 * /app/editor/$projectId — the web editor (app.capturecat.so/editor/<id>).
 * Not nested under the /app dashboard layout. Guarded like
 * src/routes/app/route.tsx; reuses the parent picker route's session when it
 * already resolved one, so a navigation costs one session read, not two.
 */
import { createFileRoute, redirect } from "@tanstack/react-router";

import { fetchSession } from "@/lib/session-fns";
import { webmcpOriginTrialMeta } from "@/editor/webmcp/originTrial";
import editorCss from "@/editor/ui/editor.css?url";
import { EditorPage } from "@/editor/ui/EditorPage";

export const Route = createFileRoute("/app_/editor/$projectId")({
  beforeLoad: async ({ location, context }) => {
    const inherited = (context as { session?: Awaited<ReturnType<typeof fetchSession>> }).session;
    const session = inherited ?? (await fetchSession());
    if (!session) {
      throw redirect({
        to: "/login",
        search: { next: location.pathname },
      });
    }
    return { session };
  },
  head: () => ({
    meta: [{ title: "Editor · CaptureCat" }, { name: "robots", content: "noindex" }, ...webmcpOriginTrialMeta()],
    links: [{ rel: "stylesheet", href: editorCss }],
  }),
  component: EditorRoute,
});

function EditorRoute() {
  const { projectId } = Route.useParams();
  return <EditorPage projectId={projectId} />;
}
