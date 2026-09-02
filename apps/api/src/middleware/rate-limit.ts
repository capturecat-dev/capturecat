/**
 * Simple rate limiter using Cloudflare Cache API as a counter store.
 * No external dependencies — runs entirely on the edge.
 */

import { createMiddleware } from "hono/factory";
import type { Env } from "../types";

interface RateLimitOptions {
  /** Max requests per window */
  limit: number;
  /** Window size in seconds */
  windowSec: number;
  /** Key prefix to namespace different limiters */
  prefix?: string;
}

function getClientIP(request: Request): string {
  return request.headers.get("CF-Connecting-IP") ?? "unknown";
}

export function rateLimit(options: RateLimitOptions) {
  return createMiddleware<{ Bindings: Env }>(async (c, next) => {
    const ip = getClientIP(c.req.raw);
    const prefix = options.prefix ?? "rl";
    const windowId = Math.floor(Date.now() / 1000 / options.windowSec);
    const cacheKey = new Request(
      `https://rate-limit.internal/${prefix}/${ip}/${windowId}`
    );

    const cache = caches.default;
    const cached = await cache.match(cacheKey);

    let count = 0;
    if (cached) {
      count = parseInt(await cached.text(), 10);
    }

    if (count >= options.limit) {
      return c.json(
        { error: "Too many requests" },
        { status: 429, headers: { "Retry-After": String(options.windowSec) } }
      );
    }

    // Increment counter
    count++;
    const response = new Response(String(count), {
      headers: {
        "Cache-Control": `s-maxage=${options.windowSec}`,
      },
    });
    await cache.put(cacheKey, response);

    // Set rate limit headers
    c.header("X-RateLimit-Limit", String(options.limit));
    c.header("X-RateLimit-Remaining", String(options.limit - count));

    await next();
  });
}
