/**
 * AI search engines: one adapter per engine, each turning a question into a
 * normalised EngineAnswer (analyze.ts). Each engine takes the best route the
 * Worker has, so the same five ids stay comparable across runs:
 *
 *   gemini      AI Gateway (the `AI` binding, Unified Billing: no provider
 *               key), else GEMINI_API_KEY directly. Gemini with the Google
 *               Search grounding tool, and the pages it used.
 *   chatgpt     DataForSEO's ChatGPT scraper (the consumer app's answer) when
 *               DATAFORSEO_LOGIN/PASSWORD are set, else the OpenAI Responses
 *               API with web search through AI Gateway.
 *   claude      DataForSEO when set, else Claude with web search through AI
 *               Gateway.
 *   perplexity  DataForSEO only (not in AI Gateway's Unified Billing).
 *   google      DataForSEO only: Google organic top 20 + the AI Overview.
 *
 * The route that answered is recorded on every result as its model, so a
 * change of route shows in the history instead of passing for a trend.
 *
 * Errors: RetryLater means "the engine is busy, not this question's fault".
 * A rate limit puts the job back with its attempt refunded; an overloaded or
 * failing upstream puts it back but spends the attempt, so a provider that
 * stays down ends in an error instead of looping. Anything else is recorded
 * on the answer as its error.
 */

import type { Env } from "../../types";
import { domainOf, type AnswerSource, type EngineAnswer, type EngineId } from "./analyze";

export interface EngineInfo {
  id: EngineId;
  label: string;
  kind: "ai" | "search";
  /** Times each question is asked per run: AI answers vary, so a rate needs samples. */
  samples: number;
  /** Jobs in flight at once for this engine within one invocation. */
  concurrency: number;
}

export const ENGINES: EngineInfo[] = [
  { id: "chatgpt", label: "ChatGPT", kind: "ai", samples: 1, concurrency: 3 },
  // The cheapest engine by far (~$0.005 an answer), so asked three times.
  // One at a time: a direct free-tier key allows only ~10 requests a minute.
  { id: "gemini", label: "Gemini", kind: "ai", samples: 3, concurrency: 1 },
  { id: "perplexity", label: "Perplexity", kind: "ai", samples: 1, concurrency: 3 },
  { id: "claude", label: "Claude", kind: "ai", samples: 1, concurrency: 3 },
  { id: "google", label: "Google", kind: "search", samples: 1, concurrency: 3 },
];

export function engineInfo(id: EngineId): EngineInfo {
  return ENGINES.find((e) => e.id === id)!;
}

export type RouteVia = "dataforseo" | "gateway" | "gemini-key";

export interface Route {
  via: RouteVia;
  /** What answers, in words, for the admin page. */
  label: string;
}

const hasDataForSeo = (env: Env) => !!(env.DATAFORSEO_LOGIN && env.DATAFORSEO_PASSWORD);
const hasGateway = (env: Env) => !!env.AI;

const geminiModel = (env: Env) => env.AI_SEARCH_GEMINI_MODEL || "gemini-flash-latest";
const openAiModel = (env: Env) => env.AI_SEARCH_OPENAI_MODEL || "gpt-5.1";
const claudeModel = (env: Env) => env.AI_SEARCH_CLAUDE_MODEL || "claude-sonnet-5-5";

/** How this Worker would ask `engine`, or null when it can't. */
export function engineRoute(env: Env, engine: EngineId): Route | null {
  switch (engine) {
    case "gemini":
      if (hasGateway(env)) return { via: "gateway", label: `${geminiModel(env)} + Google Search, via AI Gateway` };
      if (env.GEMINI_API_KEY) return { via: "gemini-key", label: `${geminiModel(env)} + Google Search` };
      return null;
    case "chatgpt":
      if (hasDataForSeo(env)) return { via: "dataforseo", label: "The ChatGPT app, via DataForSEO" };
      if (hasGateway(env)) return { via: "gateway", label: `OpenAI ${openAiModel(env)} + web search, via AI Gateway` };
      return null;
    case "claude":
      if (hasDataForSeo(env)) return { via: "dataforseo", label: "Claude with web search, via DataForSEO" };
      if (hasGateway(env)) return { via: "gateway", label: `${claudeModel(env)} + web search, via AI Gateway` };
      return null;
    case "perplexity":
      return hasDataForSeo(env) ? { via: "dataforseo", label: "Perplexity Sonar, via DataForSEO" } : null;
    case "google":
      return hasDataForSeo(env) ? { via: "dataforseo", label: "Google organic + AI Overview, via DataForSEO" } : null;
  }
}

