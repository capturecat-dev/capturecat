/**
 * Custom server entry. Reproduces the routing work the Next app did in
 * next.config.ts + middleware.ts, which TanStack Start has no config file for:
 *
 *  - app.capturecat.so/*        → served from /app/*
 *  - legacy paths               → 307 to their /app/* homes
 *  - Pro custom share domains   → /:videoId → /share/:videoId, /e/:id → /embed/:id,
 *    anything else on a customer domain bounces to capturecat.so
 */
import {
  createStartHandler,
  defaultStreamHandler,
} from "@tanstack/react-start/server";
import { createServerEntry } from "@tanstack/react-start/server-entry";

const startHandler = createStartHandler({ handler: defaultStreamHandler });

const CAPTURECAT_HOSTS = new Set([
  "capturecat.so",
  "www.capturecat.so",
  "app.capturecat.so",
]);

const LEGACY_REDIRECTS: Record<string, string> = {
  "/settings": "/app/settings",
  "/billing": "/app/billing",
  "/videos": "/app",
  "/dashboard": "/app",
};

function isFirstPartyHost(host: string): boolean {
  return (
    CAPTURECAT_HOSTS.has(host) ||
    host === "localhost" ||
    host.startsWith("localhost:") ||
    host.startsWith("127.0.0.1") ||
    host.endsWith(".workers.dev")
  );
}

function isAssetPath(pathname: string): boolean {
  return (
    pathname.startsWith("/assets/") ||
    pathname.startsWith("/_") ||
    /\.[a-z0-9]+$/i.test(pathname)
  );
}

function rewrite(request: Request): Request | Response {
  const url = new URL(request.url);
  const host = url.host;
  const path = url.pathname;

  // Share-page markdown twin: /share/<id>.md → /md-share/<id> (per-video
  // route with the transcript; the static registry below can't serve it).
  const shareMd = path.match(/^\/share\/([^/]+)\.md$/);
  if (shareMd) {
    url.pathname = `/md-share/${shareMd[1]}`;
    return new Request(url.toString(), request);
  }

  // Markdown twins: /pricing.md → /md/pricing, /index.md → /md (same rewrite
  // the Next app did in next.config). The /md/$ route serves from the
  // site-content registry.
  if (path.endsWith(".md") && !path.startsWith("/md/")) {
    const inner = path.slice(0, -3); // strip ".md"
    url.pathname = inner === "/index" || inner === "/" ? "/md" : `/md${inner}`;
    return new Request(url.toString(), request);
  }

  // Marketing-domain only: on app.capturecat.so these clean paths ARE the
  // dashboard routes (the router maps them onto /app internally) — running
  // the legacy map there sent /billing to the double-prefixed /app/billing.
  if (
    (host === "capturecat.so" || host === "www.capturecat.so") &&
    LEGACY_REDIRECTS[path]
  ) {
    const target = LEGACY_REDIRECTS[path];
    const stripped = target.slice("/app".length) || "/";
    return Response.redirect(`https://app.capturecat.so${stripped}`, 307);
  }

  // The dashboard's one home is app.capturecat.so — /app/* on the marketing
  // domain bounces there with the prefix stripped.
  if (
    (host === "capturecat.so" || host === "www.capturecat.so") &&
    (path === "/app" || path.startsWith("/app/"))
  ) {
    const stripped = path.slice("/app".length) || "/";
    return Response.redirect(
      `https://app.capturecat.so${stripped}${url.search}`,
      307
    );
  }

  // App subdomain: the ROUTER's rewrite (src/router.tsx) owns the mapping
  // between clean URLs and the internal /app routes — rewriting here as well
  // made the router's canonicalization redirect-loop against it. The only
  // server-side job left is collapsing a literal /app prefix (old links)
  // onto the clean form.
  if (host === "app.capturecat.so") {
    if (path === "/app" || path.startsWith("/app/")) {
      url.pathname = path.slice("/app".length) || "/";
      return Response.redirect(url.toString(), 307);
    }
    return request;
  }

  // Customer custom domains: share/embed only, all else bounces home.
  if (!isFirstPartyHost(host)) {
    if (isAssetPath(path) || path.startsWith("/share/") || path.startsWith("/embed/")) {
      return request;
    }
    const embedMatch = path.match(/^\/e\/([^/]+)$/);
    if (embedMatch) {
      url.pathname = `/embed/${embedMatch[1]}`;
      return new Request(url.toString(), request);
    }
    const videoMatch = path.match(/^\/([^/]+)$/);
    if (videoMatch) {
      url.pathname = `/share/${videoMatch[1]}`;
      return new Request(url.toString(), request);
    }
    return Response.redirect("https://capturecat.so" + path, 302);
  }

  return request;
}

/**
 * Baseline security headers. Embeds must stay frameable (that's the product);
 * every other page — dashboard included — refuses to be framed.
 */
async function withSecurityHeaders(request: Request, response: Response): Promise<Response> {
  const path = new URL(request.url).pathname;
  const frameable = path.startsWith("/embed/") || /^\/e\/[^/]+$/.test(path);
  const headers = new Headers(response.headers);
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("Referrer-Policy", "strict-origin-when-cross-origin");
  if (!frameable) {
    headers.set("X-Frame-Options", "DENY");
    headers.set("Content-Security-Policy", "frame-ancestors 'none'");
  }
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

export default createServerEntry({
  async fetch(request: Request) {
    const routed = rewrite(request);
    if (routed instanceof Response) return routed;
    return withSecurityHeaders(routed, await startHandler(routed));
  },
});
