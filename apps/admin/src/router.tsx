import { createRouter } from "@tanstack/react-router";

import { routeTree } from "./routeTree.gen";

export function getRouter() {
  return createRouter({
    routeTree,
    defaultPreload: "intent",
    scrollRestoration: true,
    defaultNotFoundComponent: () => (
      <div className="flex min-h-[60vh] flex-col items-center justify-center gap-2 text-center">
        <p className="text-5xl font-semibold tracking-tight">404</p>
        <p className="text-muted-foreground">This page doesn&rsquo;t exist.</p>
      </div>
    ),
    // A render error used to unmount the whole document (a blank white page).
    // Show what broke instead, inside the dashboard frame.
    defaultErrorComponent: ({ error, reset }) => (
      <div className="flex min-h-[60vh] flex-col items-center justify-center gap-3 px-6 text-center">
        <p className="text-lg font-semibold">This page hit an error</p>
        <pre className="max-w-2xl whitespace-pre-wrap rounded-md bg-muted px-4 py-3 text-left text-xs text-muted-foreground">
          {error instanceof Error ? `${error.name}: ${error.message}` : String(error)}
        </pre>
        <button type="button" className="text-sm underline" onClick={() => { reset(); window.location.reload(); }}>
          Reload
        </button>
      </div>
    ),
  });
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof getRouter>;
  }
}
