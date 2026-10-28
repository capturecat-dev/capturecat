/**
 * app.capturecat.so's clean URLs (src/router.tsx): the internal /app route
 * prefix never shows — app.capturecat.so/billing IS /app/billing. Pure, so the
 * mapping is tested on its own (app-host-rewrite.test.ts).
 */

/** Dashboard hosts where the internal /app prefix must never show in URLs. */
export function isAppHost(host: string): boolean {
  return host === "app.capturecat.so" || host.startsWith("app.localhost");
}

/** Root files crawlers and agents read on every host (routes/robots[.]txt.ts,
 *  sitemap[.]xml.ts, llms[.]txt.ts answer per host). Mapped onto /app they
 *  bounced to sign-in, so app.capturecat.so had no robots.txt at all. */
const ROOT_FILES = new Set(["/robots.txt", "/sitemap.xml", "/llms.txt"]);

/** Visible URL → internal route URL, or undefined to leave it alone. */
export function appHostInput(url: URL): URL | undefined {
  if (!isAppHost(url.host)) return undefined;
  const path = url.pathname;
  if (
    // "/app" or "/app/…" only — a bare startsWith("/app") also caught
    // /approvals/<id> (the link agents send), which then 404'd.
    path === "/app" ||
    path.startsWith("/app/") ||
    path.startsWith("/api/") ||
    path.startsWith("/login") ||
    // The OAuth consent page is a root route on every host
    // (routes/oauth.authorize.tsx) — the API sends clients there.
    path.startsWith("/oauth/") ||
    ROOT_FILES.has(path) ||
    // Discovery documents (src/server/agent-discovery.ts answers the ones
    // that exist before the router runs); anything else is a real 404, not
    // a sign-in page.
    path.startsWith("/.well-known/")
  ) {
    return undefined;
  }
  const next = new URL(url);
  next.pathname = path === "/" ? "/app" : `/app${path}`;
  return next;
}

/** Internal route URL → visible URL (strips the /app prefix), or undefined. */
export function appHostOutput(url: URL): URL | undefined {
  if (!isAppHost(url.host)) return undefined;
  if (url.pathname === "/app" || url.pathname.startsWith("/app/")) {
    const next = new URL(url);
    next.pathname = url.pathname.slice("/app".length) || "/";
    return next;
  }
  return undefined;
}
