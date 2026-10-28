/**
 * Where this visitor came from, for the admin's acquisition reports (API
 * migration 0030).
 *
 * Captured once, on the page load that lands on the site, and kept in module
 * memory ONLY — no cookie, no localStorage/sessionStorage, no id. The privacy
 * policy promises a single essential cookie, and this keeps that true. The
 * site navigates client-side (<Link>), so the memory survives from the
 * landing page to /download or /login within the same tab; a reload or a new
 * tab starts over, which is the honest limit of a cookieless design.
 *
 * Three things use it:
 *   trackVisit()      one anonymous `visit` beacon per landing
 *   tagDownload       appends it to a DMG link, so the API counts the
 *                     download against the right source
 *   signInAttribution passed through the OAuth state, so a web sign-up
 *                     records its source on the user row
 *
 * Only a referrer HOST and the utm_* tags leave the page; the API re-validates
 * all of it (src/lib/traffic-source.ts) and collapses capability paths.
 */

import { API_URL } from "@/lib/api-url";

export interface Landing {
  referrer: string | null;
  utmSource: string | null;
  utmMedium: string | null;
  utmCampaign: string | null;
  path: string;
}

let landing: Landing | null = null;
/** False when this load is not a landing (reload, back/forward, internal). */
let isLanding = false;

const OWN_HOST = /(^|\.)capturecat\.so$|^localhost$|^127\.0\.0\.1$/;

/** Signed-in surfaces and embeds on other sites are not someone arriving. */
const NOT_A_LANDING = /^\/(app|embed|editor-lab)(\/|$)/;

function referrerHost(): { host: string | null; internal: boolean } {
  if (!document.referrer) return { host: null, internal: false };
  try {
    const host = new URL(document.referrer).hostname.replace(/^www\./, "");
    return OWN_HOST.test(host) ? { host: null, internal: true } : { host, internal: false };
  } catch {
    return { host: null, internal: false };
  }
}

function navigationType(): string {
  const nav = performance.getEntriesByType?.("navigation")[0] as PerformanceNavigationTiming | undefined;
  return nav?.type ?? "navigate";
}

/** The landing of this page load; null during SSR. */
export function getLanding(): Landing | null {
  if (typeof window === "undefined") return null;
  if (landing) return landing;
  const params = new URLSearchParams(window.location.search);
  const tag = (k: string) => params.get(k)?.trim().slice(0, 80) || null;
  const ref = referrerHost();
  landing = {
    referrer: ref.host,
    // `?ref=` is the common untagged convention (Product Hunt, newsletters).
    utmSource: tag("utm_source") ?? tag("ref"),
    utmMedium: tag("utm_medium"),
    utmCampaign: tag("utm_campaign"),
    path: window.location.pathname,
  };
  isLanding =
    !ref.internal &&
    navigationType() === "navigate" &&
    !NOT_A_LANDING.test(landing.path) &&
    !navigator.webdriver;
  return landing;
}

let sent = false;

/** One anonymous visit per landing. Call once, after hydration. */
export function trackVisit(): void {
  const l = getLanding();
  if (!l || !isLanding || sent) return;
  sent = true;
  const body = JSON.stringify(l);
  const url = `${API_URL}/api/site/visit`;
  try {
    // text/plain keeps it a CORS-safelisted request: no preflight.
    if (navigator.sendBeacon?.(url, new Blob([body], { type: "text/plain;charset=UTF-8" }))) return;
  } catch {
    // Fall through to fetch.
  }
  void fetch(url, { method: "POST", body, keepalive: true, headers: { "Content-Type": "text/plain" } }).catch(() => {});
}

/**
 * onClick for a DMG link: append the landing to its query just before the
 * browser follows it. Done at click time, not render time, so the server and
 * client render the same href (no hydration mismatch).
 */
export function tagDownload(e: { currentTarget: HTMLAnchorElement }): void {
  const l = getLanding();
  if (!l) return;
  try {
    const url = new URL(e.currentTarget.href);
    if (url.searchParams.has("lp")) return;
    if (l.referrer) url.searchParams.set("ref", l.referrer);
    if (l.utmSource) url.searchParams.set("utm_source", l.utmSource);
    if (l.utmMedium) url.searchParams.set("utm_medium", l.utmMedium);
    if (l.utmCampaign) url.searchParams.set("utm_campaign", l.utmCampaign);
    url.searchParams.set("lp", l.path);
    e.currentTarget.href = url.toString();
  } catch {
    // Leave the link as it was; the download still works.
  }
}

/** For signIn.social's `additionalData` — `cc*` keys, nulls dropped. */
export function signInAttribution(): Record<string, string> {
  const l = getLanding();
  if (!l) return {};
  const out: Record<string, string> = { ccLanding: l.path };
  if (l.referrer) out.ccReferrer = l.referrer;
  if (l.utmSource) out.ccUtmSource = l.utmSource;
  if (l.utmMedium) out.ccUtmMedium = l.utmMedium;
  if (l.utmCampaign) out.ccUtmCampaign = l.utmCampaign;
  return out;
}
