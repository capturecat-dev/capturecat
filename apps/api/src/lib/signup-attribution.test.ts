import { describe, expect, it } from "vitest";
import { signupAttributionFrom, utmSourceOf } from "./signup-attribution";

const req = (country?: string) => ({ cf: country ? { country } : undefined }) as unknown as Request;

describe("signupAttributionFrom", () => {
  it("reads country from Cloudflare geo and validates it", () => {
    expect(signupAttributionFrom(req("DE"), null).country).toBe("DE");
    expect(signupAttributionFrom(req("XX1"), null).country).toBeNull();
    expect(signupAttributionFrom(null, null).country).toBeNull();
  });

  it("marks the Mac app's loopback bridge as desktop", () => {
    const state = { callbackURL: "https://api.capturecat.so/api/desktop/complete?rid=abc" };
    expect(signupAttributionFrom(req("US"), state).via).toBe("desktop");
    expect(signupAttributionFrom(req("US"), { callbackURL: "https://capturecat.so/app" }).via).toBe("web");
  });

  it("re-validates the landing data a browser put in the state", () => {
    const a = signupAttributionFrom(req("GB"), {
      callbackURL: "https://capturecat.so/app",
      ccReferrer: "https://www.claude.ai/chat/123",
      ccUtmSource: "ChatGPT.com",
      ccUtmMedium: "a|b",
      ccLanding: "/share/secret-id",
    });
    expect(a).toEqual({
      country: "GB",
      via: "web",
      referrer: "claude.ai",
      utm: "chatgpt.com|ab|",
      landing: "/share/*",
    });
    expect(utmSourceOf(a.utm)).toBe("chatgpt.com");
  });

  it("drops internal referrers and junk", () => {
    const a = signupAttributionFrom(null, {
      ccReferrer: "https://capturecat.so/pricing",
      ccLanding: "https://evil.example",
      ccUtmSource: 5,
    });
    expect(a.referrer).toBeNull();
    expect(a.landing).toBeNull();
    expect(a.utm).toBeNull();
    expect(utmSourceOf(null)).toBeNull();
  });
});
