/**
 * AI search visibility — the pure half: reading an engine's answer, sorting
 * its sources into OWN / CLAIM / EARN / CONTEST, diagnosing why a question is
 * lost, and the rates the admin page trends. No I/O here, so it is all unit
 * tested (analyze.test.ts) and the runner and the routes share one copy.
 *
 * Vocabulary:
 *   mentioned  CaptureCat is named in the answer text.
 *   cited      a capturecat.so URL is among the sources the engine cited.
 *   rank       AI: CaptureCat's place among the products the answer names
 *              (1 = named first). Google: organic position of capturecat.so.
 */

import { COMPETITORS } from "../../../../web/src/lib/competitors";

export const ENGINE_IDS = ["chatgpt", "gemini", "perplexity", "claude", "google"] as const;
export type EngineId = (typeof ENGINE_IDS)[number];

export const SOURCE_KINDS = ["own", "claim", "earn", "contest", "competitor", "ignore"] as const;
export type SourceKind = (typeof SOURCE_KINDS)[number];

export const SOURCE_STATUSES = ["todo", "doing", "done"] as const;
export type SourceStatus = (typeof SOURCE_STATUSES)[number];

const CAPTURECAT_RE = /\bcapture\s?cat\b/i;

export function mentionsCaptureCat(text: string): boolean {
  return CAPTURECAT_RE.test(text);
}

/** Lowercased host without `www.`, or null when the URL won't parse. */
export function domainOf(url: string): string | null {
  try {
    const host = new URL(url).hostname.toLowerCase().replace(/^www\./, "").replace(/\.$/, "");
    return host || null;
  } catch {
    return null;
  }
}

/** A page we publish: the site, its subdomains, and the open-source repo. */
export function isOwnUrl(url: string): boolean {
  const host = domainOf(url);
  if (!host) return false;
  if (host === "capturecat.so" || host.endsWith(".capturecat.so")) return true;
  if (host === "github.com") {
    try {
      return new URL(url).pathname.toLowerCase().startsWith("/capturecat-dev/");
    } catch {
      return false;
    }
  }
  return false;
}

// ---------------------------------------------------------------------------
// Brands named in an answer
// ---------------------------------------------------------------------------

interface BrandPattern {
  name: string;
  re: RegExp;
}

const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/**
 * Every product on the comparison pages plus CaptureCat. Names are matched
 * case-sensitively at word boundaries — "Kap", "Detail" and "Arcade"
 * are also ordinary words, and brand casing is what tells them apart.
 */
const BRANDS: BrandPattern[] = [
  { name: "CaptureCat", re: CAPTURECAT_RE },
  ...COMPETITORS.map((c) => ({
    name: c.name,
    re: new RegExp(`(^|[^A-Za-z0-9])${escapeRe(c.name)}(?![A-Za-z0-9])`),
  })),
];

/** Brands named in `text`, in order of first mention, each once. */
export function brandsInText(text: string): string[] {
  const hits: Array<{ name: string; at: number }> = [];
  for (const b of BRANDS) {
    const m = b.re.exec(text);
    if (m) hits.push({ name: b.name, at: m.index + (m[1]?.length ?? 0) });
  }
  // A longer name containing a shorter one ("OBS Studio" vs a "Studio"
  // brand) reports both; drop the one that starts inside another's span.
  hits.sort((a, b) => a.at - b.at || b.name.length - a.name.length);
  const out: Array<{ name: string; at: number }> = [];
  for (const h of hits) {
    const prev = out[out.length - 1];
    if (prev && h.at < prev.at + prev.name.length) continue;
    out.push(h);
  }
  return out.map((h) => h.name);
}

/** CaptureCat's 1-based place among the brands named, or null. */
export function rankAmong(brands: string[]): number | null {
  const i = brands.indexOf("CaptureCat");
  return i < 0 ? null : i + 1;
}

// ---------------------------------------------------------------------------
// One engine answer, normalised
// ---------------------------------------------------------------------------

export interface AnswerSource {
  url: string;
  title: string;
}

/** What every engine adapter returns (lib/ai-search/engines.ts). */
export interface EngineAnswer {
  model: string | null;
  /** AI engines: the answer. Google: the AI Overview text, "" when none. */
  text: string;
  /** AI: sources the answer cited. Google: organic results, in rank order. */
  sources: AnswerSource[];
  /** Google only: the AI Overview's references (also searched for capturecat.so). */
  overviewSources?: AnswerSource[];
  /** Brands the engine itself tagged (ChatGPT), in order; else derived from text. */
  brands?: string[];
  queries: string[];
  costUsd: number;
}

