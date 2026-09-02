import { defineConfig } from "vitest/config";

// Plain Node pool on purpose: everything under test is a PURE module
// (src/lib/screenshot/*) using only Web Crypto + URL, both native in Node.
// The Workers-runtime pieces — the Hono routes, D1, R2, and above all the
// Browser Rendering REST call — cannot run here at all; live verification is
// `wrangler dev` (with real CF_ACCOUNT_ID/BROWSER_RENDERING_TOKEN in
// .dev.vars) against a NON-prod target, never `wrangler deploy` from a test.
export default defineConfig({
  test: {
    include: ["src/**/*.test.ts"],
    environment: "node",
  },
});
