import { describe, it, expect } from "vitest";
import {
  buildRestBody,
  buildMeasureBody,
  cappedClipHeight,
  measuredHeightFromScrape,
  cacheKey,
  CONTENT_TYPES,
} from "./renderer";
import { buildHideCss, COOKIE_BANNER_SELECTORS, CHAT_WIDGET_SELECTORS } from "./hide-rules";
import { domainCookieSelectors } from "./cookie-rules";
import cookieRules from "./cookie-rules.generated.json";
import { parseScreenshotParams, type ScreenshotParams } from "./params";

function params(overrides: Record<string, unknown> = {}): ScreenshotParams {
  const r = parseScreenshotParams({ url: "https://example.com", ...overrides });
  if (!r.ok) throw new Error(`fixture params invalid: ${r.error.message}`);
  return r.params;
}

describe("buildRestBody — option → engine mapping", () => {
  it("maps the basics", () => {
    const body = buildRestBody(params());
    expect(body.url).toBe("https://example.com");
    expect(body.viewport).toEqual({
      width: 1440,
      height: 900,
      deviceScaleFactor: 2,
      isMobile: false,
      hasTouch: false,
    });
    expect(body.gotoOptions).toEqual({ waitUntil: "networkidle2", timeout: 30000 });
    expect(body.screenshotOptions).toEqual({ type: "png", fullPage: false });
    expect(body.userAgent).toBeUndefined();
    expect(body.addStyleTag).toBeUndefined();
    expect(body.addScriptTag).toBeUndefined();
    expect(body.waitForTimeout).toBeUndefined();
  });

  it("maps device preset UA + mobile flags", () => {
    const body = buildRestBody(params({ device: "mobile" }));
    expect((body.viewport as { isMobile: boolean }).isMobile).toBe(true);
    expect((body.viewport as { deviceScaleFactor: number }).deviceScaleFactor).toBe(3);
    expect(String(body.userAgent)).toContain("iPhone");
  });

  it("maps format/quality/full_page and delay", () => {
    const body = buildRestBody(params({ format: "jpeg", quality: "70", full_page: "true", delay: "2" }));
    expect(body.screenshotOptions).toEqual({ type: "jpeg", fullPage: true, quality: 70 });
    expect(body.waitForTimeout).toBe(2000);
  });

  it("injects one style tag covering banners, chats and user selectors", () => {
    const body = buildRestBody(
      params({ block_cookie_banners: "true", block_chats: "true", hide_selectors: ".promo" }),
    );
    const tags = body.addStyleTag as Array<{ content: string }>;
    expect(tags).toHaveLength(1);
    expect(tags[0].content).toContain("#onetrust-consent-sdk");
    expect(tags[0].content).toContain("#intercom-container");
    expect(tags[0].content).toContain(".promo");
    expect(tags[0].content).toContain("display: none !important");
  });

  it("injects matchMedia overrides for dark_mode / reduced_motion (best effort on REST)", () => {
    const body = buildRestBody(params({ dark_mode: "true", reduced_motion: "true" }));
    const scripts = (body.addScriptTag as Array<{ content: string }>).map((s) => s.content).join("\n");
    expect(scripts).toContain("prefers-color-scheme");
    expect(scripts).toContain("prefers-reduced-motion");
    expect(scripts).toContain("colorScheme = 'dark'");
  });

  it("injects a guarded click for click_selector", () => {
    const body = buildRestBody(params({ click_selector: "#accept" }));
    const scripts = (body.addScriptTag as Array<{ content: string }>).map((s) => s.content).join("\n");
    expect(scripts).toContain('document.querySelector("#accept")?.click()');
  });

  it("has a content type for every format", () => {
    expect(CONTENT_TYPES.png).toBe("image/png");
    expect(CONTENT_TYPES.jpeg).toBe("image/jpeg");
    expect(CONTENT_TYPES.webp).toBe("image/webp");
  });
});