export function engineConfigured(env: Env, e: EngineInfo): boolean {
  return engineRoute(env, e.id) !== null;
}

/** The engine was busy. `refund`: a rate limit, not a failed attempt. */
export class RetryLater extends Error {
  constructor(message: string, readonly refund: boolean) {
    super(message);
  }
}

/** 429 → retry, attempt refunded; overloaded/unavailable upstream → retry, attempt spent. */
function retryFor(status: number, what: string): RetryLater | null {
  if (status === 429) return new RetryLater(`${what} HTTP 429`, true);
  if (status === 502 || status === 503 || status === 504 || status === 529) return new RetryLater(`${what} HTTP ${status}`, false);
  return null;
}

const US = { location_code: 2840, language_code: "en" } as const;

export async function askEngine(env: Env, engine: EngineId, prompt: string): Promise<EngineAnswer> {
  const route = engineRoute(env, engine);
  if (!route) throw new Error("Engine not configured");
  switch (engine) {
    case "gemini":
      return askGemini(env, prompt, route.via === "gateway");
    case "chatgpt":
      return route.via === "dataforseo" ? askChatGpt(env, prompt) : askOpenAi(env, prompt);
    case "claude":
      return route.via === "dataforseo"
        ? askLlmResponses(env, "claude", prompt, {
            model_name: claudeModel(env),
            web_search: true,
            force_web_search: true,
            web_search_country_iso_code: "US",
          })
        : askAnthropic(env, prompt);
    case "perplexity":
      return askLlmResponses(env, "perplexity", prompt, {
        model_name: env.AI_SEARCH_PERPLEXITY_MODEL || "sonar",
        web_search_country_iso_code: "US",
      });
    case "google":
      return askGoogle(env, prompt);
  }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

const str = (v: unknown): string => (typeof v === "string" ? v : "");
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const rec = (v: unknown): Record<string, unknown> => (v && typeof v === "object" ? (v as Record<string, unknown>) : {});
const strings = (v: unknown): string[] => arr(v).filter((x): x is string => typeof x === "string");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Drop utm_* tags (OpenAI adds `utm_source=openai` to every citation). */
export function stripTracking(url: string): string {
  try {
    const u = new URL(url);
    for (const k of [...u.searchParams.keys()]) if (/^utm_/i.test(k)) u.searchParams.delete(k);
    return u.toString();
  } catch {
    return url;
  }
}

export function dedupeSources(xs: AnswerSource[]): AnswerSource[] {
  const seen = new Set<string>();
  return xs
    .map((s) => ({ ...s, url: stripTracking(s.url) }))
    .filter((s) => {
      const k = s.url.replace(/#.*$/, "").replace(/\/$/, "");
      if (seen.has(k) || !domainOf(s.url)) return false;
      seen.add(k);
      return true;
    });
}

/** Every {url, title} object found under a key named `key`, anywhere in `root`, in document order. */
export function collectLinks(root: unknown, key: string): AnswerSource[] {
  const out: AnswerSource[] = [];
  const walk = (node: unknown, depth: number) => {
    if (depth > 8 || !node || typeof node !== "object") return;
    if (Array.isArray(node)) {
      for (const n of node) walk(n, depth + 1);
      return;
    }
    for (const [k, v] of Object.entries(node)) {
      if (k === key) {
        for (const item of arr(v)) {
          const o = rec(item);
          if (typeof o.url === "string" && /^https?:\/\//.test(o.url)) out.push({ url: o.url, title: str(o.title) || str(o.source) });
        }
      } else {
        walk(v, depth + 1);
      }
    }
  };
  walk(root, 0);
  return out;
}

// ---------------------------------------------------------------------------
// AI Gateway (the `AI` binding): provider-native requests, Unified Billing
// ---------------------------------------------------------------------------

async function viaGateway(
  env: Env,
  provider: "google-ai-studio" | "openai" | "anthropic",
  endpoint: string,
  body: unknown,
  headers: Record<string, string> = {},
): Promise<{ data: Record<string, unknown>; cost: number }> {
  const gw = env.AI!.gateway(env.AI_GATEWAY_ID || "default");
  const res = await gw.run(
    { provider, endpoint, headers: { "Content-Type": "application/json", ...headers }, query: body },
    { signal: AbortSignal.timeout(150_000) },
  );
  const what = `${provider} via AI Gateway`;
  const retry = retryFor(res.status, what);
  if (retry) {
    await res.body?.cancel();
    throw retry;
  }
  if (!res.ok) throw new Error(`${what} HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const data = rec(await res.json());
  return { data, cost: await gatewayCost(gw, res.headers.get("cf-aig-log-id")) };
}

/**
 * What the gateway charged, from its log. The log is written just after the
 * response, so the first read can miss it; two short retries, then 0 (the
 * gateway dashboard still has the true figure).
 */
async function gatewayCost(gw: AiGateway, logId: string | null): Promise<number> {
  if (!logId) return 0;
  for (const wait of [0, 1500, 3000]) {
    if (wait) await sleep(wait);
    try {
      const log = await gw.getLog(logId);
      if (typeof log.cost === "number") return log.cost;
    } catch {
      // not written yet
    }
  }
  return 0;
}

// ---------------------------------------------------------------------------
// Gemini: generateContent with the google_search grounding tool
// ---------------------------------------------------------------------------

/** Grounding chunk links are vertexaisearch redirects; resolve this many per answer. */
const MAX_RESOLVED_SOURCES = 10;

async function askGemini(env: Env, prompt: string, gateway: boolean): Promise<EngineAnswer> {
  // "-latest" on purpose: the point is what Gemini users get today, and the
  // model that answered is recorded on every result.
  const model = geminiModel(env);
  const body = { contents: [{ role: "user", parts: [{ text: prompt }] }], tools: [{ google_search: {} }] };
  let data: Record<string, unknown>;
  let cost = 0;
  if (gateway) {
    ({ data, cost } = await viaGateway(env, "google-ai-studio", `v1beta/models/${model}:generateContent`, body));
  } else {
    const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": env.GEMINI_API_KEY! },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(90_000),
    });
    const retry = retryFor(res.status, "Gemini");
    if (retry) throw retry;
    if (!res.ok) throw new Error(`Gemini HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
    data = rec(await res.json());
  }
  const parsed = parseGemini(data, cost);
  // Resolve the grounding redirects to the pages themselves.
  const sources: AnswerSource[] = [];
  for (const s of parsed.sources.slice(0, MAX_RESOLVED_SOURCES)) {
    const label = s.title;
    const url = (await resolveRedirect(s.url)) ?? (/^[a-z0-9.-]+\.[a-z]{2,}$/i.test(label) ? `https://${label}/` : s.url);
    sources.push({ url, title: s.title });
  }
  return { ...parsed, sources: dedupeSources(sources) };
}

/** A generateContent response → answer, with grounding links still as redirects. */
export function parseGemini(data: Record<string, unknown>, cost: number): EngineAnswer {
  const cand = rec(arr(data.candidates)[0]);
  const meta = rec(cand.groundingMetadata);
  const text = arr(rec(cand.content).parts).map((p) => str(rec(p).text)).join("");
  const sources = arr(meta.groundingChunks)
    .map((c) => rec(rec(c).web))
    .filter((w) => typeof w.uri === "string")
    .map((w) => ({ url: str(w.uri), title: str(w.domain) || str(w.title) }));
  return { model: str(data.modelVersion) || null, text, sources, queries: strings(meta.webSearchQueries), costUsd: cost };
}

/** The Location of a grounding redirect, without following it; null on any failure. */
async function resolveRedirect(uri: string): Promise<string | null> {
  if (!/^https:\/\/vertexaisearch\.cloud\.google\.com\//.test(uri)) return uri;
  try {
    const res = await fetch(uri, { method: "GET", redirect: "manual", signal: AbortSignal.timeout(10_000) });
    const loc = res.headers.get("location");
    await res.body?.cancel();
    return loc && /^https?:\/\//.test(loc) ? loc : null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// OpenAI Responses API + web search (AI Gateway)
// ---------------------------------------------------------------------------

async function askOpenAi(env: Env, prompt: string): Promise<EngineAnswer> {
  const { data, cost } = await viaGateway(env, "openai", "responses", {
    model: openAiModel(env),
    input: prompt,
    tools: [{ type: "web_search" }],
  });
  return parseOpenAiResponse(data, cost);
}

export function parseOpenAiResponse(data: Record<string, unknown>, cost: number): EngineAnswer {
  const output = arr(data.output).map(rec);
  const parts = output
    .filter((o) => o.type === "message")
    .flatMap((m) => arr(m.content).map(rec))
    .filter((c) => c.type === "output_text");
  const sources = parts.flatMap((p) =>
    arr(p.annotations).map(rec).filter((a) => a.type === "url_citation" && typeof a.url === "string").map((a) => ({ url: str(a.url), title: str(a.title) })),
  );
  const queries = output
    .filter((o) => o.type === "web_search_call")
    .flatMap((o) => {
      const action = rec(o.action);
      const qs = strings(action.queries);
      return qs.length ? qs : str(action.query) ? [str(action.query)] : [];
    });
  return {
    model: str(data.model) || null,
    text: parts.map((p) => str(p.text)).join("\n\n"),
    sources: dedupeSources(sources),
    queries: [...new Set(queries)],
    costUsd: cost,
  };
}

// ---------------------------------------------------------------------------
// Anthropic Messages API + web search (AI Gateway)
// ---------------------------------------------------------------------------

async function askAnthropic(env: Env, prompt: string): Promise<EngineAnswer> {
  const { data, cost } = await viaGateway(
    env,
    "anthropic",
    "v1/messages",
    {
      model: claudeModel(env),
      max_tokens: 2500,
      messages: [{ role: "user", content: prompt }],
      tools: [{ type: "web_search_20250305", name: "web_search", max_uses: 5 }],
    },
    { "anthropic-version": "2023-06-01" },
  );
  return parseAnthropic(data, cost);
}

export function parseAnthropic(data: Record<string, unknown>, cost: number): EngineAnswer {
  const blocks = arr(data.content).map(rec);
  const textBlocks = blocks.filter((b) => b.type === "text");
  const cited = textBlocks.flatMap((b) =>
    arr(b.citations).map(rec).filter((c) => typeof c.url === "string").map((c) => ({ url: str(c.url), title: str(c.title) })),
  );
  // No inline citations: the pages it searched are the best evidence of what it read.
  const searched = blocks
    .filter((b) => b.type === "web_search_tool_result")
    .flatMap((b) => arr(b.content).map(rec))
    .filter((r) => typeof r.url === "string")
    .map((r) => ({ url: str(r.url), title: str(r.title) }));
  return {
    model: str(data.model) || null,
    text: textBlocks.map((b) => str(b.text)).join(""),
    sources: dedupeSources(cited.length ? cited : searched),
    queries: blocks.filter((b) => b.type === "server_tool_use").map((b) => str(rec(b.input).query)).filter(Boolean),
    costUsd: cost,
  };
}

// ---------------------------------------------------------------------------
// DataForSEO
// ---------------------------------------------------------------------------

interface DfsEnvelope {
  status_code?: number;
  status_message?: string;
  tasks?: Array<{ status_code?: number; status_message?: string; cost?: number; result?: unknown[] | null }>;
}

async function dataForSeo(env: Env, path: string, task: Record<string, unknown>): Promise<{ result: Record<string, unknown>; cost: number }> {
  const res = await fetch(`https://api.dataforseo.com${path}`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${btoa(`${env.DATAFORSEO_LOGIN}:${env.DATAFORSEO_PASSWORD}`)}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify([task]),
    // Live LLM endpoints take up to 120 s.
    signal: AbortSignal.timeout(150_000),
  });
  const retry = retryFor(res.status, "DataForSEO");
  if (retry) throw retry;
  if (!res.ok) throw new Error(`DataForSEO HTTP ${res.status}`);
  const body = (await res.json()) as DfsEnvelope;
  if (body.status_code !== 20000) throw new Error(`DataForSEO: ${body.status_message ?? body.status_code}`);
  const t = body.tasks?.[0];
  // 40202: too many concurrent live tasks.
  if (t?.status_code === 40202) throw new RetryLater(`DataForSEO: ${t.status_message}`, true);
  if (!t || t.status_code !== 20000) throw new Error(`DataForSEO: ${t?.status_message ?? "no task"}`);
  const result = (t.result?.[0] ?? null) as Record<string, unknown> | null;
  if (!result) throw new Error("DataForSEO: empty result");
  return { result, cost: t.cost ?? 0 };
}

async function askChatGpt(env: Env, prompt: string): Promise<EngineAnswer> {
  const { result, cost } = await dataForSeo(env, "/v3/ai_optimization/chat_gpt/llm_scraper/live/advanced", {
    keyword: prompt,
    ...US,
    force_web_search: true,
  });
  return parseChatGpt(result, cost);
}

export function parseChatGpt(result: Record<string, unknown>, cost: number): EngineAnswer {
  const items = arr(result.items).map(rec);
  const text = str(result.markdown) || items.map((i) => str(i.markdown) || str(i.text)).filter(Boolean).join("\n\n");
  const cited = arr(result.sources).length ? collectLinks({ sources: result.sources }, "sources") : collectLinks(items, "sources");
  const brandSrc = arr(result.brand_entities).length ? arr(result.brand_entities) : items.flatMap((i) => arr(i.brand_entities));
  return {
    model: str(result.model) || null,
    text,
    sources: dedupeSources(cited),
    brands: brandSrc.map((b) => str(rec(b).title)).filter(Boolean),
    queries: strings(result.fan_out_queries),
    costUsd: cost,
  };
}

async function askLlmResponses(
  env: Env,
  platform: "perplexity" | "claude",
  prompt: string,
  extra: Record<string, unknown>,
): Promise<EngineAnswer> {
  const { result, cost } = await dataForSeo(env, `/v3/ai_optimization/${platform}/llm_responses/live`, {
    user_prompt: prompt.slice(0, 500),
    ...extra,
  });
  return parseLlmResponse(result, cost);
}

export function parseLlmResponse(result: Record<string, unknown>, cost: number): EngineAnswer {
  const messages = arr(result.items).map(rec).filter((i) => i.type === "message");
  const text = messages
    .flatMap((m) => arr(m.sections).map(rec))
    .filter((s) => s.type === undefined || s.type === "text")
    .map((s) => str(s.text))
    .join("");
  const annotations = collectLinks(messages, "annotations");
  // Some answers carry no annotations; then the pages it searched are the best evidence of what it read.
  const sources = annotations.length ? annotations : collectLinks(result, "search_results");
  return {
    model: str(result.model_name) || null,
    text,
    sources: dedupeSources(sources),
    queries: strings(result.fan_out_queries),
    costUsd: cost,
  };
}

async function askGoogle(env: Env, keyword: string): Promise<EngineAnswer> {
  const { result, cost } = await dataForSeo(env, "/v3/serp/google/organic/live/advanced", {
    keyword,
    ...US,
    depth: 20,
    load_async_ai_overview: true,
  });
  return parseGoogle(result, cost);
}

export function parseGoogle(result: Record<string, unknown>, cost: number): EngineAnswer {
  const items = arr(result.items).map(rec);
  const organic = items
    .filter((i) => i.type === "organic" && typeof i.url === "string")
    .sort((a, b) => Number(a.rank_group ?? 0) - Number(b.rank_group ?? 0))
    .map((i) => ({ url: str(i.url), title: str(i.title) }));
  const overview = items.find((i) => i.type === "ai_overview");
  const overviewText = overview
    ? str(overview.markdown) || arr(overview.items).map((e) => str(rec(e).markdown) || str(rec(e).text)).join("\n\n")
    : "";
  return {
    model: null,
    text: overviewText,
    sources: dedupeSources(organic),
    overviewSources: overview ? dedupeSources(collectLinks(overview, "references")) : [],
    queries: [],
    costUsd: cost,
  };
}
