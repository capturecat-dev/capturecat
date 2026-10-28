import { createRouter } from "@tanstack/react-router";

import { routeTree } from "./routeTree.gen";
import { withEditorLabRoutes } from "./editor/lab/labRoutes";
import { appHostInput, appHostOutput } from "./lib/app-host-rewrite";

export function getRouter() {
  return createRouter({
    // DEV-only editor labs are code routes attached here (never in prod
    // bundles: the branch is dead code and the lab module is dropped).
    routeTree: import.meta.env.DEV ? withEditorLabRoutes(routeTree) : routeTree,
    // On the app subdomain the /app route prefix is an internal detail:
    // input maps the clean visible URL onto the internal /app routes, output
    // strips the prefix back off every href the router generates — so links,
    // pushes, and redirects all render without the double "app".
    rewrite: {
      input: ({ url }) => appHostInput(url),
      output: ({ url }) => appHostOutput(url),
    },
    defaultPreload: "intent",
    scrollRestoration: true,
    defaultNotFoundComponent: () => (
      <div className="flex min-h-[60vh] flex-col items-center justify-center gap-2 text-center">
        <p className="text-5xl font-semibold tracking-tight">404</p>
        <p className="text-muted-foreground">This page doesn&rsquo;t exist.</p>
      </div>
    ),
  });
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof getRouter>;
  }
}
