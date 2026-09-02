/**
 * Server entry. Unlike apps/web, the admin console serves a single host
 * (admin.capturecat.so) — no host-rewrite or legacy-redirect logic needed.
 */
import {
  createStartHandler,
  defaultStreamHandler,
} from "@tanstack/react-start/server";
import { createServerEntry } from "@tanstack/react-start/server-entry";

const startHandler = createStartHandler({ handler: defaultStreamHandler });

export default createServerEntry({
  async fetch(request: Request) {
    // The admin console is never legitimately framed.
    const response = await startHandler(request);
    const headers = new Headers(response.headers);
    headers.set("X-Frame-Options", "DENY");
    headers.set("Content-Security-Policy", "frame-ancestors 'none'");
    headers.set("X-Content-Type-Options", "nosniff");
    headers.set("Referrer-Policy", "strict-origin-when-cross-origin");
    return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
  },
});
