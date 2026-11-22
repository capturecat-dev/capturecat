/**
 * The pure half of AI search: reading answers, sorting sources, diagnosing
 * losses, run rates, and the engine response parsers.
 */
import { describe, expect, it } from "vitest";
import {
  brandsInText,
  classifySource,
  diagnose,
  isOwnUrl,
  judgeAnswer,
  mentionsCaptureCat,
  runMetrics,
  snapshot,
  suggestKind,
  type EngineSnapshot,
  type ResultLite,
} from "./analyze";
import { collectLinks, engineRoute, parseAnthropic, parseChatGpt, parseGemini, parseGoogle, parseLlmResponse, parseOpenAiResponse, stripTracking } from "./engines";
import type { Env } from "../../types";
import { pageProblems, parseRobots, robotsAllows, visibleWords } from "./page-check";

describe("mentions and brands", () => {
  it("finds CaptureCat in any spelling", () => {
    expect(mentionsCaptureCat("Try CaptureCat for demos")).toBe(true);
    expect(mentionsCaptureCat("capture cat is open source")).toBe(true);
    expect(mentionsCaptureCat("CAPTURECAT")).toBe(true);
    expect(mentionsCaptureCat("captured a cat video")).toBe(false);
  });

  it("lists brands in order of first mention, once each", () => {
    const text = "For tutorials, Camtasia is popular. OBS Studio is free. CaptureCat adds zooms. Camtasia again.";
    expect(brandsInText(text)).toEqual(["Camtasia", "OBS Studio", "CaptureCat"]);
  });

  it("matches short names only with their brand casing", () => {
    expect(brandsInText("Use Kap for GIFs")).toContain("Kap");
    expect(brandsInText("there's a cap on length and kap is lowercase")).not.toContain("Kap");
  });

  it("knows our own URLs", () => {
    expect(isOwnUrl("https://capturecat.so/guides/x")).toBe(true);
    expect(isOwnUrl("https://www.capturecat.so/")).toBe(true);
    expect(isOwnUrl("https://app.capturecat.so/share/abc")).toBe(true);
    expect(isOwnUrl("https://github.com/capturecat-dev/capturecat")).toBe(true);
    expect(isOwnUrl("https://github.com/someone/capturecat")).toBe(false);
    expect(isOwnUrl("https://notcapturecat.so/")).toBe(false);
  });
});

describe("judgeAnswer", () => {
  it("AI: mentioned, cited and ranked", () => {
    const v = judgeAnswer("gemini", {
      model: "m",
      text: "1. ScreenFlow\n2. CaptureCat — free for personal use",
      sources: [{ url: "https://alternativeto.net/x", title: "" }, { url: "https://capturecat.so/best/screen-recorder-for-mac", title: "" }],
      queries: [],
      costUsd: 0,
    });
    expect(v).toMatchObject({ mentioned: true, cited: true, rank: 2, ownUrl: "https://capturecat.so/best/screen-recorder-for-mac" });
  });

  it("AI: ChatGPT's tagged brands lead, and a tagged CaptureCat counts as a mention", () => {
    const v = judgeAnswer("chatgpt", {
      model: null,
      text: "Here are some options.",
      sources: [],
      brands: ["Loom", "Capture Cat"],
      queries: [],
      costUsd: 0,
    });
    expect(v.brands).toEqual(["Loom", "CaptureCat"]);
    expect(v.mentioned).toBe(true);
    expect(v.rank).toBe(2);
  });

  it("Google: organic rank and AI Overview citation", () => {
    const v = judgeAnswer("google", {
      model: null,
      text: "",
      sources: [{ url: "https://a.com/", title: "" }, { url: "https://b.com/", title: "" }, { url: "https://capturecat.so/guides/y", title: "" }],
      overviewSources: [{ url: "https://capturecat.so/guides/y", title: "" }],
      queries: [],
      costUsd: 0,
    });
    expect(v).toMatchObject({ rank: 3, cited: true, mentioned: false, ownUrl: "https://capturecat.so/guides/y" });
  });
});

