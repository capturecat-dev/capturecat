import { describe, it, expect } from "vitest";
import {
  checkUrlAllowed,
  parseScreenshotParams,
  screenshotGate,
  sessionDailyScreenshotCap,
  DEVICE_PRESETS,
} from "./params";

describe("checkUrlAllowed — SSRF truth table", () => {
  const allowed = [
    "https://example.com",
    "http://example.com/path?q=1",
    "https://sub.deep.example.co.uk",
    "https://8.8.8.8", // public literal IP is fine
    "https://internal-tools.example.com", // 'internal' inside a label ≠ .internal TLD
  ];
  const blocked = [
    "file:///etc/passwd",
    "ftp://example.com",
    "javascript:alert(1)",
    "not a url",
    "http://localhost",
    "http://localhost:8787",
    "http://LOCALHOST",
    "http://foo.localhost",
    "http://0.0.0.0",
    "http://127.0.0.1",
    "http://127.8.9.200",
    "http://10.0.0.5",
    "http://172.16.0.1",
    "http://172.31.255.255",
    "http://192.168.1.1",
    "http://169.254.169.254", // cloud metadata
    "http://100.64.1.2", // CGNAT
    "http://198.18.0.1",
    "http://224.0.0.1",
    "http://[::1]",
    "http://[::]",
    "http://[fe80::1]",
    "http://[fd00::1]",
    "http://[::ffff:127.0.0.1]",
    "http://2130706433", // decimal 127.0.0.1 — WHATWG canonicalizes, we catch
    "http://0x7f000001", // hex 127.0.0.1
    "http://myhost.internal",
    "http://printer.local",
    "http://router.home.arpa",
    "http://user:pass@example.com",
    "http://metadata.google.internal",
  ];

  for (const u of allowed) {
    it(`allows ${u}`, () => expect(checkUrlAllowed(u)).toBeNull());
  }
  for (const u of blocked) {
    it(`blocks ${u}`, () => expect(checkUrlAllowed(u)).not.toBeNull());
  }

  it("applies the operator blocklist to host and subdomains", () => {
    const bl = "corp.example.com, secret.io";
    expect(checkUrlAllowed("https://corp.example.com", bl)?.code).toBe("host_not_allowed");
    expect(checkUrlAllowed("https://a.b.corp.example.com", bl)?.code).toBe("host_not_allowed");
    expect(checkUrlAllowed("https://secret.io/x", bl)?.code).toBe("host_not_allowed");
    expect(checkUrlAllowed("https://notcorp.example.com", bl)).toBeNull();
    expect(checkUrlAllowed("https://mysecret.io", bl)).toBeNull(); // suffix must be label-aligned
  });
});

