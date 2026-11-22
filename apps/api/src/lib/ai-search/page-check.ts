/**
 * Crawl/index check of the pages our questions point at, taken when a run
 * starts. "Was there a crawl or indexing problem?" is one of the four reasons
 * a question is lost, and it's the only one we can check from here.
 *
 * What it can see: the page's HTTP status as an ordinary client gets it, a
 * noindex (header or meta), a canonical pointing elsewhere, absence from
 * sitemap.xml, robots.txt rules against the search and answer bots, and a
 * thin page. What it can't: Cloudflare's AI-crawler blocking acts on the
 * crawlers' own requests (UA + verified IPs), which a Worker can't imitate —
 * check that in the dashboard (AI Crawl Control), not here.
 */

export const SITE = "https://capturecat.so";

/** Crawlers that fetch pages for search results and AI answers (not training). */
export const ANSWER_BOTS = ["Googlebot", "Bingbot", "OAI-SearchBot", "ChatGPT-User", "PerplexityBot", "Claude-SearchBot", "Claude-User"];

const CHECK_UA = "Mozilla/5.0 (compatible; CaptureCat-AI-Search/1.0; +https://capturecat.so)";

export const THIN_PAGE_WORDS = 300;

interface RobotsGroup {
  agents: string[];
  rules: Array<{ allow: boolean; path: string }>;
}

