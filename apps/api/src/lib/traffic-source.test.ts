import { describe, expect, it } from "vitest";
import {
  bareHost,
  classifySource,
  deviceFromUserAgent,
  externalReferrerHost,
  isBotUserAgent,
  normalizeLandingPath,
} from "./traffic-source";

const id = (host: string | null, utm: string | null = null) => classifySource(host, utm).id;

describe("classifySource", () => {
  it("recognises AI assistants by referrer and by utm tag", () => {
    expect(id("chatgpt.com")).toBe("chatgpt");
    expect(id("chat.openai.com")).toBe("chatgpt");
    expect(id(null, "chatgpt.com")).toBe("chatgpt");
    expect(id("claude.ai")).toBe("claude");
    expect(id("www.perplexity.ai".replace("www.", ""))).toBe("perplexity");
    expect(id("copilot.microsoft.com")).toBe("copilot");
    expect(classifySource("claude.ai", null).kind).toBe("ai");
  });

  it("puts Gemini ahead of Google search and Gmail outside it", () => {
    expect(id("gemini.google.com")).toBe("gemini");
    expect(id("mail.google.com")).toBe("gmail");
    expect(id("google.com")).toBe("google");
    expect(id("google.co.uk")).toBe("google");
    expect(id("google.com.au")).toBe("google");
    expect(id("com.google.android.googlequicksearchbox")).toBe("google");
    expect(classifySource("google.de", null).kind).toBe("search");
  });

  it("matches subdomains of a rule's host", () => {
    expect(id("l.facebook.com")).toBe("facebook");
    expect(id("out.reddit.com")).toBe("reddit");
    expect(id("m.youtube.com")).toBe("youtube");
    expect(id("t.co")).toBe("x");
  });

  it("lets a recognised utm tag beat the referrer", () => {
    expect(id("google.com", "chatgpt.com")).toBe("chatgpt");
  });

  it("falls back to campaign, then referral host, then direct", () => {
    expect(classifySource("reddit.com", "spring-launch")).toMatchObject({ id: "reddit" });
    expect(classifySource(null, "Newsletter")).toEqual({ id: "utm:newsletter", label: "newsletter", kind: "campaign" });
    expect(classifySource("someblog.dev", null)).toEqual({ id: "someblog.dev", label: "someblog.dev", kind: "referral" });
    expect(classifySource(null, null).kind).toBe("direct");
    expect(classifySource("", "  ").kind).toBe("direct");
  });

  it("does not treat lookalike hosts as the real channel", () => {
    expect(id("notclaude.ai")).toBe("notclaude.ai");
    expect(id("google.example.com")).toBe("google.example.com");
  });
});

describe("externalReferrerHost", () => {
  it("strips www and returns only the host", () => {
    expect(externalReferrerHost("https://www.google.com/search?q=secret")).toBe("google.com");
    expect(bareHost("claude.ai")).toBe("claude.ai");
  });

  it("drops our own origins and sign-in / checkout round trips", () => {
    expect(externalReferrerHost("https://capturecat.so/pricing")).toBeNull();
    expect(externalReferrerHost("https://api.capturecat.so/")).toBeNull();
    expect(externalReferrerHost("https://accounts.google.com/")).toBeNull();
    expect(externalReferrerHost("https://checkout.stripe.com/c/pay/x")).toBeNull();
    expect(externalReferrerHost("http://localhost:3200/")).toBeNull();
  });

  it("returns null for empty or garbled input", () => {
    expect(externalReferrerHost("")).toBeNull();
    expect(externalReferrerHost(null)).toBeNull();
    expect(externalReferrerHost("http://")).toBeNull();
  });
});

describe("normalizeLandingPath", () => {
  it("collapses capability ids and drops the query", () => {
    expect(normalizeLandingPath("/share/abc123?t=1")).toBe("/share/*");
    expect(normalizeLandingPath("/embed/xyz")).toBe("/embed/*");
    expect(normalizeLandingPath("/pricing/?utm_source=x")).toBe("/pricing");
    expect(normalizeLandingPath("/")).toBe("/");
  });

  it("rejects non-paths", () => {
    expect(normalizeLandingPath("https://evil.example/")).toBeNull();
    expect(normalizeLandingPath(42)).toBeNull();
  });
});

describe("user agents", () => {
  it("maps platforms, iOS before Mac", () => {
    expect(deviceFromUserAgent("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)")).toBe("ios");
    expect(deviceFromUserAgent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")).toBe("mac");
    expect(deviceFromUserAgent("Mozilla/5.0 (Windows NT 10.0; Win64; x64)")).toBe("windows");
    expect(deviceFromUserAgent("Mozilla/5.0 (Linux; Android 15)")).toBe("android");
  });

  it("flags crawlers and scripts", () => {
    expect(isBotUserAgent("Mozilla/5.0 (compatible; Googlebot/2.1)")).toBe(true);
    expect(isBotUserAgent("Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2)")).toBe(true);
    expect(isBotUserAgent("curl/8.7.1")).toBe(true);
    expect(isBotUserAgent("Mozilla/5.0 HeadlessChrome/131.0")).toBe(true);
    expect(isBotUserAgent("")).toBe(true);
    expect(isBotUserAgent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15")).toBe(false);
  });
});
