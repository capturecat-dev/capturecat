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

/** Hosts on the zone that belong to OTHER Workers (api., admin.). They reach
 *  their own Workers through their Custom Domains and must never land here.
 *  If one does, a zone route is misconfigured: answer 421 and NEVER re-fetch
 *  it — `fetch(request)` to our own zone re-enters our own route. A `*\/*`
 *  route to this Worker once took api. and admin. down with Cloudflare 1019
 *  (2026-09-30); see apps/api/scripts/setup-saas.sh. */
function isSiblingHost(host: string): boolean {
  return host.endsWith(".capturecat.so") && !CAPTURECAT_HOSTS.has(host);
}

/** A customer domain only serves share pages while the API says it is live
 *  (DNS + Cloudflare hostname + certificate + the owner's plan). Cached at
 *  the edge for five minutes by the API; the API purges on verify/delete. */
async function customHostIsLive(host: string): Promise<boolean> {
  try {
    const api = import.meta.env.VITE_API_URL ?? "https://api.capturecat.so";
    const res = await fetch(`${api}/api/domains/resolve?host=${encodeURIComponent(host)}`, {
      cf: { cacheTtl: 300, cacheEverything: true },
    } as RequestInit);
    if (!res.ok) return false;
    const body = (await res.json()) as { found?: boolean };
    return body.found === true;
  } catch {
    return false;
  }
}

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

async function rewrite(request: Request): Promise<Request | Response> {
  const url = new URL(request.url);
  const host = url.host;
  const path = url.pathname;

  if (isSiblingHost(host)) {
    // Not ours, and never proxied (see isSiblingHost): no subrequest, no loop.
    return new Response("Misdirected request", { status: 421 });
  }

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

  // Customer custom domains: share/embed only, all else bounces home. A host
  // nobody registered (or that lapsed) bounces too — never serve a share
  // page on a domain the API does not vouch for.
  if (!isFirstPartyHost(host)) {
    if (!(await customHostIsLive(host))) {
      return Response.redirect("https://capturecat.so" + path, 302);
    }
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
    const routed = await rewrite(request);
    if (routed instanceof Response) return routed;
    return withSecurityHeaders(routed, await startHandler(routed));
  },
});
