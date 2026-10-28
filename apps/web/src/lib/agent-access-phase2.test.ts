import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import {
  ASK_FIRST_TOOLS,
  MCP_TOOLS,
  OAUTH_PARAMS,
  WEBHOOK_EVENTS,
  WEBHOOK_EVENT_LABELS,
  approvalAction,
  minutesLeft,
  requesterName,
  webhookUrlProblem,
} from "./agent-access";

const api = (file: string) => readFileSync(fileURLToPath(new URL(`../../../api/src/${file}`, import.meta.url)), "utf8");
const strings = (block: string | undefined) => [...(block ?? "").matchAll(/"([^"]+)"/g)].map((m) => m[1]);

describe("phase 2 drift guards", () => {
  it("webhook events match the API (apps/api/src/lib/webhooks.ts)", () => {
    const block = /export const WEBHOOK_EVENTS = \[([\s\S]*?)\] as const;/.exec(api("lib/webhooks.ts"))?.[1];
    expect(strings(block)).toEqual([...WEBHOOK_EVENTS]);
    for (const e of WEBHOOK_EVENTS) expect(WEBHOOK_EVENT_LABELS[e].label).toBeTruthy();
  });

  it("the consent page forwards exactly the parameters the API validates (lib/oauth/authorize.ts)", () => {
    const block = /export const AUTHORIZE_PARAM_NAMES = \[([\s\S]*?)\] as const;/.exec(api("lib/oauth/authorize.ts"))?.[1];
    expect(strings(block)).toEqual([...OAUTH_PARAMS]);
  });

  it("ask-first tools are real tools, and the API gates them (an `approval` hook)", () => {
    const source = api("mcp/tools.ts");
    for (const name of ASK_FIRST_TOOLS) {
      expect(MCP_TOOLS.map((t) => t.name)).toContain(name);
      const def = new RegExp(`name: "${name}",[\\s\\S]*?async approval\\(`).exec(source);
      expect(def, `${name} has no approval hook`).toBeTruthy();
    }
  });
});

describe("helpers", () => {
  it("webhookUrlProblem mirrors the API's SSRF guard for instant feedback", () => {
    expect(webhookUrlProblem("https://hooks.example.com/x")).toBeNull();
    expect(webhookUrlProblem("http://hooks.example.com/x")).toContain("https");
    expect(webhookUrlProblem("https://10.0.0.1/x")).toContain("IP address");
    expect(webhookUrlProblem("https://[::1]/x")).toContain("IP address");
    expect(webhookUrlProblem("https://localhost/x")).toContain("public internet");
    expect(webhookUrlProblem("https://printer.local/x")).toContain("public internet");
    expect(webhookUrlProblem("not a url")).toContain("full URL");
  });

  it("names the requester and the action", () => {
    const base = { requester: { tokenName: "Claude Code", tokenPrefix: "cc_pat_x", kind: "personal" as const, oauthClient: null } };
    expect(requesterName(base)).toBe("Claude Code");
    expect(
      requesterName({
        requester: { ...base.requester, kind: "oauth", oauthClient: { clientId: "c", name: "ChatGPT", logoUri: null, clientUri: null } },
      }),
    ).toBe("ChatGPT");
    expect(approvalAction("post_comment")).toBe("Post a comment");
    expect(approvalAction("update_share_settings")).toBe("Make a video more visible");
  });

  it("minutesLeft counts down to expired", () => {
    const now = new Date("2026-10-28T12:00:00.000Z");
    expect(minutesLeft("2026-10-28T12:14:30.000Z", now)).toBe("expires in 15 min");
    expect(minutesLeft("2026-10-28T11:59:00.000Z", now)).toBe("expired");
  });
});
