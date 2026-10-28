/**
 * SSRF guard for URLs a USER (or an agent, or an OAuth client) chooses and
 * this Worker then fetches itself: webhook endpoints (lib/webhooks.ts) and
 * OAuth Client ID Metadata Documents (lib/oauth/clients.ts).
 *
 * Stricter than the Screenshot API's checkUrlAllowed (lib/screenshot/
 * params.ts), which only proxies a request into Browser Rendering:
 *
 *   • https only, default port only, no credentials, no fragment;
 *   • NO IP literals at all — v4 (in any spelling: WHATWG URL parsing turns
 *     https://2130706433/ into 127.0.0.1 before we look), v6, mapped;
 *   • a real public-looking DNS name: at least one dot, not localhost or a
 *     reserved/internal suffix (.local, .internal, .home.arpa, .test, …);
 *   • never our own zone (capturecat.so): a Worker fetching its own zone
 *     re-enters itself — the 2026-09-30 1019 outage's lesson.
 *
 * What a URL check cannot see: a public name that RESOLVES to a private
 * address. Workers have no route to private networks (a subrequest leaves
 * from Cloudflare's edge, not from an origin network), so that is not a
 * path into anything of ours. Redirects are never followed (fetch with
 * `redirect: "manual"`), so a public URL cannot bounce the request onward.
 */

const BLOCKED_HOSTNAMES = new Set(["localhost", "metadata.google.internal", "metadata"]);
const BLOCKED_SUFFIXES = [
  ".localhost",
  ".local",
  ".localdomain",
  ".internal",
  ".intranet",
  ".corp",
  ".lan",
  ".home",
  ".home.arpa",
  ".arpa",
  ".test",
  ".example",
  ".invalid",
  ".onion",
];
const OWN_ZONE = "capturecat.so";

export type OutboundUrlCheck = { ok: true; url: URL } | { ok: false; error: string };

export interface OutboundUrlOptions {
  /** Name used in error messages ("webhook url", "client_id"). */
  label: string;
  /** Client ID Metadata Documents: a non-root path is required and dot
   *  segments are refused (draft-ietf-oauth-client-id-metadata-document §3). */
  requirePath?: boolean;
  maxLength?: number;
}

function isIpLiteral(host: string): boolean {
  if (host.startsWith("[") || host.includes(":")) return true; // IPv6 (URL keeps it bracketed)
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(host); // IPv4 after WHATWG canonicalization
}

export function checkOutboundUrl(raw: string, opts: OutboundUrlOptions): OutboundUrlCheck {
  const label = opts.label;
  if (typeof raw !== "string" || raw.length === 0) return { ok: false, error: `${label} is required` };
  if (raw.length > (opts.maxLength ?? 2048)) return { ok: false, error: `${label} is too long` };
  if (/[\s\\]/.test(raw)) return { ok: false, error: `${label} must not contain spaces or backslashes` };
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return { ok: false, error: `${label} is not a valid absolute URL` };
  }
  if (url.protocol !== "https:") return { ok: false, error: `${label} must be an https URL` };
  if (url.username || url.password) return { ok: false, error: `${label} must not contain credentials` };
  if (url.hash || raw.includes("#")) return { ok: false, error: `${label} must not contain a fragment` };
  if (url.port && url.port !== "443") return { ok: false, error: `${label} must use the default https port` };

  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (isIpLiteral(host)) return { ok: false, error: `${label} must use a domain name, not an IP address` };
  if (!host.includes(".") || BLOCKED_HOSTNAMES.has(host) || BLOCKED_SUFFIXES.some((s) => host.endsWith(s))) {
    return { ok: false, error: `${label} must be a public host` };
  }
  if (host === OWN_ZONE || host.endsWith(`.${OWN_ZONE}`)) {
    return { ok: false, error: `${label} must not point at CaptureCat itself` };
  }
  if (opts.requirePath) {
    if (url.pathname === "/" || url.pathname === "") return { ok: false, error: `${label} must have a path` };
    // WHATWG parsing already resolved them away — look at what was sent.
    const afterScheme = raw.replace(/^https:\/\//i, "");
    const slash = afterScheme.indexOf("/");
    const rawPath = slash === -1 ? "" : afterScheme.slice(slash).split("?")[0];
    if (rawPath.split("/").some((segment) => /^(?:\.|%2e){1,2}$/i.test(segment))) {
      return { ok: false, error: `${label} must not contain . or .. path segments` };
    }
  }
  return { ok: true, url };
}

/**
 * The body of `res` as text, or null when it exceeds `maxBytes` (the read is
 * cancelled there — a hostile server cannot make us buffer more).
 */
export async function readCappedText(res: Response, maxBytes: number): Promise<string | null> {
  const declared = Number(res.headers.get("Content-Length") ?? "");
  if (Number.isFinite(declared) && declared > maxBytes) {
    await res.body?.cancel().catch(() => {});
    return null;
  }
  if (!res.body) return "";
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel().catch(() => {});
      return null;
    }
    chunks.push(value);
  }
  const all = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    all.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(all);
}