export interface AnswerVerdict {
  mentioned: boolean;
  cited: boolean;
  rank: number | null;
  ownUrl: string | null;
  brands: string[];
}

export function judgeAnswer(engine: EngineId, a: EngineAnswer): AnswerVerdict {
  if (engine === "google") {
    const organic = a.sources.findIndex((s) => isOwnUrl(s.url));
    const overviewOwn = (a.overviewSources ?? []).find((s) => isOwnUrl(s.url));
    return {
      mentioned: mentionsCaptureCat(a.text),
      cited: !!overviewOwn,
      rank: organic < 0 ? null : organic + 1,
      ownUrl: organic >= 0 ? a.sources[organic].url : overviewOwn?.url ?? null,
      brands: brandsInText(a.text),
    };
  }
  const brands = mergeBrands(a.brands ?? [], brandsInText(a.text));
  const own = a.sources.find((s) => isOwnUrl(s.url));
  return {
    mentioned: mentionsCaptureCat(a.text) || brands.includes("CaptureCat"),
    cited: !!own,
    rank: rankAmong(brands),
    ownUrl: own?.url ?? null,
    brands,
  };
}

/** Engine-tagged brands first (they're authoritative), then any we found that it missed. */
function mergeBrands(tagged: string[], found: string[]): string[] {
  const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, "");
  const out: string[] = [];
  const seen = new Set<string>();
  for (const raw of [...tagged, ...found]) {
    const name = CAPTURECAT_RE.test(raw) ? "CaptureCat" : raw.trim();
    const k = norm(name);
    if (!k || seen.has(k)) continue;
    seen.add(k);
    out.push(name);
  }
  return out;
}

// ---------------------------------------------------------------------------
// OWN / CLAIM / EARN / CONTEST
// ---------------------------------------------------------------------------

/**
 * Profiles and listings CaptureCat can create or take over itself. Everything
 * else third-party defaults to EARN (editorial, reviews, forums, videos).
 * CONTEST is only ever set by hand: it means a page states something wrong.
 */
const CLAIMABLE = [
  "producthunt.com", "alternativeto.net", "saashub.com", "g2.com", "capterra.com",
  "getapp.com", "softwareadvice.com", "trustradius.com", "slant.co", "macupdate.com",
  "apps.apple.com", "setapp.com", "crunchbase.com", "theresanaiforthat.com",
  "futurepedia.io", "uneed.best", "stackshare.io", "sourceforge.net", "softonic.com",
  "uptodown.com", "formulae.brew.sh", "macupdater.net", "toolify.ai", "aitoolsdirectory.com",
  "betalist.com", "launchingnext.com", "microlaunch.net", "peerlist.io", "openalternative.co",
  "linkedin.com", "x.com", "twitter.com", "toolradar.com",
  // MCP server directories: listing the CaptureCat server is ours to do.
  "glama.ai", "mcpservers.org", "lobehub.com", "smithery.ai", "pulsemcp.com", "mcp.so",
  "registry.modelcontextprotocol.io",
];

const COMPETITOR_DOMAINS = new Set(
  COMPETITORS.map((c) => domainOf(c.website)).filter((d): d is string => !!d),
);

const underDomain = (host: string, d: string) => host === d || host.endsWith(`.${d}`);

export function suggestKind(domain: string): SourceKind {
  if (domain === "capturecat.so" || domain.endsWith(".capturecat.so")) return "own";
  if (CLAIMABLE.some((d) => underDomain(domain, d))) return "claim";
  for (const d of COMPETITOR_DOMAINS) if (underDomain(domain, d)) return "competitor";
  return "earn";
}

export const KIND_ACTIONS: Record<SourceKind, string> = {
  own: "Make the page answer the question in its first paragraph.",
  claim: "Create or claim the CaptureCat listing and keep its facts current.",
  earn: "Get CaptureCat covered: pitch the author, or join the discussion where it fits.",
  contest: "Ask for the wrong or outdated facts about CaptureCat to be corrected.",
  competitor: "A competitor's own page: answer it with a comparison page of ours.",
  ignore: "",
};

export interface SourceDecision {
  key: string;
  kind: SourceKind;
}

/**
 * The decision that applies to a URL: an exact-URL entry wins, then the
 * domain, then a parent domain; else the suggestion (marked as such).
 */
export function classifySource(
  url: string,
  decisions: Map<string, SourceDecision>,
): { kind: SourceKind; key: string | null; suggested: boolean } {
  const exact = decisions.get(url);
  if (exact) return { kind: exact.kind, key: exact.key, suggested: false };
  const domain = domainOf(url) ?? url;
  if (isOwnUrl(url)) return { kind: "own", key: null, suggested: true };
  const parts = domain.split(".");
  for (let i = 0; i < parts.length - 1; i++) {
    const d = decisions.get(parts.slice(i).join("."));
    if (d) return { kind: d.kind, key: d.key, suggested: false };
  }
  return { kind: suggestKind(domain), key: null, suggested: true };
}