/** robots.txt → groups. Consecutive User-agent lines share the rules that follow them. */
export function parseRobots(txt: string): RobotsGroup[] {
  const groups: RobotsGroup[] = [];
  let cur: RobotsGroup | null = null;
  let inAgents = false;
  for (const raw of txt.split(/\r?\n/)) {
    const line = raw.replace(/#.*$/, "").trim();
    const m = /^([A-Za-z-]+)\s*:\s*(.*)$/.exec(line);
    if (!m) continue;
    const field = m[1].toLowerCase();
    const value = m[2].trim();
    if (field === "user-agent") {
      if (!cur || !inAgents) {
        cur = { agents: [], rules: [] };
        groups.push(cur);
      }
      cur.agents.push(value.toLowerCase());
      inAgents = true;
    } else if (field === "allow" || field === "disallow") {
      inAgents = false;
      // An empty Disallow allows everything; it adds no rule.
      if (cur && value) cur.rules.push({ allow: field === "allow", path: value });
    } else {
      inAgents = false;
    }
  }
  return groups;
}

function ruleMatches(rulePath: string, path: string): number {
  // Google's semantics: `*` wildcard, `$` end anchor; the match length decides.
  const anchored = rulePath.endsWith("$");
  const body = anchored ? rulePath.slice(0, -1) : rulePath;
  const re = new RegExp(`^${body.split("*").map((s) => s.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*")}${anchored ? "$" : ""}`);
  return re.test(path) ? body.length : -1;
}

/** Whether `agent` may fetch `path`: its own group, else `*`; longest rule wins, Allow wins ties. */
export function robotsAllows(groups: RobotsGroup[], agent: string, path: string): boolean {
  const a = agent.toLowerCase();
  const own = groups.filter((g) => g.agents.includes(a));
  const applicable = own.length ? own : groups.filter((g) => g.agents.includes("*"));
  let best = -1;
  let allowed = true;
  for (const g of applicable) {
    for (const r of g.rules) {
      const len = ruleMatches(r.path, path);
      if (len < 0) continue;
      if (len > best || (len === best && r.allow)) {
        best = len;
        allowed = r.allow;
      }
    }
  }
  return best < 0 ? true : allowed;
}

export function visibleWords(html: string): number {
  const body = /<body[\s\S]*<\/body>/i.exec(html)?.[0] ?? html;
  const text = body
    .replace(/<(script|style|noscript|svg|template)\b[\s\S]*?<\/\1>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&[a-z#0-9]+;/gi, " ");
  return text.split(/\s+/).filter((w) => /[A-Za-z0-9]/.test(w)).length;
}

const canonicalHref = (html: string): string | null =>
  /<link\b[^>]*rel=["']canonical["'][^>]*>/i.exec(html)?.[0].match(/href=["']([^"']+)["']/i)?.[1] ?? null;

const hasNoindexMeta = (html: string): boolean =>
  [...html.matchAll(/<meta\b[^>]*>/gi)].some(
    ([tag]) => /name=["'](robots|googlebot)["']/i.test(tag) && /content=["'][^"']*noindex/i.test(tag),
  );

export const pageUrl = (path: string) => (path === "/" ? SITE : `${SITE}${path}`);
const sameUrl = (a: string, b: string) => a.replace(/\/$/, "") === b.replace(/\/$/, "");

export interface PageCheck {
  path: string;
  httpStatus: number | null;
  problems: string[];
  words: number | null;
}

/** Problems with one page, given what was fetched. Pure, for tests. */
export function pageProblems(input: {
  path: string;
  status: number | null;
  location?: string | null;
  xRobotsTag?: string | null;
  html?: string;
  inSitemap: boolean | null;
  robots: RobotsGroup[] | null;
}): { problems: string[]; words: number | null } {
  const problems: string[] = [];
  let words: number | null = null;
  if (input.status == null) {
    problems.push("couldn't be fetched");
  } else if (input.status >= 300 && input.status < 400) {
    problems.push(`redirects (${input.status})${input.location ? ` to ${input.location}` : ""}`);
  } else if (input.status !== 200) {
    problems.push(`answers HTTP ${input.status}`);
  }
  if (input.xRobotsTag && /noindex/i.test(input.xRobotsTag)) problems.push("X-Robots-Tag: noindex");
  if (input.html && input.status === 200) {
    if (hasNoindexMeta(input.html)) problems.push("robots meta tag says noindex");
    const canonical = canonicalHref(input.html);
    if (canonical && !sameUrl(canonical, pageUrl(input.path))) problems.push(`canonical points to ${canonical}`);
    words = visibleWords(input.html);
    if (words < THIN_PAGE_WORDS) problems.push(`thin: ${words} words`);
  }
  if (input.inSitemap === false) problems.push("not in sitemap.xml");
  if (input.robots) {
    const blocked = ANSWER_BOTS.filter((bot) => !robotsAllows(input.robots!, bot, input.path));
    if (blocked.length) problems.push(`robots.txt blocks ${blocked.join(", ")}`);
  }
  return { problems, words };
}

async function getText(url: string, timeoutMs = 15_000): Promise<{ status: number; text: string; res: Response } | null> {
  try {
    const res = await fetch(url, { headers: { "User-Agent": CHECK_UA }, redirect: "manual", signal: AbortSignal.timeout(timeoutMs) });
    const text = res.status === 200 ? await res.text() : (await res.body?.cancel(), "");
    return { status: res.status, text, res };
  } catch {
    return null;
  }
}

/** Check every path (a handful at a time). One robots.txt and one sitemap fetch for all. */
export async function checkPages(paths: string[]): Promise<PageCheck[]> {
  const [robotsRes, sitemapRes] = await Promise.all([getText(`${SITE}/robots.txt`), getText(`${SITE}/sitemap.xml`)]);
  const robots = robotsRes?.status === 200 ? parseRobots(robotsRes.text) : null;
  const sitemap =
    sitemapRes?.status === 200
      ? new Set([...sitemapRes.text.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1].trim().replace(/\/$/, "")))
      : null;

  const out: PageCheck[] = [];
  const queue = [...new Set(paths)];
  const worker = async () => {
    for (let path = queue.shift(); path !== undefined; path = queue.shift()) {
      const got = await getText(pageUrl(path));
      const { problems, words } = pageProblems({
        path,
        status: got?.status ?? null,
        location: got?.res.headers.get("location"),
        xRobotsTag: got?.res.headers.get("x-robots-tag"),
        html: got?.text,
        inSitemap: sitemap ? sitemap.has(pageUrl(path).replace(/\/$/, "")) : null,
        robots,
      });
      out.push({ path, httpStatus: got?.status ?? null, problems, words });
    }
  };
  await Promise.all([worker(), worker(), worker(), worker()]);
  return out.sort((a, b) => a.path.localeCompare(b.path));
}
