import { createRouter } from "@tanstack/react-router";

import { routeTree } from "./routeTree.gen";

/** Dashboard hosts where the internal /app prefix must never show in URLs —
 *  app.capturecat.so/billing IS /app/billing. */
function isAppHost(host: string): boolean {
  return host === "app.capturecat.so" || host.startsWith("app.localhost");
}

export function getRouter() {
  return createRouter({
    routeTree,
    // On the app subdomain the /app route prefix is an internal detail:
    // input maps the clean visible URL onto the internal /app routes, output
    // strips the prefix back off every href the router generates — so links,
    // pushes, and redirects all render without the double "app".
    rewrite: {
      input: ({ url }) => {
        if (!isAppHost(url.host)) return undefined;
        if (
          url.pathname.startsWith("/app") ||
          url.pathname.startsWith("/api/") ||
          url.pathname.startsWith("/login")
        ) {
          return undefined;
        }
        const next = new URL(url);
        next.pathname = url.pathname === "/" ? "/app" : `/app${url.pathname}`;
        return next;
      },
      output: ({ url }) => {
        if (!isAppHost(url.host)) return undefined;
        if (url.pathname === "/app" || url.pathname.startsWith("/app/")) {
          const next = new URL(url);
          next.pathname = url.pathname.slice("/app".length) || "/";
          return next;
        }
        return undefined;
      },
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