// ---------------------------------------------------------------------------
// Per question: snapshot of the latest answers, and the diagnosis
// ---------------------------------------------------------------------------

export interface ResultLite {
  runId: string;
  engine: EngineId;
  status: "pending" | "running" | "ok" | "error";
  finishedAt: string | null;
  mentioned: boolean | null;
  cited: boolean | null;
  rank: number | null;
  ownUrl: string | null;
  brands: string[];
  error: string | null;
}

export interface EngineSnapshot {
  runId: string;
  checkedAt: string | null;
  samples: number;
  ok: number;
  mentionRate: number | null;
  citationRate: number | null;
  /** Best (lowest) rank across samples. */
  rank: number | null;
  ownUrl: string | null;
  /** Other products named, most often first (up to 5). */
  topBrands: string[];
  error: string | null;
}

export function snapshot(results: ResultLite[]): EngineSnapshot | null {
  if (results.length === 0) return null;
  const ok = results.filter((r) => r.status === "ok");
  const rate = (pick: (r: ResultLite) => boolean | null) =>
    ok.length === 0 ? null : ok.filter((r) => pick(r) === true).length / ok.length;
  const ranks = ok.map((r) => r.rank).filter((r): r is number => r != null);
  const counts = new Map<string, number>();
  for (const r of ok) for (const b of r.brands) if (b !== "CaptureCat") counts.set(b, (counts.get(b) ?? 0) + 1);
  const finished = results.map((r) => r.finishedAt).filter((d): d is string => !!d).sort();
  return {
    runId: results[0].runId,
    checkedAt: finished[finished.length - 1] ?? null,
    samples: results.length,
    ok: ok.length,
    mentionRate: rate((r) => r.mentioned),
    citationRate: rate((r) => r.cited),
    rank: ranks.length ? Math.min(...ranks) : null,
    ownUrl: ok.find((r) => r.ownUrl)?.ownUrl ?? null,
    topBrands: [...counts.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, 5).map(([b]) => b),
    error: ok.length === 0 ? results.find((r) => r.error)?.error ?? null : null,
  };
}

export type CauseCode = "crawl" | "missing_page" | "weak_page" | "third_party";

export interface Diagnosis {
  status: "winning" | "partial" | "losing" | "unmeasured";
  /** Mean mention rate over the AI engines that answered. */
  mentionRate: number | null;
  causes: Array<{ code: CauseCode; detail: string }>;
  /** The one next change to make (step 9: one change, then rerun). */
  action: string;
  /** Third-party domains the engines cited for this question, most first. */
  topSources: Array<{ domain: string; count: number; kind: SourceKind }>;
}

export interface DiagnoseInput {
  prompt: string;
  targetPath: string | null;
  snapshots: Partial<Record<EngineId, EngineSnapshot>>;
  /** Problems from the latest crawl check of targetPath ([] = healthy, null = not checked). */
  pageProblems: string[] | null;
  /** Third-party sources cited by AI engines for this question in their latest answers. */
  citedSources: Array<{ domain: string; count: number; kind: SourceKind }>;
}

export const WINNING_RATE = 0.5;

