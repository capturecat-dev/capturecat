/**
 * DEV-ONLY code-based routes for the editor labs.
 *
 * Why not a file route: every file under src/routes lands in routeTree.gen.ts
 * and therefore in the production route tree + manifest, even when its body
 * is gated. These routes are attached at runtime by src/router.tsx inside an
 * `import.meta.env.DEV` branch; in a production build that branch is dead
 * code, this module has no top-level side effects, and the bundler drops it
 * (and the lazily imported lab + fixtures) entirely — verify with
 * `grep -r "editor-lab" apps/web/dist` → no hits.
 *
 *   /editor-lab/shell   the editor shell + fixtures (see ShellLab.tsx for params)
 *   /editor-lab/open    the REAL editor page, no login (this Mac's projects)
 *   /editor-lab/dashboard  the dashboard's Record / Projects pages, no login
 *   /editor-lab/share-test bare getDisplayMedia probes (browser capability checks)
 *
 * It is a SIBLING of the engine's file route /editor-lab (a leaf), not a
 * child — both resolve independently (verified with both present).
 */
import { createRoute, lazyRouteComponent, type AnyRoute } from "@tanstack/react-router";

import editorCss from "@/editor/ui/editor.css?url";

const SHELL_PATH = "/editor-lab/shell";
const OPEN_PATH = "/editor-lab/open";
const DASHBOARD_PATH = "/editor-lab/dashboard";

export function withEditorLabRoutes<T extends AnyRoute>(tree: T): T {
  const existing = (tree.children ?? []) as AnyRoute[] | Record<string, AnyRoute>;
  const children = Array.isArray(existing) ? existing : Object.values(existing);
  // getRouter() runs per request on the server, and an HMR re-evaluation of
  // routeTree.gen.ts resets the root's children IN PLACE — so check the
  // current children rather than remembering which trees were patched.
  if (children.some((c) => (c.options as { path?: string } | undefined)?.path === SHELL_PATH)) return tree;
  const shell = createRoute({
    getParentRoute: () => tree,
    path: SHELL_PATH,
    ssr: false,
    head: () => ({
      meta: [{ title: "Editor lab · shell" }, { name: "robots", content: "noindex" }],
      links: [{ rel: "stylesheet", href: editorCss }],
    }),
    component: lazyRouteComponent(() => import("./ShellLab")),
  });
  const open = createRoute({
    getParentRoute: () => tree,
    path: OPEN_PATH,
    ssr: false,
    head: () => ({
      meta: [{ title: "Editor lab · open project" }, { name: "robots", content: "noindex" }],
      links: [{ rel: "stylesheet", href: editorCss }],
    }),
    component: lazyRouteComponent(() => import("./OpenProjectLab")),
  });
  const dashboard = createRoute({
    getParentRoute: () => tree,
    path: DASHBOARD_PATH,
    ssr: false,
    head: () => ({ meta: [{ title: "Editor lab · dashboard pages" }, { name: "robots", content: "noindex" }] }),
    component: lazyRouteComponent(() => import("./DashboardLab")),
  });
  const shareTest = createRoute({
    getParentRoute: () => tree,
    path: "/editor-lab/share-test",
    ssr: false,
    head: () => ({ meta: [{ title: "Editor lab · share test" }, { name: "robots", content: "noindex" }] }),
    component: lazyRouteComponent(() => import("./ShareTestLab")),
  });
  tree.addChildren([...children, shell, open, dashboard, shareTest]);
  return tree;
}
