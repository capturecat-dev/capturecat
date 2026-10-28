import { describe, expect, it } from "vitest";

import { appHostInput, appHostOutput } from "./app-host-rewrite";

const input = (href: string) => appHostInput(new URL(href))?.pathname ?? null;
const output = (href: string) => appHostOutput(new URL(href))?.pathname ?? null;

describe("app.capturecat.so clean URLs", () => {
  it("maps clean paths onto the internal /app routes — including ones that merely START with 'app'", () => {
    expect(input("https://app.capturecat.so/")).toBe("/app");
    expect(input("https://app.capturecat.so/billing")).toBe("/app/billing");
    expect(input("https://app.capturecat.so/approvals/apr_123")).toBe("/app/approvals/apr_123");
  });
  it("leaves the internal prefix, the API, login and OAuth alone, and other hosts untouched", () => {
    expect(input("https://app.capturecat.so/app/settings")).toBeNull();
    expect(input("https://app.capturecat.so/app")).toBeNull();
    expect(input("https://app.capturecat.so/api/trpc")).toBeNull();
    expect(input("https://app.capturecat.so/login")).toBeNull();
    expect(input("https://app.capturecat.so/oauth/authorize")).toBeNull();
    expect(input("https://capturecat.so/approvals/apr_123")).toBeNull();
  });
  it("strips the prefix from generated links, and only a real /app prefix", () => {
    expect(output("https://app.capturecat.so/app/approvals/apr_123")).toBe("/approvals/apr_123");
    expect(output("https://app.capturecat.so/app")).toBe("/");
    expect(output("https://app.capturecat.so/approvals/apr_123")).toBeNull();
  });
});
