/**
 * WebMCP ships in Chrome behind an origin trial (Chrome 149–156). The token
 * is registered for https://app.capturecat.so at
 * https://developer.chrome.com/origintrials and is PUBLIC by design — it is
 * delivered in the page. Set it at build time:
 *
 *   apps/web/.env.production   VITE_WEBMCP_ORIGIN_TRIAL=<token>
 *
 * Only the editor pages carry it (the tools live there). Without a token the
 * meta tag is omitted and WebMCP stays off except behind Chrome's flag.
 */
export const WEBMCP_ORIGIN_TRIAL_TOKEN: string = (import.meta.env.VITE_WEBMCP_ORIGIN_TRIAL ?? "").trim();

/** Head meta for the editor routes: `<meta http-equiv="origin-trial">`. */
export function webmcpOriginTrialMeta(token: string = WEBMCP_ORIGIN_TRIAL_TOKEN): Array<{ httpEquiv: string; content: string }> {
  return token ? [{ httpEquiv: "origin-trial", content: token }] : [];
}
