import { createFileRoute, notFound } from "@tanstack/react-router";
import { lazy, Suspense } from "react";

/**
 * DEV-ONLY render-engine lab. `import.meta.env.DEV` is statically `false` in
 * production builds, so the lab chunk (and the engine it pulls in) is
 * dead-code-eliminated and the route answers 404.
 */
const LabPage = import.meta.env.DEV ? lazy(() => import("@/editor/lab/LabPage")) : null;

export const Route = createFileRoute("/editor-lab")({
  ssr: false,
  beforeLoad: () => {
    if (!import.meta.env.DEV) throw notFound();
  },
  head: () => ({
    meta: [{ title: "Editor lab (dev)" }, { name: "robots", content: "noindex" }],
  }),
  component: EditorLab,
});

function EditorLab() {
  if (!LabPage) return null;
  return (
    <Suspense fallback={null}>
      <LabPage />
    </Suspense>
  );
}