describe("sources: OWN / CLAIM / EARN / CONTEST", () => {
  it("suggests a kind from the domain", () => {
    expect(suggestKind("capturecat.so")).toBe("own");
    expect(suggestKind("alternativeto.net")).toBe("claim");
    expect(suggestKind("www.producthunt.com".replace(/^www\./, ""))).toBe("claim");
    expect(suggestKind("reddit.com")).toBe("earn");
    expect(suggestKind("techsmith.com")).toBe("competitor");
  });

  it("a recorded decision beats the suggestion; an exact URL beats its domain", () => {
    const decisions = new Map([
      ["reddit.com", { key: "reddit.com", kind: "earn" as const }],
      ["https://blog.example.com/old-review", { key: "https://blog.example.com/old-review", kind: "contest" as const }],
      ["example.com", { key: "example.com", kind: "ignore" as const }],
    ]);
    expect(classifySource("https://old.reddit.com/r/macapps/1", decisions)).toEqual({ kind: "earn", key: "reddit.com", suggested: false });
    expect(classifySource("https://blog.example.com/old-review", decisions).kind).toBe("contest");
    expect(classifySource("https://blog.example.com/other", decisions)).toEqual({ kind: "ignore", key: "example.com", suggested: false });
    expect(classifySource("https://g2.com/products/x", decisions)).toEqual({ kind: "claim", key: null, suggested: true });
  });
});

const lite = (over: Partial<ResultLite>): ResultLite => ({
  runId: "r1", engine: "gemini", status: "ok", finishedAt: "2026-11-09T10:00:00Z",
  mentioned: false, cited: false, rank: null, ownUrl: null, brands: [], error: null, ...over,
});

describe("snapshot", () => {
  it("averages samples and keeps the best rank", () => {
    const s = snapshot([
      lite({ mentioned: true, rank: 3, brands: ["Loom", "CaptureCat"] }),
      lite({ mentioned: true, rank: 1, cited: true, ownUrl: "https://capturecat.so/a", brands: ["CaptureCat", "Loom"] }),
      lite({ mentioned: false, brands: ["Loom", "OBS Studio"] }),
    ])!;
    expect(s.mentionRate).toBeCloseTo(2 / 3);
    expect(s.citationRate).toBeCloseTo(1 / 3);
    expect(s.rank).toBe(1);
    expect(s.topBrands).toEqual(["Loom", "OBS Studio"]);
    expect(s.ownUrl).toBe("https://capturecat.so/a");
  });

  it("all samples failed: no rates, the error surfaces", () => {
    const s = snapshot([lite({ status: "error", mentioned: null, cited: null, error: "DataForSEO: Payment Required." })])!;
    expect(s.ok).toBe(0);
    expect(s.mentionRate).toBeNull();
    expect(s.error).toBe("DataForSEO: Payment Required.");
  });
});

const snap = (over: Partial<EngineSnapshot>): EngineSnapshot => ({
  runId: "r1", checkedAt: null, samples: 1, ok: 1, mentionRate: 0, citationRate: 0, rank: null, ownUrl: null, topBrands: [], error: null, ...over,
});