describe("parseScreenshotParams", () => {
  it("requires url", () => {
    const r = parseScreenshotParams({});
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error.code).toBe("missing_parameter");
  });

  it("applies desktop defaults", () => {
    const r = parseScreenshotParams({ url: "https://example.com" });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.params.viewportWidth).toBe(1440);
    expect(r.params.viewportHeight).toBe(900);
    expect(r.params.deviceScaleFactor).toBe(2);
    expect(r.params.format).toBe("png");
    expect(r.params.fullPage).toBe(false);
    expect(r.params.timeoutMs).toBe(30000);
    expect(r.params.userAgent).toBeNull(); // no preset requested → engine UA
  });

  it("maps device presets to the app's capture profiles", () => {
    for (const [name, preset] of Object.entries(DEVICE_PRESETS)) {
      const r = parseScreenshotParams({ url: "https://example.com", device: name });
      expect(r.ok).toBe(true);
      if (!r.ok) continue;
      expect(r.params.viewportWidth).toBe(preset.width);
      expect(r.params.deviceScaleFactor).toBe(preset.deviceScaleFactor);
      expect(r.params.userAgent).toBe(preset.userAgent);
      expect(r.params.isMobile).toBe(preset.isMobile);
    }
  });

  it("lets explicit viewport override the preset", () => {
    const r = parseScreenshotParams({
      url: "https://example.com",
      device: "mobile",
      viewport_width: "500",
      device_scale_factor: "1",
    });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.params.viewportWidth).toBe(500);
    expect(r.params.viewportHeight).toBe(844); // preset height kept
    expect(r.params.deviceScaleFactor).toBe(1);
  });

  it("accepts string bools from query params and real bools from JSON", () => {
    const q = parseScreenshotParams({ url: "https://e.com", full_page: "true", dark_mode: "1", store: "true" });
    const j = parseScreenshotParams({ url: "https://e.com", full_page: true, dark_mode: true, store: true });
    for (const r of [q, j]) {
      expect(r.ok).toBe(true);
      if (!r.ok) continue;
      expect(r.params.fullPage).toBe(true);
      expect(r.params.darkMode).toBe(true);
      expect(r.params.store).toBe(true);
    }
  });

  it("drops quality for png, keeps it for jpeg/webp, bounds it", () => {
    const png = parseScreenshotParams({ url: "https://e.com", format: "png", quality: "80" });
    if (png.ok) expect(png.params.quality).toBeNull();
    const jpg = parseScreenshotParams({ url: "https://e.com", format: "jpeg", quality: "80" });
    if (jpg.ok) expect(jpg.params.quality).toBe(80);
    expect(parseScreenshotParams({ url: "https://e.com", format: "jpeg", quality: "0" }).ok).toBe(false);
    expect(parseScreenshotParams({ url: "https://e.com", format: "jpeg", quality: "101" }).ok).toBe(false);
    expect(parseScreenshotParams({ url: "https://e.com", format: "gif" }).ok).toBe(false);
  });

  it("bounds delay, timeout, viewport", () => {
    expect(parseScreenshotParams({ url: "https://e.com", delay: "11" }).ok).toBe(false);
    expect(parseScreenshotParams({ url: "https://e.com", delay: "-1" }).ok).toBe(false);
    expect(parseScreenshotParams({ url: "https://e.com", timeout: "0" }).ok).toBe(false);
    expect(parseScreenshotParams({ url: "https://e.com", timeout: "31" }).ok).toBe(false);
    expect(parseScreenshotParams({ url: "https://e.com", viewport_width: "50" }).ok).toBe(false);
    expect(parseScreenshotParams({ url: "https://e.com", viewport_width: "4000" }).ok).toBe(false);
    const ok = parseScreenshotParams({ url: "https://e.com", delay: "3", timeout: "10" });
    if (ok.ok) {
      expect(ok.params.delayMs).toBe(3000);
      expect(ok.params.timeoutMs).toBe(10000);
    }
  });

  it("rejects selectors that could escape the style block", () => {
    expect(parseScreenshotParams({ url: "https://e.com", hide_selectors: ".x} body{display:none" }).ok).toBe(false);
    expect(parseScreenshotParams({ url: "https://e.com", hide_selectors: "<script>" }).ok).toBe(false);
    expect(parseScreenshotParams({ url: "https://e.com", click_selector: "a{b}" }).ok).toBe(false);
    const ok = parseScreenshotParams({ url: "https://e.com", hide_selectors: " .banner , #promo " });
    expect(ok.ok).toBe(true);
    if (ok.ok) expect(ok.params.hideSelectors).toEqual([".banner", "#promo"]);
  });

  it("rejects unknown devices", () => {
    expect(parseScreenshotParams({ url: "https://e.com", device: "tv" }).ok).toBe(false);
  });

  it("parses max_height_multiple within 1–10, null when absent", () => {
    const absent = parseScreenshotParams({ url: "https://e.com" });
    expect(absent.ok && absent.params.maxHeightMultiple === null).toBe(true);
    const four = parseScreenshotParams({ url: "https://e.com", full_page: "true", max_height_multiple: "4" });
    expect(four.ok && four.params.maxHeightMultiple === 4).toBe(true);
    const jsonNum = parseScreenshotParams({ url: "https://e.com", max_height_multiple: 10 });
    expect(jsonNum.ok && jsonNum.params.maxHeightMultiple === 10).toBe(true);
    expect(parseScreenshotParams({ url: "https://e.com", max_height_multiple: "0" }).ok).toBe(false);
    expect(parseScreenshotParams({ url: "https://e.com", max_height_multiple: "11" }).ok).toBe(false);
    expect(parseScreenshotParams({ url: "https://e.com", max_height_multiple: "x" }).ok).toBe(false);
  });
});

describe("screenshotGate — entitlement matrix (mock plan)", () => {
  it("denies when the plan lacks the feature, whatever the tier", () => {
    for (const tier of ["free", "tester", "paid"] as const) {
      const r = screenshotGate({ tier, features: { screenshotApi: false } });
      expect(r.ok).toBe(false);
      if (!r.ok) {
        expect(r.status).toBe(403);
        expect(r.error.code).toBe("upgrade_required");
      }
    }
  });

  it("denies when the feature key is missing entirely (deny-by-default)", () => {
    expect(screenshotGate({ tier: "paid", features: {} }).ok).toBe(false);
  });

  it("allows when the plan grants the feature", () => {
    expect(screenshotGate({ tier: "paid", features: { screenshotApi: true } }).ok).toBe(true);
    expect(screenshotGate({ tier: "tester", features: { screenshotApi: true } }).ok).toBe(true);
  });
});

describe("sessionDailyScreenshotCap — app callers render on every plan", () => {
  it("grants a positive allowance to every tier (free must never be 0)", () => {
    expect(sessionDailyScreenshotCap("free")).toBe(30);
    expect(sessionDailyScreenshotCap("paid")).toBe(500);
    expect(sessionDailyScreenshotCap("tester")).toBe(500);
  });
});
