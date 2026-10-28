/**
 * Where a visitor or a new user came from — the single classifier behind the
 * admin's acquisition reports (migration 0030).
 *
 * Raw inputs are stored (a bare referrer host and the utm_* tags) and the
 * channel is derived HERE at read time, so a rule added later reclassifies
 * history instead of leaving old rows on old labels.
 *
 * Precedence: a utm_source we recognise, then a referrer we recognise, then an
 * unrecognised utm_source (a campaign), then an unrecognised referrer host,
 * then direct. utm wins because AI assistants are exactly the referrers that
 * get stripped — ChatGPT tags its citations `utm_source=chatgpt.com` and
 * native apps send no Referer at all.
 */

export type SourceKind = "ai" | "search" | "social" | "campaign" | "referral" | "direct";

export interface TrafficSource {
  /** Stable grouping key: a known channel id, a referrer host, or "direct". */
  id: string;
  label: string;
  kind: SourceKind;
}

interface Rule {
  id: string;
  label: string;
  kind: SourceKind;
  /** Matched exactly or as a parent domain (`l.facebook.com` → facebook.com). */
  hosts: string[];
  /** Extra utm_source spellings beyond the hosts themselves. */
  utm?: string[];
}

// Order matters: gemini.google.com must resolve before the google.* search rule.
const RULES: Rule[] = [
  { id: "chatgpt", label: "ChatGPT", kind: "ai", hosts: ["chatgpt.com", "chat.openai.com"], utm: ["chatgpt", "openai"] },
  { id: "claude", label: "Claude", kind: "ai", hosts: ["claude.ai"], utm: ["claude", "anthropic"] },
  { id: "perplexity", label: "Perplexity", kind: "ai", hosts: ["perplexity.ai"], utm: ["perplexity"] },
  { id: "gemini", label: "Gemini", kind: "ai", hosts: ["gemini.google.com", "bard.google.com"], utm: ["gemini"] },
  { id: "copilot", label: "Copilot", kind: "ai", hosts: ["copilot.microsoft.com", "copilot.cloud.microsoft"], utm: ["copilot"] },
  { id: "deepseek", label: "DeepSeek", kind: "ai", hosts: ["chat.deepseek.com", "deepseek.com"], utm: ["deepseek"] },
  { id: "grok", label: "Grok", kind: "ai", hosts: ["grok.com"], utm: ["grok"] },
  { id: "meta-ai", label: "Meta AI", kind: "ai", hosts: ["meta.ai"] },
  { id: "mistral", label: "Le Chat", kind: "ai", hosts: ["chat.mistral.ai"], utm: ["mistral"] },
  { id: "you", label: "You.com", kind: "ai", hosts: ["you.com"] },
  { id: "phind", label: "Phind", kind: "ai", hosts: ["phind.com"] },

  { id: "gmail", label: "Gmail", kind: "referral", hosts: ["mail.google.com"] },
  // google.<any TLD> is handled in matchHost; the Android Google app sends
  // `android-app://com.google.android.googlequicksearchbox/`.
  { id: "google", label: "Google", kind: "search", hosts: ["com.google.android.googlequicksearchbox"] },
  { id: "bing", label: "Bing", kind: "search", hosts: ["bing.com"] },
  { id: "duckduckgo", label: "DuckDuckGo", kind: "search", hosts: ["duckduckgo.com"] },
  { id: "brave", label: "Brave Search", kind: "search", hosts: ["search.brave.com"] },
  { id: "yahoo", label: "Yahoo", kind: "search", hosts: ["yahoo.com"] },
  { id: "ecosia", label: "Ecosia", kind: "search", hosts: ["ecosia.org"] },
  { id: "kagi", label: "Kagi", kind: "search", hosts: ["kagi.com"] },
  { id: "yandex", label: "Yandex", kind: "search", hosts: ["yandex.ru", "yandex.com"] },
  { id: "baidu", label: "Baidu", kind: "search", hosts: ["baidu.com"] },
  { id: "startpage", label: "Startpage", kind: "search", hosts: ["startpage.com"] },
  { id: "qwant", label: "Qwant", kind: "search", hosts: ["qwant.com"] },
  { id: "naver", label: "Naver", kind: "search", hosts: ["naver.com"] },

  { id: "x", label: "X / Twitter", kind: "social", hosts: ["t.co", "x.com", "twitter.com"], utm: ["twitter", "x"] },
  { id: "reddit", label: "Reddit", kind: "social", hosts: ["reddit.com"] },
  { id: "hacker-news", label: "Hacker News", kind: "social", hosts: ["news.ycombinator.com"], utm: ["hackernews", "hn"] },
  { id: "product-hunt", label: "Product Hunt", kind: "social", hosts: ["producthunt.com"], utm: ["producthunt"] },
  { id: "linkedin", label: "LinkedIn", kind: "social", hosts: ["linkedin.com", "lnkd.in"] },
  { id: "youtube", label: "YouTube", kind: "social", hosts: ["youtube.com", "youtu.be"] },
  { id: "facebook", label: "Facebook", kind: "social", hosts: ["facebook.com", "fb.com"] },
  { id: "instagram", label: "Instagram", kind: "social", hosts: ["instagram.com"] },
  { id: "threads", label: "Threads", kind: "social", hosts: ["threads.net", "threads.com"] },
  { id: "bluesky", label: "Bluesky", kind: "social", hosts: ["bsky.app"] },
  { id: "tiktok", label: "TikTok", kind: "social", hosts: ["tiktok.com"] },
  { id: "github", label: "GitHub", kind: "social", hosts: ["github.com"] },
  { id: "discord", label: "Discord", kind: "social", hosts: ["discord.com"] },
  { id: "slack", label: "Slack", kind: "social", hosts: ["slack.com"] },
  { id: "indie-hackers", label: "Indie Hackers", kind: "social", hosts: ["indiehackers.com"] },
];