export function diagnose(input: DiagnoseInput): Diagnosis {
  const ai = (Object.entries(input.snapshots) as Array<[EngineId, EngineSnapshot | undefined]>)
    .filter(([e, s]) => e !== "google" && s && s.ok > 0 && s.mentionRate != null)
    .map(([, s]) => s!);
  const google = input.snapshots.google;
  const googleMeasured = !!google && google.ok > 0;
  const topSources = input.citedSources.filter((s) => s.kind !== "own").slice(0, 5);

  if (ai.length === 0) {
    return {
      status: "unmeasured",
      mentionRate: null,
      causes: [],
      action: "Not measured yet: run it.",
      topSources,
    };
  }

  const mentionRate = ai.reduce((sum, s) => sum + (s.mentionRate ?? 0), 0) / ai.length;
  const status = mentionRate >= WINNING_RATE ? "winning" : mentionRate > 0 ? "partial" : "losing";
  const causes: Diagnosis["causes"] = [];
  const page = input.targetPath;

  if (page && input.pageProblems && input.pageProblems.length > 0) {
    causes.push({ code: "crawl", detail: `${page}: ${input.pageProblems.join("; ")}` });
  }
  if (!page) {
    causes.push({ code: "missing_page", detail: "No page of ours targets this question." });
  } else {
    const citedOurs = ai.some((s) => (s.citationRate ?? 0) > 0);
    const googleRank = googleMeasured ? google!.rank : null;
    if (!citedOurs && (!googleMeasured || googleRank == null || googleRank > 10)) {
      causes.push({
        code: "weak_page",
        detail: googleMeasured
          ? `${page} isn't cited by any AI engine and isn't in Google's top 10${googleRank ? ` (#${googleRank})` : ""}.`
          : `${page} isn't cited by any AI engine.`,
      });
    } else if (citedOurs && mentionRate < WINNING_RATE) {
      causes.push({
        code: "weak_page",
        detail: `Engines read ${page} but don't recommend CaptureCat from it: the answer isn't plain enough.`,
      });
    }
  }
  if (topSources.length > 0 && status !== "winning") {
    causes.push({
      code: "third_party",
      detail: `Answers come from ${topSources.slice(0, 3).map((s) => `${s.domain} (${s.count})`).join(", ")}.`,
    });
  }

  return { status, mentionRate, causes, action: nextAction(status, causes, input, topSources), topSources };
}

function nextAction(
  status: Diagnosis["status"],
  causes: Diagnosis["causes"],
  input: DiagnoseInput,
  topSources: Diagnosis["topSources"],
): string {
  if (status === "winning") return "Holding: rerun and watch for slips.";
  const first = causes[0];
  if (!first) return "Rerun: one answer isn't enough to call it.";
  switch (first.code) {
    case "crawl":
      return `Fix the crawl/index problem on ${input.targetPath} first.`;
    case "missing_page":
      return "Write one page that answers this question directly.";
    case "weak_page":
      return /isn't plain enough/.test(first.detail)
        ? `Rewrite the top of ${input.targetPath} to answer "${input.prompt}" in its first paragraph.`
        : `Improve ${input.targetPath} for this question instead of publishing another page.`;
    case "third_party": {
      const top = topSources[0];
      return top ? `${top.domain}: ${KIND_ACTIONS[top.kind]}` : "Work the third-party sources.";
    }
  }
}

// ---------------------------------------------------------------------------
// Run metrics (the trend line)
// ---------------------------------------------------------------------------

export interface RateTriple {
  mentionRate: number | null;
  citationRate: number | null;
  answers: number;
}

export interface RunMetrics extends RateTriple {
  /** Share of keywords with capturecat.so in Google's organic top 10. */
  googleTop10: number | null;
  byEngine: Partial<Record<EngineId, RateTriple>>;
}

/**
 * Non-branded only: a brand question ("What is CaptureCat?") naming us says
 * nothing about whether we get recommended. Each question counts once per
 * engine (its samples are averaged first), so an engine asked three times
 * doesn't outweigh one asked once.
 */
export function runMetrics(
  rows: Array<{ questionId: string; engine: EngineId; status: string; mentioned: boolean | null; cited: boolean | null; rank: number | null }>,
  branded: Set<string>,
): RunMetrics {
  const per = new Map<string, { engine: EngineId; n: number; m: number; c: number; rank: number | null }>();
  for (const r of rows) {
    if (r.status !== "ok" || branded.has(r.questionId)) continue;
    const k = `${r.questionId}|${r.engine}`;
    const cur = per.get(k) ?? { engine: r.engine, n: 0, m: 0, c: 0, rank: null };
    cur.n += 1;
    cur.m += r.mentioned ? 1 : 0;
    cur.c += r.cited ? 1 : 0;
    if (r.rank != null) cur.rank = cur.rank == null ? r.rank : Math.min(cur.rank, r.rank);
    per.set(k, cur);
  }
  const triple = (xs: Array<{ n: number; m: number; c: number }>): RateTriple =>
    xs.length === 0
      ? { mentionRate: null, citationRate: null, answers: 0 }
      : {
          mentionRate: xs.reduce((s, x) => s + x.m / x.n, 0) / xs.length,
          citationRate: xs.reduce((s, x) => s + x.c / x.n, 0) / xs.length,
          answers: xs.length,
        };
  const values = [...per.values()];
  const aiValues = values.filter((v) => v.engine !== "google");
  const googleValues = values.filter((v) => v.engine === "google");
  const byEngine: RunMetrics["byEngine"] = {};
  for (const e of ENGINE_IDS) {
    const xs = values.filter((v) => v.engine === e);
    if (xs.length) byEngine[e] = triple(xs);
  }
  return {
    ...triple(aiValues),
    googleTop10: googleValues.length
      ? googleValues.filter((v) => v.rank != null && v.rank <= 10).length / googleValues.length
      : null,
    byEngine,
  };
}