describe("max_height_multiple — measure-then-clip", () => {
  it("buildMeasureBody mirrors the render payload but scrapes html", () => {
    const p = params({
      full_page: "true",
      max_height_multiple: "4",
      block_cookie_banners: "true",
      dark_mode: "true",
      delay: "2",
      device: "mobile",
    });
    const measure = buildMeasureBody(p);
    const shot = buildRestBody(p);
    expect(measure.screenshotOptions).toBeUndefined();
    expect(measure.elements).toEqual([{ selector: "html" }]);
    // The measurement must see the SAME page the screenshot will: hidden
    // banners change the height, dark mode can change layout, delay matters.
    expect(measure.viewport).toEqual(shot.viewport);
    expect(measure.userAgent).toEqual(shot.userAgent);
    expect(measure.addStyleTag).toEqual(shot.addStyleTag);
    expect(measure.addScriptTag).toEqual(shot.addScriptTag);
    expect(measure.waitForTimeout).toEqual(shot.waitForTimeout);
    expect(measure.gotoOptions).toEqual(shot.gotoOptions);
  });

  it("cappedClipHeight = clamp(measured, viewport, N × viewport)", () => {
    const p = params({ full_page: "true", max_height_multiple: "4" }); // desktop 1440×900
    expect(cappedClipHeight(p, 10_000)).toBe(3600); // long page → cap
    expect(cappedClipHeight(p, 2500)).toBe(2500); // mid page → natural height
    expect(cappedClipHeight(p, 400)).toBe(900); // short page → viewport floor
    expect(cappedClipHeight(p, null)).toBe(3600); // failed measure → cap
    expect(cappedClipHeight(p, Number.NaN)).toBe(3600);
  });

  it("measuredHeightFromScrape reads the html element height, null on junk", () => {
    expect(
      measuredHeightFromScrape({ result: [{ results: [{ height: 5029, width: 1440 }], selector: "html" }] }),
    ).toBe(5029);
    expect(measuredHeightFromScrape({ result: [] })).toBeNull();
    expect(measuredHeightFromScrape({ result: [{ results: [{ height: "x" }] }] })).toBeNull();
    expect(measuredHeightFromScrape(null)).toBeNull();
    expect(measuredHeightFromScrape({ result: [{ results: [{ height: 0 }] }] })).toBeNull();
  });

  it("plain full_page (Entire) keeps fullPage semantics untouched", () => {
    const body = buildRestBody(params({ full_page: "true" }));
    expect(body.screenshotOptions).toEqual({ type: "png", fullPage: true });
  });
});

describe("buildHideCss", () => {
  it("returns null when nothing is hidden", () => {
    expect(buildHideCss({ cookieBanners: false, chats: false, extraSelectors: [] })).toBeNull();
  });
  it("includes every curated selector when enabled", () => {
    const css = buildHideCss({ cookieBanners: true, chats: true, extraSelectors: [] })!;
    for (const s of [...COOKIE_BANNER_SELECTORS, ...CHAT_WIDGET_SELECTORS]) {
      expect(css).toContain(s);
    }
  });
  it("includes the EasyList generic block when cookie hiding is on", () => {
    const css = buildHideCss({ cookieBanners: true, chats: false, extraSelectors: [] })!;
    // A converted generic rule from the EasyList Cookie List.
    expect(css).toContain("#onetrust-banner-sdk");
    expect(css).toContain("#CybotCookiebotDialog");
    // And the generated block is large — proves it is the list, not the
    // curated handful.
    expect(css.length).toBeGreaterThan(100_000);
  });
  it("omits the EasyList block when cookie hiding is off", () => {
    const css = buildHideCss({ cookieBanners: false, chats: true, extraSelectors: [] })!;
    expect(css.length).toBeLessThan(10_000);
  });
});

describe("domainCookieSelectors", () => {
  const domainsMap = cookieRules.domains as Record<string, string[]>;
  const anyDomain = Object.keys(domainsMap)[0];
  it("matches the exact domain", () => {
    expect(domainCookieSelectors(anyDomain)).toEqual(domainsMap[anyDomain]);
  });
  it("matches subdomains (AdBlock semantics)", () => {
    expect(domainCookieSelectors(`www.${anyDomain}`)).toEqual(domainsMap[anyDomain]);
    expect(domainCookieSelectors(`a.b.${anyDomain}`)).toEqual(domainsMap[anyDomain]);
  });
  it("does not match suffix-similar hosts", () => {
    expect(domainCookieSelectors(`not${anyDomain}`)).toEqual([]);
  });
  it("is case-insensitive and null-safe", () => {
    expect(domainCookieSelectors(anyDomain.toUpperCase())).toEqual(domainsMap[anyDomain]);
    expect(domainCookieSelectors(null)).toEqual([]);
    expect(domainCookieSelectors("")).toEqual([]);
  });
  it("flows into buildHideCss via host", () => {
    const sel = domainsMap[anyDomain][0];
    const withHost = buildHideCss({
      cookieBanners: true,
      chats: false,
      extraSelectors: [],
      host: `www.${anyDomain}`,
    })!;
    expect(withHost).toContain(sel);
  });
});

describe("cacheKey", () => {
  it("is deterministic for identical options and ignores `store`", async () => {
    const a = await cacheKey(params({ store: "true" }));
    const b = await cacheKey(params({ store: "false" }));
    expect(a).toBe(b);
    expect(a).toMatch(/^[0-9a-f]{32}$/);
  });
  it("differs when any option differs", async () => {
    const a = await cacheKey(params());
    const b = await cacheKey(params({ full_page: "true" }));
    const c = await cacheKey(params({ url: "https://example.org" }));
    expect(new Set([a, b, c]).size).toBe(3);
  });
});
