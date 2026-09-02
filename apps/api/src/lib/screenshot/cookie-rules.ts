/**
 * EasyList Cookie List rules, converted to plain CSS selectors by
 * `scripts/update-cookie-rules.mjs` (see cookie-rules.generated.json meta for
 * source URL, fetch date and licence; attribution in
 * COOKIE-RULES-ATTRIBUTION.txt).
 *
 * The generated artifact is shared byte-for-byte with the macOS app's bundle
 * copy, so both capture paths hide the same elements. The hand-curated lists
 * in hide-rules.ts remain a verified overrides layer applied on top.
 */
import rules from "./cookie-rules.generated.json";

const GENERIC: string[] = rules.generic;
const DOMAINS: Record<string, string[]> = rules.domains;

/**
 * Pre-joined at module load — the generic list is ~15k selectors and building
 * the string once keeps per-capture cost to a lookup + small concat.
 */
export const GENERIC_COOKIE_CSS: string = `${GENERIC.join(",\n")} { display: none !important; }`;

/**
 * Domain-scoped selectors for a host, with AdBlock subdomain semantics: a rule
 * for `example.com` also applies to `www.example.com`, but never to
 * `notexample.com`. Walks every label suffix of the host.
 */
export function domainCookieSelectors(host: string | null | undefined): string[] {
  if (!host) return [];
  const labels = host.toLowerCase().split(".");
  const out: string[] = [];
  for (let i = 0; i < labels.length - 1; i++) {
    const suffix = labels.slice(i).join(".");
    const sels = DOMAINS[suffix];
    if (sels) out.push(...sels);
  }
  return out;
}

export const COOKIE_RULES_META = rules.meta;
