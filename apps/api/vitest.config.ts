import { defineConfig } from "vitest/config";

// Plain Node pool on purpose: everything under test is a PURE module
// (src/lib/screenshot/*) using only Web Crypto + URL, both native in Node.
// The Workers-runtime pieces — the Hono routes, D1, R2, and above all the
// Browser Rendering REST call — cannot run here at all; live verification is
// `wrangler dev` (with real CF_ACCOUNT_ID/BROWSER_RENDERING_TOKEN in
// .dev.vars) against a NON-prod target, never `wrangler deploy` from a test.
//
// Exception by construction: src/routes/cloud-projects.test.ts drives a Hono
// router in Node against the REAL migrations/SQL through node:sqlite
// (src/test-support/d1-sqlite.js, Node ≥ 22.5), with the session and the S3
// presigner mocked and R2 in memory — it never reaches Cloudflare.
export default defineConfig({
  test: {
    include: ["src/**/*.test.ts"],
    environment: "node",
  },
});