describe("diagnose", () => {
  const base = { prompt: "Best Mac recorder?", pageProblems: [] as string[] | null, citedSources: [] };

  it("unmeasured until an AI engine answers", () => {
    expect(diagnose({ ...base, targetPath: "/x", snapshots: {} }).status).toBe("unmeasured");
    expect(diagnose({ ...base, targetPath: "/x", snapshots: { google: snap({ rank: 4 }) } }).status).toBe("unmeasured");
  });

  it("missing page when no page targets the question", () => {
    const d = diagnose({ ...base, targetPath: null, snapshots: { gemini: snap({}) } });
    expect(d.status).toBe("losing");
    expect(d.causes.map((c) => c.code)).toEqual(["missing_page"]);
    expect(d.action).toMatch(/Write one page/);
  });

  it("a crawl problem comes first", () => {
    const d = diagnose({ ...base, targetPath: "/x", pageProblems: ["answers HTTP 404"], snapshots: { gemini: snap({}) } });
    expect(d.causes[0]).toEqual({ code: "crawl", detail: "/x: answers HTTP 404" });
    expect(d.action).toMatch(/crawl\/index problem on \/x/);
  });

  it("weak page: not cited, not in Google's top 10 → improve it, don't publish another", () => {
    const d = diagnose({ ...base, targetPath: "/x", snapshots: { gemini: snap({}), google: snap({ rank: 14, mentionRate: null }) } });
    expect(d.causes[0].code).toBe("weak_page");
    expect(d.causes[0].detail).toMatch(/#14/);
    expect(d.action).toMatch(/Improve \/x .* instead of publishing another page/);
  });

  it("weak page: cited but not recommended → rewrite the top", () => {
    const d = diagnose({ ...base, targetPath: "/x", snapshots: { gemini: snap({ mentionRate: 0, citationRate: 1 }) } });
    expect(d.causes[0].code).toBe("weak_page");
    expect(d.action).toMatch(/Rewrite the top of \/x/);
  });

  it("ranks on Google, still not named by AI → third-party sources are the gap", () => {
    const d = diagnose({
      ...base,
      targetPath: "/x",
      snapshots: { chatgpt: snap({}), google: snap({ rank: 3, mentionRate: null }) },
      citedSources: [{ domain: "alternativeto.net", count: 3, kind: "claim" }, { domain: "reddit.com", count: 2, kind: "earn" }],
    });
    expect(d.causes.map((c) => c.code)).toEqual(["third_party"]);
    expect(d.action).toBe("alternativeto.net: Create or claim the CaptureCat listing and keep its facts current.");
  });

  it("winning at half the answers or more", () => {
    const d = diagnose({ ...base, targetPath: "/x", snapshots: { gemini: snap({ mentionRate: 1, citationRate: 1 }), chatgpt: snap({ mentionRate: 0 }) } });
    expect(d.status).toBe("winning");
    expect(d.mentionRate).toBe(0.5);
  });
});

describe("runMetrics", () => {
  it("non-branded only, one vote per question × engine, Google top 10 separately", () => {
    const m = runMetrics(
      [
        { questionId: "q1", engine: "gemini", status: "ok", mentioned: true, cited: false, rank: 1 },
        { questionId: "q1", engine: "gemini", status: "ok", mentioned: false, cited: false, rank: null },
        { questionId: "q2", engine: "gemini", status: "ok", mentioned: false, cited: true, rank: null },
        { questionId: "q2", engine: "gemini", status: "error", mentioned: null, cited: null, rank: null },
        { questionId: "brand", engine: "gemini", status: "ok", mentioned: true, cited: true, rank: 1 },
        { questionId: "q1", engine: "google", status: "ok", mentioned: false, cited: false, rank: 4 },
        { questionId: "q2", engine: "google", status: "ok", mentioned: false, cited: false, rank: 30 },
      ],
      new Set(["brand"]),
    );
    expect(m.mentionRate).toBeCloseTo(0.25); // q1: 1/2, q2: 0/1
    expect(m.citationRate).toBeCloseTo(0.5); // q1: 0, q2: 1
    expect(m.answers).toBe(2);
    expect(m.googleTop10).toBe(0.5);
    expect(m.byEngine.gemini?.answers).toBe(2);
  });
});

describe("engine parsers", () => {
  it("ChatGPT scraper: markdown, cited sources, tagged brands, fan-out queries", () => {
    const a = parseChatGpt(
      {
        model: "gpt-5",
        markdown: "**CaptureCat** and Loom",
        sources: [{ url: "https://capturecat.so/", title: "CaptureCat" }, { url: "https://loom.com/", title: "Loom" }],
        search_results: [{ url: "https://not-cited.example/" }],
        brand_entities: [{ title: "CaptureCat" }, { title: "Loom" }],
        fan_out_queries: ["best mac screen recorder 2026"],
      },
      0.004,
    );
    expect(a.sources.map((s) => s.url)).toEqual(["https://capturecat.so/", "https://loom.com/"]);
    expect(a.brands).toEqual(["CaptureCat", "Loom"]);
    expect(a.queries).toEqual(["best mac screen recorder 2026"]);
    expect(a.costUsd).toBe(0.004);
  });

  it("LLM responses (Perplexity/Claude): section text and annotations", () => {
    const a = parseLlmResponse(
      {
        model_name: "sonar",
        items: [
          { type: "message", sections: [{ type: "text", text: "Use CaptureCat.", annotations: [{ title: "capturecat.so", url: "https://capturecat.so/x" }] }] },
        ],
        search_results: [{ url: "https://other.example/" }],
        fan_out_queries: [],
      },
      0.01,
    );
    expect(a.text).toBe("Use CaptureCat.");
    expect(a.sources.map((s) => s.url)).toEqual(["https://capturecat.so/x"]);
  });

  it("LLM responses with no annotations fall back to the pages it searched", () => {
    const a = parseLlmResponse({ items: [{ type: "message", sections: [{ type: "text", text: "hi" }] }], search_results: [{ url: "https://s.example/a", title: "S" }] }, 0);
    expect(a.sources).toEqual([{ url: "https://s.example/a", title: "S" }]);
  });

  it("Google SERP: organic in rank order, AI Overview references apart", () => {
    const a = parseGoogle(
      {
        items: [
          { type: "organic", rank_group: 2, url: "https://b.example/", title: "B" },
          { type: "ai_overview", markdown: "CaptureCat adds zooms", items: [{ type: "ai_overview_element", references: [{ url: "https://capturecat.so/g", title: "G", source: "CaptureCat" }] }] },
          { type: "organic", rank_group: 1, url: "https://a.example/", title: "A" },
          { type: "people_also_ask", url: "https://ignored.example/" },
        ],
      },
      0.002,
    );
    expect(a.sources.map((s) => s.url)).toEqual(["https://a.example/", "https://b.example/"]);
    expect(a.overviewSources?.map((s) => s.url)).toEqual(["https://capturecat.so/g"]);
    expect(a.text).toBe("CaptureCat adds zooms");
  });

  it("OpenAI Responses (AI Gateway): output text, url citations without utm tags, searches", () => {
    const a = parseOpenAiResponse(
      {
        model: "gpt-5.1-2025-11-13",
        output: [
          { type: "web_search_call", action: { type: "search", queries: ["best mac screen recorder 2026"], query: "best mac screen recorder 2026" } },
          {
            type: "message",
            content: [
              {
                type: "output_text",
                text: "CaptureCat and Loom",
                annotations: [
                  { type: "url_citation", url: "https://toolradar.com/guides/x?utm_source=openai", title: "Toolradar" },
                  { type: "url_citation", url: "https://toolradar.com/guides/x?utm_source=openai", title: "Toolradar" },
                  { type: "url_citation", url: "https://capturecat.so/best/screen-recorder-for-mac?utm_source=openai&ref=a", title: "Ours" },
                ],
              },
            ],
          },
        ],
      },
      0.019,
    );
    expect(a.text).toBe("CaptureCat and Loom");
    expect(a.sources.map((s) => s.url)).toEqual(["https://toolradar.com/guides/x", "https://capturecat.so/best/screen-recorder-for-mac?ref=a"]);
    expect(a.queries).toEqual(["best mac screen recorder 2026"]);
    expect(a).toMatchObject({ model: "gpt-5.1-2025-11-13", costUsd: 0.019 });
  });

  it("Anthropic Messages (AI Gateway): text blocks, citations, searches; search results when uncited", () => {
    const a = parseAnthropic(
      {
        model: "claude-sonnet-5-5",
        content: [
          { type: "server_tool_use", name: "web_search", input: { query: "best screen recorder for Mac 2026" } },
          { type: "web_search_tool_result", content: [{ type: "web_search_result", url: "https://setapp.com/a", title: "Setapp" }, { type: "web_search_result", url: "https://b.example/", title: "B" }] },
          { type: "thinking", thinking: "…" },
          { type: "text", text: "There's no single best. " },
          { type: "text", text: "CaptureCat adds zooms.", citations: [{ type: "web_search_result_location", url: "https://setapp.com/a", title: "Setapp", cited_text: "x" }] },
        ],
      },
      0.059,
    );
    expect(a.text).toBe("There's no single best. CaptureCat adds zooms.");
    expect(a.sources).toEqual([{ url: "https://setapp.com/a", title: "Setapp" }]);
    expect(a.queries).toEqual(["best screen recorder for Mac 2026"]);
    const uncited = parseAnthropic({ content: [{ type: "web_search_tool_result", content: [{ type: "web_search_result", url: "https://b.example/", title: "B" }] }, { type: "text", text: "hi" }] }, 0);
    expect(uncited.sources.map((s) => s.url)).toEqual(["https://b.example/"]);
  });

  it("Gemini: text, grounding links (domain as the label), searches; an ungrounded answer has none", () => {
    const a = parseGemini(
      {
        modelVersion: "gemini-3.8-flash",
        candidates: [{
          content: { parts: [{ text: "Use " }, { text: "CaptureCat", thoughtSignature: "x" }] },
          groundingMetadata: { webSearchQueries: ["q1"], groundingChunks: [{ web: { uri: "https://vertexaisearch.cloud.google.com/grounding-api-redirect/a", title: "Setapp", domain: "setapp.com" } }] },
        }],
      },
      0.005,
    );
    expect(a).toMatchObject({ model: "gemini-3.8-flash", text: "Use CaptureCat", queries: ["q1"], costUsd: 0.005 });
    expect(a.sources).toEqual([{ url: "https://vertexaisearch.cloud.google.com/grounding-api-redirect/a", title: "setapp.com" }]);
    expect(parseGemini({ candidates: [{ content: { parts: [{ text: "From memory." }] } }] }, 0).sources).toEqual([]);
  });

  it("stripTracking drops utm tags only", () => {
    expect(stripTracking("https://a.example/x?utm_source=openai&utm_medium=y&id=3#h")).toBe("https://a.example/x?id=3#h");
    expect(stripTracking("not a url")).toBe("not a url");
  });

  it("routes: DataForSEO for the consumer apps when set, else AI Gateway, else a direct Gemini key", () => {
    const ai = {} as Ai;
    const none = {} as Env;
    expect(["chatgpt", "gemini", "perplexity", "claude", "google"].map((e) => engineRoute(none, e as never))).toEqual([null, null, null, null, null]);
    expect(engineRoute({ GEMINI_API_KEY: "k" } as Env, "gemini")?.via).toBe("gemini-key");
    const gw = { AI: ai, GEMINI_API_KEY: "k" } as Env;
    expect(engineRoute(gw, "gemini")?.via).toBe("gateway");
    expect(engineRoute(gw, "chatgpt")).toEqual({ via: "gateway", label: "OpenAI gpt-5.1 + web search, via AI Gateway" });
    expect(engineRoute(gw, "claude")?.via).toBe("gateway");
    expect(engineRoute(gw, "perplexity")).toBeNull();
    expect(engineRoute(gw, "google")).toBeNull();
    const both = { AI: ai, DATAFORSEO_LOGIN: "l", DATAFORSEO_PASSWORD: "p" } as Env;
    expect(engineRoute(both, "chatgpt")?.via).toBe("dataforseo");
    expect(engineRoute(both, "claude")?.via).toBe("dataforseo");
    expect(engineRoute(both, "gemini")?.via).toBe("gateway");
    expect(engineRoute(both, "perplexity")?.via).toBe("dataforseo");
  });

  it("collectLinks skips non-http links", () => {
    expect(collectLinks({ sources: [{ url: "javascript:alert(1)" }, { url: "https://ok.example/" }] }, "sources")).toEqual([
      { url: "https://ok.example/", title: "" },
    ]);
  });
});

describe("page checks", () => {
  const robots = parseRobots(`
User-agent: *
Allow: /
Disallow: /app
Disallow: /api/

User-agent: GPTBot
User-agent: PerplexityBot
Disallow: /guides/
Allow: /guides/public$
`);

  it("robots.txt: own group over *, longest rule wins, $ anchors", () => {
    expect(robotsAllows(robots, "Googlebot", "/guides/x")).toBe(true);
    expect(robotsAllows(robots, "Googlebot", "/app/settings")).toBe(false);
    expect(robotsAllows(robots, "PerplexityBot", "/guides/x")).toBe(false);
    expect(robotsAllows(robots, "perplexitybot", "/guides/public")).toBe(true);
    expect(robotsAllows(robots, "GPTBot", "/guides/public/more")).toBe(false);
    expect(robotsAllows(robots, "GPTBot", "/pricing")).toBe(true);
  });

  it("flags status, noindex, canonical, sitemap, robots and thin pages", () => {
    const words = Array.from({ length: 400 }, (_, i) => `w${i}`).join(" ");
    const good = `<html><head><link rel="canonical" href="https://capturecat.so/guides/x"/></head><body><p>${words}</p></body></html>`;
    expect(pageProblems({ path: "/guides/x", status: 200, html: good, inSitemap: true, robots: parseRobots("User-agent: *\nAllow: /") }).problems).toEqual([]);

    const bad = `<html><head><meta name="robots" content="noindex, follow"><link rel="canonical" href="https://capturecat.so/other"></head><body><script>var a = "lots of words here";</script>short page</body></html>`;
    const p = pageProblems({ path: "/guides/x", status: 200, html: bad, xRobotsTag: null, inSitemap: false, robots }).problems;
    expect(p).toEqual([
      "robots meta tag says noindex",
      "canonical points to https://capturecat.so/other",
      "thin: 2 words",
      "not in sitemap.xml",
      "robots.txt blocks PerplexityBot",
    ]);
    expect(pageProblems({ path: "/x", status: 301, location: "https://capturecat.so/y", inSitemap: null, robots: null }).problems).toEqual([
      "redirects (301) to https://capturecat.so/y",
    ]);
    expect(pageProblems({ path: "/", status: null, inSitemap: null, robots: null }).problems).toEqual(["couldn't be fetched"]);
  });

  it("counts visible words only", () => {
    expect(visibleWords("<body><style>a{b:c}</style><h1>Hello world</h1><svg><text>no</text></svg> &amp; more</body>")).toBe(3);
  });
});
