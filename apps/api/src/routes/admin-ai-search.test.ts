/**
 * Admin → AI search through the WHOLE Worker (index.ts: CORS, mounts,
 * requireAuth, the admin gate), the real migrations (0041 included, with its
 * starter questions) and a fake session (`Bearer <uid>`). Gemini, its
 * grounding redirects and capturecat.so are faked at `fetch`.
 *
 * What must hold: only admins get in; a run queues question × engine ×
 * sample and refuses to start twice; the queue drains to a finished run with
 * the right rates; a lost question gets the right cause (missing page, crawl,
 * third-party); rate limits put the job back without spending an attempt;
 * the schedule starts a run only when one is due.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";
import { maybeStartScheduledRun, processQueue } from "../lib/ai-search/runner";
import type { AiSearchOverview, QuestionDetail } from "../lib/ai-search/overview";

vi.mock("cloudflare:workers", () => ({ DurableObject: class {} }));
vi.mock("../lib/auth", () => import("../test-support/fake-session"));
vi.stubGlobal("caches", { default: { match: async () => undefined, put: async () => undefined, delete: async () => true } });

// --- the fake internet -------------------------------------------------------
let geminiCalls = 0;
let gemini429 = 0;
const page = (path: string, words = 500) =>
  `<html><head><link rel="canonical" href="https://capturecat.so${path === "/" ? "" : path}"/></head><body>${"word ".repeat(words)}</body></html>`;

function geminiAnswer(prompt: string) {
  // The open-source question is "won": named first and our page cited.
  const won = /open-source/.test(prompt);
  const text = won
    ? "CaptureCat is open source. OBS Studio is another option."
    : "Popular choices are Loom and OBS Studio.";
  const chunks = won
    ? [{ web: { uri: "https://vertexaisearch.cloud.google.com/grounding-api-redirect/own", title: "capturecat.so" } }]
    : [
        { web: { uri: "https://vertexaisearch.cloud.google.com/grounding-api-redirect/alt", title: "alternativeto.net" } },
        { web: { uri: "https://vertexaisearch.cloud.google.com/grounding-api-redirect/rd", title: "reddit.com" } },
      ];
  return { modelVersion: "gemini-test-001", candidates: [{ content: { parts: [{ text }] }, groundingMetadata: { webSearchQueries: [prompt.toLowerCase()], groundingChunks: chunks } }] };
}

const fakeFetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  if (url.startsWith("https://generativelanguage.googleapis.com/")) {
    geminiCalls++;
    if (gemini429 > 0) {
      gemini429--;
      return new Response("slow down", { status: 429 });
    }
    const body = JSON.parse(String(init?.body));
    return Response.json(geminiAnswer(body.contents[0].parts[0].text));
  }
  if (url.startsWith("https://vertexaisearch.cloud.google.com/")) {
    const to = { own: "https://capturecat.so/best/open-source-screen-recorders", alt: "https://alternativeto.net/software/kap/", rd: "https://www.reddit.com/r/macapps/comments/1/" }[url.split("/").pop()!];
    return new Response(null, { status: 302, headers: { Location: to! } });
  }
  if (url === "https://capturecat.so/robots.txt") return new Response("User-agent: *\nAllow: /\nDisallow: /app\n");
  if (url === "https://capturecat.so/sitemap.xml") {
    return new Response(`<urlset><url><loc>https://capturecat.so/best/screen-recorder-for-mac</loc></url><url><loc>https://capturecat.so/best/open-source-screen-recorders</loc></url></urlset>`);
  }
  if (url.startsWith("https://capturecat.so")) {
    const path = new URL(url).pathname;
    if (path === "/guides/record-iphone-screen-on-mac") return new Response("gone", { status: 404 });
    return new Response(page(path));
  }
  return new Response("offline test", { status: 500 });
});
vi.stubGlobal("fetch", fakeFetch);

const { default: worker } = await import("../index");

const ADMIN = "admin-user";
const USER = "plain-user";
let db: TestD1;
let env: Env;
let pending: Promise<unknown>[] = [];

function addUser(id: string, email: string, role = "user") {
  const iso = new Date().toISOString();
  db.query(
    `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked, role)
     VALUES (?, ?, ?, 1, ?, ?, 0, 0, ?)`,
    id, email.split("@")[0], email, iso, iso, role,
  );
}

beforeEach(() => {
  db = createTestD1();
  env = { DB: db, BETTER_AUTH_URL: "http://localhost:8787" } as unknown as Env;
  addUser(ADMIN, "owner@test.local", "admin");
  addUser(USER, "someone@test.local");
  geminiCalls = 0;
  gemini429 = 0;
  pending = [];
});

async function call(method: string, path: string, body?: unknown, as: string | null = ADMIN) {
  const res = await worker.fetch(
    new Request(`http://localhost:8787/api${path}`, {
      method,
      headers: {
        ...(as ? { Authorization: `Bearer ${as}` } : {}),
        ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    }),
    env,
    { waitUntil: (p: Promise<unknown>) => pending.push(p), passThroughOnException() {} } as unknown as ExecutionContext,
  );
  // Settle anything the route kicked off before the test looks at the DB.
  await Promise.all(pending);
  pending = [];
  return res;
}

const overview = async () => (await (await call("GET", "/admin/ai-search")).json()) as AiSearchOverview;

describe("access", () => {
  it("is admin-only and answers 404 to everyone else", async () => {
    expect((await call("GET", "/admin/ai-search", undefined, USER)).status).toBe(404);
    expect((await call("GET", "/admin/ai-search", undefined, null)).status).toBe(401);
    expect((await call("GET", "/admin/ai-search")).status).toBe(200);
  });
});

describe("before any run", () => {
  it("lists the starter questions, unmeasured, with no engine configured", async () => {
    const o = await overview();
    expect(o.questions).toHaveLength(29);
    expect(o.questions.filter((q) => q.branded)).toHaveLength(3);
    expect(o.questions.every((q) => q.diagnosis.status === "unmeasured")).toBe(true);
    expect(o.engines.every((e) => !e.configured)).toBe(true);
    expect(o.schedule.nextDueAt).toBeNull();
    expect(o.traffic).toHaveLength(8);
  });

  it("won't start a run without an engine", async () => {
    const res = await call("POST", "/admin/ai-search/runs");
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: string }).error).toMatch(/No engine is configured/);
  });
});

describe("a run with Gemini", () => {
  beforeEach(() => {
    env.GEMINI_API_KEY = "test-key";
  });

  it("queues every active question three times, refuses a second run, and drains to done", async () => {
    // Retire one question first: it must not be asked.
    expect((await call("PATCH", "/admin/ai-search/questions/brand-windows", { active: false })).status).toBe(200);

    const start = await call("POST", "/admin/ai-search/runs");
    expect(start.status).toBe(202);
    const { runId, jobs } = (await start.json()) as { runId: string; jobs: number };
    expect(jobs).toBe(28 * 3);
    // The kick answered a few already (12 at most).
    expect(geminiCalls).toBeGreaterThan(0);
    expect(geminiCalls).toBeLessThanOrEqual(12);

    const again = await call("POST", "/admin/ai-search/runs");
    expect(again.status).toBe(409);
    expect(((await again.json()) as { runId: string }).runId).toBe(runId);

    const report = await processQueue(env, { budgetMs: 60_000, maxJobs: 1000 });
    expect(report.failed).toBe(0);
    expect(report.finishedRuns).toBe(1);

    const o = await overview();
    const run = o.runs[0];
    expect(run).toMatchObject({ id: runId, kind: "manual", status: "done", engines: ["gemini"] });
    expect(run.jobs).toEqual({ total: 84, done: 84, failed: 0 });
    // 26 non-branded questions (the retired one was branded); only the open-source one names us.
    expect(run.metrics.answers).toBe(26);
    expect(run.metrics.mentionRate).toBeCloseTo(1 / 26);
    expect(run.metrics.citationRate).toBeCloseTo(1 / 26);
    expect(run.metrics.googleTop10).toBeNull();
  });

  it("diagnoses each question and builds the source list", async () => {
    // Every starter question has a page; take one away to see a missing page diagnosed.
    expect((await call("PATCH", "/admin/ai-search/questions/tut-tool", { targetPath: null })).status).toBe(200);
    await call("POST", "/admin/ai-search/runs");
    await processQueue(env, { budgetMs: 60_000, maxJobs: 1000 });
    const o = await overview();
    const q = (id: string) => o.questions.find((x) => x.id === id)!;

    expect(q("mac-open-source").diagnosis.status).toBe("winning");
    expect(q("mac-open-source").latest.gemini).toMatchObject({ samples: 3, ok: 3, mentionRate: 1, citationRate: 1, rank: 1 });

    // No page targets it → missing page, ahead of the third-party cause.
    expect(q("tut-tool").diagnosis.causes.map((c) => c.code)).toEqual(["missing_page", "third_party"]);
    // Its target page 404s → crawl problem first.
    expect(q("other-iphone").diagnosis.causes[0]).toMatchObject({ code: "crawl", detail: expect.stringMatching(/answers HTTP 404/) });
    // A healthy page nobody cites → weak page, with the sources named.
    const best = q("mac-best").diagnosis;
    expect(best.status).toBe("losing");
    expect(best.causes.map((c) => c.code)).toEqual(["weak_page", "third_party"]);
    expect(best.topSources.map((s) => s.domain)).toEqual(["alternativeto.net", "reddit.com"]);
    expect(best.action).toMatch(/^Improve \/best\/screen-recorder-for-mac/);

    // Crawl checks: one per distinct target path; the sitemap only lists two.
    const pages = new Map(o.pages.map((p) => [p.path, p]));
    expect(pages.get("/best/screen-recorder-for-mac")?.problems).toEqual([]);
    expect(pages.get("/guides/record-iphone-screen-on-mac")?.problems).toEqual(["answers HTTP 404", "not in sitemap.xml"]);

    // Sources: the first-pass decisions seeded by 0041 apply; anything else is a suggestion.
    const alt = o.sources.find((s) => s.key === "alternativeto.net")!;
    expect(alt).toMatchObject({ kind: "claim", suggested: false, status: "todo" });
    expect(alt.aiCitations).toBe(28 * 3); // three answers to each of the 28 lost questions (the won one cites us)
    expect(alt.topUrls).toEqual(["https://alternativeto.net/software/kap/"]);
    expect(o.sources.find((s) => s.key === "reddit.com")).toMatchObject({ kind: "earn", suggested: false });
    expect(o.sources.find((s) => s.key === "capturecat.so")).toMatchObject({ kind: "own" });

    // Record a decision; it replaces the suggestion and keeps unchanged fields on the next write.
    expect((await call("PUT", "/admin/ai-search/sources", { key: "alternativeto.net", kind: "claim", status: "doing", nextStep: "Submit the listing", url: "https://alternativeto.net/software/capturecat/" })).status).toBe(200);
    expect((await call("PUT", "/admin/ai-search/sources", { key: "alternativeto.net", kind: "claim", status: "done" })).status).toBe(200);
    const after = (await overview()).sources.find((s) => s.key === "alternativeto.net")!;
    expect(after).toMatchObject({ suggested: false, status: "done", nextStep: "Submit the listing", url: "https://alternativeto.net/software/capturecat/" });

    // A decision with no citations yet still shows on the to-do list (seeded or new).
    expect(o.sources.find((s) => s.key === "producthunt.com")).toMatchObject({ aiCitations: 0, status: "todo", suggested: false });
    await call("PUT", "/admin/ai-search/sources", { key: "uneed.best", kind: "claim" });
    expect((await overview()).sources.find((s) => s.key === "uneed.best")).toMatchObject({ aiCitations: 0, status: "todo", suggested: false, nextStep: expect.stringMatching(/claim the CaptureCat listing/) });
    // Here every cited third party was seeded; only our own domain is classified by suggestion.
    expect(o.sources.filter((s) => s.suggested).map((s) => s.key)).toEqual(["capturecat.so"]);

    // The question detail carries full answers with classified sources.
    const detail = (await (await call("GET", "/admin/ai-search/questions/mac-best")).json()) as QuestionDetail;
    expect(detail.answers).toHaveLength(3);
    expect(detail.answers[0]).toMatchObject({ engine: "gemini", model: "gemini-test-001", mentioned: false, brands: ["Loom", "OBS Studio"] });
    expect(detail.answers[0].sources.map((s) => [s.domain, s.kind])).toEqual([["alternativeto.net", "claim"], ["reddit.com", "earn"]]);
    expect((await call("GET", "/admin/ai-search/questions/nope")).status).toBe(404);
  });

  it("a rate limit puts the job back without spending an attempt", async () => {
    await call("POST", "/admin/ai-search/runs");
    gemini429 = 1;
    const r = await processQueue(env, { budgetMs: 60_000, maxJobs: 1 });
    expect(r).toMatchObject({ answered: 0, failed: 0 });
    const row = db.query("SELECT status, attempts FROM ai_search_results WHERE status != 'ok' ORDER BY question_id, sample LIMIT 1")[0];
    expect(row).toEqual({ status: "pending", attempts: 0 });
  });

  it("the schedule starts a run when one is due, and not again inside the window", async () => {
    expect(await maybeStartScheduledRun(env, Date.now())).toEqual(expect.any(String));
    db.query("UPDATE ai_search_runs SET status = 'done'");
    expect(await maybeStartScheduledRun(env, Date.now() + 6 * 86_400_000)).toBeNull();
    expect(await maybeStartScheduledRun(env, Date.now() + 8 * 86_400_000)).toEqual(expect.any(String));
    env.AI_SEARCH_SCHEDULE_DAYS = "0";
    db.query("UPDATE ai_search_runs SET status = 'done'");
    expect(await maybeStartScheduledRun(env, Date.now() + 30 * 86_400_000)).toBeNull();
  });
});

describe("a run through AI Gateway (the AI binding)", () => {
  let anthropic503 = 0;
  const gatewayCalls: string[] = [];
  const fakeAi = {
    gateway: (id: string) => ({
      async run(req: { provider: string; endpoint: string; query: Record<string, unknown> }) {
        gatewayCalls.push(`${id}:${req.provider}:${req.endpoint}`);
        const headers = { "cf-aig-log-id": `log-${gatewayCalls.length}` };
        if (req.provider === "google-ai-studio") {
          const q = req.query as { contents: Array<{ parts: Array<{ text: string }> }>; tools: unknown[] };
          expect(q.tools).toEqual([{ google_search: {} }]);
          return Response.json(geminiAnswer(q.contents[0].parts[0].text), { headers });
        }
        if (req.provider === "openai") {
          const q = req.query as { input: string; tools: unknown[] };
          expect(q.tools).toEqual([{ type: "web_search" }]);
          const won = /open-source/.test(q.input);
          return Response.json({
            model: "gpt-5.1-test",
            output: [
              { type: "web_search_call", action: { type: "search", query: q.input.toLowerCase() } },
              { type: "message", content: [{ type: "output_text", text: won ? "CaptureCat is open source." : "Loom is popular.", annotations: [{ type: "url_citation", url: won ? "https://capturecat.so/best/open-source-screen-recorders?utm_source=openai" : "https://toolradar.com/x?utm_source=openai", title: "T" }] }] },
            ],
          }, { headers });
        }
        if (req.provider === "anthropic") {
          if (anthropic503 > 0) {
            anthropic503--;
            return new Response("overloaded", { status: 503 });
          }
          return Response.json({
            model: "claude-sonnet-5-5",
            content: [
              { type: "server_tool_use", input: { query: "q" } },
              { type: "web_search_tool_result", content: [{ type: "web_search_result", url: "https://setapp.com/a", title: "Setapp" }] },
              { type: "text", text: "Try OBS Studio.", citations: [{ type: "web_search_result_location", url: "https://setapp.com/a", title: "Setapp" }] },
            ],
          }, { headers });
        }
        return new Response("unknown provider", { status: 400 });
      },
      async getLog() {
        return { cost: 0.01 };
      },
    }),
  };

  beforeEach(() => {
    env.AI = fakeAi as unknown as Ai;
    anthropic503 = 0;
    gatewayCalls.length = 0;
  });

  it("asks Gemini, OpenAI and Claude through the default gateway, with no provider keys", async () => {
    const o0 = await overview();
    expect(o0.engines.map((e) => [e.id, e.via])).toEqual([["chatgpt", "gateway"], ["gemini", "gateway"], ["perplexity", null], ["claude", "gateway"], ["google", null]]);

    const start = await call("POST", "/admin/ai-search/runs");
    expect(start.status).toBe(202);
    expect(((await start.json()) as { jobs: number }).jobs).toBe(29 * 5);
    await processQueue(env, { budgetMs: 60_000, maxJobs: 1000 });

    expect(new Set(gatewayCalls.map((c) => c.split(":").slice(0, 2).join(":")))).toEqual(
      new Set(["default:google-ai-studio", "default:openai", "default:anthropic"]),
    );
    const o = await overview();
    const run = o.runs[0];
    expect(run).toMatchObject({ status: "done", engines: ["chatgpt", "gemini", "claude"] });
    expect(run.jobs).toEqual({ total: 145, done: 145, failed: 0 });
    expect(run.costUsd).toBeCloseTo(145 * 0.01);
    expect(run.metrics.byEngine.chatgpt?.mentionRate).toBeCloseTo(1 / 26);
    expect(run.metrics.byEngine.claude?.mentionRate).toBe(0);

    const detail = (await (await call("GET", "/admin/ai-search/questions/mac-open-source")).json()) as QuestionDetail;
    const chatgpt = detail.answers.find((a) => a.engine === "chatgpt")!;
    expect(chatgpt).toMatchObject({ model: "gpt-5.1-test", mentioned: true, cited: true, ownUrl: "https://capturecat.so/best/open-source-screen-recorders" });
    const claude = detail.answers.find((a) => a.engine === "claude")!;
    expect(claude).toMatchObject({ mentioned: false, brands: ["OBS Studio"], queries: ["q"] });
    expect(claude.sources.map((x) => x.domain)).toEqual(["setapp.com"]);
  });

  it("an overloaded provider is retried, but each try spends an attempt and the third ends it", async () => {
    db.query("UPDATE ai_search_questions SET active = 0 WHERE id != 'mac-best'");
    anthropic503 = 99;
    await call("POST", "/admin/ai-search/runs");
    for (let i = 0; i < 3; i++) await processQueue(env, { budgetMs: 60_000, maxJobs: 1000 });
    const claude = db.query("SELECT status, attempts, error FROM ai_search_results WHERE engine = 'claude'");
    expect(claude).toEqual([{ status: "error", attempts: 3, error: "anthropic via AI Gateway HTTP 503" }]);
    // The other engines finished on the first pass.
    expect(db.query("SELECT COUNT(*) AS n FROM ai_search_results WHERE engine != 'claude' AND status = 'ok'")[0]).toEqual({ n: 4 });
  });
});

describe("questions", () => {
  it("creates, edits and validates", async () => {
    const res = await call("POST", "/admin/ai-search/questions", {
      decision: "Pick a Mac screen recorder",
      prompt: "Which Mac screen recorder do indie developers use for launch videos?",
      keyword: "screen recorder for launch video",
      targetPath: "/best/screen-recorder-for-product-demos",
    });
    expect(res.status).toBe(201);
    const { id } = (await res.json()) as { id: string };
    expect((await call("PATCH", `/admin/ai-search/questions/${id}`, { targetPath: null, notes: "no page yet" })).status).toBe(200);
    const q = (await overview()).questions.find((x) => x.id === id)!;
    expect(q).toMatchObject({ targetPath: null, notes: "no page yet", active: true, branded: false });
    expect(q.sort).toBeGreaterThan(930);

    expect((await call("POST", "/admin/ai-search/questions", { decision: "x", prompt: "Which one?", keyword: "k", targetPath: "guides/no-slash" })).status).toBe(400);
    expect((await call("POST", "/admin/ai-search/questions", { decision: "x", prompt: "y".repeat(501), keyword: "k" })).status).toBe(400);
    expect((await call("PATCH", "/admin/ai-search/questions/nope", { active: false })).status).toBe(404);
    expect((await call("PATCH", `/admin/ai-search/questions/${id}`, {})).status).toBe(400);
    expect((await call("PUT", "/admin/ai-search/sources", { key: "Not A Domain", kind: "claim" })).status).toBe(400);
  });
});