const GOOGLE_RULE = RULES.find((r) => r.id === "google")!;

function matchHost(host: string): Rule | null {
  for (const rule of RULES) {
    if (rule.hosts.some((h) => host === h || host.endsWith(`.${h}`))) return rule;
    // Checked inside the loop so the AI rules above (gemini.google.com) win.
    if (rule === GOOGLE_RULE && /(^|\.)google\.[a-z]{2,3}(\.[a-z]{2})?$/.test(host)) return rule;
  }
  return null;
}

function matchUtm(source: string): Rule | null {
  return (
    RULES.find((r) => r.utm?.includes(source)) ??
    matchHost(source) ??
    null
  );
}

/** Lowercased host without `www.`, or null when absent/garbled. */
export function bareHost(value: string | null | undefined): string | null {
  if (!value) return null;
  const v = value.trim().toLowerCase();
  if (!v) return null;
  let host: string;
  try {
    host = new URL(v.includes("://") ? v : `https://${v}`).hostname;
  } catch {
    return null;
  }
  host = host.replace(/^www\./, "").replace(/\.$/, "");
  return host && host.length <= 253 ? host : null;
}

/**
 * Hosts that hand a visitor BACK to us mid-flow: our own origins, the OAuth
 * providers' consent pages, and Stripe's checkout/portal. Arriving from one of
 * these is a returning step, not a source — without this every sign-in would
 * count as a visit from "Google".
 */
const FLOW_HOSTS = ["accounts.google.com", "appleid.apple.com", "checkout.stripe.com", "billing.stripe.com"];

export function isInternalHost(host: string): boolean {
  return (
    host === "capturecat.so" ||
    host.endsWith(".capturecat.so") ||
    host === "localhost" ||
    host === "127.0.0.1" ||
    FLOW_HOSTS.includes(host)
  );
}

/**
 * The external referrer host of a visit, or null for none/internal. Accepts a
 * full URL (document.referrer) or a bare host.
 */
export function externalReferrerHost(value: string | null | undefined): string | null {
  const host = bareHost(value);
  return host && !isInternalHost(host) ? host : null;
}

export function classifySource(
  referrerHost: string | null | undefined,
  utmSource: string | null | undefined,
): TrafficSource {
  const utm = utmSource?.trim().toLowerCase().replace(/^www\./, "") || null;
  const host = referrerHost?.trim().toLowerCase() || null;

  const utmRule = utm ? matchUtm(utm) : null;
  if (utmRule) return { id: utmRule.id, label: utmRule.label, kind: utmRule.kind };

  const hostRule = host ? matchHost(host) : null;
  if (hostRule) return { id: hostRule.id, label: hostRule.label, kind: hostRule.kind };

  if (utm) return { id: `utm:${utm}`, label: utm, kind: "campaign" };
  if (host) return { id: host, label: host, kind: "referral" };
  return { id: "direct", label: "Direct / unknown", kind: "direct" };
}

export type Device = "mac" | "windows" | "ios" | "android" | "linux" | "other";

export function deviceFromUserAgent(ua: string | null | undefined): Device {
  if (!ua) return "other";
  // iOS before Mac: iPhone UAs also say "like Mac OS X".
  if (/iPhone|iPad|iPod/.test(ua)) return "ios";
  if (/Android/.test(ua)) return "android";
  if (/Macintosh|Mac OS X/.test(ua)) return "mac";
  if (/Windows/.test(ua)) return "windows";
  if (/Linux|X11|CrOS/.test(ua)) return "linux";
  return "other";
}

const BOT_UA =
  /bot\b|bot\/|crawl|spider|slurp|headless|lighthouse|pagespeed|gtmetrix|pingdom|uptime|monitor|preview|facebookexternalhit|embedly|curl\/|wget|python-|httpclient|okhttp|go-http|java\/|phantomjs|selenium|puppeteer|playwright/i;

/** No UA at all is a script, not a browser. */
export function isBotUserAgent(ua: string | null | undefined): boolean {
  return !ua || BOT_UA.test(ua);
}

const CAPABILITY_PATHS = ["/share/", "/embed/", "/md-share/", "/accept-invitation/"];

/**
 * A landing path safe to store: pathname only, capped, and with capability ids
 * collapsed — an unlisted share link's id IS its access token.
 */
export function normalizeLandingPath(value: unknown): string | null {
  if (typeof value !== "string" || !value.startsWith("/")) return null;
  let path = value.split(/[?#]/)[0]!;
  for (const prefix of CAPABILITY_PATHS) {
    if (path.startsWith(prefix)) return `${prefix}*`;
  }
  if (path.length > 1) path = path.replace(/\/+$/, "");
  return path.slice(0, 120) || "/";
}

/** utm_* values: trimmed, lowercased, capped; empty → null. */
export function cleanTag(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const v = value.trim().toLowerCase().slice(0, 80);
  return v || null;
}
