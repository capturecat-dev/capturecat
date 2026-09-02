/**
 * Server-side AI proxy. The Gemini key lives ONLY in the Worker
 * (`wrangler secret put GEMINI_API_KEY`) — never in the app binary or
 * client defaults, so it can't be extracted and abused.
 *
 * The app previously kept a `gemini_api_key` in UserDefaults for a since-
 * removed feature; any future AI feature must call this route instead.
 */

import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { requireEntitlement, userRateLimit } from "../lib/entitlement";
import { checkAssertion } from "./attest";

const GEMINI_MODEL = "gemini-2.0-flash";

export const aiRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

/**
 * POST /ai/generate — thin generateContent proxy.
 * Body: { prompt: string, system?: string }
 * Tester/paid only; 20 requests/min per uid.
 */
aiRoutes.post(
  "/ai/generate",
  requireAuth,
  requireEntitlement({ minTier: "tester" }),
  userRateLimit({ limit: 20, windowSec: 60, scope: "ai" }),
  checkAssertion(),
  async (c) => {
    if (!c.env.GEMINI_API_KEY) {
      return c.json({ error: "AI is not configured on this deployment" }, 503);
    }

    const body = await c.req.json<{ prompt?: string; system?: string }>();
    if (!body.prompt || body.prompt.length === 0) {
      return c.json({ error: "prompt is required" }, 400);
    }
    if (body.prompt.length > 32_000) {
      return c.json({ error: "prompt too long" }, 413);
    }
    if (body.system && body.system.length > 8_000) {
      return c.json({ error: "system prompt too long" }, 413);
    }

    const payload: Record<string, unknown> = {
      contents: [{ role: "user", parts: [{ text: body.prompt }] }],
    };
    if (body.system) {
      payload.systemInstruction = { parts: [{ text: body.system }] };
    }

    const upstream = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-goog-api-key": c.env.GEMINI_API_KEY,
        },
        body: JSON.stringify(payload),
      },
    );

    if (!upstream.ok) {
      const detail = await upstream.text();
      console.error(`gemini upstream ${upstream.status}: ${detail.slice(0, 500)}`);
      return c.json({ error: "AI request failed" }, 502);
    }

    const data = (await upstream.json()) as {
      candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>;
    };
    const text = data.candidates?.[0]?.content?.parts
      ?.map((p) => p.text ?? "")
      .join("") ?? "";

    return c.json({ text });
  },
);
